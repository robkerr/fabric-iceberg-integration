# Run the create_lakehouse_shortcuts script in a Python virtual environment.
# Creates the venv and installs dependencies if not already present.
#
# Usage:
#   .\run.ps1 [config_file]
#
# Defaults to shortcuts.yaml if no config file is specified.

param(
    [string]$Config = "shortcuts.yaml"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = Join-Path $ScriptDir ".venv"

# Create virtual environment if it doesn't exist
if (-not (Test-Path $VenvDir)) {
    Write-Host "Creating Python virtual environment in $VenvDir..."
    python -m venv $VenvDir
}

# Activate the virtual environment
$ActivateScript = Join-Path $VenvDir "Scripts\Activate.ps1"
. $ActivateScript

# Install dependencies
pip install --quiet -r (Join-Path $ScriptDir "requirements.txt")

# Run the script
python (Join-Path $ScriptDir "create_lakehouse_shortcuts.py") $Config
