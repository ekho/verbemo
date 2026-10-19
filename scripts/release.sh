#!/usr/bin/env bash
# Deliberately no implicit build or publication from the old entry point.
set -euo pipefail
cat <<'HELP'
Verbemo uses one common release for macOS and Windows.
Use .github/workflows/release.yml with ref, version and operation:
  prepare (default): build both signed platforms and validate artifacts
  publish: prepare both platforms, verify downloads, then promote latest
  resume: verify an already published release and finish latest promotion
Offline validation: python3 scripts/release.py prepare --help
Local development without release credentials: make app SIGN_ID=-
HELP
exit 2
