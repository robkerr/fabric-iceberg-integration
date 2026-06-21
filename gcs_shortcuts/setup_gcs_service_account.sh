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
echo "=== Generating HMAC key for Fabric (S3-compatible access) ==="
HMAC_OUTPUT=$(gcloud storage hmac create "${SA_EMAIL}" --format=json)

HMAC_ACCESS_ID=$(echo "${HMAC_OUTPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['metadata']['accessId'])")
HMAC_SECRET=$(echo "${HMAC_OUTPUT}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['secret'])")

# Write Fabric connection details to key file
GCS_URL="https://${BUCKET_NAME}.storage.googleapis.com"
python3 -c "
import json
data = {
    'service_account': '${SA_EMAIL}',
    'hmac_access_id': '${HMAC_ACCESS_ID}',
    'hmac_secret': '${HMAC_SECRET}',
    'gcs_endpoint_url': '${GCS_URL}'
}
with open('${KEY_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
print('  HMAC Access ID: ${HMAC_ACCESS_ID}')
"

echo ""
echo "=== Done ==="
echo ""
echo "Service account:  ${SA_EMAIL}"
echo "Key file:         ${KEY_FILE}"
echo ""
echo "Fabric connection details (also saved in ${KEY_FILE}):"
echo "  Connection URL: ${GCS_URL}"
echo "  Access Key ID:  ${HMAC_ACCESS_ID}"
echo "  Secret:         (see ${KEY_FILE})"
echo "  Bucket:         ${BUCKET_NAME}"
echo ""
echo "Next steps:"
echo "  1. Use these HMAC credentials to configure a GCS connection in Microsoft Fabric"
echo "  2. Keep the key file secure and do NOT commit it to source control"
