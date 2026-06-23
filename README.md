# Fabric Integration Scripts

> **Educational-use notice:** This repository is provided for educational and demonstration purposes only. It is **not** fully tested, security-hardened, or production-ready.

This repository contains individual tooling to automate and aid in the setup of Microsoft Fabric shortcuts and mirroring functionality. Each folder is a self-contained package with its own setup scripts, configuration, and detailed README, covering a specific source platform or integration pattern.

## Tooling packages

| Folder | What it does | README |
|---|---|---|
| [`gcs_shortcuts/`](gcs_shortcuts/) | Automates the creation of Fabric Lakehouse shortcuts to Apache Iceberg tables stored in Google Cloud Storage (GCS). Includes service account setup (HMAC credentials) and shortcut automation via the Fabric REST API. | [→ README](gcs_shortcuts/README.md) |
| [`bigquery_mirroring/`](bigquery_mirroring/) | Automates the setup of Fabric database mirroring from a Google BigQuery dataset into OneLake. Includes service account setup, CDC enablement, staging bucket creation, and mirroring lifecycle management via the Fabric REST API. | [→ README](bigquery_mirroring/README.md) |
