#!/usr/bin/env bash
# Set up a GCP service account with the minimal permissions required for
# Microsoft Fabric to mirror a BigQuery dataset into OneLake.
#
# Usage:
#   ./setup_bigquery_service_account.sh <PROJECT_ID> <DATASET_ID> <SERVICE_ACCOUNT_NAME>
#
# This script:
#   1. Creates a service account with the specified name
#   2. Creates a custom IAM role with exactly the permissions Fabric mirroring needs
#   3. Binds the custom role to the service account at project level
#   4. Creates the required GCS staging bucket (<project_id>_fabric_staging_bucket)
#      in the same region as the BigQuery dataset
#   5. Grants the service account Storage Admin access on the staging bucket
#   6. Enables change history on every table in the dataset (required for CDC)
#   7. Generates a JSON key file for the service account
#   8. Prints the Fabric connection parameters you need to enter in the UI
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)
#   - bq CLI available (ships with gcloud SDK)
#
# Example:
#   ./setup_bigquery_service_account.sh gen-lang-client-0875336337 nyc_taxi svc-fabric-bq-mirror

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <PROJECT_ID> <DATASET_ID> <SERVICE_ACCOUNT_NAME>"
  echo ""
  echo "  PROJECT_ID           - Your GCP project ID"
  echo "  DATASET_ID           - BigQuery dataset to mirror (e.g. nyc_taxi)"
  echo "  SERVICE_ACCOUNT_NAME - Name for the new service account (e.g. svc-fabric-bq-mirror)"
  exit 1
fi

PROJECT_ID="$1"
DATASET_ID="$2"
SA_NAME="$3"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CUSTOM_ROLE_ID="FabricBigQueryMirror"
KEY_FILE="${SA_NAME}-key.json"

# ── 1. Set project ──────────────────────────────────────────────────────────
echo "=== Setting project to ${PROJECT_ID} ==="
gcloud config set project "${PROJECT_ID}"

# ── 2. Discover dataset location ────────────────────────────────────────────
echo ""
echo "=== Discovering dataset location for ${DATASET_ID} ==="
DATASET_LOCATION=$(bq show --format=json "${PROJECT_ID}:${DATASET_ID}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['location'])")
echo "  Dataset location: ${DATASET_LOCATION}"

STAGING_BUCKET="${PROJECT_ID}_fabric_staging_bucket"

# ── 3. Create service account ───────────────────────────────────────────────
echo ""
echo "=== Creating service account: ${SA_NAME} ==="
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Fabric BigQuery Mirror" \
  --description="Service account for Microsoft Fabric to mirror BigQuery datasets into OneLake" \
  2>/dev/null || echo "  (Service account may already exist, continuing...)"

# ── 4. Create custom IAM role with minimal Fabric mirroring permissions ─────
echo ""
echo "=== Creating custom IAM role: ${CUSTOM_ROLE_ID} ==="

# Check role state: active, soft-deleted, or absent.
# Use --show-deleted because `describe` returns an error for soft-deleted roles,
# making it impossible to distinguish "deleted" from "never existed".
ROLE_FULL_NAME="projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}"
ROLE_CSV=$(gcloud iam roles list --project="${PROJECT_ID}" \
  --show-deleted \
  --filter="name=${ROLE_FULL_NAME}" \
  --format="csv[no-heading](name,deleted)" 2>/dev/null)
# ROLE_CSV is empty if role doesn't exist, otherwise "name," (active) or "name,True" (soft-deleted)

if [ -z "${ROLE_CSV}" ]; then
  ROLE_STATE="NOT_FOUND"
elif echo "${ROLE_CSV}" | grep -q ",True"; then
  ROLE_STATE="DELETED"
else
  ROLE_STATE="ACTIVE"
fi

ROLE_YAML=$(cat <<YAML
title: "Fabric BigQuery Mirror"
description: "Minimal permissions for Microsoft Fabric to mirror a BigQuery dataset into OneLake"
stage: "GA"
includedPermissions:
  # Dataset and project discovery
  - bigquery.datasets.get
  - resourcemanager.projects.get
  # Table metadata and change history configuration
  - bigquery.tables.get
  - bigquery.tables.list
  - bigquery.routines.get
  - bigquery.routines.list
  # Read change history and table data
  - bigquery.tables.getData
  - bigquery.jobs.create
  - bigquery.jobs.get
  - bigquery.jobs.list
  - bigquery.readsessions.create
  - bigquery.readsessions.getData
  # Export data to GCS staging bucket
  - bigquery.tables.export
  - storage.objects.create
  - storage.objects.list
  - storage.objects.delete
  - storage.buckets.get
  - storage.buckets.list
  # Sign blobs for GCS access
  - iam.serviceAccounts.signBlob
YAML
)

ROLE_FILE=$(mktemp /tmp/fabric-bq-role-XXXXXX.yaml)
echo "${ROLE_YAML}" > "${ROLE_FILE}"

