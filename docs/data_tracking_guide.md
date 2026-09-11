# Scientific Project Data-Tracking: Template & Adoption Guide

A lightweight, reproducible data-tracking and verification framework for genomics and scientific projects tracked in Git.  

---

## Workflow Summary  
A lightweight reproducibility workflow for scientific repositories that manages external data, analysis code, and software environments across three pillars:  
* **Raw Data (Pillar 1):** Large datasets remain on external storage, mapped into the project via symlinks (usually in `raw_data/` but can be anywhere else) and verified against upstream cryptographic hashes and modification timestamps via a Git-tracked manifest (`local_pointers.tsv`) that records relative paths and locked hashes.  
* **Code & Workflows (Pillar 2):** Scripts, pipelines, and notebooks are tracked directly in Git. Raw data and pipeline intermediates and results are excluded.  
* **Environment Provenance (Pillar 3):** Software and library versions are declared directly inside each script (header docstrings) and notebook (e.g., `session_info()`).  

---

## 1. The Core Philosophy: The Three Reproducibility Pillars

In scientific computing, raw datasets (FASTQs, BAMs, large matrices) are too massive to track directly in Git. However, storing them loosely without cryptographic versioning ruins reproducibility.  

This workflow is anchored on the **Three Pillars of Reproducibility**:  

$$\mathbf{Locked\ Raw\ Data} + \mathbf{Git\ Code} + \mathbf{In\text{-}Script\ Environment\ Provenance} \implies \mathbf{Biological\ Reproducibility}$$  

```
+-------------------------------------------------------------------------------+
|                             REPRODUCIBILITY TRIANGLE                          |
|                                                                               |
|   [Pillar 1: Raw Data]          [Pillar 2: Code & Workflows] [Pillar 3: Env] |
|   - External $DATA_ROOT         - Git commits                - In-script state|
|   - local_pointers.tsv          - scripts/                   - session_info() |
|   - Symlinks in raw_data/       - *.qmd notebooks anywhere   - Script headers |
|   - Upstream checksum files     - Pipeline definitions       - Standard venvs |
+-------------------------------------------------------------------------------+
                                        │
                                        ▼
             Everything else is DERIVED STATE and STRICTLY EXCLUDED:
           (results/, work/, .snakemake/, .nextflow/, scratch/, logs/)
```

### Biological Reproducibility vs. Monolithic Lockfile Overkill
The goal of this architecture is **pragmatic scientific reproducibility** (guaranteeing that biological conclusions can be faithfully verified and reproduced) rather than fragile, byte-for-byte bit-level identity.  

Centralized, monolithic lockfiles (like 500-line Conda files) often fail on HPC clusters due to permission issues, incompatible drivers, or package deprecations. By contrast, **co-locating the software versions directly inside the scripts and notebooks** keeps code and provenance permanently locked together in Git history.  

---

## 2. Pillar 3: In-Script & In-Document Version Provenance

Rather than relying on a single, brittle global environment, this project adopts **co-located provenance**: every analysis file explicitly documents the tools and versions it was executed with.  

### A. R & Quarto Notebooks (`.qmd`)
In the R community, calling `sessionInfo()` in the final chunk is the gold standard. When rendered to HTML, Markdown, or PDF, the exact R version, attached libraries, and system architecture become a permanent part of the document:  

```yaml
---
title: "Differential Expression Analysis"
# Tested: R 4.3+, DESeq2 (v1.42+), edgeR (v3.44+)
---
```

At the end of the document:  
```r
sessioninfo::session_info() # or sessionInfo()
```
*(See working template in [`examples/template_analysis_r.qmd`](examples/template_analysis_r.qmd))*  

