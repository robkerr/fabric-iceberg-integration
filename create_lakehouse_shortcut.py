"""
Create OneLake shortcuts in a Fabric Lakehouse pointing to Iceberg tables
in Google Cloud Storage.

Prerequisites:
  - Azure CLI installed and signed in (`az login`)
  - A Fabric connection to GCS already configured in your tenant

Subcommands:
  list-connections  Search for a connection by name to find its GUID.
  create-shortcut   Create a shortcut to a GCS Iceberg table.

Examples:
  # Find your connection GUID by name
  python create_lakehouse_shortcut.py list-connections --filter "rk_gcp_iceberg"

  # Create a shortcut (using connection name — auto-resolves to GUID)
  python create_lakehouse_shortcut.py create-shortcut \
    --workspace-id 2e83824d-05b8-40d9-b3ff-0f707dd8e696 \
    --lakehouse-id a5e3d9b7-787d-4cde-b24e-51ae823acd38 \
    --connection "rk_gcp_iceberg" \
    --location "https://storage.googleapis.com/my-bucket" \
    --table-path "consulting/engagement_roles"

  # Or use the connection GUID directly
  python create_lakehouse_shortcut.py create-shortcut \
    --workspace-id 2e83824d-05b8-40d9-b3ff-0f707dd8e696 \
    --lakehouse-id a5e3d9b7-787d-4cde-b24e-51ae823acd38 \
    --connection 3c976446-0bda-472e-8800-f1d6e4f162dc \
    --location "https://storage.googleapis.com/my-bucket" \
    --table-path "consulting/engagement_roles"
"""

import argparse
import json
import re
import subprocess
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError

FABRIC_API_BASE = "https://api.fabric.microsoft.com/v1"
UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
)


def get_fabric_token() -> str:
    """Acquire a bearer token for the Fabric API using the Azure CLI."""
    result = subprocess.run(
        ["az", "account", "get-access-token", "--resource", "https://api.fabric.microsoft.com"],
        capture_output=True,
        text=True,
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
            if name_filter_lower in c.get("displayName", "").lower()
        ]

    return connections


def resolve_connection_id(connection_ref: str, token: str) -> str:
    """
    Resolve a connection reference to a GUID.
    If it's already a GUID, return it directly.
    Otherwise, search by name and return the matching connection ID.
    """
    if UUID_PATTERN.match(connection_ref):
        return connection_ref

    connections = list_connections(token, name_filter=connection_ref)

    if not connections:
        print(
            f"ERROR: No connection found matching '{connection_ref}'.\n"
            "Use 'list-connections' to see available connections.",
            file=sys.stderr,
        )
        sys.exit(1)

    if len(connections) > 1:
        print(f"Multiple connections match '{connection_ref}':", file=sys.stderr)
        for c in connections:
            print(f"  {c['id']}  {c.get('displayName', '(unnamed)')}", file=sys.stderr)
        print("\nPlease use the full GUID or a more specific name.", file=sys.stderr)
        sys.exit(1)

    match = connections[0]
    print(f"Resolved connection '{match.get('displayName')}' -> {match['id']}")
    return match["id"]


def create_shortcut(
    workspace_id: str,
    lakehouse_id: str,
    connection_id: str,
    location: str,
    table_path: str,
    token: str,
) -> dict:
    """Create a GCS shortcut in the Lakehouse Tables section."""
    # Derive shortcut name from the last path segment
    shortcut_name = table_path.rstrip("/").split("/")[-1]

    # Ensure subpath has a leading slash
    subpath = f"/{table_path.strip('/')}"

    url = (
        f"{FABRIC_API_BASE}/workspaces/{workspace_id}"
        f"/items/{lakehouse_id}/shortcuts"
    )

    body = {
        "path": "Tables",
        "name": shortcut_name,
        "target": {
            "googleCloudStorage": {
                "location": location,
                "subpath": subpath,
                "connectionId": connection_id,
            }
        },
    }

    print(f"Creating shortcut '{shortcut_name}' -> {location}{subpath}")

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
            action = "Updated" if status == 200 else "Created"
            print(f"  ✓ {action} shortcut '{shortcut_name}' successfully.")
            print(json.dumps(response_body, indent=2))
            return response_body
    except HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(
            f"ERROR: HTTP {e.code} creating shortcut '{shortcut_name}'.\n{error_body}",
            file=sys.stderr,
        )
        sys.exit(1)


def cmd_list_connections(args):
    """Handler for the list-connections subcommand."""
    token = get_fabric_token()
    connections = list_connections(token, name_filter=args.filter)

    if not connections:
        print("No connections found." + (f" (filter: '{args.filter}')" if args.filter else ""))
        return

    print(f"{'ID':<38} {'Name':<40} {'Type'}")
    print(f"{'─' * 38} {'─' * 40} {'─' * 20}")
    for c in connections:
        cid = c.get("id", "")
        name = c.get("displayName", "(unnamed)")
        ctype = c.get("connectivityType", c.get("type", ""))
        print(f"{cid:<38} {name:<40} {ctype}")


def cmd_create_shortcut(args):
    """Handler for the create-shortcut subcommand."""
    token = get_fabric_token()
    connection_id = resolve_connection_id(args.connection, token)

    create_shortcut(
        workspace_id=args.workspace_id,
        lakehouse_id=args.lakehouse_id,
        connection_id=connection_id,
        location=args.location,
        table_path=args.table_path,
        token=token,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Manage OneLake shortcuts to GCS Iceberg tables in Fabric.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # list-connections
    lc_parser = subparsers.add_parser(
        "list-connections",
        help="List available Fabric connections (find your connection GUID).",
    )
    lc_parser.add_argument(
        "--filter", default=None,
        help="Filter connections by name (case-insensitive substring match).",
    )

    # create-shortcut
    cs_parser = subparsers.add_parser(
        "create-shortcut",
        help="Create a shortcut to a GCS Iceberg table in a Lakehouse.",
    )
    cs_parser.add_argument("--workspace-id", required=True, help="Fabric workspace GUID")
    cs_parser.add_argument("--lakehouse-id", required=True, help="Lakehouse item GUID")
    cs_parser.add_argument(
        "--connection", required=True,
        help="Connection name or GUID. If a name is given, it will be resolved to a GUID.",
    )
    cs_parser.add_argument(
        "--location", required=True,
        help="GCS bucket URL, e.g. https://storage.googleapis.com/my-bucket",
    )
    cs_parser.add_argument(
        "--table-path", required=True,
        help='Path to the Iceberg table in the bucket, e.g. "consulting/engagement_roles"',
    )

    args = parser.parse_args()

    if args.command == "list-connections":
        cmd_list_connections(args)
    elif args.command == "create-shortcut":
        cmd_create_shortcut(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
