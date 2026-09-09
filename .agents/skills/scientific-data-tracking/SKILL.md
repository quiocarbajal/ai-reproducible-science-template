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

### 1. Adding a New Dataset
When the user wants to add or track a new sample:
```bash
./scripts/data_tracker.sh add <link_name> <relative_source_path> <relative_source_metadata_path>
```
*Note*: The tool checks the Stale Checksum Guard before locking the hash. If the checksum file is older than the binary, notify the user that upstream checksums must be regenerated.

### 2. Routine Tier 1 Fast Verification
Run to check that all files exist, checksums are fresh, and locked hashes match upstream metadata:
```bash
./scripts/data_tracker.sh verify
```

### 3. Tier 2 Deep Cryptographic Audit
When the user asks to "audit", "deep check", or verify prior to paper submission / cluster job launch:
```bash
./scripts/data_tracker.sh verify --deep
```

### 4. Updating a Legitimate Change
If upstream data was legitimately re-sequenced or re-aligned:
```bash
./scripts/data_tracker.sh update <link_name>
```

### 5. Relocating Storage Paths
If external mounts or folders were reorganized (e.g. from `cohort_a/` to `archive/cohort_a/`):
```bash
./scripts/data_tracker.sh relocate <old_path_string> <new_path_string>
```

### 6. Provisioning or Repairing Symlinks
When opening the project on a new machine or cluster node:
```bash
./scripts/data_tracker.sh link
```

## Constraints
* Never run `git add -f` or `git add raw_data/`.
* Never read binary files (`.bam`, `.cram`, `.fastq.gz`) with `view_file` or `cat`.
* Source datasets under `$DATA_ROOT` and `raw_data/` are strictly read-only: never modify, overwrite, append to, truncate, delete, or rename source data. Direct all pipeline outputs to `results/` or `output/`.
