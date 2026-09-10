# Antigravity Agent Guidelines: Scientific Data Tracking & Reproducibility

You are assisting with a scientific / genomics repository that follows a strict **Three Pillars Reproducibility Workflow**.

---

## 1. Core Architectural Constraints

1. **Strict Raw Data Boundary:**
   - Raw datasets (FASTQs, BAMs, CRAMs, matrices) are stored externally under `$DATA_ROOT` (or named roots like `$REF_ROOT`) and accessed locally via symlinks in `raw_data/` (or project subdirectories when `SYMLINK_DIR=.` is configured in `.env`).
   - **NEVER** stage, commit, or force-add (`git add -f`) raw data symlinks or any large binary files.
   - An Antigravity AI lifecycle hook (`.agents/hooks.json`) is actively enforcing this rule; attempting to run `git add -f` will be hard-blocked.
   - **NEVER** use `view_file` or shell dumping (`cat`, `head`) on large binary files (`.bam`, `.cram`, `.fastq.gz`). Use domain tools like `samtools view -H` or `zcat | head` instead.

2. **Strict Read-Only Source Data Invariant (Immutable Raw Inputs):**
   - Source datasets under storage roots and their local symlinks are **strictly immutable and read-only**.
   - **NEVER** edit, overwrite, append to, truncate, delete, or rename source data files in any way (whether directly or through shell redirection, `rm`, `sed`, `mv`, Python, R, or pipeline outputs).
   - Any pipeline outputs, intermediate files, or filtered datasets must **always** be directed to project output folders (e.g. `results/`, `output/`, `scratch/`), **never** back into storage roots or symlink folders.

3. **Data-Tracking Operations via CLI:**
   Always use `./scripts/data_tracker.sh` for dataset management:
   - To register / lock a new dataset: `./scripts/data_tracker.sh add <link_name> <rel_data_path> <rel_checksum_path>`
   - To auto-adopt existing project symlinks: `./scripts/data_tracker.sh adopt [--dry-run]`
   - To verify data integrity: `./scripts/data_tracker.sh verify` (Tier 1 fast handshake across all active roots)
   - For pre-publication audits: `./scripts/data_tracker.sh verify --deep` (Tier 2 full cryptographic calculation)
   - To adopt new upstream hashes: `./scripts/data_tracker.sh update <link_name>`
   - If storage directories moved: `./scripts/data_tracker.sh relocate <old_path> <new_path>`
   - To provision local symlinks: `./scripts/data_tracker.sh link`
   - To inspect data status: `./scripts/data_tracker.sh status`

4. **In-Script & In-Document Versioning (Pillar 3):**
   - When generating new Quarto (`.qmd`) documents in R, always conclude with a final chunk calling `sessioninfo::session_info()`.
   - When generating Quarto documents in Python, conclude with `session_info.show()` (via `import session_info`).
   - When writing Python scripts (`.py`), include a top docstring specifying the tested Python version and core package versions.
   - When writing Bash pipeline scripts (`.sh`), document tested CLI tools (`samtools`, `bedtools`, etc.) in the header block.
   - Do not force monolithic Conda environments unless explicitly asked. Prefer standard virtual environments (`venv`).

5. **Human-in-the-Loop Diagnostics (Never Auto-Update Pointers):**
   If a Git pre-commit hook fails:
   - **NEVER** run `./scripts/data_tracker.sh update` or modify `local_pointers.tsv` autonomously. An unexpected checksum mismatch could indicate data corruption or an unmounted volume.
   - Diagnose the issue: check if `$DATA_ROOT` is mounted, whether the checksum is stale, or if the upstream hash changed.
   - Clearly report the findings to the user and **wait for their explicit confirmation** before running any update or pointer modification.
