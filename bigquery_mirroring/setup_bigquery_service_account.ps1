# Set up a GCP service account with the minimal permissions required for
# Microsoft Fabric to mirror a BigQuery dataset into OneLake.
#
# Usage:
#   .\setup_bigquery_service_account.ps1 <PROJECT_ID> <DATASET_ID> <SERVICE_ACCOUNT_NAME>
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
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - bq CLI available (ships with gcloud SDK)
#
# Example:
#   .\setup_bigquery_service_account.ps1 my-gcp-project my-dataset svc-fabric-bq-mirror

param(
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$DatasetId,
    [Parameter(Mandatory=$true)][string]$ServiceAccountName
)

$ErrorActionPreference = "Stop"

$SaEmail        = "$ServiceAccountName@$ProjectId.iam.gserviceaccount.com"
$CustomRoleId   = "FabricBigQueryMirror"
$RoleFullName   = "projects/$ProjectId/roles/$CustomRoleId"
$KeyFile        = "$ServiceAccountName-key.json"
$StagingBucket  = "${ProjectId}_fabric_staging_bucket"

# ── 1. Set project ──────────────────────────────────────────────────────────
Write-Host "=== Setting project to $ProjectId ==="
gcloud config set project $ProjectId
if ($LASTEXITCODE -ne 0) { throw "Failed to set project" }

# ── 2. Discover dataset location ────────────────────────────────────────────
Write-Host ""
Write-Host "=== Discovering dataset location for $DatasetId ==="
$DatasetJson = bq show --format=json "${ProjectId}:${DatasetId}" 2>&1 | Out-String
$DatasetLocation = ($DatasetJson | ConvertFrom-Json).location
Write-Host "  Dataset location: $DatasetLocation"

# ── 3. Create service account ───────────────────────────────────────────────
Write-Host ""
Write-Host "=== Creating service account: $ServiceAccountName ==="
gcloud iam service-accounts create $ServiceAccountName `
    --display-name="Fabric BigQuery Mirror" `
    --description="Service account for Microsoft Fabric to mirror BigQuery datasets into OneLake" `
    2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (Service account may already exist, continuing...)"
}

# ── 4. Create custom IAM role ────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Creating custom IAM role: $CustomRoleId ==="

# Use --show-deleted so we can distinguish soft-deleted from never-existed
$RoleCsv = gcloud iam roles list --project=$ProjectId `
    --show-deleted `
    --filter="name=$RoleFullName" `
    --format="csv[no-heading](name,deleted)" 2>$null | Out-String

if ([string]::IsNullOrWhiteSpace($RoleCsv)) {
    $RoleState = "NOT_FOUND"
} elseif ($RoleCsv -match ",True") {
    $RoleState = "DELETED"
} else {
    $RoleState = "ACTIVE"
}

$RoleYaml = @"
title: "Fabric BigQuery Mirror"
description: "Minimal permissions for Microsoft Fabric to mirror a BigQuery dataset into OneLake"
stage: "GA"
includedPermissions:
  - bigquery.datasets.get
  - resourcemanager.projects.get
  - bigquery.tables.get
  - bigquery.tables.list
  - bigquery.routines.get
  - bigquery.routines.list
  - bigquery.tables.getData
  - bigquery.jobs.create
  - bigquery.jobs.get
  - bigquery.jobs.list
  - bigquery.readsessions.create
  - bigquery.readsessions.getData
  - bigquery.tables.export
  - storage.objects.create
  - storage.objects.list
  - storage.objects.delete
  - storage.buckets.get
  - storage.buckets.list
  - iam.serviceAccounts.signBlob
"@

$RoleFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yaml'
$RoleYaml | Set-Content -Path $RoleFile -Encoding UTF8

if ($RoleState -eq "DELETED") {
    Write-Host "  Role is soft-deleted — undeleting..."
    gcloud iam roles undelete $CustomRoleId --project=$ProjectId --quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to undelete role" }
    Write-Host "  Updating role permissions..."
    gcloud iam roles update $CustomRoleId --project=$ProjectId --file=$RoleFile --quiet 2>$null
    Write-Host "  Role restored and updated."
} elseif ($RoleState -eq "NOT_FOUND") {
    gcloud iam roles create $CustomRoleId --project=$ProjectId --file=$RoleFile --quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to create role" }
    Write-Host "  Created new role."
} else {
    gcloud iam roles update $CustomRoleId --project=$ProjectId --file=$RoleFile --quiet 2>$null
    Write-Host "  Updated existing role."
}
Remove-Item $RoleFile -Force

