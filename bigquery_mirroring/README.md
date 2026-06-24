# BigQuery Mirroring to Microsoft Fabric

This folder contains scripts to automate the setup of Microsoft Fabric **database mirroring** from a Google BigQuery dataset into OneLake. Mirroring continuously replicates your BigQuery tables into Fabric in near real-time, converting them to Delta/Parquet format so they can be queried with SQL, Spark, Power BI, and other Fabric tools.

## How it works

```
Google BigQuery dataset (your-dataset)
        │
        │  CDC via change history + BigQuery Storage Read API
        │  Staging export to GCS bucket
        ▼
  Fabric Mirrored Database
        │
        │  Near real-time replication into OneLake (Delta format)
        ▼
  SQL Analytics Endpoint  +  OneLake Tables
```

Fabric reads change history from BigQuery using a service account, stages exported data in a GCS bucket, then pulls it into OneLake. The GCS staging bucket is managed automatically by Fabric — you just need to create it in the right region.

## Prerequisites

- `gcloud` CLI and `bq` CLI installed and authenticated (`gcloud auth login`)
- `az` CLI installed and signed in (`az login`)
- Python 3.9+
- A Microsoft Fabric workspace (not "My Workspace") already created
- A Fabric capacity (or trial)

## Step-by-step setup

### Step 1 — Create the GCP service account and prepare BigQuery (automated)

Run the setup script to create a service account with minimal permissions, create the required GCS staging bucket, and enable change history (CDC) on all tables in the dataset:

```bash
# Linux / macOS
./setup_bigquery_service_account.sh <PROJECT_ID> <DATASET_ID> <SERVICE_ACCOUNT_NAME>

# Example
./setup_bigquery_service_account.sh your-project-name your-dataset svc-fabric-bq-mirror
```

```powershell
# Windows
.\setup_bigquery_service_account.ps1 <PROJECT_ID> <DATASET_ID> <SERVICE_ACCOUNT_NAME>

# Example
.\setup_bigquery_service_account.ps1 your-project-name your-dataset svc-fabric-bq-mirror
```

The script outputs a summary of everything you need for Step 2:

```
================================================================
 Setup complete — Fabric connection parameters
================================================================

 GCP Project ID:          your-project-name
 BigQuery Dataset:        your-dataset
 Dataset Location:        us-central1
 Service Account Email:   svc-fabric-bq-mirror@your-project-name.iam.gserviceaccount.com
 JSON Key File:           svc-fabric-bq-mirror-key.json
 GCS Staging Bucket:      your-project-name_fabric_staging_bucket

 To configure the Google BigQuery connection in Fabric:
   1. Go to your Fabric workspace > Settings > Connections
   2. Choose 'Google BigQuery'
   3. Enter:
      - Service Account Email
      - Service Account JSON key: paste the full contents of svc-fabric-bq-mirror-key.json
```

### Step 2 — Create the BigQuery connection in Fabric (manual, one-time)

1. In the Fabric portal, go to your workspace → **Settings → Manage connections and gateways → New connection**
2. Choose **Google BigQuery**
3. Enter the **Service Account Email** and paste the full contents of the JSON key file generated in Step 1
4. Give the connection a name (e.g. `my-bigquery-connection`) — you'll reference this when creating the mirrored database

### Step 3 — Create the Mirrored Database in Fabric (manual, one-time)

1. In your Fabric workspace, select **New → Mirrored Google BigQuery**
2. Select the connection you created in Step 2
3. Choose your GCP project and dataset
4. Name the mirrored database and click **Create**

> Fabric creates two items in your workspace: a **MirroredDatabase** item and a companion **SQLEndpoint**. They share the same display name. You need the **MirroredDatabase** ID (not the SQLEndpoint ID) for the next step.

### Step 4 — Configure mirroring.yaml

Find the IDs you need using the helper commands:

