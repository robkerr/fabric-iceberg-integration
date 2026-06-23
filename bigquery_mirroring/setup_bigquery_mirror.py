"""
Manage Microsoft Fabric mirroring of a Google BigQuery dataset.

Prerequisites:
  - Azure CLI installed and signed in (`az login`)
  - PyYAML installed (`pip install pyyaml`)
  - A Mirrored Google BigQuery item created in your Fabric workspace
    (New > Mirrored Google BigQuery in the Fabric portal)
  - A Google BigQuery connection configured in Fabric using the service
    account credentials output by setup_bigquery_service_account.sh

Usage:
  # Start mirroring and show per-table status
  python setup_bigquery_mirror.py mirroring.yaml

  # Check current mirroring status only (no start)
  python setup_bigquery_mirror.py mirroring.yaml --status

  # Stop mirroring
  python setup_bigquery_mirror.py mirroring.yaml --stop

  # List Fabric connections (find your Google BigQuery connection GUID)
  python setup_bigquery_mirror.py --list-connections [--filter NAME]

  # List all mirrored databases in a workspace
  python setup_bigquery_mirror.py --list-mirrored-databases --workspace WORKSPACE_ID

See mirroring.yaml for the config file format.

Reference:
  https://learn.microsoft.com/en-us/rest/api/fabric/mirroreddatabase
"""

import argparse
import json
import subprocess
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

import yaml

FABRIC_API_BASE = "https://api.fabric.microsoft.com/v1"
STATUS_POLL_INTERVAL = 10   # seconds between status polls
STATUS_POLL_ATTEMPTS = 12   # max polls when waiting for Running state (~2 min)


def get_fabric_token() -> str:
    """Acquire a bearer token for the Fabric API using the Azure CLI."""
    result = subprocess.run(
        "az account get-access-token --resource https://api.fabric.microsoft.com",
        capture_output=True,
        text=True,
        shell=True,
    )
    if result.returncode != 0:
        print(f"ERROR: Failed to get access token.\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)["accessToken"]


def fabric_request(method: str, path: str, token: str, body: dict | None = None) -> dict | None:
    """Make a request to the Fabric REST API. Returns parsed JSON or None for 204."""
    url = f"{FABRIC_API_BASE}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Authorization": f"Bearer {token}"}
    if data:
        headers["Content-Type"] = "application/json"

    req = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw.decode("utf-8")) if raw else None
    except HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"ERROR: HTTP {e.code} on {method} {path}\n{error_body}", file=sys.stderr)
        sys.exit(1)


def list_connections(token: str, name_filter: str | None = None) -> list[dict]:
    """Fetch all connections visible to the current user, optionally filtered by name."""
    data = fabric_request("GET", "/connections", token)
    connections = (data or {}).get("value", [])
    if name_filter:
        fl = name_filter.lower()
        connections = [c for c in connections if fl in (c.get("displayName") or "").lower()]
    return connections


def resolve_connection(connection_ref: str, token: str) -> str:
    """Resolve a connection name or GUID to its GUID."""
    import re
    uuid_pattern = re.compile(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
    )
    if uuid_pattern.match(connection_ref):
        return connection_ref

    connections = list_connections(token, name_filter=connection_ref)
    if not connections:
        print(
            f"ERROR: No connection found matching '{connection_ref}'.\n"
            "Use '--list-connections' to see available connections.",
            file=sys.stderr,
        )
        sys.exit(1)
    if len(connections) > 1:
        print(f"Multiple connections match '{connection_ref}':", file=sys.stderr)
        for c in connections:
            print(f"  {c['id']}  {c.get('displayName') or '(unnamed)'}", file=sys.stderr)
        print("Please use the full GUID or a more specific name.", file=sys.stderr)
        sys.exit(1)
    match = connections[0]
    print(f"Resolved connection '{match.get('displayName')}' -> {match['id']}")
    return match["id"]


def list_mirrored_databases(workspace_id: str, token: str) -> list[dict]:
    """Return all mirrored database items in a workspace."""
    data = fabric_request("GET", f"/workspaces/{workspace_id}/mirroredDatabases", token)
    return (data or {}).get("value", [])


