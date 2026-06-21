# Create a GCP service account with read/write access to GCS buckets
# for use with Microsoft Fabric Iceberg table shortcuts.
#
# Usage:
#   .\setup_gcs_service_account.ps1 <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
#
# This creates:
#   - A service account with the specified name
#   - Grants it roles/storage.objectAdmin on the specified bucket
#   - Generates a JSON key file for use in Fabric connection setup
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)

param(
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$BucketName,
    [Parameter(Mandatory=$true)][string]$ServiceAccountName
)

$ErrorActionPreference = "Stop"

$SaEmail = "$ServiceAccountName@$ProjectId.iam.gserviceaccount.com"
$KeyFile = "$ServiceAccountName-key.json"

Write-Host "=== Setting project to $ProjectId ==="
gcloud config set project $ProjectId

Write-Host ""
Write-Host "=== Creating service account: $ServiceAccountName ==="
try {
    gcloud iam service-accounts create $ServiceAccountName `
        --display-name="Fabric GCS Iceberg Access" `
        --description="Service account for Microsoft Fabric to access Iceberg tables in GCS" 2>$null
} catch {
    Write-Host "  (Service account may already exist, continuing...)"
}
# Also catch non-terminating errors from gcloud
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (Service account may already exist, continuing...)"
}

# Allow time for IAM propagation before assigning roles
Write-Host "  Waiting 30s for IAM propagation..."
Start-Sleep -Seconds 30

Write-Host ""
Write-Host "=== Granting roles/storage.objectAdmin on gs://$BucketName ==="
gcloud storage buckets add-iam-policy-binding "gs://$BucketName" `
    --member="serviceAccount:$SaEmail" `
    --role="roles/storage.objectAdmin"
if ($LASTEXITCODE -ne 0) { throw "Failed to grant IAM binding" }

Write-Host ""
Write-Host "=== Generating HMAC key for Fabric (S3-compatible access) ==="
$HmacOutput = gcloud storage hmac create $SaEmail --format=json | ConvertFrom-Json

$HmacAccessId = $HmacOutput.metadata.accessId
$HmacSecret = $HmacOutput.secret

# Write Fabric connection details to key file
$GcsUrl = "https://$BucketName.storage.googleapis.com"
$KeyData = @{
    service_account   = $SaEmail
    hmac_access_id    = $HmacAccessId
    hmac_secret       = $HmacSecret
    gcs_connection_url = $GcsUrl
    gcs_bucket        = $BucketName
}
$KeyData | ConvertTo-Json -Depth 3 | Set-Content -Path $KeyFile -Encoding UTF8
Write-Host "  HMAC Access ID: $HmacAccessId"

Write-Host ""
Write-Host "=== Done ==="
Write-Host ""
Write-Host "Service account:  $SaEmail"
Write-Host "Key file:         $KeyFile"
Write-Host ""
Write-Host "Fabric connection details (also saved in $KeyFile):"
Write-Host "  Connection URL: $GcsUrl"
Write-Host "  Access Key ID:  $HmacAccessId"
Write-Host "  Secret:         (see $KeyFile)"
Write-Host "  Bucket:         $BucketName"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Use these HMAC credentials to configure a GCS connection in Microsoft Fabric"
Write-Host "  2. Keep the key file secure and do NOT commit it to source control"
