---
name: scientific-data-tracking
description: >-
  Manage, verify, and lock external raw datasets in scientific and genomics projects using
  data_tracker.sh. Activate when the user asks to add datasets, verify data integrity,
  run deep cryptographic checks, update locked hashes, or relocate storage paths.
---

# Scientific Data-Tracking Skill for Antigravity

Use this skill when managing raw external datasets, pointers in `local_pointers.tsv`,
and verification checks in this repository.

## Operational Procedures

### 1. Adding Datasets
When adding or tracking datasets:
```bash
# Single dataset:
./scripts/data_tracker.sh add <link_name> <relative_source_path> <relative_source_metadata_path>

# Batch registration (shallow):
./scripts/data_tracker.sh add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> [-p "*.bam"]

# Batch registration (recursive directory tree with real folders & file symlinks):
./scripts/data_tracker.sh add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> -r [-p "*.bw"]
```
*Note*: The tool checks the Stale Checksum Guard before locking the hash. If the checksum file is older than the binary, notify the user that upstream checksums must be regenerated.
*Multi-Mount*: For datasets spanning multiple drives, prefix the source path with the root variable name (e.g., `REF_ROOT:genomes/hg38.fa`).
*Directory Symlink Policy*: Never symlink directories. Use `add-batch -r` so intermediate directories are real physical folders (`mkdir -p`) and leaf files are tracked symlinks.

### 2. Auto-Adopting Existing Project Symlinks
When adopting the workflow on an existing project where symlinks already exist across project directories:
```bash
# Preview adoption with detailed categorization report
./scripts/data_tracker.sh adopt --dry-run --report

# List symlinks lacking upstream checksums
./scripts/data_tracker.sh adopt --missing-checksums

# List symlinks pointing to directories (must convert to real folders via add-batch -r)
./scripts/data_tracker.sh adopt --directory-symlinks

# List unignored symlinks and add them to .gitignore
./scripts/data_tracker.sh adopt --unignored >> .gitignore

# Run adoption, audit .gitignore safety, and auto-populate local_pointers.tsv
./scripts/data_tracker.sh adopt
```

### 3. Viewing Command Help
Display rich documentation and examples for any command:
```bash
./scripts/data_tracker.sh help <command>
./scripts/data_tracker.sh <command> --help
```

### 4. Routine Tier 1 Fast Verification
Run to check that all files exist across all configured storage roots, checksums are fresh, and locked hashes match upstream metadata:
```bash
./scripts/data_tracker.sh verify
```

### 4. Tier 2 Deep Cryptographic Audit
When the user asks to "audit", "deep check", or verify prior to paper submission / cluster job launch:
```bash
./scripts/data_tracker.sh verify --deep
```

### 5. Updating a Legitimate Change
If upstream data was legitimately re-sequenced or re-aligned:
```bash
./scripts/data_tracker.sh update <link_name>
```

### 6. Relocating Storage Paths
If external mounts or folders were reorganized (e.g. from `cohort_a/` to `archive/cohort_a/`):
```bash
./scripts/data_tracker.sh relocate <old_path_string> <new_path_string>
```

### 7. Provisioning or Repairing Symlinks
When opening the project on a new machine or cluster node:
```bash
./scripts/data_tracker.sh link
```

## Constraints
* Never run `git add -f` or `git add raw_data/`.
* Never read binary files (`.bam`, `.cram`, `.fastq.gz`) with `view_file` or `cat`.
* Source datasets under `$DATA_ROOT` and `raw_data/` are strictly read-only: never modify, overwrite, append to, truncate, delete, or rename source data. Direct all pipeline outputs to `results/` or `output/`.
