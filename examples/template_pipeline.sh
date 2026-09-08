#!/usr/bin/env bash
# ==============================================================================
# template_pipeline.sh - Template Pipeline Step
#
# Demonstrates In-Script CLI Tool Version Declaration:
# Documents external standalone binaries tested for this pipeline step.
#
# Tested CLI Tool Versions:
#   - samtools: 1.18+ (tested on 1.18)
#   - bedtools: 2.31.0+ (tested on 2.31.0)
#   - bwa-mem2: 2.2.1+
#
# Installation Hints:
#   - macOS:  brew install samtools bedtools
#   - Ubuntu: apt install samtools bedtools
#   - HPC:    module load samtools bedtools
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Running Template Pipeline Step ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"

# Optional: Log tool versions to pipeline run output
if command -v samtools >/dev/null 2>&1; then
    echo "samtools: $(samtools --version | head -n 1)"
fi
if command -v bedtools >/dev/null 2>&1; then
    echo "bedtools: $(bedtools --version)"
fi

# Ensure data pointers are linked
if [[ ! -d "${PROJECT_ROOT}/raw_data" ]]; then
    echo "Provisioning data symlinks..."
    "${PROJECT_ROOT}/scripts/data_tracker.sh" link
fi

echo "Pipeline step completed."
