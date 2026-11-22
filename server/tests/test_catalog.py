"""Rack-side Drive folder catalog tests use an argument-vector fake rclone."""

import json
import subprocess
from pathlib import Path

import pytest

from lcp_server import catalog_cli
from lcp_server.catalog import CatalogError, DriveClassCatalog


class FakeRclone:
    def __init__(self, payload):
        self.payload = payload
        self.commands = []

    def __call__(self, command, **kwargs):
        self.commands.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, self.payload, b"")


def test_catalog_lists_immediate_drive_folders_and_preserves_exact_names(tmp_path):
    remote = FakeRclone(json.dumps([
        {"Name": "PHIL 102", "ID": "phil-id", "IsDir": True},
        {"Name": "CS 201", "ID": "cs-id", "IsDir": True},
        {"Name": "LCP Test", "ID": "test-id", "IsDir": True},
        {"Name": "ignored.txt", "ID": "file-id", "IsDir": False},
    ]).encode())
    catalog = DriveClassCatalog(
        "gdrive", "root-id", runner=remote
    )

    classes = catalog.list_classes()

    assert [(item.name, item.folder_id) for item in classes] == [
        ("CS 201", "cs-id"),
        ("PHIL 102", "phil-id"),
    ]
    command = remote.commands[0][0]
    assert command[:4] == ["rclone", "lsjson", "gdrive:", "--dirs-only"]
    assert "--max-depth" in command and command[command.index("--drive-root-folder-id") + 1] == "root-id"


def test_catalog_can_explicitly_include_reserved_test_folder():
    remote = FakeRclone(json.dumps([
        {"Name": "LCP Test", "ID": "test-id", "IsDir": True},
        {"Name": "LIT 101", "ID": "lit-id", "IsDir": True},
    ]).encode())

    classes = DriveClassCatalog(
        "gdrive", "root-id", runner=remote, include_test_folder=True
    ).list_classes()

    assert [(item.name, item.folder_id) for item in classes] == [
        ("LIT 101", "lit-id"),
        ("LCP Test", "test-id"),
    ]


def test_catalog_cli_excludes_test_folder_by_default_and_forwards_explicit_opt_in(
    tmp_path, monkeypatch
):
    calls = []

    class FakeCatalog:
        def __init__(self, **kwargs):
            calls.append(kwargs)

        def write(self, output):
            return {"classes": []}

    monkeypatch.setattr(catalog_cli, "DriveClassCatalog", FakeCatalog)
    common = [
        "--output", str(tmp_path / "classes.json"),
        "--remote", "gdrive",
        "--drive-root-folder-id", "root-id",
    ]

    assert catalog_cli.main(common) == 0
    assert calls[-1]["include_test_folder"] is False
    assert catalog_cli.main([*common, "--include-test-folder"]) == 0
    assert calls[-1]["include_test_folder"] is True


def test_catalog_write_is_versioned_and_atomic(tmp_path):
    remote = FakeRclone(json.dumps([
        {"Name": "LIT 101", "ID": "lit-id", "IsDir": True},
    ]).encode())
    output = tmp_path / "nested" / "classes.json"
    manifest = DriveClassCatalog("gdrive", "root-id", runner=remote).write(output)

    assert json.loads(output.read_text()) == manifest
    assert manifest["version"] == 1
    assert manifest["source"] == "google_drive"
    assert manifest["root_folder_id"] == "root-id"
    assert manifest["classes"] == [{
        "name": "LIT 101",
        "course_code": "LIT 101",
        "drive_folder_id": "lit-id",
    }]
    assert isinstance(manifest["generated_at"], str)


@pytest.mark.parametrize(
    "listing",
    [
        [{"Name": "A/B", "ID": "folder-id", "IsDir": True}],
        [{"Name": "..", "ID": "folder-id", "IsDir": True}],
        [{"Name": "Class", "ID": "bad/id", "IsDir": True}],
        [{"Name": "Class", "ID": "same", "IsDir": True},
         {"Name": "class", "ID": "other", "IsDir": True}],
    ],
)
def test_catalog_rejects_unsafe_or_ambiguous_drive_folders(listing):
    remote = FakeRclone(json.dumps(listing).encode())
    with pytest.raises(CatalogError, match="Drive"):
        DriveClassCatalog("gdrive", "root-id", runner=remote).list_classes()


def test_catalog_does_not_replace_existing_snapshot_on_refresh_failure(tmp_path):
    output = tmp_path / "classes.json"
    output.write_text('{"version": 1, "classes": []}\n')
    remote = FakeRclone(b"not-json")
    with pytest.raises(CatalogError):
        DriveClassCatalog("gdrive", "root-id", runner=remote).write(output)
    assert output.read_text() == '{"version": 1, "classes": []}\n'


@pytest.mark.parametrize("remote", ["", "gdrive:path", ":local:", "bad/name"])
def test_catalog_rejects_unscoped_remote(remote):
    with pytest.raises(ValueError, match="remote"):
        DriveClassCatalog(remote, "root-id")
