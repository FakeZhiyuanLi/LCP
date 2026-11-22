"""The server accepts the same course-code character categories as the Mac."""

import json
from datetime import datetime

import pytest

from lcp_server.manifest import load_manifest, manifest_from_data


def manifest_data(course="CS182", timestamp="2026-10-18_1430"):
    return {
        "version": 1,
        "filename": f"{course}_{timestamp}.m4a",
        "size_bytes": 3,
        "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    }


def test_decomposed_unicode_course_preserves_spelling_and_local_timestamp(tmp_path):
    data = manifest_data("Cafe\u0301")
    marker = tmp_path / f"{data['filename']}.ready.json"
    marker.write_text(json.dumps(data))

    manifest = load_manifest(marker, tmp_path)

    assert manifest.course == "Cafe\u0301"
    assert manifest.filename == data["filename"]
    assert manifest.captured_at == datetime(2026, 10, 18, 14, 30)
    assert manifest.captured_at.tzinfo is None
    assert manifest.expected == (data["size_bytes"], data["sha256"])


@pytest.mark.parametrize("course", ["CS_182-A", "数学١", "CSⅠ", "कक्षा", "A\u20dd", "\u0301"])
def test_course_allows_unicode_letters_marks_numbers_and_separators(course):
    assert manifest_from_data(manifest_data(course)).course == course


@pytest.mark.parametrize("course", [
    "", "../CS182", "/CS182", "CS/182", "CS\\182", "CS.182", "..", ".",
    "CS\t182", "CS\n182", "CS\u00a0182", "CS\u200b182", "CS\x00182", "CS🎓",
])
def test_course_rejects_traversal_whitespace_controls_and_symbols(course):
    with pytest.raises(ValueError):
        manifest_from_data(manifest_data(course))


def test_course_allows_drive_folder_names_with_ascii_spaces():
    assert manifest_from_data(manifest_data("CS 182")).course == "CS 182"


@pytest.mark.parametrize("timestamp", ["2026-02-30_1430", "2026-10-18_2460", "2026-10-18_143000"])
def test_unicode_course_does_not_relax_timestamp_validation(timestamp):
    with pytest.raises(ValueError):
        manifest_from_data(manifest_data("Cafe\u0301", timestamp))
