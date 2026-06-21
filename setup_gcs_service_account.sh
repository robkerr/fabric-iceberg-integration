#!/usr/bin/env bash
# Create a GCP service account with read/write access to GCS buckets
# for use with Microsoft Fabric Iceberg table shortcuts.
#
# Usage:
#   ./setup_gcs_service_account.sh <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
#
# This creates:
#   - A service account with the specified name
#   - Grants it roles/storage.objectAdmin on the specified bucket
#   - Generates a JSON key file for use in Fabric connection setup
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>"
  echo ""
  echo "  PROJECT_ID           - Your GCP project ID"
  echo "  BUCKET_NAME          - GCS bucket name (without gs:// prefix)"
  echo "  SERVICE_ACCOUNT_NAME - Name for the service account (e.g. fabric-gcs-access)"
  exit 1
fi

PROJECT_ID="$1"
BUCKET_NAME="$2"
SA_NAME="$3"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="${SA_NAME}-key.json"

echo "=== Setting project to ${PROJECT_ID} ==="
gcloud config set project "${PROJECT_ID}"

echo ""
echo "=== Creating service account: ${SA_NAME} ==="
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Fabric GCS Iceberg Access" \
  --description="Service account for Microsoft Fabric to access Iceberg tables in GCS" \
  2>/dev/null || echo "  (Service account may already exist, continuing...)"

# Allow time for IAM propagation before assigning roles
echo "  Waiting 30s for IAM propagation..."
sleep 30

echo ""
echo "=== Granting roles/storage.objectAdmin on gs://${BUCKET_NAME} ==="
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

echo ""
echo "=== Generating key file: ${KEY_FILE} ==="
gcloud iam service-accounts keys create "${KEY_FILE}" \
  --iam-account="${SA_EMAIL}"

# Add the GCS bucket URL to the key file for Fabric connection setup
TEMP_KEY=$(mktemp)
python3 -c "
import json, sys
with open('${KEY_FILE}') as f:
    data = json.load(f)
data['gcs_bucket_url'] = 'gs://${BUCKET_NAME}'
with open('${KEY_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
"

echo ""
echo "=== Done ==="
echo ""
echo "Service account: ${SA_EMAIL}"
echo "Key file:        ${KEY_FILE}"
echo ""
echo "Next steps:"
echo "  1. Use ${KEY_FILE} to configure a GCS connection in Microsoft Fabric"
echo "  2. Keep the key file secure and do NOT commit it to source control"
echo ""
echo "To verify access:"
echo "  gcloud auth activate-service-account --key-file=${KEY_FILE}"
echo "  gcloud storage ls gs://${BUCKET_NAME}/"
