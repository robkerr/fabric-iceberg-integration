# Remove the GCP service account and resources created by setup_bigquery_service_account.ps1.
# This is the teardown counterpart for the Fabric BigQuery mirroring setup.
#
# Usage:
#   .\remove_bigquery_service_account.ps1 <PROJECT_ID> <SERVICE_ACCOUNT_NAME> [OPTIONS]
#
# Options:
#   -DeleteBucket   Also delete the GCS staging bucket (prompts for confirmation)
#   -DeleteRole     Also delete the shared FabricBigQueryMirror custom IAM role.
#                   Only use this if no other service accounts are using the role.
#
# Examples:
#   .\remove_bigquery_service_account.ps1 my-project svc-fabric-bq-mirror
#   .\remove_bigquery_service_account.ps1 my-project svc-fabric-bq-mirror -DeleteBucket -DeleteRole

param(
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$ServiceAccountName,
    [switch]$DeleteBucket,
    [switch]$DeleteRole
)

$ErrorActionPreference = "Stop"

$SaEmail       = "$ServiceAccountName@$ProjectId.iam.gserviceaccount.com"
$CustomRoleId  = "FabricBigQueryMirror"
$StagingBucket = "${ProjectId}_fabric_staging_bucket"
$KeyFile       = "$ServiceAccountName-key.json"

Write-Host "=== Setting project to $ProjectId ==="
gcloud config set project $ProjectId
if ($LASTEXITCODE -ne 0) { throw "Failed to set project" }

# ── 1. Remove custom role binding ───────────────────────────────────────────
Write-Host ""
Write-Host "=== Removing IAM role binding: projects/$ProjectId/roles/$CustomRoleId ==="
gcloud projects remove-iam-policy-binding $ProjectId `
    --member="serviceAccount:$SaEmail" `
    --role="projects/$ProjectId/roles/$CustomRoleId" `
    --quiet `
    2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Binding removed."
} else {
    Write-Host "  (Binding not found or already removed, continuing...)"
}

# ── 2. Delete service account ────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Deleting service account: $SaEmail ==="
gcloud iam service-accounts delete $SaEmail --quiet 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Service account deleted."
} else {
    Write-Host "  (Service account not found or already deleted.)"
}

# ── 3. Optionally delete staging bucket ─────────────────────────────────────
if ($DeleteBucket) {
    Write-Host ""
    Write-Host "=== Deleting staging bucket: gs://$StagingBucket ==="
    Write-Host "  WARNING: This permanently deletes all data in the bucket."
    $confirm = Read-Host "  Are you sure? [y/N]"
    if ($confirm -match "^[Yy]$") {
        gcloud storage rm --recursive "gs://$StagingBucket" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Bucket deleted."
        } else {
            Write-Host "  (Bucket not found or already deleted.)"
        }
    } else {
        Write-Host "  Skipped bucket deletion."
    }
} else {
    Write-Host ""
    Write-Host "=== Skipping staging bucket deletion ==="
    Write-Host "  (Pass -DeleteBucket to also remove gs://$StagingBucket)"
}

# ── 4. Optionally delete the shared custom IAM role ──────────────────────────
if ($DeleteRole) {
    Write-Host ""
    Write-Host "=== Deleting custom IAM role: projects/$ProjectId/roles/$CustomRoleId ==="
    Write-Host "  NOTE: Only do this if no other service accounts are using this role."
    gcloud iam roles delete $CustomRoleId --project=$ProjectId 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Role deleted."
    } else {
        Write-Host "  (Role not found or already deleted.)"
    }
} else {
    Write-Host ""
    Write-Host "=== Skipping custom IAM role deletion ==="
    Write-Host "  The role 'projects/$ProjectId/roles/$CustomRoleId' is shared and"
    Write-Host "  not deleted by default (other service accounts may be using it)."
    Write-Host "  To delete it when no longer needed:"
    Write-Host "    gcloud iam roles delete $CustomRoleId --project=$ProjectId"
}

# ── 5. Remove local key file ─────────────────────────────────────────────────
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
