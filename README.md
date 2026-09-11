# Scientific Project Data-Tracking Template & Guide

A lightweight, reproducible data-tracking framework and template repository for genomics and computational science projects tracked in Git.  

[![Tests](https://img.shields.io/badge/tests-22%20passed-brightgreen.svg)](tests/test_data_tracker.sh)  
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20HPC-blue.svg)](scripts/data_tracker.sh)  
[![Reproducibility](https://img.shields.io/badge/reproducibility-3%20Pillars-orange.svg)](docs/data_tracking_guide.md)  

---

## Workflow Summary  
A lightweight reproducibility workflow for scientific repositories that manages external data, analysis code, and software environments across three pillars:  
* **Raw Data (Pillar 1):** Large datasets remain on external storage, mapped into the project via symlinks (usually in `raw_data/` but can be anywhere else) and verified against upstream cryptographic hashes and modification timestamps via a Git-tracked manifest (`local_pointers.tsv`) that records relative paths and locked hashes.  
* **Code & Workflows (Pillar 2):** Scripts, pipelines, and notebooks are tracked directly in Git. Raw data and pipeline intermediates and results are excluded.  
* **Environment Provenance (Pillar 3):** Software and library versions are declared directly inside each script (header docstrings) and notebook (e.g., `session_info()`).  

---

## Key Features

* ⚡ **Tier 1 Fast Handshake (<1s):** Pre-commit hook verifies metadata exists and compares the locked hash against upstream text files (`md5sum *`, `sha256sum *`, or TSV manifests) without expensive full-file recalculation.  
* 🛡️ **Stale Checksum Guard:** Compares file modification timestamps (`mtime`). If an upstream data file was touched or modified after its checksum was created, commits are aborted.  
* 🔍 **Tier 2 Deep Verification (`--deep`):** Computes full cryptographic hashes across raw datasets on demand (e.g. before cluster submission or publication).  
* 📁 **Hierarchical Checksums & Subdirectory Symlinks:** Supports upstream manifests stored at higher directory levels and provisions organized subfolders (e.g. `raw_data/Resources/`, `raw_data/sciATAC_fragment_files/`).  
* 🛠️ **Upstream Checksum Generator (`generate_checksums.sh`):** Portable tool (macOS & Linux) to scan external storage directories and generate clean `checksums.tsv` files.  
* 📦 **Batch Registration (`add-batch`):** Register entire cohorts or folders of files matching regex/glob patterns in one command, with `-r` / `--recursive` mode to replicate nested folder trees as real physical directories while tracking leaf files.  
* 🔄 **Scattered Symlinks (Repository-Relative):** Fully compatible with legacy projects where symlinks live in disparate project subdirectories instead of a single folder (set `SYMLINK_DIR=.` in `.env`).  
* 🗄️ **Multi-Mount / Named Storage Roots:** Seamlessly reference raw data spanning multiple distinct physical hard drives or cluster mount points (e.g. `REF_ROOT:genomes/hg38.fa`).  
* 🧭 **Automated Project Adoption (`adopt`):** Automatically scan existing project symlinks, audit `.gitignore` safety to prevent accidental Git leaks, detect directory symlinks, match external storage mounts, and populate `local_pointers.tsv`.  
* 📖 **Command-Specific Help Menus:** Built-in rich help and usage examples for every command (`data_tracker.sh help <cmd>` or `<cmd> --help`).  
* 📝 **In-Document Version Locking:** Full support for R Quarto (`sessioninfo::session_info()`), Python Quarto (`session_info.show()`), Python docstrings, and Bash pipeline headers.  
* 🌐 **Environment Portability:** All paths are relative to `$DATA_ROOT` (works seamlessly across local macOS laptops, institutional clusters, and cloud mounts).  

---

## Directory Structure

```
.
├── .agents/                  <- Antigravity agent skills & lifecycle safety hooks
│   ├── hooks.json            <- PreToolUse lifecycle safety firewall (blocks git add -f on data)
│   ├── scripts/guard.py      <- Deterministic AI safety gatekeeper
│   └── skills/               <- Autonomous data-tracking skill (scientific-data-tracking)
├── .env.example              <- Example configuration for $DATA_ROOT across OSes
├── .githooks/
│   └── pre-commit            <- Enforces Tier 1 verification on git commit
├── .gitignore                <- Clean allowlist/blocklist for scientific projects
├── .vscode/                  <- Antigravity IDE one-click tasks and settings
├── examples/                 <- In-script versioning & ingestion templates
│   ├── 00_setup_data_symlinks.qmd    <- Modernized R/Quarto symlink setup notebook
│   ├── template_analysis_r.qmd       <- R Quarto template with sessioninfo
│   ├── template_analysis_python.qmd  <- Python Quarto template with session_info
│   ├── template_script.py            <- Python script with version docstring
│   └── template_pipeline.sh          <- Bash pipeline with CLI tool versions
├── local_pointers.tsv        <- Active cryptographic pointer manifest (Pillar 1)
├── local_pointers.example.tsv<- Annotated example of multi-file checksum manifests
├── raw_data/                 <- Local symlink directory (gitignored, provisioned by tool)
├── scripts/
│   ├── data_tracker.sh       <- Portable data-tracking CLI tool
│   └── generate_checksums.sh <- Portable upstream checksum & manifest generator (Mac & Linux)
├── tests/
│   └── test_data_tracker.sh  <- Automated verification test suite (66 test assertions)
├── docs/                     <- Comprehensive documentation
│   ├── data_tracking_guide.md<- End-to-end operational handbook & adoption cookbook
│   ├── historical/           <- Archived design prompts (not copied to new projects)
│   └── html/                 <- Publication-ready HTML renderings with floating TOC
├── GEMINI.md                 <- AI agent instructions & architectural reproducibility constraints
└── README.md                 <- Project overview & quickstart
```

---

## Quickstart

### 1. Bootstrap Project
```bash
./scripts/data_tracker.sh init
```

### 2. Configure Local Storage Mount
Copy `.env.example` to `.env` (gitignored) and define your local data mount:  
```bash
# macOS:
DATA_ROOT=/Volumes/LabDrive/raw_datasets

# Linux HPC:
DATA_ROOT=/mnt/scratch/bioinfo_core/raw_datasets
```

### 3. Add & Lock Raw Datasets
```bash
# Add a single file from default DATA_ROOT
./scripts/data_tracker.sh add sample1.bam cohort1/bams/sample1.bam cohort1/checksums.md5

# Add a file from a secondary named root (e.g. institutional reference volume)
./scripts/data_tracker.sh add ref.fa REF_ROOT:genomes/hg38.fa REF_ROOT:genomes/checksums.tsv

# Or auto-adopt existing project symlinks in one step:
./scripts/data_tracker.sh adopt --dry-run --report
./scripts/data_tracker.sh adopt
```

### 4. Verify Integrity
```bash
# Routine Tier 1 check (< 1 second)
./scripts/data_tracker.sh verify

# Deep cryptographic verification (on-demand before pipeline runs)
./scripts/data_tracker.sh verify --deep
```

---

## Documentation

For detailed guides, migration instructions for existing projects, and operational recipes:  
👉 **[Read the Complete Adoption Guide (`docs/data_tracking_guide.md`)](docs/data_tracking_guide.md)**  

---

## Verification & Testing

Run the automated test suite to verify compatibility on your system:  
```bash
./tests/test_data_tracker.sh
```
All 66 tests covering bootstrap, multi-line parsing, Stale Checksum Guard, hash mismatches, updates, relocations, deep hashing, hierarchical manifests, batch addition (shallow and recursive), scattered symlinks, named multi-mount roots, automated adoption, directory symlink detection, per-command help menus, categorized error reporting, and pre-commit hook enforcement will execute in an isolated sandbox.  

## Credits  
This project was designed and implemented with the help of AI (mostly Gemini, Flash 3.8)  