def get_mirroring_status(workspace_id: str, db_id: str, token: str) -> dict:
    """Return the overall mirroring status for a mirrored database."""
    data = fabric_request(
        "GET",
        f"/workspaces/{workspace_id}/mirroredDatabases/{db_id}/mirroringStatus",
        token,
    )
    return data or {}


def get_tables_status(workspace_id: str, db_id: str, token: str) -> list[dict]:
    """Return per-table mirroring status for a mirrored database."""
    data = fabric_request(
        "POST",
        f"/workspaces/{workspace_id}/mirroredDatabases/{db_id}/getTablesMirroringStatus",
        token,
        body={},
    )
    return (data or {}).get("data", [])


def print_mirroring_status(workspace_id: str, db_id: str, token: str) -> str:
    """Print overall + per-table mirroring status. Returns the overall status string."""
    status = get_mirroring_status(workspace_id, db_id, token)
    overall = status.get("status", "Unknown")

    status_icon = {
        "Running": "✓",
        "Stopped": "■",
        "Stopping": "⏹",
        "Starting": "⏵",
        "Initializing": "⏳",
        "Error": "✗",
    }.get(overall, "?")

    print(f"\nMirroring status: {status_icon} {overall}")
    if status.get("lastRefreshTime"):
        print(f"  Last refresh:   {status['lastRefreshTime']}")

    tables = get_tables_status(workspace_id, db_id, token)
    if tables:
        print(f"\n  {'Schema':<20} {'Table':<30} {'Status':<15} {'Processed Rows'}")
        print(f"  {'-'*20} {'-'*30} {'-'*15} {'-'*15}")
        for t in tables:
            schema = t.get("sourceSchemaName", "")
            table = t.get("sourceTableName", "")
            tstatus = t.get("status", "")
            rows = t.get("processedBytes", "")
            print(f"  {schema:<20} {table:<30} {tstatus:<15} {rows}")
    else:
        print("  (No per-table status available yet)")

    return overall


# ── Commands ─────────────────────────────────────────────────────────────────

def cmd_list_connections(name_filter: str | None):
    """List connections visible to the current user."""
    token = get_fabric_token()
    connections = list_connections(token, name_filter)
    if not connections:
        msg = "No connections found."
        if name_filter:
            msg += f" (filter: '{name_filter}')"
        print(msg)
        return
    print(f"{'ID':<38} {'Name':<40} {'Type'}")
    print(f"{'-'*38} {'-'*40} {'-'*20}")
    for c in connections:
        cid = c.get("id", "")
        name = c.get("displayName") or "(unnamed)"
        ctype = c.get("connectivityType", c.get("type", ""))
        print(f"{cid:<38} {name:<40} {ctype}")


def cmd_list_mirrored_databases(workspace_id: str):
    """List all mirrored databases in a workspace.

    NOTE: Fabric creates a companion SQLEndpoint item alongside each MirroredDatabase.
    Both share the same display name. Always use the MirroredDatabase ID in mirroring.yaml,
    not the SQLEndpoint ID (which powers the SQL analytics endpoint).
    """
    token = get_fabric_token()
    dbs = list_mirrored_databases(workspace_id, token)
    if not dbs:
        print(f"No mirrored databases found in workspace {workspace_id}.")
        print(f"\nTip: check that the workspace ID is correct and that you have created a")
        print(f"  'Mirrored Google BigQuery' item in the Fabric portal.")
        return

    print(f"\n  {'ID':<38} {'Name':<40}")
    print(f"  {'-'*38} {'-'*40}")
    for db in dbs:
        print(f"  {db.get('id',''):<38} {db.get('displayName','')}")

    print()
    print("Use the ID above as 'mirrored_database_id' in mirroring.yaml.")
    print("(Fabric also creates a SQLEndpoint with a different ID — do NOT use that one.)")


