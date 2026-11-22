"""Standalone isolated-Python launcher; never adds the deployed worker to sys.path."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lcp_desktop_exporter.desktop_export import main

raise SystemExit(main())
