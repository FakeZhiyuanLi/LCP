#!/usr/bin/env python3
"""Idempotently add the LCP server-to-Mac Syncthing catalog folder.

The script talks only to the local Syncthing REST API.  It copies the existing
audio-folder configuration as a template, so version-specific defaults are
preserved, then changes only the catalog folder's ID, label, path, direction,
and device list.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def request(api_url: str, api_key: str, method: str, endpoint: str, body: object | None = None) -> tuple[int, object]:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        f"{api_url.rstrip('/')}{endpoint}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    request.add_unredirected_header("X-API-Key", api_key)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return error.code, None
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"Syncthing {method} {endpoint} failed ({error.code}): {detail}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-xml", type=pathlib.Path, required=True)
    parser.add_argument("--path", type=pathlib.Path, required=True)
    parser.add_argument("--folder-id", default="lecture-classes")
    parser.add_argument("--label", default="Lecture Classes")
    parser.add_argument("--type", choices=("sendonly", "receiveonly"), required=True)
    parser.add_argument("--device-id", action="append", required=True)
    parser.add_argument("--template-folder-id", default="lecture-inbox")
    parser.add_argument("--api-url", default="http://127.0.0.1:8384")
    parser.add_argument(
        "--skip-path-create",
        action="store_true",
        help="Configure Syncthing without creating the path (useful before an administrator creates it)",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    root = ET.parse(args.config_xml).getroot()
    api_key = root.findtext("./gui/apikey")
    if not api_key:
        raise SystemExit("Syncthing API key is missing from the configured XML")

    folder_status, folder = request(args.api_url, api_key, "GET", f"/rest/config/folders/{args.folder_id}")
    if folder_status == 404:
        template_status, template = request(
            args.api_url, api_key, "GET", f"/rest/config/folders/{args.template_folder_id}"
        )
        if template_status != 200 or not isinstance(template, dict):
            raise SystemExit("The Syncthing template folder could not be read")
        folder = template
    if not isinstance(folder, dict):
        raise SystemExit("Syncthing returned an invalid folder configuration")

    folder["id"] = args.folder_id
    folder["label"] = args.label
    folder["path"] = str(args.path)
    folder["type"] = args.type
    existing = {item.get("deviceID"): item for item in folder.get("devices", []) if isinstance(item, dict)}
    folder["devices"] = [
        existing.get(device_id, {"deviceID": device_id, "introducedBy": ""})
        for device_id in dict.fromkeys(args.device_id)
    ]

    if not args.skip_path_create:
        args.path.expanduser().mkdir(parents=True, exist_ok=True)
    status, _ = request(args.api_url, api_key, "PUT", f"/rest/config/folders/{args.folder_id}", folder)
    if status not in (200, 201, 204):
        raise SystemExit(f"Unexpected Syncthing response: {status}")
    print(f"configured {args.folder_id} as {args.type} at {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