if [ "${ROLE_STATE}" = "DELETED" ]; then
  # Role exists but is soft-deleted (within GCP's 7-day retention window).
  # Undelete it first, then apply the latest permissions via update.
  echo "  Role is soft-deleted — undeleting..."
  gcloud iam roles undelete "${CUSTOM_ROLE_ID}" --project="${PROJECT_ID}" --quiet
  echo "  Updating role permissions..."
  gcloud iam roles update "${CUSTOM_ROLE_ID}" \
    --project="${PROJECT_ID}" \
    --file="${ROLE_FILE}" \
    2>/dev/null || echo "  (Role update skipped — already up to date)"
  echo "  Role restored and updated."
elif [ "${ROLE_STATE}" = "NOT_FOUND" ]; then
  gcloud iam roles create "${CUSTOM_ROLE_ID}" \
    --project="${PROJECT_ID}" \
    --file="${ROLE_FILE}"
  echo "  Created new role."
else
  # Role exists and is active — just update permissions
  gcloud iam roles update "${CUSTOM_ROLE_ID}" \
    --project="${PROJECT_ID}" \
    --file="${ROLE_FILE}" \
    2>/dev/null || echo "  (Role update skipped — already up to date)"
  echo "  Updated existing role."
fi
rm -f "${ROLE_FILE}"

# ── 5. Bind custom role to service account at project level ─────────────────
echo ""
echo "=== Binding role projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID} to ${SA_EMAIL} ==="
echo "  Waiting 15s for IAM propagation after role creation..."
sleep 15

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}" \
  --condition=None \
  --quiet

# ── 6. Create the GCS staging bucket ────────────────────────────────────────
echo ""
echo "=== Creating staging bucket: gs://${STAGING_BUCKET} (${DATASET_LOCATION}) ==="
gcloud storage buckets create "gs://${STAGING_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${DATASET_LOCATION}" \
  --uniform-bucket-level-access \
  2>/dev/null || echo "  (Bucket may already exist, continuing...)"

# Grant Storage Admin on the staging bucket to the service account
echo "  Granting roles/storage.admin on gs://${STAGING_BUCKET} to ${SA_EMAIL}..."
gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.admin"

# ── 7. Enable change history on all tables in the dataset ───────────────────
echo ""
echo "=== Enabling change history on tables in ${DATASET_ID} ==="
TABLES=$(bq ls --format=json "${PROJECT_ID}:${DATASET_ID}" \
  | python3 -c "
import json, sys
tables = json.load(sys.stdin)
for t in tables:
    if t.get('type') == 'TABLE':
        print(t['tableReference']['tableId'])
")

for TABLE in ${TABLES}; do
  echo "  Enabling change history on ${DATASET_ID}.${TABLE}..."
  bq query \
    --project_id="${PROJECT_ID}" \
    --use_legacy_sql=false \
    --nouse_cache \
    "ALTER TABLE \`${PROJECT_ID}.${DATASET_ID}.${TABLE}\`
     SET OPTIONS (enable_change_history = TRUE);" \
    2>/dev/null && echo "    Done." || echo "    (May already be enabled or table doesn't support it, continuing...)"
done

# ── 8. Generate JSON key file ────────────────────────────────────────────────
echo ""
echo "=== Generating service account JSON key file ==="
if [ -f "${KEY_FILE}" ]; then
  echo "  WARNING: ${KEY_FILE} already exists — overwriting."
  rm -f "${KEY_FILE}"
fi
gcloud iam service-accounts keys create "${KEY_FILE}" \
  --iam-account="${SA_EMAIL}"
echo "  Key saved to: ${KEY_FILE}"

# ── 9. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " Setup complete — Fabric connection parameters"
echo "================================================================"
echo ""
echo " GCP Project ID:          ${PROJECT_ID}"
echo " BigQuery Dataset:        ${DATASET_ID}"
echo " Dataset Location:        ${DATASET_LOCATION}"
echo " Service Account Email:   ${SA_EMAIL}"
echo " JSON Key File:           ${KEY_FILE}"
echo " GCS Staging Bucket:      ${STAGING_BUCKET}"
echo ""
echo " To configure the Google BigQuery connection in Fabric:"
echo "   1. Go to your Fabric workspace > Settings > Connections"
echo "      (or from the 'New connection' dialog when creating the mirrored DB)"
echo "   2. Choose 'Google BigQuery'"
echo "   3. Enter the following:"
echo "      - Service Account Email:    ${SA_EMAIL}"
echo "      - Service Account JSON key: paste the full contents of ${KEY_FILE}"
echo ""
echo " To create the Mirrored Database in Fabric:"
echo "   1. In your workspace, select New > Mirrored Google BigQuery"
echo "   2. Select the connection you just created"
echo "   3. Choose project '${PROJECT_ID}' and dataset '${DATASET_ID}'"
echo "   4. Note the mirrored database item ID (from the URL after creation)"
echo "   5. Update mirroring.yaml with workspace_id and mirrored_database_id"
echo "   6. Run: python setup_bigquery_mirror.py mirroring.yaml --start"
echo ""
echo " IMPORTANT: Keep ${KEY_FILE} secure. Do NOT commit it to source control."
echo "================================================================"
