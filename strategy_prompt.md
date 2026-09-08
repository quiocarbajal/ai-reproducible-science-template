**System Role & Task:**
You are a senior bioinformatician and workflow automation engineer. Implement a lightweight, reproducible data-tracking and verification workflow for a genomics project tracked via Git.

**Problem Context & Objective:**
Raw datasets are intentionally kept out of the Git repository. Input data is accessed locally via symlinks that point outside the project directory to a configurable local symlink directory (e.g., `raw_data/`). 
Crucially, metadata and cryptographic hashes are managed **at the source**. The upstream external directories maintain their own checksum files (e.g., `source_checksums.txt`, `md5sum.txt`). The local Git project needs to lock in which version of the source file is being used to guarantee reproducibility, without running time-prohibitive full-file SHA/MD5 calculations locally. 
The system must be highly portable across different environments (e.g., local machines vs. HPC clusters) and robust against upstream reorganizations.

**Architectural Strategy:**
1. **Separation of Concerns:**
   * Code, pipelines, and small metadata files remain in Git.
   * Strict exclusion rules in `.gitignore` ensure no raw data or symlink directories enter Git history.
2. **Source-Driven Metadata (The Handshake):**
   * **Upstream:** External source directories act as the global registry, holding the true hashes in text files.
   * **Local:** The Git repository maintains a lightweight `local_pointers.tsv` containing: `link_name`, `relative_source_path`, `relative_source_metadata_path`, and `locked_hash`. 
3. **Environment Portability (Path Templating):**
   * To ensure portability across machines with different mount points, all paths in the TSV must be relative to a base environment variable (e.g., `$DATA_ROOT`). The CLI tool and hooks will construct the absolute path dynamically at runtime (e.g., `$DATA_ROOT/relative_source_path`).
4. **Tiered Verification Strategy:**
   * *Tier 1 (Fast Handshake & Stale-Guard Gate):* A sub-second check combining two steps:
     1. **Stale Checksum Guard:** Verify that the upstream checksum file is newer than or equal to the binary data file (`mtime` comparison). If the data file is newer, the checksum file is stale.
     2. **Hash Match:** Compare the `locked_hash` in the local TSV against the text hash written in the upstream metadata file. 
     Suitable for routine pre-commit hooks.
   * *Tier 2 (Deep Cryptographic Verification):* An actual cryptographic checksum recalculation (`sha256sum` or `md5sum`) of the binary file, executed only on demand via a `--deep` flag to ensure the source checksum text file matches the actual binary.

**Deliverables Expected:**
1. Complete `.gitignore` targeting all symlinked files from outside the project.
2. An automated setup & verification CLI tool in Bash (Mac and Linux compatible) that:
   * Accepts `$DATA_ROOT` from the environment and constructs absolute paths for validation.
   * **Metadata Parsing:** Correctly parses standard multi-line checksum files (e.g., output of `md5sum *`) using tools like `grep` or `awk` to extract the hash corresponding to the specific binary, rather than assuming a single-hash file.
   * Applies the Stale Checksum Guard before trusting upstream metadata.
   * Reads the hash from the defined source metadata path and saves it to the local `local_pointers.tsv`.
   * Provides an `--update <link_name>` command to intentionally pull the latest hash from the source directory if the upstream data has legitimately changed.
   * Provides a `--relocate <old_path_string> <new_path_string>` command to batch-update strings in the TSV if the upstream server is reorganized.
   * Automatically provisions symbolic links inside the configured local directory.
3. A Git `pre-commit` hook that executes Tier 1 verification and aborts commits if there is a hash mismatch, a missing file, or a stale upstream checksum file.