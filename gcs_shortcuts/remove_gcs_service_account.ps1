# Remove a GCP service account and its IAM bindings from a GCS bucket.
# This is the backout/teardown counterpart to setup_gcs_service_account.ps1.
#
# Usage:
#   .\remove_gcs_service_account.ps1 <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
#
# This will:
#   1. Remove the roles/storage.objectAdmin binding from the bucket
#   2. Delete the service account itself
#   3. Remove the local key file
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
Write-Host "=== Removing roles/storage.objectAdmin from gs://$BucketName ==="
gcloud storage buckets remove-iam-policy-binding "gs://$BucketName" `
    --member="serviceAccount:$SaEmail" `
    --role="roles/storage.objectAdmin" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Binding removed."
} else {
    Write-Host "  (Binding not found or already removed, continuing...)"
}

Write-Host ""
Write-Host "=== Deleting service account: $SaEmail ==="
gcloud iam service-accounts delete $SaEmail --quiet 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Service account deleted."
} else {
    Write-Host "  (Service account not found or already deleted.)"
}

Write-Host ""
if (Test-Path $KeyFile) {
    Write-Host "=== Removing local key file: $KeyFile ==="
    Remove-Item $KeyFile -Force
    Write-Host "  Deleted."
} else {
    Write-Host "=== No local key file found ($KeyFile) ==="
}

Write-Host ""
Write-Host "=== Done ==="
