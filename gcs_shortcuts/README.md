# GCS Iceberg Shortcuts for Microsoft Fabric

This folder contains scripts to automate the creation of Microsoft Fabric Lakehouse **shortcuts** that point to Apache Iceberg tables stored in Google Cloud Storage (GCS). Shortcuts let Fabric read live Iceberg data directly from GCS without copying it into OneLake.

## How it works

```
GCS bucket (Iceberg tables)
        │
        │  HMAC credentials (S3-compatible)
        ▼
  Fabric connection
        │
        │  OneLake shortcut (per table)
        ▼
  Fabric Lakehouse (Tables section)
```

Fabric accesses GCS through its S3-compatible XML API using HMAC keys tied to a GCP service account. The shortcut points directly at the Iceberg table directory in the bucket — no data is copied.

## Prerequisites

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- `az` CLI installed and signed in (`az login`)
- Python 3.9+
- A Microsoft Fabric workspace and Lakehouse already created

## Step-by-step setup

### Step 1 — Create the GCP service account and credentials

Run the setup script to create a service account, grant it access to your GCS bucket, and generate HMAC credentials for Fabric:

```bash
# Linux / macOS
./setup_gcs_service_account.sh <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>

# Example
./setup_gcs_service_account.sh my-gcp-project my-iceberg-bucket svc-fabric-gcs
```

```powershell
# Windows
.\setup_gcs_service_account.ps1 <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
```

The script outputs a connection summary like this:

```
Fabric connection details (also saved in svc-fabric-gcs-key.json):
  Connection URL: https://my-iceberg-bucket.storage.googleapis.com
  Access Key ID:  GOOG1E...
  Secret:         (see key file)
  Bucket:         my-iceberg-bucket
```

### Step 2 — Create the GCS connection in Fabric (manual, one-time)

1. In the Fabric portal, go to **Settings → Manage connections and gateways → New connection**
2. Choose **Google Cloud Storage**
3. Enter the **Connection URL**, **Access Key ID**, and **Secret** from the key file output in Step 1
4. Give the connection a name (e.g. `my-gcs-connection`) — you'll reference this in `shortcuts.yaml`

### Step 3 — Configure shortcuts.yaml

Edit `shortcuts.yaml` with your workspace ID, lakehouse ID, and connection name.

Find your workspace and lakehouse IDs in the Fabric portal URL:
`https://app.fabric.microsoft.com/groups/<workspace_id>/lakehouses/<lakehouse_id>`

```yaml
workspace_id: "your-workspace-id"
lakehouse_id: "your-lakehouse-id"
connection: "my-gcs-connection"      # connection name or GUID from Step 2
gcs_bucket: "gs://my-iceberg-bucket"
gcs_prefix: "my-folder"              # folder within the bucket to scan
```

To find the connection GUID:
```bash
python create_lakehouse_shortcuts.py --list-connections --filter my-gcs-connection
```

### Step 4 — Create the shortcuts

```bash
# Auto-discover Iceberg tables and create shortcuts
./run.sh shortcuts.yaml

# Or run the Python script directly
python create_lakehouse_shortcuts.py shortcuts.yaml
```

The script scans the GCS prefix for Iceberg tables (identified by a `metadata/` subfolder), prompts for confirmation, then creates a Fabric shortcut for each table in the Lakehouse Tables section.

## Teardown

To remove the service account and clean up IAM bindings:

```bash
./remove_gcs_service_account.sh <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
```

```powershell
.\remove_gcs_service_account.ps1 <PROJECT_ID> <BUCKET_NAME> <SERVICE_ACCOUNT_NAME>
```

## File reference

| File | What it does |
|---|---|
| `setup_gcs_service_account.sh` | Creates the GCP service account, grants `roles/storage.objectAdmin` on the bucket, generates HMAC credentials, and writes Fabric connection details to a JSON key file |
| `setup_gcs_service_account.ps1` | PowerShell version of the above for Windows |
| `remove_gcs_service_account.sh` | Removes IAM bindings, deletes the service account and all its keys, and cleans up the local key file |
| `remove_gcs_service_account.ps1` | PowerShell version of the above for Windows |
| `create_lakehouse_shortcuts.py` | Main automation script — discovers Iceberg tables in GCS (or uses explicit paths) and creates Fabric Lakehouse shortcuts via the Fabric REST API |
| `shortcuts.yaml` | Configuration file — workspace/lakehouse IDs, connection reference, bucket/prefix, and shortcut options |
| `run.sh` | Bash helper that creates a Python virtual environment, installs dependencies, and runs the shortcut script |
| `run.ps1` | PowerShell version of the run helper |
| `requirements.txt` | Python dependencies (`pyyaml`) |
| `svc-account-hmac-auth.json` | Example JSON output showing the credential format written by the setup script |
| `docs/` | Architecture diagrams and demo assets |
