#!/usr/bin/env python3
"""
guard.py - Antigravity PreToolUse Safety Guard for Scientific Projects

Intercepts tool calls before execution to enforce deterministic safety guardrails:
1. Hard-blocks 'git add -f' and 'git add --force' to prevent bypassing .gitignore.
2. Hard-blocks staging 'raw_data/' or raw binary datasets directly into Git.
3. Hard-blocks reading massive genomic binaries (BAM, CRAM, FASTQ.gz) into AI context.
4. Prompts user confirmation ('ask') for destructive operations (git clean, rm -rf).
"""

import json
import os
import re
import sys

LARGE_BINARY_EXTENSIONS = (
    ".bam", ".bai", ".cram", ".crai",
    ".fastq.gz", ".fq.gz", ".vcf.gz", ".tbi",
    ".h5ad", ".rds", ".tar.gz", ".zip"
)

def respond(decision: str, reason: str = ""):
    payload = {"decision": decision}
    if reason:
        payload["reason"] = reason
    json.dump(payload, sys.stdout)
    sys.stdout.flush()
    sys.exit(0)

def check_run_command(cmd: str):
    cmd_lower = cmd.lower()

    # 1. Block git add -f / git add --force
    # Matches: git add -f, git add --force, git add -A -f, git add -f ., etc.
    if re.search(r"\bgit\b\s+add\b.*?\s+(-f\b|--force\b)", cmd):
        respond(
            "deny",
            "HARD BLOCKED by AI Hook: Using 'git add -f' or '--force' to bypass .gitignore "
            "is strictly prohibited in this scientific repository. Raw data binaries and symlinks "
            "must remain external. Use './scripts/data_tracker.sh add <link> <data> <meta>' instead."
        )

    # 2. Block git add targeting raw_data directly
    if re.search(r"\bgit\b\s+add\b.*?\s+raw_data(/|\b)", cmd):
        respond(
            "deny",
            "HARD BLOCKED by AI Hook: Directly staging 'raw_data/' into Git is prohibited. "
            "Raw data is tracked exclusively via cryptographic pointers in local_pointers.tsv. "
            "Use './scripts/data_tracker.sh add <link> <data> <meta>'."
        )

    # 3. Block attempts to cat/view massive binary files directly
    for ext in LARGE_BINARY_EXTENSIONS:
        if re.search(rf"\b(cat|head|tail|less|more)\b\s+.*\{ext}\b", cmd):
            respond(
                "deny",
                f"HARD BLOCKED by AI Hook: Direct shell dumping of binary '{ext}' files "
                "will corrupt terminal output or blow up the AI context window. "
                "Use domain tools (e.g. 'samtools view -H', 'zcat ... | head -n 20') instead."
            )

    # 4. Require user confirmation for pointer hash updates (never auto-heal)
    if re.search(r"\bdata_tracker\.sh\b\s+update\b", cmd):
        respond(
            "ask",
            "Updating a locked pointer will adopt a new upstream cryptographic hash into "
            "local_pointers.tsv. User confirmation required to verify this change was intentional."
        )

    # 5. Require user confirmation for destructive actions
    if re.search(r"\bgit\b\s+clean\b\s+-[a-zA-Z]*f", cmd) or re.search(r"\brm\b\s+-[a-zA-Z]*r[a-zA-Z]*f\b", cmd):
        respond(
            "ask",
            "This command performs a destructive deletion (git clean or rm -rf) that may erase "
            "untracked data, symlinks, or .env configuration. User confirmation required."
        )

    # 6. Hard-block write/delete/redirection operations targeting raw_data/ or DATA_ROOT
    if re.search(r"(>|>>|\btee\b|\btruncate\b|\bsed\b\s+-i|\brm\b|\bmv\b).*?\braw_data(/|\b)", cmd):
        respond(
            "deny",
            "HARD BLOCKED by AI Hook: Direct modification, deletion, or output redirection into 'raw_data/' "
            "is strictly prohibited. Raw datasets are immutable read-only inputs. "
            "Direct all pipeline and script outputs to 'results/', 'output/', or 'scratch/'."
        )

    # Check DATA_ROOT modifications if defined
    data_root = os.environ.get("DATA_ROOT", "")
    if not data_root:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        env_file = os.path.join(repo_root, ".env")
        if os.path.exists(env_file):
            try:
                with open(env_file) as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("DATA_ROOT=") and not line.startswith("#"):
                            data_root = line.split("=", 1)[1].strip().strip('"').strip("'")
            except Exception:
                pass

    if data_root and len(data_root) > 3 and data_root in cmd:
        if re.search(r"(>|>>|\btee\b|\btruncate\b|\bsed\b\s+-i|\brm\b|\bmv\b)", cmd):
            respond(
                "deny",
                f"HARD BLOCKED by AI Hook: Modifying or redirecting output into DATA_ROOT ('{data_root}') "
                "is strictly prohibited. External source datasets are immutable and read-only."
            )

    # Allow everything else
    respond("allow")

def check_view_file(path: str):
    # Normalize path
    norm_path = os.path.normpath(path)
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    project_raw_data = os.path.join(repo_root, "raw_data")

    # 1. Block viewing files inside this project's raw_data/
    if norm_path == project_raw_data or norm_path.startswith(project_raw_data + os.sep):
        respond(
            "deny",
            "HARD BLOCKED by AI Hook: Cannot read files inside 'raw_data/' into context window. "
            "Raw datasets are external. Use command-line tools (samtools, bedtools) to query headers."
        )

    # 2. Block viewing binary formats
    for ext in LARGE_BINARY_EXTENSIONS:
        if norm_path.endswith(ext):
            respond(
                "deny",
                f"HARD BLOCKED by AI Hook: Cannot inspect '{ext}' binary file directly with view_file. "
                "Doing so would exhaust context window tokens. Use specialized CLI tools."
            )

    respond("allow")

def main():
    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            respond("allow")

        data = json.loads(raw_input)
        tool_call = data.get("toolCall", {})
        tool_name = tool_call.get("name", "")
        args = tool_call.get("args", {})

        if tool_name == "run_command":
            cmd = args.get("CommandLine", "")
            check_run_command(cmd)

        elif tool_name == "view_file":
            path = args.get("AbsolutePath", "")
            check_view_file(path)

        # Default fallback: allow
        respond("allow")

    except Exception as e:
        # In case of any unexpected error, fail safe: log to stderr and allow
        sys.stderr.write(f"[guard.py warning] Hook error: {e}\n")
        respond("allow")

if __name__ == "__main__":
    main()
