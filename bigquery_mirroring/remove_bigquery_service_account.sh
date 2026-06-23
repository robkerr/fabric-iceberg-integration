#!/usr/bin/env bash
# Remove the GCP service account and resources created by setup_bigquery_service_account.sh.
# This is the teardown counterpart for the Fabric BigQuery mirroring setup.
#
# Usage:
#   ./remove_bigquery_service_account.sh <PROJECT_ID> <SERVICE_ACCOUNT_NAME> [OPTIONS]
#
# Options:
#   --delete-bucket   Also delete the GCS staging bucket (prompts for confirmation)
#   --delete-role     Also delete the shared FabricBigQueryMirror custom IAM role.
#                     Only use this if no other service accounts are using the role.
#
# This will:
#   1. Remove the custom IAM role binding from the project
#   2. Delete the service account (also revokes all its keys)
#   3. Optionally delete the GCS staging bucket (--delete-bucket)
#   4. Optionally delete the custom IAM role (--delete-role)
#   5. Delete the local JSON key file if present
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)
#
# Example — remove service account only:
#   ./remove_bigquery_service_account.sh my-project svc-fabric-bq-mirror
#
# Example — full teardown (bucket + role):
#   ./remove_bigquery_service_account.sh my-project svc-fabric-bq-mirror --delete-bucket --delete-role

set -euo pipefail

DELETE_BUCKET=false
DELETE_ROLE=false
POSITIONAL=()

for arg in "$@"; do
  case "${arg}" in
    --delete-bucket) DELETE_BUCKET=true ;;
    --delete-role)   DELETE_ROLE=true ;;
    *) POSITIONAL+=("${arg}") ;;
  esac
done

if [ "${#POSITIONAL[@]}" -lt 2 ]; then
  echo "Usage: $0 <PROJECT_ID> <SERVICE_ACCOUNT_NAME> [--delete-bucket] [--delete-role]"
  echo ""
  echo "  PROJECT_ID           - Your GCP project ID"
  echo "  SERVICE_ACCOUNT_NAME - Name of the service account to remove"
  echo "  --delete-bucket      - Also delete the GCS staging bucket"
  echo "  --delete-role        - Also delete the shared FabricBigQueryMirror IAM role"
  echo "                         (only if no other service accounts are using it)"
  exit 1
fi

PROJECT_ID="${POSITIONAL[0]}"
SA_NAME="${POSITIONAL[1]}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CUSTOM_ROLE_ID="FabricBigQueryMirror"
STAGING_BUCKET="${PROJECT_ID}_fabric_staging_bucket"
KEY_FILE="${SA_NAME}-key.json"

echo "=== Setting project to ${PROJECT_ID} ==="
gcloud config set project "${PROJECT_ID}"

# ── 1. Remove custom role binding ───────────────────────────────────────────
echo ""
echo "=== Removing IAM role binding: projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID} ==="
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}" \
  --quiet \
  2>/dev/null && echo "  Binding removed." || echo "  (Binding not found or already removed, continuing...)"

# ── 2. Delete service account (also revokes all its keys) ───────────────────
echo ""
echo "=== Deleting service account: ${SA_EMAIL} ==="
gcloud iam service-accounts delete "${SA_EMAIL}" --quiet \
  2>/dev/null && echo "  Service account deleted." || echo "  (Service account not found or already deleted.)"

# ── 3. Optionally delete staging bucket ─────────────────────────────────────
if [ "${DELETE_BUCKET}" = true ]; then
  echo ""
  echo "=== Deleting staging bucket: gs://${STAGING_BUCKET} ==="
  echo "  WARNING: This permanently deletes all data in the bucket."
  read -r -p "  Are you sure? [y/N] " confirm
  if [[ "${confirm}" =~ ^[Yy]$ ]]; then
    gcloud storage rm --recursive "gs://${STAGING_BUCKET}" \
      2>/dev/null && echo "  Bucket deleted." || echo "  (Bucket not found or already deleted.)"
  else
    echo "  Skipped bucket deletion."
  fi
else
  echo ""
  echo "=== Skipping staging bucket deletion ==="
  echo "  (Pass --delete-bucket to also remove gs://${STAGING_BUCKET})"
fi

# ── 4. Optionally delete the shared custom IAM role ──────────────────────────
if [ "${DELETE_ROLE}" = true ]; then
  echo ""
  echo "=== Deleting custom IAM role: projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID} ==="
  echo "  NOTE: Only do this if no other service accounts are using this role."
  gcloud iam roles delete "${CUSTOM_ROLE_ID}" --project="${PROJECT_ID}" \
    2>/dev/null && echo "  Role deleted." || echo "  (Role not found or already deleted.)"
else
  echo ""
  echo "=== Skipping custom IAM role deletion ==="
  echo "  The role 'projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}' is shared and"
  echo "  not deleted by default (other service accounts may be using it)."
  echo "  To delete it when no longer needed:"
  echo "    gcloud iam roles delete ${CUSTOM_ROLE_ID} --project=${PROJECT_ID}"
fi

# ── 5. Remove local key file ─────────────────────────────────────────────────
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
