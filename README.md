# Fabric Iceberg Integration Scripts

> **Educational-use notice:** This repository is provided for educational and demonstration purposes only. It is **not** fully tested, security-hardened, or production-ready.

This repository is a collection of scripts used to automate and manage Microsoft Fabric integrations with Apache Iceberg tables stored in Google Cloud Storage.

## Script Packages

| Folder | Purpose |
|---|---|
| `gcs_shortcuts/` | Creates and manages Fabric shortcuts to GCS-hosted Iceberg tables, including connection setup and teardown scripts. |

## `gcs_shortcuts/` Contents

| Path | What it does |
|---|---|
| `create_lakehouse_shortcuts.py` | Main automation script. Discovers Iceberg tables in GCS (or uses explicit paths from config) and creates Fabric Lakehouse shortcuts. |
| `shortcuts.yaml` | Configuration file for workspace/lakehouse IDs, connection reference, bucket/prefix, and shortcut options. |
| `setup_gcs_service_account.sh` | Bash setup script that creates a service account, assigns bucket IAM, generates HMAC credentials, and writes Fabric-ready connection JSON. |
| `setup_gcs_service_account.ps1` | PowerShell version of the setup script for Windows environments. |
| `remove_gcs_service_account.sh` | Bash backout script that removes IAM bindings, deletes the service account, and cleans up local key material. |
| `remove_gcs_service_account.ps1` | PowerShell version of the backout script for Windows environments. |
| `run.sh` | Bash helper that creates/uses a Python virtual environment, installs dependencies, and runs the shortcut creation script. |
| `run.ps1` | PowerShell version of the run helper for Windows environments. |
| `requirements.txt` | Python dependencies required to run the shortcut automation script. |
| `svc-account-hmac-auth.json` | Example JSON credential output format for Fabric GCS connection setup (HMAC-based). |
| `docs/` | Supporting presentation/demo assets for the integration workflow. |
| `docs/architecture-diagram.png` | 4K architecture diagram for presentations and solution walkthroughs. |
| `docs/confirm_tables.sql` | SQL used during validation/demo steps for confirming table metadata and format. |
| `docs/video-demo-script.docx` | Editable demo narration script for presenting the end-to-end solution. |

> Note: `.venv/` and `__pycache__/` under `gcs_shortcuts/` are local/generated artifacts and not part of the reusable script package.