```bash
# Linux / macOS
./run.sh --list-mirrored-databases --workspace <WORKSPACE_ID>
./run.sh --list-connections --filter <your-connection-name>
```

```powershell
# Windows
.\run.ps1 --list-mirrored-databases --workspace <WORKSPACE_ID>
.\run.ps1 --list-connections --filter <your-connection-name>
```

Edit `mirroring.yaml`:

```yaml
workspace_id: "your-workspace-id"
mirrored_database_id: "mirrored-database-item-id"   # from --list-mirrored-databases
connection: "your-connection-name"                  # connection name or GUID from Step 2
```

### Step 5 — Start mirroring and monitor status

```bash
# Linux / macOS — start mirroring and poll until Running, then show per-table status
./run.sh mirroring.yaml

# Check status at any time
./run.sh mirroring.yaml --status
```

```powershell
# Windows
.\run.ps1 mirroring.yaml
.\run.ps1 mirroring.yaml --status
```

Example status output:

```
Mirroring status: ✓ Running

  Schema               Table                          Status               Rows  Last Sync
  -------------------- ------------------------------ --------------- ------------ -------------------------
  your-dataset         table_one                      Replicating             265  2026-06-23 20:39:15
  your-dataset         table_two                      Replicating      44,417,596  2026-06-23 20:39:30
```

## Stopping mirroring

```bash
# Linux / macOS
./run.sh mirroring.yaml --stop
```

```powershell
# Windows
.\run.ps1 mirroring.yaml --stop
```

## Teardown

To remove the service account and clean up GCP resources:

```bash
# Linux / macOS — remove service account only
./remove_bigquery_service_account.sh your-project-name svc-fabric-bq-mirror

# Also delete the GCS staging bucket (prompts for confirmation)
./remove_bigquery_service_account.sh your-project-name svc-fabric-bq-mirror --delete-bucket

# Full teardown — also delete the custom IAM role
./remove_bigquery_service_account.sh your-project-name svc-fabric-bq-mirror --delete-bucket --delete-role
```

```powershell
# Windows — remove service account only
.\remove_bigquery_service_account.ps1 your-project-name svc-fabric-bq-mirror

# Also delete the GCS staging bucket (prompts for confirmation)
.\remove_bigquery_service_account.ps1 your-project-name svc-fabric-bq-mirror -DeleteBucket

# Full teardown — also delete the custom IAM role
.\remove_bigquery_service_account.ps1 your-project-name svc-fabric-bq-mirror -DeleteBucket -DeleteRole
```

> **Note on the custom IAM role:** The `FabricBigQueryMirror` role is a shared project-level resource. It is not deleted by default because multiple service accounts (e.g. one per dataset) can reuse it. Pass `--delete-role` only when you're sure no other service accounts in the project are using it.

## File reference

| File | What it does |
|---|---|
| `setup_bigquery_service_account.sh` | Creates the GCP service account with a custom minimal IAM role, creates the required GCS staging bucket, enables change history (CDC) on all dataset tables, generates a JSON key file, and prints Fabric connection parameters |
| `setup_bigquery_service_account.ps1` | PowerShell version of the above for Windows |
| `remove_bigquery_service_account.sh` | Removes IAM bindings, deletes the service account and its keys, and optionally deletes the GCS staging bucket (`--delete-bucket`) and custom IAM role (`--delete-role`) |
| `remove_bigquery_service_account.ps1` | PowerShell version of the above for Windows (uses `-DeleteBucket` and `-DeleteRole` switches) |
| `setup_bigquery_mirror.py` | Fabric-side automation — starts/stops mirroring and reports per-table replication status via the Fabric REST API |
| `mirroring.yaml` | Configuration file — workspace ID, mirrored database item ID, and connection reference |
| `run.sh` | Bash helper that creates a Python virtual environment, installs dependencies, and runs the mirror management script |
| `run.ps1` | PowerShell version of the run helper |
| `requirements.txt` | Python dependencies (`pyyaml`) |
