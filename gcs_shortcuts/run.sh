#!/usr/bin/env bash
# Run the create_lakehouse_shortcuts script in a Python virtual environment.
# Creates the venv and installs dependencies if not already present.
#
# Usage:
#   ./run.sh [config_file]
#
# Defaults to shortcuts.yaml if no config file is specified.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
CONFIG="${1:-shortcuts.yaml}"

# Use python3 explicitly (works on Ubuntu where 'python' may not exist)
PYTHON="python3"

# Create virtual environment if it doesn't exist
if [ ! -d "${VENV_DIR}" ]; then
  echo "Creating Python virtual environment in ${VENV_DIR}..."
  ${PYTHON} -m venv "${VENV_DIR}"
fi

# Activate the virtual environment
source "${VENV_DIR}/bin/activate"

# Install dependencies
pip install --quiet -r "${SCRIPT_DIR}/requirements.txt"

# Run the script
python "${SCRIPT_DIR}/create_lakehouse_shortcuts.py" "${CONFIG}"
