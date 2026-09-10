#!/usr/bin/env bash
# ==============================================================================
# data_tracker.sh - Portable Scientific Data-Tracking & Verification Tool
#
# Mac & Linux compatible. Implements a lightweight, reproducible data-tracking
# workflow for scientific & genomics repositories tracked in Git.
#
# Pillars:
# 1. Raw Data: Tracked via cryptographic pointers in local_pointers.tsv
# 2. Code: Tracked via Git
# 3. Environment: Declared in-script (session_info, script headers, standard venvs)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POINTERS_FILE="${REPO_ROOT}/local_pointers.tsv"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Disable colors if stdout is not a TTY
if [[ ! -t 1 ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

# Lowercase string helper compatible with Bash 3.2+ (macOS default) and Linux
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

print_header() {
    printf "\n${BOLD}%s${NC}\n" "$1"
    printf "%s\n" "------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# Environment & Path Resolution Helpers
# ------------------------------------------------------------------------------

# Load environment configuration from .env if present (environment takes precedence)
load_env() {
    if [[ -f "${REPO_ROOT}/.env" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            key="$(echo "$key" | tr -d '[:space:]')"
            if [[ -n "$key" && ! "$key" =~ ^# ]]; then
                # Only set if not already defined in caller environment
                if [[ -z "${!key:-}" ]]; then
                    val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
                    export "$key=$val"
                fi
            fi
        done < "${REPO_ROOT}/.env"
    fi
}

# Resolve SYMLINK_DIR: defaults to raw_data; '.' or empty means repository root (scattered symlinks)
resolve_symlink_dir() {
    load_env
    local dir="${SYMLINK_DIR:-}"
    if [[ -z "$dir" ]]; then
        SYMLINK_DIR="${REPO_ROOT}/raw_data"
    elif [[ "$dir" == "." ]]; then
        SYMLINK_DIR="${REPO_ROOT}"
    elif [[ "$dir" = /* ]]; then
        SYMLINK_DIR="$dir"
    else
        SYMLINK_DIR="${REPO_ROOT}/${dir}"
    fi
}

resolve_symlink_dir

# Extract root variable name from a source path specification (defaults to DATA_ROOT)
get_root_var_from_spec() {
    local spec="$1"
    if [[ "$spec" =~ ^([A-Za-z_][A-Za-z0-9_]*):(.*)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "DATA_ROOT"
    fi
}

# Extract clean relative path from a source path specification
get_rel_path_from_spec() {
    local spec="$1"
    if [[ "$spec" =~ ^([A-Za-z_][A-Za-z0-9_]*):(.*)$ ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo "$spec"
    fi
}

# Resolve a path spec to an absolute path on external storage, verifying root exists
resolve_source_path() {
    local spec="$1"
    local root_var
    local rel_path
    root_var="$(get_root_var_from_spec "$spec")"
    rel_path="$(get_rel_path_from_spec "$spec")"

    load_env
    local root_dir="${!root_var:-}"
    if [[ -z "$root_dir" ]]; then
        log_error "Root environment variable '${root_var}' is not set (required for '${spec}')."
        printf "  Please configure ${root_var} in ${REPO_ROOT}/.env or export ${root_var}=/path/to/storage\n" >&2
        exit 1
    fi

    if [[ ! -d "$root_dir" ]]; then
        log_error "Root directory '${root_var}' does not exist or is not mounted: ${root_dir}"
        exit 1
    fi

    local clean_rel="${rel_path#/}"
    local clean_root="${root_dir%/}"
    echo "${clean_root}/${clean_rel}"
}

# List all configured active storage roots from environment / .env
get_all_roots() {
    load_env
    local roots=()
    if [[ -n "${DATA_ROOT:-}" ]]; then
        roots+=("DATA_ROOT")
    fi
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        key="$(echo "$key" | tr -d '[:space:]')"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*_ROOT$ && "$key" != "DATA_ROOT" && "$key" != "REPO_ROOT" && "$key" != "PROJECT_ROOT" ]]; then
            if [[ -n "${!key:-}" ]]; then
                roots+=("$key")
            fi
        fi
    done < <(env)
    if [[ ${#roots[@]} -gt 0 ]]; then
        printf "%s\n" "${roots[@]}" | sort -u
    fi
}

# Cross-platform file modification time (epoch seconds)
# macOS BSD stat uses -f %m; Linux GNU stat uses -c %Y
get_file_mtime() {
    local target="$1"
    if stat -c %Y "$target" >/dev/null 2>&1; then
        stat -c %Y "$target"
    elif stat -f %m "$target" >/dev/null 2>&1; then
        stat -f %m "$target"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import os, sys; print(int(os.path.getmtime(sys.argv[1])))" "$target"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'print((stat($ARGV[0]))[9])' "$target"
    else
        log_error "Cannot determine file modification time: neither stat, python3, nor perl available."
        exit 1
    fi
}

# Cross-platform human readable date from epoch
format_epoch() {
    local epoch="$1"
    if date -r "$epoch" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
        date -r "$epoch" "+%Y-%m-%d %H:%M:%S" # BSD / macOS
    else
        date -d "@$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$epoch" # Linux GNU
    fi
}

# Extract hash corresponding to a specific file from multi-line or single-line checksum files
# Supports:
# - Upstream checksums at a higher directory level (rel_from_meta matching)
# - TSV manifests: <path>\t<hash> (from generate_checksums.sh) or <hash>\t<path>
# - Standard GNU format: <hash>  [*]<filename>
# - BSD format: ALGO (filename) = <hash>
# - Raw single-hash files
extract_hash_from_checksum_file() {
    local checksum_path="$1"
    local relative_source_path="$2"
    local relative_source_metadata_path="${3:-}"

    local base_name
    base_name="$(basename "$relative_source_path")"

    # Compute path of data file relative to the metadata file directory
    local rel_from_meta="$relative_source_path"
    if [[ -n "$relative_source_metadata_path" ]]; then
        local meta_dir
        meta_dir="$(dirname "$relative_source_metadata_path")"
        if [[ "$meta_dir" != "." && "$relative_source_path" == "${meta_dir}/"* ]]; then
            rel_from_meta="${relative_source_path#"${meta_dir}/"}"
        fi
    fi

    awk -v target_base="$base_name" -v target_file="$relative_source_path" -v target_rel="$rel_from_meta" '
    {
        gsub(/\r/, "")
        line = $0

        # 1. BSD format: ALGO (filename) = <hash>
        if ($0 ~ /^[A-Za-z0-9_-]+ \(.+\) = [0-9a-fA-F]+$/) {
            if (line ~ ("\\(" target_base "\\)") || line ~ ("\\(" target_file "\\)") || line ~ ("\\(" target_rel "\\)")) {
                print tolower($NF)
                exit 0
            }
        }

        # 2. TSV format with path first: <path>\t<hash>... (e.g. from generate_checksums.sh)
        if ($NF ~ /^[0-9a-fA-F]{32,128}$/ || $2 ~ /^[0-9a-fA-F]{32,128}$/) {
            target_hash = ""
            path_col = $1
            if ($2 ~ /^[0-9a-fA-F]{32,128}$/) {
                target_hash = tolower($2)
            } else {
                target_hash = tolower($NF)
            }
            if (path_col == target_rel || path_col == target_base || path_col == target_file || path_col == ("./" target_rel) || path_col ~ ("(^|/)" target_base "$")) {
                print target_hash
                exit 0
            }
        }

        # 3. Standard GNU format: <hash>  [*]<filename> (or TSV with hash first)
        if ($1 ~ /^[0-9a-fA-F]{32,128}$/) {
            rest = substr(line, length($1) + 1)
            sub(/^[ \t]+/, "", rest)
            sub(/^\*/, "", rest)

            split(rest, parts, "\t")
            matched_path = parts[1]
            if (matched_path == target_rel || matched_path == target_base || matched_path == target_file || matched_path == ("./" target_rel) || matched_path ~ ("(^|/)" target_base "$")) {
                print tolower($1)
                exit 0
            }

            if (rest == target_rel || rest == target_base || rest == target_file || rest == ("./" target_rel) || rest ~ ("(^|/)" target_base "$")) {
                print tolower($1)
                exit 0
            }
        }

        # 4. Fallback: Single-line file with only a hash
        if (NR == 1 && NF == 1 && $1 ~ /^[0-9a-fA-F]{32,128}$/) {
            single_hash = tolower($1)
        }
    }
    END {
        if (single_hash != "") {
            print single_hash
        }
    }
    ' "$checksum_path"
}

# Calculate cryptographic hash of a binary file on demand (Tier 2 Deep Verification)
compute_file_hash() {
    local file_path="$1"
    local expected_hash="$2"
    local hash_len=${#expected_hash}

    if [[ $hash_len -eq 32 ]]; then
        # MD5
        if command -v md5sum >/dev/null 2>&1; then
            md5sum "$file_path" | awk '{print tolower($1)}'
        elif command -v md5 >/dev/null 2>&1; then
            md5 -q "$file_path" | awk '{print tolower($1)}'
        else
            python3 -c "import hashlib, sys; print(hashlib.md5(open(sys.argv[1],'rb').read()).hexdigest())" "$file_path"
        fi
    elif [[ $hash_len -eq 64 ]]; then
        # SHA256
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$file_path" | awk '{print tolower($1)}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$file_path" | awk '{print tolower($1)}'
        else
            python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$file_path"
        fi
    elif [[ $hash_len -eq 40 ]]; then
        # SHA1
        if command -v sha1sum >/dev/null 2>&1; then
            sha1sum "$file_path" | awk '{print tolower($1)}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 1 "$file_path" | awk '{print tolower($1)}'
        else
            python3 -c "import hashlib, sys; print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$file_path"
        fi
    else
        # Default fallback to sha256sum or md5sum
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$file_path" | awk '{print tolower($1)}'
        elif command -v md5sum >/dev/null 2>&1; then
            md5sum "$file_path" | awk '{print tolower($1)}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$file_path" | awk '{print tolower($1)}'
        else
            python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$file_path"
        fi
    fi
}

# Ensure $DATA_ROOT is defined and accessible
require_data_root() {
    load_env
    if [[ -z "${DATA_ROOT:-}" ]]; then
        log_error "DATA_ROOT environment variable is not set."
        printf "  Please set it in your environment (e.g., export DATA_ROOT=/path/to/data)\n" >&2
        printf "  or configure it in ${REPO_ROOT}/.env (see .env.example).\n" >&2
        exit 1
    fi

    if [[ ! -d "$DATA_ROOT" ]]; then
        log_error "DATA_ROOT directory does not exist or is not mounted: $DATA_ROOT"
        exit 1
    fi
}

# Ensure local_pointers.tsv exists
ensure_pointers_file() {
    if [[ ! -f "$POINTERS_FILE" ]]; then
        printf "link_name\trelative_source_path\trelative_source_metadata_path\tlocked_hash\n" > "$POINTERS_FILE"
    fi
}

# ------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------

# Command: init
cmd_init() {
    print_header "Bootstrapping Project Data-Tracking"
    resolve_symlink_dir

    # 1. Create symlink directory if not REPO_ROOT
    if [[ "$SYMLINK_DIR" != "$REPO_ROOT" ]]; then
        mkdir -p "$SYMLINK_DIR"
        log_success "Provisioned local symlink directory: ${SYMLINK_DIR}"
    else
        log_success "Using repository-relative symlink mode (SYMLINK_DIR=.)"
    fi

    # 2. Initialize pointers file
    ensure_pointers_file
    log_success "Initialized pointer manifest: ${POINTERS_FILE}"

    # 3. Copy .env.example to .env if not present
    if [[ ! -f "${REPO_ROOT}/.env" && -f "${REPO_ROOT}/.env.example" ]]; then
        cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
        log_warn "Created template .env from .env.example. Please edit .env to set DATA_ROOT."
    fi

    # 4. Install Git hook
    cmd_install_hook

    printf "\n${GREEN}${BOLD}Project data-tracking initialized successfully!${NC}\n"
    printf "Next steps:\n"
    printf "  1. Set DATA_ROOT in .env or via 'export DATA_ROOT=...'\n"
    printf "  2. Track data: ./scripts/data_tracker.sh add <link_name> <rel_data_path> <rel_checksum_path>\n"
    printf "  3. Verify:     ./scripts/data_tracker.sh verify\n\n"
}

# Command: install-hook
cmd_install_hook() {
    local hook_src="${REPO_ROOT}/.githooks/pre-commit"
    local git_dir="${REPO_ROOT}/.git"

    if [[ ! -d "$git_dir" ]]; then
        log_warn "Not a git repository root. Skipping pre-commit hook installation."
        return 0
    fi

    # Try setting core.hooksPath first (modern git recommendation)
    if git -C "$REPO_ROOT" config core.hooksPath .githooks 2>/dev/null; then
        chmod +x "$hook_src" 2>/dev/null || true
        log_success "Configured Git core.hooksPath to .githooks"
    elif mkdir -p "${git_dir}/hooks" 2>/dev/null && cp "$hook_src" "${git_dir}/hooks/pre-commit" 2>/dev/null; then
        chmod +x "${git_dir}/hooks/pre-commit" 2>/dev/null || true
        log_success "Installed pre-commit hook into .git/hooks/pre-commit"
    else
        log_warn "Could not configure Git hook (restricted .git permissions). Ensure core.hooksPath is set to .githooks."
    fi
}

# Command: add <link_name> <relative_source_path> <relative_source_metadata_path>
cmd_add() {
    local link_name="${1:-}"
    local rel_data="${2:-}"
    local rel_meta="${3:-}"

    if [[ -z "$link_name" || -z "$rel_data" || -z "$rel_meta" ]]; then
        log_error "Usage: $0 add <link_name> <relative_source_path> <relative_source_metadata_path>"
        exit 1
    fi

    resolve_symlink_dir
    ensure_pointers_file

    local abs_data
    local abs_meta
    abs_data="$(resolve_source_path "$rel_data")"
    abs_meta="$(resolve_source_path "$rel_meta")"

    local clean_data
    local clean_meta
    clean_data="$(get_rel_path_from_spec "$rel_data")"
    clean_meta="$(get_rel_path_from_spec "$rel_meta")"

    log_info "Adding pointer: ${link_name} -> ${rel_data}"

    # Verify source data file exists
    if [[ ! -f "$abs_data" ]]; then
        log_error "Source data file does not exist: $abs_data"
        exit 1
    fi

    # Verify source checksum file exists
    if [[ ! -f "$abs_meta" ]]; then
        log_error "Source checksum file does not exist: $abs_meta"
        exit 1
    fi

    # Stale Checksum Guard
    local mtime_data
    local mtime_meta
    mtime_data=$(get_file_mtime "$abs_data")
    mtime_meta=$(get_file_mtime "$abs_meta")

    if [[ "$mtime_data" -gt "$mtime_meta" ]]; then
        log_error "Stale Checksum Guard triggered!"
        printf "  The upstream data file is newer than the checksum file:\n" >&2
        printf "  Data file:     %s (%s)\n" "$abs_data" "$(format_epoch "$mtime_data")" >&2
        printf "  Checksum file: %s (%s)\n" "$abs_meta" "$(format_epoch "$mtime_meta")" >&2
        printf "  Aborting: The upstream checksum file is out of date. Update it upstream first.\n" >&2
        exit 1
    fi

    # Extract hash
    local extracted_hash
    extracted_hash=$(extract_hash_from_checksum_file "$abs_meta" "$clean_data" "$clean_meta")

    if [[ -z "$extracted_hash" ]]; then
        log_error "Failed to parse hash for '${clean_data}' from upstream metadata: $abs_meta"
        exit 1
    fi

    # Update or append in local_pointers.tsv
    local tmp_file
    tmp_file="$(mktemp "${REPO_ROOT}/pointers.tmp.XXXXXX")"

    local replaced=0
    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        if [[ "$col_link" == "link_name" ]]; then
            printf "%s\t%s\t%s\t%s\n" "$col_link" "$col_data" "$col_meta" "$col_hash" >> "$tmp_file"
            continue
        fi

        if [[ "$col_link" == "$link_name" ]]; then
            printf "%s\t%s\t%s\t%s\n" "$link_name" "$rel_data" "$rel_meta" "$extracted_hash" >> "$tmp_file"
            replaced=1
        else
            printf "%s\t%s\t%s\t%s\n" "$col_link" "$col_data" "$col_meta" "$col_hash" >> "$tmp_file"
        fi
    done < "$POINTERS_FILE"

    if [[ $replaced -eq 0 ]]; then
        printf "%s\t%s\t%s\t%s\n" "$link_name" "$rel_data" "$rel_meta" "$extracted_hash" >> "$tmp_file"
    fi

    mv "$tmp_file" "$POINTERS_FILE"

    # Provision symlink (supporting nested subdirectories like Resources/ or sciATAC/)
    local link_target="${SYMLINK_DIR}/${link_name}"
    mkdir -p "$(dirname "$link_target")"
    ln -sfn "$abs_data" "$link_target"

    log_success "Locked hash: ${extracted_hash}"
    log_success "Provisioned symlink: ${link_target} -> ${abs_data}"
    log_success "Saved pointer to ${POINTERS_FILE}"
}

# Command: add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> [--pattern <glob>]
cmd_add_batch() {
    local dest_subdir="${1:-}"
    local rel_source_dir="${2:-}"
    local rel_checksum_file="${3:-}"

    if [[ -z "$dest_subdir" || -z "$rel_source_dir" || -z "$rel_checksum_file" ]]; then
        log_error "Usage: $0 add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> [--pattern <glob>]"
        exit 1
    fi

    shift 3 || true
    local pattern=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--pattern)
                pattern="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    resolve_symlink_dir
    local abs_source_dir
    abs_source_dir="$(resolve_source_path "$rel_source_dir")"

    if [[ ! -d "$abs_source_dir" ]]; then
        log_error "Source directory does not exist: $abs_source_dir"
        exit 1
    fi

    local root_data
    root_data="$(get_root_var_from_spec "$rel_source_dir")"
    local clean_source_dir
    clean_source_dir="$(get_rel_path_from_spec "$rel_source_dir")"

    print_header "Batch Adding Pointers from ${rel_source_dir}"
    if [[ "$SYMLINK_DIR" == "$REPO_ROOT" ]]; then
        log_info "Destination directory: ${dest_subdir}"
    else
        log_info "Destination directory: ${SYMLINK_DIR#"${REPO_ROOT}/"}/${dest_subdir}"
    fi
    log_info "Checksum metadata:     ${rel_checksum_file}"
    [[ -n "$pattern" ]] && log_info "Filter pattern:        ${pattern}"

    local count=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local fname
        fname="$(basename "$f")"
        local link_name
        if [[ -z "$dest_subdir" || "$dest_subdir" == "." ]]; then
            link_name="$fname"
        else
            link_name="${dest_subdir}/${fname}"
        fi
        local rel_data_path
        if [[ "$root_data" == "DATA_ROOT" ]]; then
            rel_data_path="${clean_source_dir}/${fname}"
        else
            rel_data_path="${root_data}:${clean_source_dir}/${fname}"
        fi

        cmd_add "$link_name" "$rel_data_path" "$rel_checksum_file"
        count=$((count + 1))
    done < <(
        if [[ -n "$pattern" ]]; then
            find "$abs_source_dir" -maxdepth 1 -type f -name "$pattern" | sort
        else
            find "$abs_source_dir" -maxdepth 1 -type f | sort
        fi
    )

    if [[ "$SYMLINK_DIR" == "$REPO_ROOT" ]]; then
        printf "\n${GREEN}[SUCCESS]${NC} Batch added %d pointers into %s\n\n" "$count" "$dest_subdir"
    else
        printf "\n${GREEN}[SUCCESS]${NC} Batch added %d pointers into %s/%s\n\n" "$count" "${SYMLINK_DIR#"${REPO_ROOT}/"}" "$dest_subdir"
    fi
}

# Command: update <link_name>
cmd_update() {
    local target_link="${1:-}"

    if [[ -z "$target_link" ]]; then
        log_error "Usage: $0 update <link_name>"
        exit 1
    fi

    require_data_root
    ensure_pointers_file

    local found=0
    local rel_data=""
    local rel_meta=""
    local old_hash=""

    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        if [[ "$col_link" == "$target_link" ]]; then
            found=1
            rel_data="$col_data"
            rel_meta="$col_meta"
            old_hash="$col_hash"
            break
        fi
    done < "$POINTERS_FILE"

    if [[ $found -eq 0 ]]; then
        log_error "Pointer not found in ${POINTERS_FILE}: $target_link"
        exit 1
    fi

    log_info "Updating hash for ${target_link}..."
    cmd_add "$target_link" "$rel_data" "$rel_meta"
}

# Command: relocate <old_string> <new_string>
cmd_relocate() {
    local old_str="${1:-}"
    local new_str="${2:-}"

    if [[ -z "$old_str" || -z "$new_str" ]]; then
        log_error "Usage: $0 relocate <old_path_string> <new_path_string>"
        exit 1
    fi

    ensure_pointers_file
    print_header "Relocating Path Patterns in ${POINTERS_FILE}"
    log_info "Replacing '${old_str}' with '${new_str}'"

    local tmp_file
    tmp_file="$(mktemp "${REPO_ROOT}/pointers.tmp.XXXXXX")"

    local count=0
    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        if [[ "$col_link" == "link_name" ]]; then
            printf "%s\t%s\t%s\t%s\n" "$col_link" "$col_data" "$col_meta" "$col_hash" >> "$tmp_file"
            continue
        fi

        local new_data="${col_data//"$old_str"/$new_str}"
        local new_meta="${col_meta//"$old_str"/$new_str}"

        if [[ "$new_data" != "$col_data" || "$new_meta" != "$col_meta" ]]; then
            count=$((count + 1))
        fi

        printf "%s\t%s\t%s\t%s\n" "$col_link" "$new_data" "$new_meta" "$col_hash" >> "$tmp_file"
    done < "$POINTERS_FILE"

    mv "$tmp_file" "$POINTERS_FILE"
    log_success "Updated ${count} entries in ${POINTERS_FILE}"

    # Re-provision symlinks if DATA_ROOT is available
    if [[ -n "${DATA_ROOT:-}" && -d "${DATA_ROOT}" ]]; then
        log_info "Re-provisioning symlinks with new paths..."
        cmd_link
    fi
}

# Command: link (Provision all symlinks)
cmd_link() {
    resolve_symlink_dir
    ensure_pointers_file

    if [[ "$SYMLINK_DIR" == "$REPO_ROOT" ]]; then
        print_header "Provisioning Symlinks (Repository-Relative Mode)"
    else
        print_header "Provisioning Symlinks in ${SYMLINK_DIR}"
        mkdir -p "$SYMLINK_DIR"
    fi

    local total=0
    local created=0
    local failed=0

    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        # Skip header or empty lines
        if [[ "$col_link" == "link_name" || -z "$col_link" || "$col_link" =~ ^# ]]; then
            continue
        fi

        total=$((total + 1))
        local root_data
        root_data="$(get_root_var_from_spec "$col_data")"
        local root_data_val="${!root_data:-}"

        if [[ -z "$root_data_val" || ! -d "$root_data_val" ]]; then
            log_error "Target root variable '$root_data' is unset or unmounted (${root_data_val:-unset}) for $col_link"
            failed=$((failed + 1))
            continue
        fi

        local abs_data
        abs_data="$(resolve_source_path "$col_data")"
        local link_target="${SYMLINK_DIR}/${col_link}"

        if [[ ! -f "$abs_data" ]]; then
            log_error "Target file does not exist: $abs_data"
            failed=$((failed + 1))
            continue
        fi

        mkdir -p "$(dirname "$link_target")"
        ln -sfn "$abs_data" "$link_target"
        printf "  ✓ %-35s -> %s\n" "$col_link" "$abs_data"
        created=$((created + 1))
    done < "$POINTERS_FILE"

    printf "\nFinished: %d linked, %d failed out of %d total pointers.\n" "$created" "$failed" "$total"
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

# Command: verify [--deep]
cmd_verify() {
    local deep_mode=0
    for arg in "$@"; do
        if [[ "$arg" == "--deep" ]]; then
            deep_mode=1
        fi
    done

    resolve_symlink_dir
    ensure_pointers_file

    if [[ $deep_mode -eq 1 ]]; then
        print_header "Executing Tier 2 Deep Cryptographic Verification"
    else
        print_header "Executing Tier 1 Fast Handshake Verification"
    fi

    local configured_roots=()
    for r in $(get_all_roots); do
        if [[ -n "${!r:-}" ]]; then
            configured_roots+=("$r")
            printf "%-12s %s\n" "$r:" "${!r}"
        fi
    done
    if [[ ${#configured_roots[@]} -eq 0 ]]; then
        printf "%-12s %s\n" "DATA_ROOT:" "${DATA_ROOT:-[NOT SET]}"
    fi
    echo ""

    local total=0
    local passed=0
    local failed=0

    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        # Skip header or comment lines
        if [[ "$col_link" == "link_name" || -z "$col_link" || "$col_link" =~ ^# ]]; then
            continue
        fi

        total=$((total + 1))
        local root_data
        local root_meta
        root_data="$(get_root_var_from_spec "$col_data")"
        root_meta="$(get_root_var_from_spec "$col_meta")"

        local root_data_val="${!root_data:-}"
        local root_meta_val="${!root_meta:-}"

        printf "[%s]\n" "$col_link"

        if [[ -z "$root_data_val" || ! -d "$root_data_val" ]]; then
            log_error "  Missing storage root '$root_data' (${root_data_val:-unset or unmounted})"
            failed=$((failed + 1))
            continue
        fi

        if [[ -z "$root_meta_val" || ! -d "$root_meta_val" ]]; then
            log_error "  Missing metadata root '$root_meta' (${root_meta_val:-unset or unmounted})"
            failed=$((failed + 1))
            continue
        fi

        local abs_data
        local abs_meta
        abs_data="$(resolve_source_path "$col_data")"
        abs_meta="$(resolve_source_path "$col_meta")"

        local clean_data
        local clean_meta
        clean_data="$(get_rel_path_from_spec "$col_data")"
        clean_meta="$(get_rel_path_from_spec "$col_meta")"

        # 1. Existence checks
        if [[ ! -f "$abs_data" ]]; then
            log_error "  Missing binary data file: $abs_data"
            failed=$((failed + 1))
            continue
        fi

        if [[ ! -f "$abs_meta" ]]; then
            log_error "  Missing upstream checksum file: $abs_meta"
            failed=$((failed + 1))
            continue
        fi

        # 2. Stale Checksum Guard (mtime check)
        local mtime_data
        local mtime_meta
        mtime_data=$(get_file_mtime "$abs_data")
        mtime_meta=$(get_file_mtime "$abs_meta")

        if [[ "$mtime_data" -gt "$mtime_meta" ]]; then
            log_error "  STALE CHECKSUM: Data file is newer than checksum file!"
            printf "    Data modified:     %s\n" "$(format_epoch "$mtime_data")" >&2
            printf "    Checksum modified: %s\n" "$(format_epoch "$mtime_meta")" >&2
            failed=$((failed + 1))
            continue
        fi

        # 3. Hash Match against upstream metadata
        local upstream_hash
        upstream_hash=$(extract_hash_from_checksum_file "$abs_meta" "$clean_data" "$clean_meta")

        if [[ -z "$upstream_hash" ]]; then
            log_error "  Could not parse hash for '${clean_data}' from ${abs_meta}"
            failed=$((failed + 1))
            continue
        fi

        local norm_upstream
        local norm_col
        norm_upstream=$(to_lower "$upstream_hash")
        norm_col=$(to_lower "$col_hash")

        if [[ "$norm_upstream" != "$norm_col" ]]; then
            log_error "  HASH MISMATCH with upstream metadata file!"
            printf "    Locked in TSV: %s\n" "$col_hash" >&2
            printf "    Upstream meta: %s\n" "$upstream_hash" >&2
            failed=$((failed + 1))
            continue
        fi

        # 4. Tier 2 Deep Cryptographic Check (Optional)
        if [[ $deep_mode -eq 1 ]]; then
            printf "  Recalculating cryptographic hash of binary data...\n"
            local computed_hash
            computed_hash=$(compute_file_hash "$abs_data" "$col_hash")
            local norm_computed
            norm_computed=$(to_lower "$computed_hash")

            if [[ "$norm_computed" != "$norm_col" ]]; then
                log_error "  DEEP CRYPTOGRAPHIC FAILURE: Computed hash does not match locked hash!"
                printf "    Computed hash: %s\n" "$computed_hash" >&2
                printf "    Locked hash:   %s\n" "$col_hash" >&2
                failed=$((failed + 1))
                continue
            fi
            printf "  ✓ Deep verification passed (hash: %s)\n" "$computed_hash"
        else
            printf "  ✓ Tier 1 Handshake verified (hash: %s)\n" "$upstream_hash"
        fi

        passed=$((passed + 1))
    done < "$POINTERS_FILE"

    printf "\nSummary: %d passed, %d failed out of %d total pointers.\n" "$passed" "$failed" "$total"

    if [[ $failed -gt 0 ]]; then
        log_error "Verification failed for one or more files."
        exit 1
    fi

    log_success "All pointers verified successfully."
}

# Command: status
cmd_status() {
    resolve_symlink_dir
    ensure_pointers_file
    print_header "Scientific Data-Tracking Status"

    printf "Project Root:  %s\n" "$REPO_ROOT"
    if [[ "$SYMLINK_DIR" == "$REPO_ROOT" ]]; then
        printf "Symlinks Mode: Repository-Relative (Scattered Symlinks)\n"
    else
        printf "Symlinks Dir:  %s\n" "$SYMLINK_DIR"
    fi

    printf "\nConfigured Storage Roots:\n"
    local found_roots=0
    for r in $(get_all_roots); do
        local rval="${!r:-}"
        local mount_status="[OK]"
        if [[ ! -d "$rval" ]]; then
            mount_status="[UNMOUNTED / MISSING]"
        fi
        printf "  %-12s %s %s\n" "$r:" "$rval" "$mount_status"
        found_roots=$((found_roots + 1))
    done
    if [[ $found_roots -eq 0 ]]; then
        printf "  %-12s %s\n" "DATA_ROOT:" "${DATA_ROOT:-[NOT SET]}"
    fi
    echo ""

    printf "%-35s %-35s %-12s %s\n" "LINK NAME" "SOURCE SPEC" "LOCAL LINK" "LOCKED HASH"
    printf "%-35s %-35s %-12s %s\n" "-----------------------------------" "-----------------------------------" "------------" "--------------------------------"

    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        if [[ "$col_link" == "link_name" || -z "$col_link" || "$col_link" =~ ^# ]]; then
            continue
        fi

        local symlink_status="MISSING"
        local link_target="${SYMLINK_DIR}/${col_link}"
        if [[ -L "$link_target" ]]; then
            if [[ -e "$link_target" ]]; then
                symlink_status="OK"
            else
                symlink_status="BROKEN"
            fi
        fi

        printf "%-35s %-35s %-12s %s\n" "$col_link" "$col_data" "$symlink_status" "$col_hash"
    done < "$POINTERS_FILE"
    echo ""
}


# Show help menu
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  init                                 Bootstrap tracking, directories, template configs & Git hook
  add <link> <rel_data> <rel_meta>     Add/lock a new file from storage with Stale Guard
  add-batch <dest> <dir> <meta> [-p]   Batch-add all files from an upstream folder matching pattern
  verify [--deep]                      Verify integrity (Tier 1 fast check; --deep for Tier 2 crypto)
  update <link_name>                   Pull latest hash from upstream metadata if legitimately updated
  relocate <old_str> <new_str>         Batch-replace path substrings in local_pointers.tsv
  link                                 Provision/refresh all symbolic links
  status                               Display current pointer manifest and symlink health
  generate-checksums <dir> [opts]      Generate upstream checksums.tsv for an external data directory
  install-hook                         Configure Git pre-commit verification hook
  help                                 Show this help message

Options:
  --deep                               Perform full cryptographic calculation during verification
  --data-root <path>                   Override DATA_ROOT for this invocation

Environment Configuration (.env):
  DATA_ROOT                            Primary external storage root directory
  <NAME>_ROOT                          Named secondary storage roots (e.g., REF_ROOT=/data/ref)
  SYMLINK_DIR                          Local link directory (default: raw_data; set '.' for scattered)

Named Roots Syntax:
  In local_pointers.tsv, prefix paths with ROOT_NAME: (e.g. REF_ROOT:genomes/hg38.fa).
  Paths without a prefix automatically default to DATA_ROOT.

Examples:
  $(basename "$0") init
  $(basename "$0") add sample1.bam bams/sample1.bam bams/md5sum.txt
  $(basename "$0") add ref.fa REF_ROOT:genomes/hg38.fa REF_ROOT:genomes/checksums.sha256
  $(basename "$0") adopt
  $(basename "$0") adopt --dry-run
  $(basename "$0") verify
  $(basename "$0") verify --deep
  $(basename "$0") link
  $(basename "$0") status

EOF
}

# ------------------------------------------------------------------------------
# Entry Point & CLI Argument Parsing
# ------------------------------------------------------------------------------

# Support --data-root / -r override flag
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-root|-r)
            export DATA_ROOT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
    cmd_verify
    exit 0
fi

set -- "${ARGS[@]}"
COMMAND="$1"
shift

case "$COMMAND" in
    init)
        cmd_init "$@"
        ;;
    add)
        cmd_add "$@"
        ;;
    add-batch)
        cmd_add_batch "$@"
        ;;
    adopt|scan)
        cmd_adopt "$@"
        ;;
    generate-checksums)
        "${SCRIPT_DIR}/generate_checksums.sh" "$@"
        ;;
    verify|check)
        cmd_verify "$@"
        ;;
    --deep)
        cmd_verify --deep "$@"
        ;;
    update|--update)
        cmd_update "$@"
        ;;
    relocate|--relocate)
        cmd_relocate "$@"
        ;;
    link|--link|provision)
        cmd_link "$@"
        ;;
    status|list)
        cmd_status "$@"
        ;;
    install-hook)
        cmd_install_hook "$@"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
