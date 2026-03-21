# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# --- Shared Platform Resources ---

resource "google_storage_bucket" "genmedia" {
  name                        = "${var.gcp_project_id}-cs-${var.environment}-bucket"
  location                    = var.gcp_region
  uniform_bucket_level_access = true

  cors {
    origin          = ["*"]
    method          = ["GET", "PUT", "POST", "DELETE", "HEAD", "OPTIONS"]
    response_header = ["Content-Type", "Access-Control-Allow-Origin", "x-goog-resumable", "Authorization", "Origin"]
    max_age_seconds = 3600
  }
}

resource "google_service_account" "bucket_reader_sa" {
  account_id   = "cs-${var.environment}-read"
  display_name = "SA for reading GenMedia (${var.environment}) bucket"
}

resource "google_storage_bucket_iam_member" "bucket_viewer_binding" {
  bucket = google_storage_bucket.genmedia.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.bucket_reader_sa.email}"
}

resource "google_storage_bucket_iam_member" "bucket_creator_binding" {
  bucket = google_storage_bucket.genmedia.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.bucket_reader_sa.email}"
}

data "google_project" "project" {
  project_id = var.gcp_project_id
}

# --- Predictable URLs & Environment Variables ---
locals {
  region_code  = join("", [for s in split("-", var.gcp_region) : substr(s, 0, 1)])
  backend_url = "https://${var.backend_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"

  frontend_url = "https://${var.firebase_site_id}.web.app" # Predictable Firebase URL

  backend_env_vars = merge(
    lookup(var.be_env_vars, "common", {}),
    lookup(var.be_env_vars, var.environment, {}),
    {
      "CORS_ORIGINS"           = "[\"${local.frontend_url}\"]"
      "GENMEDIA_BUCKET"        = google_storage_bucket.genmedia.name
      "SIGNING_SA_EMAIL"       = google_service_account.bucket_reader_sa.email
      "BACKEND_URL"            = local.backend_url
      "WORKFLOWS_EXECUTOR_URL" = "${local.backend_url}/api/workflows-executor"
    }
  )
}


# Postgres Database related
# 1. Read the Secret (Created by Bootstrap script)
data "google_secret_manager_secret_version" "db_password" {
  secret  = "creative-studio-db-password"
  project = var.gcp_project_id
  version = "latest"
}

# 2. Call PostgreSQL Module
module "postgresql" {
  source      = "../postgresql"
  project_id  = var.gcp_project_id
  region      = var.gcp_region
  
  # Pass the ACTUAL value to create the user
  db_password = data.google_secret_manager_secret_version.db_password.secret_data
}

# --- Service Module Calls ---
module "backend_service" {
  source = "../cloud-run-service"

  gcp_project_id        = var.gcp_project_id
  gcp_region            = var.gcp_region
  environment           = var.environment
  service_name          = var.backend_service_name
  resource_prefix       = "cs-be"
  container_env_vars    = local.backend_env_vars
  runtime_secrets = var.backend_runtime_secrets
  custom_audiences      = var.backend_custom_audiences
  scaling_min_instances = 1
  cpu = var.be_cpu
  memory = var.be_memory

  # database
  cloud_sql_connection_name = module.postgresql.connection_name
  db_name                   = module.postgresql.db_name
  db_user                   = module.postgresql.db_user
  
  # Pass the Secret ID reference (NOT the value) for Cloud Run
  db_secret_id              = "creative-studio-db-password"
}

resource "google_firebase_project" "default" {
  provider = google-beta
  project = var.gcp_project_id
}

module "frontend_service" {
  source = "../firebase-hosting-service"

  gcp_project_id       = var.gcp_project_id
  gcp_region           = var.gcp_region
  firebase_project_id  = google_firebase_project.default.project
  service_name         = var.gcp_project_id
  environment          = var.environment
  resource_prefix      = "cs-fe"
  firebase_site_id     = var.firebase_site_id != "" ? var.firebase_site_id : var.gcp_project_id
}

module "frontend_secrets" {
  source = "../secret-manager"

  gcp_project_id    = var.gcp_project_id
  secret_names      = var.frontend_secrets
}

module "backend_secrets" {
  source = "../secret-manager"

  gcp_project_id    = var.gcp_project_id
  secret_names      = var.backend_secrets
  accessor_sa_email = module.backend_service.run_sa_email
}

# --- Cross-Module Permissions ---