# ── 5. Bind custom role to service account ──────────────────────────────────
Write-Host ""
Write-Host "=== Binding role $RoleFullName to $SaEmail ==="
Write-Host "  Waiting 15s for IAM propagation after role creation..."
Start-Sleep -Seconds 15

gcloud projects add-iam-policy-binding $ProjectId `
    --member="serviceAccount:$SaEmail" `
    --role=$RoleFullName `
    --condition=None `
    --quiet
if ($LASTEXITCODE -ne 0) { throw "Failed to bind role to service account" }

# ── 6. Create the GCS staging bucket ────────────────────────────────────────
Write-Host ""
Write-Host "=== Creating staging bucket: gs://$StagingBucket ($DatasetLocation) ==="
gcloud storage buckets create "gs://$StagingBucket" `
    --project=$ProjectId `
    --location=$DatasetLocation `
    --uniform-bucket-level-access `
    2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (Bucket may already exist, continuing...)"
}

Write-Host "  Granting roles/storage.admin on gs://$StagingBucket to $SaEmail..."
gcloud storage buckets add-iam-policy-binding "gs://$StagingBucket" `
    --member="serviceAccount:$SaEmail" `
    --role="roles/storage.admin"
if ($LASTEXITCODE -ne 0) { throw "Failed to grant storage.admin on staging bucket" }

# ── 7. Enable change history on all tables ──────────────────────────────────
Write-Host ""
Write-Host "=== Enabling change history on tables in $DatasetId ==="

$TablesJson = bq ls --format=json "${ProjectId}:${DatasetId}" 2>&1 | Out-String
$Tables = ($TablesJson | ConvertFrom-Json) | Where-Object { $_.type -eq "TABLE" } | ForEach-Object { $_.tableReference.tableId }

foreach ($Table in $Tables) {
    Write-Host "  Enabling change history on ${DatasetId}.${Table}..."
    $Query = "ALTER TABLE ``${ProjectId}.${DatasetId}.${Table}`` SET OPTIONS (enable_change_history = TRUE);"
    bq query --project_id=$ProjectId --use_legacy_sql=false --nouse_cache $Query 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Done."
    } else {
        Write-Host "    (May already be enabled or table doesn't support it, continuing...)"
    }
}

# ── 8. Generate JSON key file ────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Generating service account JSON key file ==="
if (Test-Path $KeyFile) {
    Write-Host "  WARNING: $KeyFile already exists — overwriting."
    Remove-Item $KeyFile -Force
}
gcloud iam service-accounts keys create $KeyFile --iam-account=$SaEmail
if ($LASTEXITCODE -ne 0) { throw "Failed to create service account key" }
Write-Host "  Key saved to: $KeyFile"

# ── 9. Summary ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================"
Write-Host " Setup complete — Fabric connection parameters"
Write-Host "================================================================"
Write-Host ""
Write-Host " GCP Project ID:          $ProjectId"
Write-Host " BigQuery Dataset:        $DatasetId"
Write-Host " Dataset Location:        $DatasetLocation"
Write-Host " Service Account Email:   $SaEmail"
Write-Host " JSON Key File:           $KeyFile"
Write-Host " GCS Staging Bucket:      $StagingBucket"
Write-Host ""
Write-Host " To configure the Google BigQuery connection in Fabric:"
Write-Host "   1. Go to your Fabric workspace > Settings > Connections"
Write-Host "      (or from the 'New connection' dialog when creating the mirrored DB)"
Write-Host "   2. Choose 'Google BigQuery'"
Write-Host "   3. Enter the following:"
Write-Host "      - Service Account Email:    $SaEmail"
Write-Host "      - Service Account JSON key: paste the full contents of $KeyFile"
Write-Host ""
Write-Host " To create the Mirrored Database in Fabric:"
Write-Host "   1. In your workspace, select New > Mirrored Google BigQuery"
Write-Host "   2. Select the connection you just created"
Write-Host "   3. Choose project '$ProjectId' and dataset '$DatasetId'"
Write-Host "   4. Note the mirrored database item ID (from the URL after creation)"
Write-Host "   5. Update mirroring.yaml with workspace_id and mirrored_database_id"
Write-Host "   6. Run: python setup_bigquery_mirror.py mirroring.yaml"
Write-Host ""
Write-Host " IMPORTANT: Keep $KeyFile secure. Do NOT commit it to source control."
Write-Host "================================================================"
