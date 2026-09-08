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

1. **Copy the essential files** into your project:  
   ```bash
   cp -r /path/to/template/scripts/ your_project/scripts/
   cp -r /path/to/template/.githooks/ your_project/.githooks/
   cp /path/to/template/.env.example your_project/.env.example
   ```
2. **Update your `.gitignore`**:  
   Add the following blocks to your project's `.gitignore`:  
   ```gitignore
   # Raw data symlinks & binaries
   raw_data/
   *.bam
   *.bai
   *.cram
   *.fastq.gz
   *.vcf.gz

   # Pipeline scratch and intermediate runs
   work/
   .nextflow/
   .snakemake/
   results/
   tmp/

   # Environment secrets
   .env
   .env.*
   !.env.example
   ```
3. **Bootstrap and enable hooks**:  
   ```bash
   cd your_project
   ./scripts/data_tracker.sh init
   ```
4. **Register existing data**:  
   Run `data_tracker.sh add` for each of your external datasets.  

---

## 7. Daily Operator Cookbook

### Recipe 1: Check System Status & Symlink Health
```bash
./scripts/data_tracker.sh status
```
Prints a table of all registered pointers, target source paths, symlink statuses (`OK`, `MISSING`, `BROKEN`), and locked hashes.  

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

### Recipe 8: Interactive R / Quarto Ingestion
If you prefer managing symlinks in R (modernizing `00_Symlinks.Rmd`), open and customize:  
👉 **[`examples/00_setup_data_symlinks.qmd`](examples/00_setup_data_symlinks.qmd)**  

---

## 8. Summary of Commands

| Command | Action |
| :--- | :--- |
| `./scripts/data_tracker.sh init` | Bootstrap directories, `.env`, and Git pre-commit hook |
| `./scripts/data_tracker.sh add <link> <data> <meta>` | Lock dataset with Stale Guard & create symlink (subfolders supported) |
| `./scripts/data_tracker.sh add-batch <dest> <dir> <meta> [-p]` | Batch register files from upstream folder matching pattern |
| `./scripts/generate_checksums.sh <dir> [opts]` | Generate clean upstream `checksums.tsv` (macOS & Linux compatible) |
| `./scripts/data_tracker.sh verify` | Tier 1 Fast Handshake check (sub-second) |
| `./scripts/data_tracker.sh verify --deep` | Tier 2 Deep cryptographic verification |
| `./scripts/data_tracker.sh update <link>` | Pull updated upstream hash into TSV (requires human approval) |
| `./scripts/data_tracker.sh relocate <old> <new>` | Batch rename paths in TSV & re-link |
| `./scripts/data_tracker.sh link` | Provision / repair all symlinks in `raw_data/` |
| `./scripts/data_tracker.sh status` | Display pointer table & symlink health |
| `./tests/test_data_tracker.sh` | Run automated test suite (22 test assertions) |
