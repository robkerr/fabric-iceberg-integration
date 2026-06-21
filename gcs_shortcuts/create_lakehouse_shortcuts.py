"""
Create OneLake shortcuts in a Fabric Lakehouse pointing to Iceberg tables
in Google Cloud Storage.

Prerequisites:
  - Azure CLI installed and signed in (`az login`)
  - Google Cloud CLI installed and signed in (`gcloud auth login`) — for
    auto-discovery mode
  - A Fabric connection to GCS already configured in your tenant
  - PyYAML installed (`pip install pyyaml`)

Usage:
  # Create shortcuts from a YAML config file (manual table_paths)
  python create_lakehouse_shortcut.py shortcuts.yaml

  # Auto-discover Iceberg tables in a GCS prefix and create shortcuts
  # (set gcs_bucket + gcs_prefix in YAML, omit table_paths)
  python create_lakehouse_shortcut.py shortcuts.yaml

  # Find your connection GUID by name
  python create_lakehouse_shortcut.py --list-connections [--filter NAME]

See shortcuts.yaml for the config file format.

Reference:
  https://learn.microsoft.com/en-us/rest/api/fabric/core/onelake-shortcuts/create-shortcut
"""

import argparse
import json
import re
import subprocess
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

import yaml

FABRIC_API_BASE = "https://api.fabric.microsoft.com/v1"
UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
)
DELAY_BETWEEN_CALLS = 3  # seconds between shortcut creation calls


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
    token_info = json.loads(result.stdout)
    return token_info["accessToken"]


def fabric_get(path: str, token: str) -> dict:
    """Make a GET request to the Fabric REST API."""
    url = f"{FABRIC_API_BASE}{path}"
    req = Request(url, headers={"Authorization": f"Bearer {token}"}, method="GET")
    try:
        with urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"ERROR: HTTP {e.code} on GET {path}\n{error_body}", file=sys.stderr)
        sys.exit(1)


def list_connections(token: str, name_filter: str | None = None) -> list[dict]:
    """
    Fetch all connections visible to the current user.
    Optionally filter by name (case-insensitive substring match).
    """
    data = fabric_get("/connections", token)
    connections = data.get("value", [])

    if name_filter:
        name_filter_lower = name_filter.lower()
        connections = [
            c for c in connections
            if name_filter_lower in (c.get("displayName") or "").lower()
        ]

    return connections


def resolve_connection(connection_ref: str, token: str) -> tuple[str, str | None]:
    """
    Resolve a connection reference to a (GUID, location) tuple.
    If it's already a GUID, fetch connection details to get the location.
    Otherwise, search by name, return the matching connection ID and location.
    """
    if UUID_PATTERN.match(connection_ref):
        details = fabric_get(f"/connections/{connection_ref}", token)
        location = (details.get("connectionDetails") or {}).get("path")
        return connection_ref, location

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
        print("\nPlease use the full GUID or a more specific name.", file=sys.stderr)
        sys.exit(1)

    match = connections[0]
    conn_id = match["id"]
    print(f"Resolved connection '{match.get('displayName')}' -> {conn_id}")

    details = fabric_get(f"/connections/{conn_id}", token)
    location = (details.get("connectionDetails") or {}).get("path")
    return conn_id, location


def discover_iceberg_tables(gcs_bucket: str, gcs_prefix: str) -> list[str]:
    """
    Scan a GCS bucket/prefix for Iceberg tables using gcloud storage ls.
    An Iceberg table is identified by the presence of a metadata/ subfolder.
    Returns a list of table paths relative to the bucket root.
    """
    # Normalize: ensure bucket starts with gs:// and prefix has no leading/trailing slashes
    if not gcs_bucket.startswith("gs://"):
        gcs_bucket = f"gs://{gcs_bucket}"
    gcs_bucket = gcs_bucket.rstrip("/")
    gcs_prefix = gcs_prefix.strip("/")

    scan_url = f"{gcs_bucket}/{gcs_prefix}/" if gcs_prefix else f"{gcs_bucket}/"
    print(f"Scanning for Iceberg tables in: {scan_url}")

    # List immediate subdirectories under the prefix
    result = subprocess.run(
        ["gcloud", "storage", "ls", scan_url],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: Failed to list GCS path: {scan_url}\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    # Each line is a full gs:// path ending with /
    subdirs = [line.strip() for line in result.stdout.strip().splitlines() if line.strip().endswith("/")]

    if not subdirs:
        print("No subdirectories found.")
        return []

    # Check each subdirectory for a metadata/ subfolder
    tables = []
    for subdir in subdirs:
        metadata_path = f"{subdir}metadata/"
        check = subprocess.run(
            ["gcloud", "storage", "ls", metadata_path],
            capture_output=True,
            text=True,
        )
        if check.returncode == 0 and check.stdout.strip():
            # Extract the relative table path from the full gs:// URL
            # e.g. gs://bucket/consulting/clients/ -> consulting/clients
            bucket_prefix = f"{gcs_bucket}/"
            relative_path = subdir.replace(bucket_prefix, "").strip("/")
            tables.append(relative_path)

    return tables


def confirm_tables(tables: list[str]) -> list[str]:
    """
    Display discovered tables and ask the user for confirmation.
    Returns the confirmed list of table paths, or exits if declined.
    """
    print(f"\nDiscovered {len(tables)} Iceberg table(s):\n")
    for i, table in enumerate(tables, 1):
        name = table.rstrip("/").split("/")[-1]
        print(f"  {i:3}. {name:<30} ({table})")

    print()
    answer = input("Create shortcuts for all tables above? [Y/n] ").strip().lower()
    if answer in ("", "y", "yes"):
        return tables
    else:
        print("Aborted.")
        sys.exit(0)


def create_shortcut(
    workspace_id: str,
    lakehouse_id: str,
    connection_id: str,
    location: str,
    table_path: str,
    token: str,
    schema: str = "dbo",
    overwrite: bool = False,
) -> dict | None:
    """
    Create a GCS shortcut in the Lakehouse Tables section.
    Returns the response body on success, or None on failure (non-fatal).
    """
    shortcut_name = table_path.rstrip("/").split("/")[-1]
    subpath = f"/{table_path.strip('/')}"
    shortcut_path = f"Tables/{schema}" if schema else "Tables"

    url = (
        f"{FABRIC_API_BASE}/workspaces/{workspace_id}"
        f"/items/{lakehouse_id}/shortcuts"
    )
    if overwrite:
        url += "?shortcutConflictPolicy=CreateOrOverwrite"

    body = {
        "path": shortcut_path,
        "name": shortcut_name,
        "target": {
            "googleCloudStorage": {
                "location": location,
                "subpath": subpath,
                "connectionId": connection_id,
            }
        },
    }

    print(f"  [{shortcut_name}] {shortcut_path} -> {location}{subpath}", end=" ... ")

    req = Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urlopen(req) as resp:
            status = resp.status
            response_body = json.loads(resp.read().decode("utf-8"))
            action = "updated" if status == 200 else "created"
            print(f"OK ({action})")
            return response_body
    except HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"FAILED (HTTP {e.code})")
        print(f"    {error_body}", file=sys.stderr)
        return None