def cmd_start(config: dict, token: str):
    """Start mirroring and poll until Running."""
    workspace_id = config["workspace_id"]
    db_id = config["mirrored_database_id"]

    print(f"Config:")
    print(f"  Workspace:          {workspace_id}")
    print(f"  Mirrored Database:  {db_id}")
    if config.get("gcp_project_id"):
        print(f"  GCP Project:        {config['gcp_project_id']}")
    if config.get("bigquery_dataset"):
        print(f"  BigQuery Dataset:   {config['bigquery_dataset']}")

    # Check current status before starting
    current = get_mirroring_status(workspace_id, db_id, token).get("status", "")
    if current in ("Running", "Starting", "Initializing"):
        print(f"\nMirroring is already {current}.")
        print_mirroring_status(workspace_id, db_id, token)
        return

    print("\nStarting mirroring...", end=" ", flush=True)
    fabric_request(
        "POST",
        f"/workspaces/{workspace_id}/mirroredDatabases/{db_id}/startMirroring",
        token,
    )
    print("OK")

    # Poll until Running or error
    print(f"Polling for Running state (up to {STATUS_POLL_ATTEMPTS * STATUS_POLL_INTERVAL}s)...")
    for attempt in range(STATUS_POLL_ATTEMPTS):
        time.sleep(STATUS_POLL_INTERVAL)
        status = get_mirroring_status(workspace_id, db_id, token).get("status", "")
        print(f"  [{attempt + 1}/{STATUS_POLL_ATTEMPTS}] {status}")
        if status == "Running":
            break
        if status == "Error":
            print("\nERROR: Mirroring entered an error state.", file=sys.stderr)
            print_mirroring_status(workspace_id, db_id, token)
            sys.exit(1)

    print_mirroring_status(workspace_id, db_id, token)


def cmd_stop(config: dict, token: str):
    """Stop mirroring."""
    workspace_id = config["workspace_id"]
    db_id = config["mirrored_database_id"]

    print(f"Stopping mirroring on {db_id}...", end=" ", flush=True)
    fabric_request(
        "POST",
        f"/workspaces/{workspace_id}/mirroredDatabases/{db_id}/stopMirroring",
        token,
    )
    print("OK")


def cmd_status(config: dict, token: str):
    """Print mirroring status."""
    workspace_id = config["workspace_id"]
    db_id = config["mirrored_database_id"]
    print(f"Mirrored Database: {db_id}")
    print(f"Workspace:         {workspace_id}")
    print_mirroring_status(workspace_id, db_id, token)


def load_config(config_path: str) -> dict:
    with open(config_path, "r") as f:
        config = yaml.safe_load(f)

    for required in ("workspace_id", "mirrored_database_id"):
        val = config.get(required, "")
        if not val or val.startswith("REPLACE_WITH"):
            print(
                f"ERROR: '{required}' is not set in {config_path}.\n"
                f"  Run '--list-mirrored-databases --workspace <ID>' to find the right value.",
                file=sys.stderr,
            )
            sys.exit(1)

    return config


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Manage Fabric mirroring of a Google BigQuery dataset.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See mirroring.yaml for config file format.",
    )
    parser.add_argument(
        "config", nargs="?", default=None,
        help="Path to YAML config file (e.g. mirroring.yaml).",
    )
    parser.add_argument(
        "--status", action="store_true",
        help="Check and display current mirroring status (no start).",
    )
    parser.add_argument(
        "--stop", action="store_true",
        help="Stop mirroring on the configured mirrored database.",
    )
    parser.add_argument(
        "--list-connections", action="store_true",
        help="List available Fabric connections and exit.",
    )
    parser.add_argument(
        "--list-mirrored-databases", action="store_true",
        help="List all mirrored databases in a workspace and exit.",
    )
    parser.add_argument(
        "--workspace", default=None,
        help="Workspace ID for --list-mirrored-databases.",
    )
    parser.add_argument(
        "--filter", default=None,
        help="Filter connections by name (use with --list-connections).",
    )

    args = parser.parse_args()

    if args.list_connections:
        cmd_list_connections(args.filter)
        return

    if args.list_mirrored_databases:
        ws = args.workspace
        if not ws and args.config:
            with open(args.config, "r") as f:
                ws = yaml.safe_load(f).get("workspace_id")
        if not ws:
            print("ERROR: Provide --workspace <WORKSPACE_ID> or a config file.", file=sys.stderr)
            sys.exit(1)
        cmd_list_mirrored_databases(ws)
        return

    if not args.config:
        parser.print_help()
        sys.exit(1)

    config = load_config(args.config)
    token = get_fabric_token()

    if args.stop:
        cmd_stop(config, token)
    elif args.status:
        cmd_status(config, token)
    else:
        cmd_start(config, token)


if __name__ == "__main__":
    main()
