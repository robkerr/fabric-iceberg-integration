#!/usr/bin/env bash
# Remove a GCP service account and its IAM bindings from a GCS bucket.
# This is the backout/teardown counterpart to setup_gcs_service_account.sh.
#
# Usage:
#   ./remove_gcs_service_account.sh <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
#
# This will:
#   1. Remove the roles/storage.objectAdmin binding from the bucket
#   2. Delete all keys for the service account
#   3. Delete the service account itself
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>"
  echo ""
  echo "  PROJECT_ID           - Your GCP project ID"
  echo "  BUCKET_NAME          - GCS bucket name (without gs:// prefix)"
  echo "  SERVICE_ACCOUNT_NAME - Name of the service account to remove"
  exit 1
fi

PROJECT_ID="$1"
BUCKET_NAME="$2"
SA_NAME="$3"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Setting project to ${PROJECT_ID} ==="
gcloud config set project "${PROJECT_ID}"

echo ""
echo "=== Removing roles/storage.objectAdmin from gs://${BUCKET_NAME} ==="
gcloud storage buckets remove-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" \
  2>/dev/null && echo "  Binding removed." || echo "  (Binding not found or already removed, continuing...)"

echo ""
echo "=== Deleting service account: ${SA_EMAIL} ==="
gcloud iam service-accounts delete "${SA_EMAIL}" --quiet \
  2>/dev/null && echo "  Service account deleted." || echo "  (Service account not found or already deleted.)"

KEY_FILE="${SA_NAME}-key.json"
echo ""
if [ -f "${KEY_FILE}" ]; then
  echo "=== Removing local key file: ${KEY_FILE} ==="
  rm -f "${KEY_FILE}"
  echo "  Deleted."
else
  echo "=== No local key file found (${KEY_FILE}) ==="
fi

echo ""
echo "=== Done ==="