def cmd_list_connections(name_filter: str | None):
    """List connections visible to the current user."""
    token = get_fabric_token()
    connections = list_connections(token, name_filter=name_filter)

    if not connections:
        print("No connections found." + (f" (filter: '{name_filter}')" if name_filter else ""))
        return

    print(f"{'ID':<38} {'Name':<40} {'Type'}")
    print(f"{'-' * 38} {'-' * 40} {'-' * 20}")
    for c in connections:
        cid = c.get("id", "")
        name = c.get("displayName") or "(unnamed)"
        ctype = c.get("connectivityType", c.get("type", ""))
        print(f"{cid:<38} {name:<40} {ctype}")


def cmd_create_shortcuts(config_path: str):
    """Create shortcuts from a YAML config file."""
    with open(config_path, "r") as f:
        config = yaml.safe_load(f)

    workspace_id = config["workspace_id"]
    lakehouse_id = config["lakehouse_id"]
    connection_ref = config["connection"]
    schema = config.get("schema", "dbo")
    overwrite = config.get("overwrite", False)
    location_override = config.get("location")
    table_paths = config.get("table_paths", [])

    # Auto-discovery mode: scan GCS for Iceberg tables
    gcs_bucket = config.get("gcs_bucket")
    gcs_prefix = config.get("gcs_prefix", "")

    if not table_paths and gcs_bucket:
        discovered = discover_iceberg_tables(gcs_bucket, gcs_prefix)
        if not discovered:
            print("No Iceberg tables found at the specified location.", file=sys.stderr)
            sys.exit(1)
        table_paths = confirm_tables(discovered)

    if not table_paths:
        print("No table_paths specified in config file and no gcs_bucket for discovery.", file=sys.stderr)
        sys.exit(1)

    print(f"\nConfig: {config_path}")
    print(f"  Workspace:  {workspace_id}")
    print(f"  Lakehouse:  {lakehouse_id}")
    print(f"  Schema:     {schema or '(none)'}")
    print(f"  Overwrite:  {overwrite}")
    print(f"  Tables:     {len(table_paths)}")
    print()

    # Single token fetch for all calls
    token = get_fabric_token()
    connection_id, resolved_location = resolve_connection(connection_ref, token)

    # For discovery mode, derive location from gcs_bucket if not otherwise set
    location = location_override or resolved_location
    if not location and gcs_bucket:
        location = gcs_bucket.rstrip("/")
        if not location.startswith("gs://"):
            location = f"gs://{location}"

    if not location:
        print(
            "ERROR: Could not determine bucket location from the connection.\n"
            "Add 'location' or 'gcs_bucket' to the config file.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"  Location:   {location}")
    print()

    succeeded = 0
    failed = 0
    for i, table_path in enumerate(table_paths):
        result = create_shortcut(
            workspace_id=workspace_id,
            lakehouse_id=lakehouse_id,
            connection_id=connection_id,
            location=location,
            table_path=table_path,
            token=token,
            schema=schema,
            overwrite=overwrite,
        )
        if result is not None:
            succeeded += 1
        else:
            failed += 1

        # Back off between calls (skip after the last one)
        if i < len(table_paths) - 1:
            time.sleep(DELAY_BETWEEN_CALLS)

    print()
    print(f"Done: {succeeded} succeeded, {failed} failed out of {len(table_paths)} total.")
    if failed > 0:
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Create OneLake shortcuts to GCS Iceberg tables from a YAML config.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See shortcuts.yaml for config file format.",
    )
    parser.add_argument(
        "config", nargs="?", default=None,
        help="Path to YAML config file (e.g. shortcuts.yaml).",
    )
    parser.add_argument(
        "--list-connections", action="store_true",
        help="List available Fabric connections and exit.",
    )
    parser.add_argument(
        "--filter", default=None,
        help="Filter connections by name (use with --list-connections).",
    )

    args = parser.parse_args()

    if args.list_connections:
        cmd_list_connections(args.filter)
    elif args.config:
        cmd_create_shortcuts(args.config)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