### B. Python Quarto Notebooks (`.qmd`)
For Python chunks in Quarto, use the **`session_info`** package (the direct Python analogue to R's `sessionInfo`):  
```bash
pip install session_info
```

In the final notebook chunk:  
```python
import session_info
session_info.show()
```
This automatically inspects all loaded packages and prints their versions, Python build, OS, and timestamp directly into the rendered output.  
*(See working template in [`examples/template_analysis_python.qmd`](examples/template_analysis_python.qmd))*  

### C. Python Analysis Scripts (`.py`)
Python scripts document their environment and virtual environment requirements in their top docstring:  
```python
"""
02_variant_annotation.py

Tested environment & core versions:
  - Python: 3.11.8 (standard venv)
  - polars: 0.20.15
  - pysam: 0.22.0
  - bedtools (CLI): 2.31.0
"""
```
*(See working template in [`examples/template_script.py`](examples/template_script.py))*  

### D. Standalone CLI Tools in Bash Pipelines (`.sh`)
External command-line binaries (`bedtools`, `samtools`, `bwa-mem2`) installed via Homebrew, `apt`, or HPC modules (`module load`) are documented directly in script headers:  
```bash
#!/usr/bin/env bash
# Tested CLI tool versions:
#   bwa-mem2: 2.2.1
#   samtools: 1.18
#   bedtools: 2.31.0
```
*(See working template in [`examples/template_pipeline.sh`](examples/template_pipeline.sh))*  

---

## 3. Why Not Git LFS, git-annex, or DVC?

| Feature | Git LFS / git-annex / DVC | This Architecture |
| :--- | :--- | :--- |
| **HPC Friendly** | Requires special daemons, root setup, or cluster permissions | **Zero dependencies**: pure POSIX/Bash (`awk`, `grep`, `stat`) |
| **Local Compute Overhead** | Calculates multi-GB/TB hashes on checkout | **Sub-second handshake**: reads upstream metadata text file |
| **Storage Overhead** | Duplicates files into internal `.dvc/cache` or `.git/annex` | **Zero duplication**: uses lightweight symlinks (`ln -s`) |
| **Stale Checksum Protection** | None (hashes blindly) | **Stale Checksum Guard**: flags if binary is newer than checksum |
| **Portability** | Hardcodes absolute paths or requires remote buckets | **Path templating**: relative to `$DATA_ROOT` |

---

## 4. The Two-Tier Verification Handshake

Metadata and hashes are managed **at the source** (e.g. by sequencing cores, HPC repositories, or public archives).  

### Tier 1: Fast Handshake & Stale-Guard Gate (Sub-Second)
Executed automatically on every `git commit` via the pre-commit hook:  
1. **File Existence Check**: Ensures both the raw data and upstream checksum file exist.  
2. **Stale Checksum Guard (`mtime` check)**: Compares file modification timestamps:  
   $$\text{mtime}(\text{upstream checksum}) \ge \text{mtime}(\text{binary data})$$  
   If the binary data file is newer than the checksum file, the checksum is **stale** and untrustworthy. The commit is rejected.  
3. **Hash Matching**: Extracts the hash for the specific binary from the upstream multi-line checksum file (`md5sum *` or `sha256sum *`) and compares it against `locked_hash` in `local_pointers.tsv`.  

### Tier 2: Deep Cryptographic Verification (On Demand)
Invoked via `--deep`:  
* Calculates the actual cryptographic hash (`md5sum`, `sha256sum`) of the physical binary file.  
* Guarantees that neither silent bit rot, filesystem corruption, nor intentional tampering has occurred.  
* Recommended before pipeline execution, cluster job submissions, and paper publication.  

---

## 5. Quickstart: Using as a Starter Template for New Projects

### Step 1: Initialize Your Project
```bash
# 1. Clone or copy this template repository
git clone <template-repo-url> my_genomics_project
cd my_genomics_project

# 2. Run the one-step bootstrap command
./scripts/data_tracker.sh init
```
This automatically:  
- Provisions the local `raw_data/` directory (gitignored).  
- Sets up `local_pointers.tsv`.  
- Generates `.env` from `.env.example` if not present.  
- Configures the Git pre-commit hook (`git config core.hooksPath .githooks`).  

### Step 2: Configure `$DATA_ROOT`
Edit your local `.env` file (which is gitignored):  
```bash
# On macOS:
DATA_ROOT=/Volumes/LabStorage/raw_datasets

# On HPC Cluster:
DATA_ROOT=/mnt/scratch/bioinfo_core/raw_datasets
```

### Step 3: Add Your First Raw Data File
```bash
./scripts/data_tracker.sh add sample1_R1.fastq.gz \
    cohort2026/fastqs/sample1_R1.fastq.gz \
    cohort2026/checksums.md5
```
This command:  
1. Validates upstream files exist under `$DATA_ROOT`.  
2. Runs the Stale Checksum Guard.  
3. Parses the matching hash from `checksums.md5`.  
4. Writes the entry to `local_pointers.tsv`.  
5. Creates the symlink `raw_data/sample1_R1.fastq.gz` pointing to the external file.  

### Step 4: Commit Your Pointer
```bash
git add local_pointers.tsv
git commit -m "feat: lock raw data pointers for sample1"
```
The pre-commit hook automatically executes Tier 1 verification and verifies all data pointers before completing the commit.  

---

## 6. Adopting in an Existing Project

If you already have a running Git repository and want to retrofit this workflow:  

1. **Copy the essential scripts, templates, and AI agent configurations** into your project:  
   ```bash
   # Core tracking scripts, Git hooks, and configuration template
   cp -r /path/to/template/scripts/ your_project/scripts/
   cp -r /path/to/template/.githooks/ your_project/.githooks/
   cp /path/to/template/.env.example your_project/.env.example

   # AI agent instructions and lifecycle safety hooks (essential for AI pair programming)
   cp /path/to/template/GEMINI.md your_project/GEMINI.md
   cp -r /path/to/template/.agents/ your_project/.agents/

   # (Optional) Documentation: copy operational guide (do NOT copy docs/historical/)
   mkdir -p your_project/docs
   cp /path/to/template/docs/data_tracking_guide.md your_project/docs/
   ```
   *(Notes:*  
   - *Copying `.env.example` ensures your repository tracks the configuration template in Git so future collaborators know what variables to configure.*  
   - *Copying `GEMINI.md` is critical when using AI coding assistants (like Antigravity or Gemini): it automatically injects the reproducibility rules, data boundaries, and CLI conventions into the agent's context.*  
   - *Copying `.agents/` installs the `scientific-data-tracking` skill and active lifecycle hooks (`hooks.json` + `guard.py`) that hard-block agents from accidentally force-adding raw data symlinks or binary files into Git.*  
   - *Do **NOT** copy `docs/historical/` to new projects. That directory contains initial build specifications that are not relevant to active scientific projects).*

2. **Configure your `.gitignore`**:  
   If your project does not have a `.gitignore` yet, copy the comprehensive template file directly:  
   ```bash
   cp /path/to/template/.gitignore your_project/.gitignore
   ```
   If your project already has an existing `.gitignore`, append the template rules to it:  
   ```bash
   cat /path/to/template/.gitignore >> your_project/.gitignore
   ```
   *(Note: The rule `!.env.example` in `.gitignore` is an intentional whitelist exception—it ensures the `.env.example` blueprint stays tracked in Git while local machine `.env` files remain strictly ignored).*

3. **Bootstrap tracking and enable hooks**:  
   ```bash
   cd your_project
   ./scripts/data_tracker.sh init
   ```
   *(This automatically generates your local, gitignored `.env` from `.env.example`, initializes `local_pointers.tsv`, and activates the Git pre-commit verification hook).*

4. **Configure `$DATA_ROOT` and register data**:  
   Edit `.env` to set your local storage path, then run `./scripts/data_tracker.sh add` (or `add-batch`) for each external dataset.  

---

## 7. Daily Operator Cookbook

### Recipe 1: Check System Status & Symlink Health
```bash
# Print summary and show only pointers with issues (default)
./scripts/data_tracker.sh status

# Print all registered pointers file-by-file
./scripts/data_tracker.sh status --verbose   # or: status -v
```
By default, prints a high-level summary of all tracked pointers, storage root mounts, and Git pre-commit hook health, listing file-by-file details only for pointers that are NOT OK (`MISSING` or `BROKEN`). Use `--verbose` (or `-v`) to display all tracked pointers file by file.  

### Recipe 2: Provisioning Symlinks on a Fresh Clone / Machine
When a collaborator or HPC job clones the repository:  
```bash
export DATA_ROOT=/mnt/scratch/lab_data
./scripts/data_tracker.sh link
```

### Recipe 3: Upstream Data Changed (Legitimate Re-sequencing or Re-calling)
If the upstream facility re-generated a sample and updated their checksum file:  
```bash
./scripts/data_tracker.sh update sample1.bam
git add local_pointers.tsv
git commit -m "chore: update locked hash for sample1.bam following facility re-call"
```

### Recipe 4: Server / Storage Reorganization
If the external server restructured its folders (e.g. `cohort_2024/` was moved to `archive/cohort_2024/`):  
```bash
./scripts/data_tracker.sh relocate "cohort_2024" "archive/cohort_2024"
git add local_pointers.tsv
git commit -m "refactor: update raw data paths following storage reorganization"
```

### Recipe 5: Deep Verification Prior to Pipeline Execution or Publication
To recalculate actual cryptographic hashes for all symlinked binaries (ensuring no bit rot or tampering):  
```bash
./scripts/data_tracker.sh verify --deep
```

### Recipe 6: Generating Upstream Checksums on External Storage (Mac & Linux)
If the upstream server or drive doesn't have a checksum file yet:  
```bash
# Recursively scan and create checksums.tsv at the root of the cohort
./scripts/generate_checksums.sh /path/to/external_datasets/study_2026 -p "*.bam"

# Incrementally update existing checksums.tsv (only hashes new or modified files)
./scripts/generate_checksums.sh /path/to/external_datasets/study_2026 -u
```

### Recipe 7: Batch Registering Cohorts
To register an entire folder of files into a categorized subdirectory:  
```bash
./scripts/data_tracker.sh add-batch \
    sciATAC_fragment_files \
    study_2026/fragment_files \
    study_2026/checksums.tsv \
    -p "*_fragments.tsv.gz"
```

#### Replicating Directory Trees with `-r` (`--recursive`)
If your upstream dataset contains nested subdirectories (e.g. `study_peaks/bco_1/.../*.bw`), you should **never symlink the parent directory itself**. In scientific data tracking, symlinking directories prevents cryptographic auditing because manifests hash files, not directories, and directory symlinks allow untracked mutations.

Use `-r` / `--recursive` to replicate the folder structure:
```bash
./scripts/data_tracker.sh add-batch \
    "Bigwigs" \
    "study_peaks" \
    "study_peaks/checksums.tsv" \
    -r \
    -p "*.bw"
```
This ensures:
1. All intermediate folders (`Bigwigs/bco_1/...`) are created as **real physical local directories** (`mkdir -p`).
2. Only the leaf files inside them are tracked symlinks.
3. Every individual file pointer is verified and locked in `local_pointers.tsv`.

### Recipe 8: Interactive R / Quarto Ingestion
If you prefer managing symlinks in R (modernizing `00_Symlinks.Rmd`), open and customize:  
👉 **[`examples/00_setup_data_symlinks.qmd`](examples/00_setup_data_symlinks.qmd)**  

### Recipe 9: Adopting an Existing Project with Scattered Symlinks & Multi-Mount Roots
If adopting this framework on an already-started project where symlinks live in disparate subfolders (e.g. `analyses/01_qc/inputs/sample1.bam`, `references/hg38.fa`):

1. Configure `.env` to enable repository-relative mode:
   ```bash
   DATA_ROOT=/Volumes/PrimaryDataStorage
   SYMLINK_DIR=.
   ```
2. If your files span multiple storage mounts (e.g. references on a separate drive), declare secondary roots:
   ```bash
   REF_ROOT=/Volumes/SharedGenomes
   ```
3. Run the automated adoption scanner:
   ```bash
   # Preview adoption with detailed categorization report
   ./scripts/data_tracker.sh adopt --dry-run --report

   # List only symlinks missing upstream checksums
   ./scripts/data_tracker.sh adopt --missing-checksums

   # List unique upstream directories needing checksum generation
   ./scripts/data_tracker.sh adopt --missing-checksum-dirs

   # List symlinks that point to directories (must be converted to real dirs via add-batch -r)
   ./scripts/data_tracker.sh adopt --directory-symlinks

   # List symlinks not protected by .gitignore and auto-append them
   ./scripts/data_tracker.sh adopt --unignored >> .gitignore

   # Perform adoption, Git safety audit, and automatic manifest generation
   ./scripts/data_tracker.sh adopt
   ```
4. Verify all adopted pointers:
   ```bash
   ./scripts/data_tracker.sh verify
   ```

---

## 8. Summary of Commands

| Command | Action |
| :--- | :--- |
| `./scripts/data_tracker.sh init` | Bootstrap directories, `.env`, and Git pre-commit hook |
| `./scripts/data_tracker.sh add <link> <data> <meta>` | Lock dataset with Stale Guard & create symlink (`ROOT_NAME:` supported) |
| `./scripts/data_tracker.sh add-batch <dest> <dir> <meta> [-p] [-r]` | Batch register files from upstream folder (shallow or `-r` recursive tree) |
| `./scripts/data_tracker.sh adopt [--dry-run] [--report]` | Scan repo for existing symlinks, audit `.gitignore`, & auto-import |
| `./scripts/data_tracker.sh adopt --missing-checksums` | List symlinks lacking upstream checksum manifests |
| `./scripts/data_tracker.sh adopt --missing-checksum-dirs` | List unique upstream directories needing checksum generation |
| `./scripts/data_tracker.sh adopt --directory-symlinks` | List symlinks pointing to directories (untrackable as directories) |
| `./scripts/data_tracker.sh adopt --unignored` | List symlinks not ignored by `.gitignore` |
| `./scripts/data_tracker.sh adopt --unmatched` | List symlinks pointing outside active storage roots |
| `./scripts/data_tracker.sh adopt --broken` | List broken / dangling symlinks |
| `./scripts/generate_checksums.sh <dir> [opts]` | Generate clean upstream `checksums.tsv` (macOS & Linux compatible) |
| `./scripts/data_tracker.sh verify` | Tier 1 Fast Handshake check across all configured roots (<1s) |
| `./scripts/data_tracker.sh verify --deep` | Tier 2 Deep cryptographic verification across all storage roots |
| `./scripts/data_tracker.sh update <link>` | Pull updated upstream hash into TSV (requires human approval) |
| `./scripts/data_tracker.sh relocate <old> <new>` | Batch rename paths in TSV & re-link |
| `./scripts/data_tracker.sh link` | Provision / repair all symlinks across project |
| `./scripts/data_tracker.sh status [-v]` | Display pointer summary, root mounts, & symlink health |
| `./scripts/data_tracker.sh help [cmd]` or `<cmd> --help` | Display command-specific help documentation and examples |
| `./tests/test_data_tracker.sh` | Run automated test suite (54 test assertions) |

---

## 9. Managing Directory Permissions (Read-Only vs. Read-Write)

Locking raw dataset directories as **read-only** prevents accidental file deletion, in-place modification by downstream pipelines, or inadvertent edits, establishing an immutable data boundary.

### Setting Directories and Files as Read-Only

Directories must retain the execute (`x`) permission so they remain traversable and listable, while write (`w`) permissions are stripped:

#### Quick Method (Remove Write Permissions Recursively)
```bash
chmod -R a-w /path/to/external_data
```
*Removes write access for all users while preserving existing read and directory traversal permissions.*

#### Granular Method (Explicit File vs. Directory Permissions)
```bash
# Set all directories to readable and traversable (555 / r-xr-xr-x)
find /path/to/external_data -type d -exec chmod 555 {} +

# Set all files to read-only (444 / r--r--r--)
find /path/to/external_data -type f -exec chmod 444 {} +
```

### Restoring Read-Write Access

When you need to add new datasets, organize subfolders, or generate manifests inside the storage directory:

#### Quick Method (Restore Owner Write Access)
```bash
chmod -R u+w /path/to/external_data
```

#### Granular Method (Standard Read-Write Ownership)
```bash
# Directories: owner full access, group/others readable and traversable (755 / rwxr-xr-x)
find /path/to/external_data -type d -exec chmod 755 {} +

# Files: owner read-write, group/others read-only (644 / rw-r--r--)
find /path/to/external_data -type f -exec chmod 644 {} +
```

### Why This Is Safe With the Data Tracker
- **No Impact on Hashes:** Cryptographic checksums (MD5, SHA-256) evaluate only the byte payload of the files. Changing permission bits does not alter hashes.
- **No Impact on Stale Guard:** Running `chmod` updates inode change time (`ctime`), but leaves data modification time (`mtime`) untouched. The Tier 1 Fast Handshake (`mtime(data) > mtime(checksum)`) will continue to pass.
- **Read-Only Manifest Generation:** `./scripts/generate_checksums.sh` automatically stages temporary files in system `$TMPDIR` (`/tmp`) and defaults output to the current working directory if the target directory is read-only, avoiding permission errors.

