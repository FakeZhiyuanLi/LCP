#!/bin/bash
# Keep the existing shell entry point for local release workflows.
set -eu
exec python3 "$(dirname "$0")/package_release.py" "$@"
