#!/usr/bin/env bash
# Run setup_bigquery_mirror.py inside the local virtual environment.
#
# Usage:
#   ./run.sh [args...]
#
# Workflow:
#   1. Run setup_bigquery_service_account.sh to create the GCP service account + key
#   2. In the Fabric portal, create a Google BigQuery connection (New connection >
#      Google BigQuery) using the service account email and JSON key from step 1
#   3. In the Fabric portal, create a Mirrored Google BigQuery item in your workspace
#   4. Use the helpers below to find IDs, then fill in mirroring.yaml
#
# Examples:
#   ./run.sh --list-connections --filter <part-of-your-connection-name>
#   ./run.sh --list-mirrored-databases --workspace <WORKSPACE_ID>
#   ./run.sh mirroring.yaml          # start mirroring + show per-table status
#   ./run.sh mirroring.yaml --status # check current status
#   ./run.sh mirroring.yaml --stop   # stop mirroring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

if [ ! -d "${VENV_DIR}" ]; then
  echo "Creating virtual environment..."
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --quiet -r "${SCRIPT_DIR}/requirements.txt"
fi

"${VENV_DIR}/bin/python" "${SCRIPT_DIR}/setup_bigquery_mirror.py" "$@"
