#!/usr/bin/env bash
# ==============================================================================
# sync_to_dropbox.sh - Unidirectional sync from local project to Dropbox
#
# Preserves symlinks without dereferencing (protects raw_data boundary).
# Mirrors changes and deletes stale files in Dropbox destination.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/"
DEST_DIR="/Users/quio/OMRF Dropbox/Agustin Carbajal/Bioinformatics/Temp_files/tracking_changes_scientific_projects/"

if [[ ! -d "$DEST_DIR" ]]; then
    mkdir -p "$DEST_DIR"
fi

if [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]]; then
    echo "=== Running dry-run sync to Dropbox ==="
    rsync -avn --delete "$SOURCE_DIR" "$DEST_DIR"
else
    echo "=== Syncing project to Dropbox (unidirectional) ==="
    rsync -av --delete "$SOURCE_DIR" "$DEST_DIR"
    echo "=== Sync complete! ==="
fi
