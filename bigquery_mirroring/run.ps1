# Run setup_bigquery_mirror.py inside the local virtual environment.
#
# Usage:
#   .\run.ps1 [args...]
#
# Workflow:
#   1. Run setup_bigquery_service_account.sh to create the GCP service account + key
#   2. In the Fabric portal, create a Google BigQuery connection (New connection >
#      Google BigQuery) using the service account email and JSON key from step 1
#   3. In the Fabric portal, create a Mirrored Google BigQuery item in your workspace
#   4. Use the helpers below to find IDs, then fill in mirroring.yaml
#
# Examples:
#   .\run.ps1 --list-connections --filter <part-of-your-connection-name>
#   .\run.ps1 --list-mirrored-databases --workspace <WORKSPACE_ID>
#   .\run.ps1 mirroring.yaml          # start mirroring + show per-table status
#   .\run.ps1 mirroring.yaml --status # check current status
#   .\run.ps1 mirroring.yaml --stop   # stop mirroring

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = Join-Path $ScriptDir ".venv"

if (-not (Test-Path $VenvDir)) {
    Write-Host "Creating virtual environment..."
    python -m venv $VenvDir
    & "$VenvDir\Scripts\pip" install --quiet -r "$ScriptDir\requirements.txt"
}

& "$VenvDir\Scripts\python" "$ScriptDir\setup_bigquery_mirror.py" @args
