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

# Check if a filename or path is an OS artifact, editor swap, cloud sync metadata, or manifest
is_system_or_metadata_file() {
    local filepath="$1"
    local filename
    filename="$(basename "$filepath")"
    local file_lower
    file_lower="$(to_lower "$filename")"

    # 1. Any hidden file or AppleDouble (e.g. .DS_Store, ._*, .git, .dropbox)
    if [[ "$filename" == .* || "$filename" == ._* ]]; then
        return 0
    fi

    # 2. Windows OS artifacts
    case "$file_lower" in
        thumbs.db|desktop.ini|ehthumbs.db)
            return 0
            ;;
    esac

    # 3. Editor swap and temporary/backup files
    case "$filename" in
        *~|*.swp|*.swo|*.tmp|*.temp|*.bak|*.old|*.orig)
            return 0
            ;;
    esac

    # 4. Checksum manifests and hash files themselves
    case "$file_lower" in
        checksums.tsv|checksums.md5|checksums.sha256|md5sums|sha256sums|*.md5|*.sha256|*.md5sum|*.sha256sum)
            return 0
            ;;
    esac

    return 1
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

# Normalize an input path: if user passes an absolute path starting with an active root,
# automatically convert it into the relative storage spec (e.g. DATA_ROOT:... or rel_path)
normalize_to_spec() {
    local input_path="$1"
    load_env
    if [[ "$input_path" = /* ]]; then
        for r in $(get_all_roots); do
            local r_path="${!r%/}"
            if [[ -n "$r_path" ]]; then
                if [[ "$input_path" == "$r_path"/* ]]; then
                    local rel="${input_path#"${r_path}/"}"
                    if [[ "$r" == "DATA_ROOT" ]]; then
                        echo "$rel"
                    else
                        echo "${r}:${rel}"
                    fi
                    return 0
                elif [[ "$input_path" == "$r_path" ]]; then
                    if [[ "$r" == "DATA_ROOT" ]]; then
                        echo "."
                    else
                        echo "${r}:."
                    fi
                    return 0
                fi
            fi
        done
    fi
    echo "$input_path"
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

    rel_data="$(normalize_to_spec "$rel_data")"
    rel_meta="$(normalize_to_spec "$rel_meta")"

    # Ignore system files, OS artifacts, and metadata manifests
    if is_system_or_metadata_file "$link_name" || is_system_or_metadata_file "$rel_data"; then
        log_warn "Ignoring system/metadata file: ${rel_data}"
        return 0
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

# Command: add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> [-r] [--pattern <glob>]
cmd_add_batch() {
    local positional=()
    local pattern=""
    local recursive=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--pattern)
                pattern="$2"
                shift 2
                ;;
            -r|--recursive)
                recursive=1
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -lt 3 ]]; then
        log_error "Usage: $0 add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> [-r] [--pattern <glob>]"
        printf "Run '$0 help add-batch' for detailed options and examples.\n" >&2
        exit 1
    fi

    local dest_subdir="${positional[0]}"
    local rel_source_dir="${positional[1]}"
    local rel_checksum_file="${positional[2]}"

    rel_source_dir="$(normalize_to_spec "$rel_source_dir")"
    rel_checksum_file="$(normalize_to_spec "$rel_checksum_file")"

    resolve_symlink_dir
    ensure_pointers_file

    local abs_source_dir
    local abs_meta
    abs_source_dir="$(resolve_source_path "$rel_source_dir")"
    abs_meta="$(resolve_source_path "$rel_checksum_file")"

    if [[ ! -d "$abs_source_dir" ]]; then
        log_error "Source directory does not exist: $abs_source_dir"
        exit 1
    fi

    if [[ ! -f "$abs_meta" ]]; then
        log_error "Source checksum file does not exist: $abs_meta"
        exit 1
    fi

    local root_data
    root_data="$(get_root_var_from_spec "$rel_source_dir")"
    local clean_source_dir
    clean_source_dir="$(get_rel_path_from_spec "$rel_source_dir")"

    local clean_meta
    clean_meta="$(get_rel_path_from_spec "$rel_checksum_file")"
    local meta_dir
    meta_dir="$(dirname "$clean_meta")"

    print_header "Batch Adding Pointers from ${rel_source_dir}"
    if [[ "$SYMLINK_DIR" == "$REPO_ROOT" ]]; then
        log_info "Destination directory: ${dest_subdir}"
    else
        log_info "Destination directory: ${SYMLINK_DIR#"${REPO_ROOT}/"}/${dest_subdir}"
    fi
    log_info "Checksum metadata:     ${rel_checksum_file}"
    [[ -n "$pattern" ]] && log_info "Filter pattern:        ${pattern}"
    [[ $recursive -eq 1 ]] && log_info "Recursive mode:        Enabled (recreating real directories locally)"

    # Fast file discovery
    local candidate_list
    candidate_list="$(mktemp "${TMPDIR:-/tmp}/candidates.tmp.XXXXXX")"
    local filtered_candidates
    filtered_candidates="$(mktemp "${TMPDIR:-/tmp}/filtered_candidates.tmp.XXXXXX")"
    local matches_file
    matches_file="$(mktemp "${TMPDIR:-/tmp}/matches.tmp.XXXXXX")"
    local tmp_pointers
    tmp_pointers="$(mktemp "${TMPDIR:-/tmp}/pointers.tmp.XXXXXX")"

    cleanup_batch_tmps() {
        rm -f "$candidate_list" "$filtered_candidates" "$matches_file" "$tmp_pointers" 2>/dev/null || true
    }
    trap cleanup_batch_tmps RETURN INT TERM

    if [[ $recursive -eq 1 ]]; then
        if [[ -n "$pattern" ]]; then
            find "$abs_source_dir" -type f -name "$pattern" | sort > "$candidate_list"
        else
            find "$abs_source_dir" -type f | sort > "$candidate_list"
        fi
    else
        if [[ -n "$pattern" ]]; then
            find "$abs_source_dir" -maxdepth 1 -type f -name "$pattern" | sort > "$candidate_list"
        else
            find "$abs_source_dir" -maxdepth 1 -type f | sort > "$candidate_list"
        fi
    fi

    # Filter out OS artifacts and hidden system files
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if is_system_or_metadata_file "$f"; then
            continue
        fi
        local subpath
        subpath="${f#"${abs_source_dir}/"}"
        if [[ "$subpath" =~ (^|/)\.[^/] ]]; then
            continue
        fi
        printf "%s\n" "$f" >> "$filtered_candidates"
    done < "$candidate_list"
    rm -f "$candidate_list"

    local candidate_count
    candidate_count=$(wc -l < "$filtered_candidates" | tr -d ' ')
    if [[ "$candidate_count" -eq 0 ]]; then
        log_warn "No matching candidate files found in ${abs_source_dir}"
        cleanup_batch_tmps
        return 0
    fi

    # High-performance single-pass hash matching via awk
    awk -F'\t' \
        -v abs_src="${abs_source_dir}" \
        -v clean_src="${clean_source_dir}" \
        -v root_data="${root_data}" \
        -v meta_dir="${meta_dir}" \
        -v dest_sub="${dest_subdir}" \
        -v symlink_dir="${SYMLINK_DIR}" \
        -v rel_meta="${rel_checksum_file}" \
        -v recursive="${recursive}" '
    BEGIN {
        OFS = "\t"
    }
    # Pass 1: Parse abs_meta into memory
    NR == FNR {
        gsub(/\r/, "")
        line = $0
        if (line ~ /^[A-Za-z0-9_-]+ \(.+\) = [0-9a-fA-F]+$/) {
            match(line, /\(.*\)/)
            f = substr(line, RSTART + 1, RLENGTH - 2)
            h = tolower($NF)
            hashes[f] = h
            sub(/.*\//, "", f)
            base_hashes[f] = h
            next
        }
        if ($NF ~ /^[0-9a-fA-F]{32,128}$/ || $2 ~ /^[0-9a-fA-F]{32,128}$/) {
            f = $1
            h = ($2 ~ /^[0-9a-fA-F]{32,128}$/) ? tolower($2) : tolower($NF)
            hashes[f] = h
            sub(/^\.\//, "", f)
            hashes[f] = h
            sub(/.*\//, "", f)
            base_hashes[f] = h
            next
        }
        if ($1 ~ /^[0-9a-fA-F]{32,128}$/ && NF >= 2) {
            h = tolower($1)
            sub(/^[0-9a-fA-F]+[ \t]+\*?/, "", line)
            f = line
            hashes[f] = h
            sub(/^\.\//, "", f)
            hashes[f] = h
            sub(/.*\//, "", f)
            base_hashes[f] = h
            next
        }
        next
    }
    # Pass 2: Stream candidate files
    {
        abs_f = $0
        if (abs_f == "") next

        subpath = substr(abs_f, length(abs_src) + 2)
        if (recursive != 1) {
            sub(/.*\//, "", subpath)
        }

        if (dest_sub == "" || dest_sub == ".") {
            link_name = subpath
        } else {
            link_name = dest_sub "/" subpath
        }

        clean_data_path = clean_src "/" subpath
        if (root_data == "DATA_ROOT") {
            rel_data_spec = clean_data_path
        } else {
            rel_data_spec = root_data ":" clean_data_path
        }

        rel_from_meta = clean_data_path
        if (meta_dir != "." && substr(clean_data_path, 1, length(meta_dir) + 1) == (meta_dir "/")) {
            rel_from_meta = substr(clean_data_path, length(meta_dir) + 2)
        }

        base_f = subpath
        sub(/.*\//, "", base_f)

        found_hash = ""
        if (clean_data_path in hashes) {
            found_hash = hashes[clean_data_path]
        } else if (subpath in hashes) {
            found_hash = hashes[subpath]
        } else if (rel_from_meta in hashes) {
            found_hash = hashes[rel_from_meta]
        } else if (("./" rel_from_meta) in hashes) {
            found_hash = hashes["./" rel_from_meta]
        } else if (base_f in base_hashes) {
            found_hash = base_hashes[base_f]
        }

        link_target = symlink_dir "/" link_name

        if (found_hash == "") {
            printf "MISSING\t%s\t%s\n", clean_data_path, abs_f
        } else {
            printf "MATCH\t%s\t%s\t%s\t%s\t%s\t%s\n", link_name, rel_data_spec, rel_meta, found_hash, link_target, abs_f
        }
    }
    ' "$abs_meta" "$filtered_candidates" > "$matches_file"

    rm -f "$filtered_candidates"

    # Check for any missing hashes
    local missing_count
    missing_count=$(grep -c "^MISSING" "$matches_file" || true)
    if [[ $missing_count -gt 0 ]]; then
        while IFS=$'\t' read -r status clean_path abs_path; do
            if [[ "$status" == "MISSING" ]]; then
                log_error "Failed to parse hash for '${clean_path}' from upstream metadata: $abs_meta"
            fi
        done < "$matches_file"
        cleanup_batch_tmps
        exit 1
    fi

    # Stale Checksum Guard (evaluates in milliseconds)
    local mtime_meta
    mtime_meta=$(get_file_mtime "$abs_meta")

    local py_cmd=""
    if /usr/bin/python3 -c "import sys" >/dev/null 2>&1; then
        py_cmd="/usr/bin/python3"
    elif python3 -c "import sys" >/dev/null 2>&1; then
        py_cmd="python3"
    fi

    local stale_file=""
    if [[ -n "$py_cmd" ]]; then
        stale_file="$(awk -F'\t' '{print $7}' "$matches_file" | "$py_cmd" -c '
import os, sys
meta_mtime = int(sys.argv[1])
for line in sys.stdin:
    p = line.rstrip("\n")
    if p and os.path.isfile(p):
        try:
            if int(os.path.getmtime(p)) > meta_mtime:
                print(p)
                sys.exit(0)
        except OSError:
            pass
' "$mtime_meta" 2>/dev/null || true)"
    else
        while IFS=$'\t' read -r status l_name r_data r_meta r_hash l_target abs_file; do
            local mt
            mt=$(get_file_mtime "$abs_file")
            if [[ "$mt" -gt "$mtime_meta" ]]; then
                stale_file="$abs_file"
                break
            fi
        done < "$matches_file"
    fi

    if [[ -n "$stale_file" ]]; then
        local mtime_stale
        mtime_stale=$(get_file_mtime "$stale_file")
        log_error "Stale Checksum Guard triggered!"
        printf "  The upstream data file is newer than the checksum file:\n" >&2
        printf "  Data file:     %s (%s)\n" "$stale_file" "$(format_epoch "$mtime_stale")" >&2
        printf "  Checksum file: %s (%s)\n" "$abs_meta" "$(format_epoch "$mtime_meta")" >&2
        printf "  Aborting: The upstream checksum file is out of date. Update it upstream first.\n" >&2
        cleanup_batch_tmps
        exit 1
    fi

    # Bulk create unique parent directories
    local -a unique_dirs=()
    while IFS=$'\t' read -r status l_name r_data r_meta r_hash l_target abs_file; do
        unique_dirs+=("$(dirname "$l_target")")
    done < "$matches_file"

    if [[ ${#unique_dirs[@]} -gt 0 ]]; then
        while IFS= read -r udir; do
            [[ -n "$udir" ]] && mkdir -p "$udir"
        done < <(printf "%s\n" "${unique_dirs[@]}" | sort -u)
    fi

    # Fast symlink provisioning
    local count=0
    while IFS=$'\t' read -r status l_name r_data r_meta r_hash l_target abs_file; do
        ln -sfn "$abs_file" "$l_target"
        count=$((count + 1))
    done < "$matches_file"

    # Single atomic merge into local_pointers.tsv
    awk -F'\t' '
    BEGIN { OFS = "\t" }
    NR == FNR {
        if ($1 == "MATCH") {
            new_pointers[$2] = sprintf("%s\t%s\t%s\t%s", $2, $3, $4, $5)
        }
        next
    }
    {
        if (FNR == 1) {
            print $0
            next
        }
        if ($1 in new_pointers) {
            print new_pointers[$1]
            delete new_pointers[$1]
        } else {
            print $0
        }
    }
    END {
        for (link in new_pointers) {
            print new_pointers[link]
        }
    }
    ' "$matches_file" "$POINTERS_FILE" > "$tmp_pointers"

    mv "$tmp_pointers" "$POINTERS_FILE"
    cleanup_batch_tmps

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

# Command: adopt [--dry-run] [--report] [filter flags]
cmd_adopt() {
    local dry_run=0
    local show_report=0
    local filter_target=""

    for arg in "$@"; do
        case "$arg" in
            --dry-run|-n)
                dry_run=1
                ;;
            --report|-r|--details)
                show_report=1
                ;;
            --missing-checksums|--no-checksum)
                filter_target="missing_checksums"
                dry_run=1
                ;;
            --missing-checksum-dirs|--no-checksum-dirs)
                filter_target="missing_checksum_dirs"
                dry_run=1
                ;;
            --unignored)
                filter_target="unignored"
                dry_run=1
                ;;
            --unmatched)
                filter_target="unmatched"
                dry_run=1
                ;;
            --broken)
                filter_target="broken"
                dry_run=1
                ;;
            --already-tracked)
                filter_target="already_tracked"
                dry_run=1
                ;;
            --directory-symlinks|--dir-symlinks)
                filter_target="directory_symlinks"
                dry_run=1
                ;;
        esac
    done

    resolve_symlink_dir
    ensure_pointers_file

    if [[ -z "$filter_target" ]]; then
        print_header "Scanning Project for Existing Symlinks (adopt)"
        if [[ $dry_run -eq 1 ]]; then
            log_warn "DRY RUN MODE: No changes will be written to ${POINTERS_FILE}"
        fi
    fi

    # Check that at least one root is configured
    local all_roots=()
    for r in $(get_all_roots); do
        if [[ -n "${!r:-}" && -d "${!r}" ]]; then
            all_roots+=("$r")
        fi
    done

    if [[ ${#all_roots[@]} -eq 0 ]]; then
        log_error "No valid, mounted storage roots detected."
        printf "  Please set DATA_ROOT (and any other *_ROOT) in ${REPO_ROOT}/.env\n" >&2
        exit 1
    fi

    if [[ -z "$filter_target" ]]; then
        printf "Configured Active Storage Roots:\n"
        for r in "${all_roots[@]}"; do
            printf "  %-12s %s\n" "$r:" "${!r}"
        done
        if [[ "$SYMLINK_DIR" == "$REPO_ROOT" ]]; then
            printf "Symlinks Mode: Repository-Relative (Scattered Symlinks)\n\n"
        else
            printf "Symlinks Dir:  %s\n\n" "$SYMLINK_DIR"
        fi
    fi

    # Read existing pointers to avoid duplicate registration
    local existing_links=()
    while IFS=$'\t' read -r col_link col_data col_meta col_hash || [[ -n "$col_link" ]]; do
        if [[ "$col_link" != "link_name" && -n "$col_link" && ! "$col_link" =~ ^# ]]; then
            existing_links+=("$col_link")
        fi
    done < "$POINTERS_FILE"

    local total_found=0
    local adopted_count=0
    local already_tracked_count=0
    local broken_count=0
    local unmatched_count=0
    local no_checksum_count=0
    local unignored_count=0
    local dir_symlink_count=0

    # Categorized arrays for reports and filtering
    local unignored_list=()
    local broken_list=()
    local unmatched_list=()
    local no_checksum_list=()
    local stale_list=()
    local already_tracked_list=()
    local dir_symlink_list=()

    while IFS= read -r -d '' link_file; do
        local rel_link="${link_file#./}"

        # Ignore internal tooling / scratch / venvs / system metadata files
        if [[ "$rel_link" =~ ^(\.git|\.venv|venv|\.agents|scratch|\.test_tmp)/ ]] || is_system_or_metadata_file "$rel_link"; then
            continue
        fi

        total_found=$((total_found + 1))
        if [[ -z "$filter_target" ]]; then
            printf "%s\n" "------------------------------------------------------------"
            printf "Found symlink: %s\n" "$rel_link"
        fi

        # Determine link_name depending on SYMLINK_DIR mode
        local link_name="$rel_link"
        if [[ "$SYMLINK_DIR" != "$REPO_ROOT" ]]; then
            local rel_symlink_dir="${SYMLINK_DIR#"${REPO_ROOT}/"}"
            if [[ "$rel_link" == "${rel_symlink_dir}/"* ]]; then
                link_name="${rel_link#"${rel_symlink_dir}/"}"
            elif [[ -z "$filter_target" ]]; then
                log_warn "Symlink is outside SYMLINK_DIR (${rel_symlink_dir}): ${rel_link}"
                printf "  Recommendation: Set SYMLINK_DIR=. in .env to track scattered symlinks repository-wide.\n"
            fi
        fi

        # Check if already tracked
        local already_tracked=0
        if [[ ${#existing_links[@]} -gt 0 ]]; then
            for el in "${existing_links[@]}"; do
                if [[ "$el" == "$link_name" ]]; then
                    already_tracked=1
                    break
                fi
            done
        fi
        if [[ $already_tracked -eq 1 ]]; then
            if [[ -z "$filter_target" ]]; then
                log_info "Already tracked in manifest: ${link_name}"
            fi
            already_tracked_list+=("$link_name")
            already_tracked_count=$((already_tracked_count + 1))
            continue
        fi

        # Audit Gitignore safety
        if ! git -C "$REPO_ROOT" check-ignore -q "$rel_link" 2>/dev/null; then
            if [[ -z "$filter_target" ]]; then
                log_warn "SECURITY WARNING: Symlink is NOT ignored by Git: ${rel_link}"
                printf "  -> Recommendation: Add '%s' or its extension to .gitignore to avoid committing raw data symlinks!\n" "$rel_link" >&2
            fi
            unignored_list+=("$rel_link")
            unignored_count=$((unignored_count + 1))
        elif [[ -z "$filter_target" ]]; then
            log_success "Git protection verified: ${rel_link} is properly gitignored."
        fi

        # Resolve real target
        local abs_target=""
        local raw_target
        raw_target="$(readlink "${REPO_ROOT}/${rel_link}" 2>/dev/null || true)"
        if [[ -z "$raw_target" ]]; then
            if [[ -z "$filter_target" ]]; then
                log_error "Cannot read symlink: ${rel_link}"
            fi
            broken_list+=("${rel_link}"$'\t'"[unreadable]")
            broken_count=$((broken_count + 1))
            continue
        fi

        if [[ "$raw_target" = /* ]]; then
            abs_target="$(cd "$(dirname "$raw_target")" 2>/dev/null && pwd -P)/$(basename "$raw_target")"
        else
            abs_target="$(cd "$(dirname "${REPO_ROOT}/${rel_link}")" 2>/dev/null && cd "$(dirname "$raw_target")" 2>/dev/null && pwd -P)/$(basename "$raw_target")"
        fi

        if [[ ! -e "$abs_target" ]]; then
            if [[ -z "$filter_target" ]]; then
                log_error "Broken symlink: ${rel_link} -> ${abs_target}"
            fi
            broken_list+=("${rel_link}"$'\t'"${abs_target}")
            broken_count=$((broken_count + 1))
            continue
        fi

        # Check if target is a directory (directory symlinks cannot be cryptographically tracked)
        if [[ -d "$abs_target" ]]; then
            # Match against configured roots if possible for suggested remediation
            local dir_matched_root=""
            local dir_rel_source=""
            for r in "${all_roots[@]}"; do
                local r_path="${!r%/}"
                if [[ "$abs_target" == "$r_path"/* ]]; then
                    dir_matched_root="$r"
                    dir_rel_source="${abs_target#"${r_path}/"}"
                    break
                fi
            done
            local dir_source_spec="$dir_rel_source"
            if [[ -n "$dir_matched_root" && "$dir_matched_root" != "DATA_ROOT" ]]; then
                dir_source_spec="${dir_matched_root}:${dir_rel_source}"
            fi

            if [[ -z "$filter_target" ]]; then
                log_warn "DIRECTORY SYMLINK: ${rel_link} points to a directory (${abs_target})"
                printf "  Directory symlinks cannot be cryptographically tracked (directories lack file checksums).\n" >&2
                printf "  Remediation: Convert to real local directories with tracked file symlinks via:\n" >&2
                printf "    rm \"%s\"\n" "$rel_link" >&2
                if [[ -n "$dir_source_spec" ]]; then
                    printf "    ./scripts/data_tracker.sh add-batch \"%s\" \"%s\" \"<rel_checksum_manifest>\" -r\n" "$link_name" "$dir_source_spec" >&2
                else
                    printf "    ./scripts/data_tracker.sh add-batch \"%s\" \"<rel_source_dir>\" \"<rel_checksum_manifest>\" -r\n" "$link_name" >&2
                fi
            fi
            dir_symlink_list+=("${rel_link}"$'\t'"${abs_target}"$'\t'"${dir_matched_root}"$'\t'"${dir_source_spec}")
            dir_symlink_count=$((dir_symlink_count + 1))
            continue
        fi

        # Match against configured roots
        local matched_root=""
        local rel_source=""
        for r in "${all_roots[@]}"; do
            local r_path="${!r%/}"
            if [[ "$abs_target" == "$r_path"/* ]]; then
                matched_root="$r"
                rel_source="${abs_target#"${r_path}/"}"
                break
            fi
        done

        if [[ -z "$matched_root" ]]; then
            if [[ -z "$filter_target" ]]; then
                log_warn "Target does not fall under any active storage root: ${abs_target}"
            fi
            unmatched_list+=("${rel_link}"$'\t'"${abs_target}")
            unmatched_count=$((unmatched_count + 1))
            continue
        fi

        local col_source_spec="$rel_source"
        if [[ "$matched_root" != "DATA_ROOT" ]]; then
            col_source_spec="${matched_root}:${rel_source}"
        fi

        if [[ -z "$filter_target" ]]; then
            log_info "Matched root: ${matched_root} (${col_source_spec})"
        fi

        # Search for upstream checksum file in target's directory and parent directories up to root base
        local target_dir
        target_dir="$(dirname "$abs_target")"
        local root_base="${!matched_root%/}"
        local search_dir="$target_dir"
        local found_meta=""

        while [[ "$search_dir" == "$root_base"* ]]; do
            for candidate in "checksums.tsv" "checksums.md5" "checksums.sha256" "MD5SUMS" "SHA256SUMS" "$(basename "$abs_target").md5" "$(basename "$abs_target").sha256"; do
                if [[ -f "${search_dir}/${candidate}" ]]; then
                    local test_clean_rel="${abs_target#"${root_base}/"}"
                    local test_clean_meta="${search_dir}/${candidate}"
                    test_clean_meta="${test_clean_meta#"${root_base}/"}"
                    local test_hash
                    test_hash="$(extract_hash_from_checksum_file "${search_dir}/${candidate}" "$test_clean_rel" "$test_clean_meta")"
                    if [[ -n "$test_hash" ]]; then
                        found_meta="${search_dir}/${candidate}"
                        break 2
                    fi
                fi
            done
            if [[ "$search_dir" == "$root_base" ]]; then
                break
            fi
            search_dir="$(dirname "$search_dir")"
        done

        if [[ -z "$found_meta" ]]; then
            if [[ -z "$filter_target" ]]; then
                log_warn "No upstream checksum found for ${rel_source} under ${root_base}"
                printf "  Run './scripts/data_tracker.sh generate-checksums %s' to create one.\n" "$target_dir"
            fi
            no_checksum_list+=("${link_name}"$'\t'"${matched_root}"$'\t'"${rel_source}"$'\t'"${target_dir}")
            no_checksum_count=$((no_checksum_count + 1))
            continue
        fi

        local rel_meta="${found_meta#"${root_base}/"}"
        local col_meta_spec="$rel_meta"
        if [[ "$matched_root" != "DATA_ROOT" ]]; then
            col_meta_spec="${matched_root}:${rel_meta}"
        fi

        local final_hash
        final_hash="$(extract_hash_from_checksum_file "$found_meta" "$rel_source" "$rel_meta")"
        if [[ -z "$final_hash" ]]; then
            if [[ -z "$filter_target" ]]; then
                log_warn "Could not extract hash for ${rel_source} from ${found_meta}"
            fi
            no_checksum_list+=("${link_name}"$'\t'"${matched_root}"$'\t'"${rel_source}"$'\t'"${target_dir}")
            no_checksum_count=$((no_checksum_count + 1))
            continue
        fi

        # Check Stale Checksum Guard
        local mtime_target
        local mtime_meta
        mtime_target=$(get_file_mtime "$abs_target")
        mtime_meta=$(get_file_mtime "$found_meta")
        if [[ "$mtime_target" -gt "$mtime_meta" ]]; then
            if [[ -z "$filter_target" ]]; then
                log_warn "STALE CHECKSUM: Target file is newer than checksum manifest ${found_meta}!"
            fi
            stale_list+=("${link_name}"$'\t'"${found_meta}")
        fi

        if [[ $dry_run -eq 0 && -z "$filter_target" ]]; then
            printf "%s\t%s\t%s\t%s\n" "$link_name" "$col_source_spec" "$col_meta_spec" "$final_hash" >> "$POINTERS_FILE"
        fi

        if [[ -z "$filter_target" ]]; then
            log_success "Adopted: ${link_name} -> ${col_source_spec} [${final_hash:0:16}...]"
        fi
        adopted_count=$((adopted_count + 1))
    done < <(find . -type l \
        -not -path './.git/*' \
        -not -path './.git' \
        -not -path './.venv/*' \
        -not -path './venv/*' \
        -not -path './.agents/*' \
        -not -path './scratch/*' \
        -not -path './.test_tmp/*' \
        -print0)

    # If in filter mode, output only the requested list and exit cleanly
    if [[ -n "$filter_target" ]]; then
        case "$filter_target" in
            missing_checksums)
                if [[ ${#no_checksum_list[@]} -gt 0 ]]; then
                    for item in "${no_checksum_list[@]}"; do
                        IFS=$'\t' read -r l_name l_root l_rel l_dir <<< "$item"
                        printf "%s\n" "$l_name"
                    done
                fi
                ;;
            missing_checksum_dirs)
                if [[ ${#no_checksum_list[@]} -gt 0 ]]; then
                    local -a unique_dirs=()
                    for item in "${no_checksum_list[@]}"; do
                        IFS=$'\t' read -r l_name l_root l_rel l_dir <<< "$item"
                        local dir_seen=0
                        if [[ ${#unique_dirs[@]} -gt 0 ]]; then
                            for ud in "${unique_dirs[@]}"; do
                                if [[ "$ud" == "$l_dir" ]]; then
                                    dir_seen=1
                                    break
                                fi
                            done
                        fi
                        if [[ $dir_seen -eq 0 ]]; then
                            unique_dirs+=("$l_dir")
                            printf "%s\n" "$l_dir"
                        fi
                    done
                fi
                ;;
            unignored)
                if [[ ${#unignored_list[@]} -gt 0 ]]; then
                    for item in "${unignored_list[@]}"; do
                        printf "%s\n" "$item"
                    done
                fi
                ;;
            unmatched)
                if [[ ${#unmatched_list[@]} -gt 0 ]]; then
                    for item in "${unmatched_list[@]}"; do
                        IFS=$'\t' read -r l_link l_target <<< "$item"
                        printf "%s\t%s\n" "$l_link" "$l_target"
                    done
                fi
                ;;
            broken)
                if [[ ${#broken_list[@]} -gt 0 ]]; then
                    for item in "${broken_list[@]}"; do
                        IFS=$'\t' read -r l_link l_target <<< "$item"
                        printf "%s\t%s\n" "$l_link" "$l_target"
                    done
                fi
                ;;
            already_tracked)
                if [[ ${#already_tracked_list[@]} -gt 0 ]]; then
                    for item in "${already_tracked_list[@]}"; do
                        printf "%s\n" "$item"
                    done
                fi
                ;;
            directory_symlinks)
                if [[ ${#dir_symlink_list[@]} -gt 0 ]]; then
                    for item in "${dir_symlink_list[@]}"; do
                        IFS=$'\t' read -r l_link l_target l_root l_rel <<< "$item"
                        printf "%s\t%s\n" "$l_link" "$l_target"
                    done
                fi
                ;;
        esac
        return 0
    fi

    print_header "Adoption Summary"
    printf "Total symlinks scanned:         %d\n" "$total_found"
    printf "Successfully adopted:           %d\n" "$adopted_count"
    printf "Already tracked in manifest:    %d\n" "$already_tracked_count"
    printf "Directory symlinks (untracked): %d\n" "$dir_symlink_count"
    printf "Broken / dangling symlinks:     %d\n" "$broken_count"
    printf "Unmatched storage roots:        %d\n" "$unmatched_count"
    printf "Missing upstream checksums:     %d\n" "$no_checksum_count"
    printf "Unignored by Git (WARNINGS):    %d\n" "$unignored_count"
    printf "%s\n" "------------------------------------------------------------"

    if [[ $dir_symlink_count -gt 0 ]]; then
        log_warn "Directory symlinks detected! Convert them to real local directories with 'add-batch -r'."
    fi
    if [[ $unignored_count -gt 0 ]]; then
        log_warn "There are symlinks NOT ignored by .gitignore! Please review warnings above."
    fi
    if [[ $dry_run -eq 1 ]]; then
        log_info "Dry run complete. Run without --dry-run to commit entries to local_pointers.tsv."
    elif [[ $adopted_count -gt 0 ]]; then
        log_success "Updated ${POINTERS_FILE} successfully with adopted entries."
    fi

    # Detailed Categorized Report
    if [[ $show_report -eq 1 ]]; then
        print_header "Detailed Adoption Report & Action Items"

        if [[ ${#dir_symlink_list[@]} -gt 0 ]]; then
            printf "\n${YELLOW}[!] Directory Symlinks (%d) - Cannot be cryptographically tracked:${NC}\n" "${#dir_symlink_list[@]}"
            for item in "${dir_symlink_list[@]}"; do
                IFS=$'\t' read -r l_link l_target l_root l_rel <<< "$item"
                printf "  • Symlink:     %s\n" "$l_link"
                printf "    Target:      %s\n" "$l_target"
                printf "    Problem:     Directories cannot have file checksums; symlinked directories risk untracked mutations.\n"
                printf "    Remediation: Convert to real local directory with tracked file symlinks:\n"
                printf "                 1. rm \"%s\"\n" "$l_link"
                if [[ -n "$l_rel" ]]; then
                    printf "                 2. ./scripts/data_tracker.sh add-batch \"%s\" \"%s\" \"<rel_checksum_manifest>\" -r\n\n" "$l_link" "$l_rel"
                else
                    printf "                 2. ./scripts/data_tracker.sh add-batch \"%s\" \"<rel_source_dir>\" \"<rel_checksum_manifest>\" -r\n\n" "$l_link"
                fi
            done
            printf "  ${BOLD}Bulk Resolution:${NC} Run './scripts/data_tracker.sh adopt --directory-symlinks' to list all directory symlinks.\n\n"
        fi

        if [[ ${#unignored_list[@]} -gt 0 ]]; then
            printf "\n${YELLOW}[!] Unignored Symlinks (%d) - Risk of accidental Git commits:${NC}\n" "${#unignored_list[@]}"
            for item in "${unignored_list[@]}"; do
                printf "  • Symlink: %s\n" "$item"
                printf "    Action:  echo \"%s\" >> .gitignore\n\n" "$item"
            done
            printf "  ${BOLD}Bulk Resolution:${NC} Run './scripts/data_tracker.sh adopt --unignored >> .gitignore'\n\n"
        fi

        if [[ ${#unmatched_list[@]} -gt 0 ]]; then
            printf "\n${YELLOW}[?] Unmatched Storage Roots (%d) - Targets outside configured mounts:${NC}\n" "${#unmatched_list[@]}"
            for item in "${unmatched_list[@]}"; do
                IFS=$'\t' read -r l_link l_target <<< "$item"
                printf "  • Symlink: %s\n" "$l_link"
                printf "    Target:  %s\n" "$l_target"
                printf "    Action:  Declare a named storage root in .env (e.g., <NAME>_ROOT=\"...\")\n\n"
            done
        fi

        if [[ ${#no_checksum_list[@]} -gt 0 ]]; then
            printf "\n${YELLOW}[-] Missing Upstream Checksums (%d):${NC}\n" "${#no_checksum_list[@]}"
            local -a unique_dirs=()
            for item in "${no_checksum_list[@]}"; do
                IFS=$'\t' read -r l_name l_root l_rel l_dir <<< "$item"
                printf "  • Symlink:   %s\n" "$l_name"
                printf "    Source:    %s:%s\n" "$l_root" "$l_rel"
                printf "    Directory: %s\n" "$l_dir"
                printf "    Action:    ./scripts/data_tracker.sh generate-checksums \"%s\"\n\n" "$l_dir"
                local dir_seen=0
                if [[ ${#unique_dirs[@]} -gt 0 ]]; then
                    for ud in "${unique_dirs[@]}"; do
                        if [[ "$ud" == "$l_dir" ]]; then
                            dir_seen=1
                            break
                        fi
                    done
                fi
                if [[ $dir_seen -eq 0 ]]; then
                    unique_dirs+=("$l_dir")
                fi
            done
            printf "  ${BOLD}Bulk Resolution:${NC} Run generate-checksums for the missing directories:\n"
            if [[ ${#unique_dirs[@]} -gt 0 ]]; then
                for ud in "${unique_dirs[@]}"; do
                    printf "    ./scripts/data_tracker.sh generate-checksums \"%s\"\n" "$ud"
                done
            fi
            echo ""
        fi

        if [[ ${#broken_list[@]} -gt 0 ]]; then
            printf "\n${RED}[x] Broken / Dangling Symlinks (%d):${NC}\n" "${#broken_list[@]}"
            for item in "${broken_list[@]}"; do
                IFS=$'\t' read -r l_link l_target <<< "$item"
                printf "  • Symlink: %s\n" "$l_link"
                printf "    Target:  %s (FILE NOT FOUND)\n\n" "$l_target"
            done
        fi

        if [[ ${#stale_list[@]} -gt 0 ]]; then
            printf "\n${YELLOW}[~] Stale Upstream Checksums (%d) - Binary is newer than checksum file:${NC}\n" "${#stale_list[@]}"
            for item in "${stale_list[@]}"; do
                IFS=$'\t' read -r l_name l_meta <<< "$item"
                printf "  • Symlink:  %s\n" "$l_name"
                printf "    Manifest: %s\n" "$l_meta"
                printf "    Action:   Regenerate checksum manifest upstream.\n\n"
            done
        fi

        echo ""
    elif [[ $unignored_count -gt 0 || $unmatched_count -gt 0 || $no_checksum_count -gt 0 || $broken_count -gt 0 || $dir_symlink_count -gt 0 ]]; then
        printf "\nTip: Run './scripts/data_tracker.sh adopt --report' to see itemized paths and suggested commands.\n"
    fi
}

# ------------------------------------------------------------------------------
# Command-Specific Help Menus
# ------------------------------------------------------------------------------

usage_init() {
    cat << EOF
Usage: $(basename "$0") init

Description:
  Bootstrap tracking, directory structure, template configs, and Git hook
  in the current repository.

Actions Performed:
  • Creates raw_data/, metadata/, and scripts/ directories.
  • Creates template .env file with DATA_ROOT and storage root placeholders.
  • Creates empty local_pointers.tsv manifest with standard TSV header.
  • Adds raw_data/ to .gitignore to prevent accidental raw data commits.
  • Installs Git pre-commit verification hook.

Examples:
  $(basename "$0") init
EOF
}

usage_add() {
    cat << EOF
Usage: $(basename "$0") add <link_name> <rel_data_path> <rel_checksum_path>

Description:
  Add and cryptographically lock a single raw data file into local_pointers.tsv.
  Verifies that the target file exists, matches the upstream checksum manifest,
  and satisfies the Stale Checksum Guard (mtime comparison). Automatically
  provisions the local symlink upon registration.

Arguments:
  <link_name>           Relative symlink path inside project (e.g., sample1.bam or bams/sample1.bam)
  <rel_data_path>       Path relative to storage root (e.g., runs/sample1.bam or REF_ROOT:hg38.fa)
  <rel_checksum_path>   Upstream checksum file relative to storage root (e.g., runs/checksums.tsv)

Named Roots:
  Prefix paths with ROOT_NAME: (e.g., REF_ROOT:genomes/hg38.fa).
  Paths without a prefix default to DATA_ROOT.

Examples:
  $(basename "$0") add sample1.bam exp1/sample1.bam exp1/checksums.tsv
  $(basename "$0") add bams/sample2.bam exp1/sample2.bam exp1/checksums.tsv
  $(basename "$0") add ref.fa REF_ROOT:genomes/hg38.fa REF_ROOT:genomes/checksums.sha256
EOF
}

usage_add_batch() {
    cat << EOF
Usage: $(basename "$0") add-batch <dest_subdir> <rel_source_dir> <rel_checksum_file> [options]

Description:
  Batch-add and lock multiple raw data files from an upstream storage folder into
  local_pointers.tsv. Can perform shallow registration or recursively replicate
  the upstream directory tree locally using real directories.

Arguments:
  <dest_subdir>         Local destination subdirectory inside raw_data (or project root if SYMLINK_DIR=.)
                        Use '.' to place files directly into the symlink directory.
  <rel_source_dir>      Upstream directory relative to storage root (e.g., studyA/bams or REF_ROOT:annotations)
  <rel_checksum_file>   Upstream checksum manifest relative to storage root (e.g., studyA/checksums.tsv)

Options:
  -p, --pattern <glob>  Only add files matching glob pattern (e.g., "*.bam", "*.fastq.gz", "*.bw")
  -r, --recursive       Recursively traverse source directory tree. Recreates all intermediate
                        subdirectories as REAL local directories (mkdir -p), provisioning individual
                        file symlinks inside them. Prevents directory symlinks.

Examples:
  # Shallow batch add all files in run1/ into raw_data/bams/
  $(basename "$0") add-batch "bams" "run1" "run1/checksums.tsv"

  # Shallow batch add only BAM files
  $(basename "$0") add-batch "bams" "run1" "run1/checksums.tsv" -p "*.bam"

  # Recursive batch add preserving nested directories (creates real local folders, file symlinks)
  $(basename "$0") add-batch "Bigwigs" "study_peaks" "study_peaks/checksums.tsv" -r -p "*.bw"

  # Batch add directly into project root in scattered mode (SYMLINK_DIR=.)
  $(basename "$0") add-batch "." "study_peaks" "study_peaks/checksums.tsv" -r -p "*.bw"
EOF
}

usage_adopt() {
    cat << EOF
Usage: $(basename "$0") adopt [options]

Description:
  Scan the project repository for existing symlinks, verify their safety under Git,
  match targets against active storage roots (DATA_ROOT, <NAME>_ROOT), locate upstream
  checksum manifests, and auto-register valid files into local_pointers.tsv.

  Identifies directory symlinks, broken symlinks, unignored symlinks, and files
  missing upstream checksums, providing actionable remediation steps.

Options:
  -n, --dry-run                  Preview adoption actions without modifying local_pointers.tsv
  -r, --report, --details        Print detailed categorized breakdown of errors and action items
  --missing-checksums            Filter mode: Output symlinks missing upstream checksum manifests
  --missing-checksum-dirs        Filter mode: Output unique external directories needing checksums
  --directory-symlinks,
  --dir-symlinks                 Filter mode: Output symlinks that point to directories
  --unignored                    Filter mode: Output symlinks not ignored by .gitignore
  --unmatched                    Filter mode: Output symlinks pointing outside active storage roots
  --broken                       Filter mode: Output broken or dangling symlinks
  --already-tracked              Filter mode: Output symlinks already tracked in local_pointers.tsv

Examples:
  # Preview adoption
  $(basename "$0") adopt --dry-run

  # View detailed report with actionable commands
  $(basename "$0") adopt --report

  # Generate missing checksums for all external directories in one pass
  $(basename "$0") adopt --missing-checksum-dirs | while read d; do $(basename "$0") generate-checksums "\$d"; done

  # Add all unignored symlinks to .gitignore safely
  $(basename "$0") adopt --unignored >> .gitignore

  # List untracked directory symlinks to convert via add-batch -r
  $(basename "$0") adopt --directory-symlinks

  # Run adoption and commit entries to local_pointers.tsv
  $(basename "$0") adopt
EOF
}

usage_verify() {
    cat << EOF
Usage: $(basename "$0") verify [options]

Description:
  Verify integrity of all datasets tracked in local_pointers.tsv across all
  active storage roots. Ensures data files and checksum manifests exist, verifies
  that checksum files have not become stale, and confirms cryptographic hashes.

Verification Tiers:
  Tier 1 (Fast Handshake - Default):
    Completes in under 1 second. Checks file existence, Stale Checksum Guard (mtime),
    and matches upstream checksum manifest records against local_pointers.tsv.
    Suitable for automated pre-commit Git hooks.

  Tier 2 (Deep Cryptographic Calculation - via --deep):
    Computes cryptographic MD5/SHA256 hashes of actual raw binary files on disk
    and verifies bit-level integrity against local_pointers.tsv.
    Recommended before pipeline runs and pre-publication audits.

Options:
  --deep                Run Tier 2 deep cryptographic hash verification

Examples:
  $(basename "$0") verify
  $(basename "$0") verify --deep
EOF
}

usage_update() {
    cat << EOF
Usage: $(basename "$0") update <link_name>

Description:
  Re-read the upstream checksum manifest for a specific pointer and update its
  recorded cryptographic hash in local_pointers.tsv.

  Use this command ONLY when upstream data has been intentionally modified or
  re-generated upstream with verified provenance.

Arguments:
  <link_name>           Symlink identifier in local_pointers.tsv to update

Examples:
  $(basename "$0") update sample1.bam
  $(basename "$0") update bams/sample1.bam
EOF
}

usage_relocate() {
    cat << EOF
Usage: $(basename "$0") relocate <old_path_string> <new_path_string>

Description:
  Batch-replace path substrings in local_pointers.tsv. Useful when external storage
  mount points, server names, or folder structures are moved or renamed.
  Automatically updates data paths, metadata paths, and refreshes symlinks.

Arguments:
  <old_path_string>     Subpath or root string to replace
  <new_path_string>     Replacement subpath or root string

Examples:
  # When a storage folder has been renamed
  $(basename "$0") relocate "old_study_name" "new_study_name"

  # Migrating to a named storage root
  $(basename "$0") relocate "DATA_ROOT:genomes" "REF_ROOT:genomes"
EOF
}

usage_link() {
    cat << EOF
Usage: $(basename "$0") link

Description:
  Provision or refresh all symbolic links defined in local_pointers.tsv.
  Creates necessary local parent directories, validates target paths across
  all configured storage roots, and creates symlinks using 'ln -sfn'.

Examples:
  $(basename "$0") link
EOF
}

usage_status() {
    cat << EOF
Usage: $(basename "$0") status

Description:
  Display an overview of all tracked pointers in local_pointers.tsv, including
  target paths, symlink health (OK, BROKEN, MISSING), and recorded hashes.

Examples:
  $(basename "$0") status
EOF
}

usage_generate_checksums() {
    cat << EOF
Usage: $(basename "$0") generate-checksums <directory> [options]

Description:
  Generate a standardized checksums.tsv manifest for all files in an external
  data folder. Computes MD5 and/or SHA256 hashes using native tools (md5sum,
  shasum, or md5) with cross-platform macOS/Linux support.

Arguments:
  <directory>           External directory containing raw data files

Options:
  --algorithm <alg>     Hash algorithm: md5, sha256, or both (default: both)
  --pattern <glob>      Filter files by glob pattern (e.g., "*.bam", "*.fastq.gz")
  --output <filename>   Output manifest filename (default: checksums.tsv)

Examples:
  $(basename "$0") generate-checksums /Volumes/Data/study1
  $(basename "$0") generate-checksums /Volumes/Data/study1 --pattern "*.bam"
  $(basename "$0") generate-checksums /Volumes/Data/study1 --algorithm sha256
EOF
}

usage_install_hook() {
    cat << EOF
Usage: $(basename "$0") install-hook

Description:
  Install the Git pre-commit verification hook into .git/hooks/pre-commit.
  The hook runs Tier 1 fast verification before each commit, preventing
  broken symlinks, missing storage roots, or stale checksums from being committed.

Examples:
  $(basename "$0") install-hook
EOF
}

usage_command() {
    local cmd="${1:-}"
    case "$cmd" in
        init)
            usage_init
            ;;
        add)
            usage_add
            ;;
        add-batch)
            usage_add_batch
            ;;
        adopt|scan)
            usage_adopt
            ;;
        verify|check|--deep)
            usage_verify
            ;;
        update|--update)
            usage_update
            ;;
        relocate|--relocate)
            usage_relocate
            ;;
        link|--link|provision)
            usage_link
            ;;
        status|list)
            usage_status
            ;;
        generate-checksums)
            usage_generate_checksums
            ;;
        install-hook)
            usage_install_hook
            ;;
        *)
            log_error "No specific help available for unknown command: $cmd"
            echo ""
            usage
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Main Help Menu
# ------------------------------------------------------------------------------

usage() {
    cat << EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  init                                 Bootstrap tracking, directories, template configs & Git hook
  add <link> <rel_data> <rel_meta>     Add/lock a new file from storage with Stale Guard
  add-batch <dest> <dir> <meta> [-r]   Batch-add files from storage (shallow or -r recursive)
  adopt [opts]                         Scan repo for existing symlinks, audit gitignore, & auto-import
  verify [--deep]                      Verify integrity (Tier 1 fast check; --deep for Tier 2 crypto)
  update <link_name>                   Pull latest hash from upstream metadata if legitimately updated
  relocate <old_str> <new_str>         Batch-replace path substrings in local_pointers.tsv
  link                                 Provision/refresh all symbolic links
  status                               Display current pointer manifest and symlink health
  generate-checksums <dir> [opts]      Generate upstream checksums.tsv for an external data directory
  install-hook                         Configure Git pre-commit verification hook
  help [command]                       Show this help menu or specific help for a command

Command Help:
  $(basename "$0") help <command>      Display detailed help and examples for a specific command
  $(basename "$0") <command> --help    (or -h) Display help for a specific command

Global Options:
  --data-root <path>                   Override DATA_ROOT for this invocation
  --deep                               Perform full cryptographic calculation during verification

Adopt Options:
  --dry-run, -n                        Preview adopt actions without modifying local_pointers.tsv
  --report, -r, --details              Print detailed itemized breakdown of errors and action items
  --missing-checksums                  Filter mode: Output only symlinks missing upstream checksums
  --missing-checksum-dirs             Filter mode: Output unique directories needing checksum generation
  --directory-symlinks,
  --dir-symlinks                       Filter mode: Output symlinks pointing to directories
  --unignored                          Filter mode: Output only symlinks not ignored by Git (.gitignore)
  --unmatched                          Filter mode: Output only symlinks outside storage roots
  --broken                             Filter mode: Output only broken/dangling symlinks
  --already-tracked                    Filter mode: Output only symlinks already in local_pointers.tsv

Environment Configuration (.env):
  DATA_ROOT                            Primary external storage root directory
  <NAME>_ROOT                          Named secondary storage roots (e.g., REF_ROOT=/data/ref)
  SYMLINK_DIR                          Local link directory (default: raw_data; set '.' for scattered)

Named Roots Syntax:
  In local_pointers.tsv, prefix paths with ROOT_NAME: (e.g. REF_ROOT:genomes/hg38.fa).
  Paths without a prefix automatically default to DATA_ROOT.

Examples:
  $(basename "$0") init
  $(basename "$0") help add-batch
  $(basename "$0") add-batch "Bigwigs" "study_peaks" "study_peaks/checksums.tsv" -r -p "*.bw"
  $(basename "$0") adopt --dry-run --report
  $(basename "$0") adopt --missing-checksum-dirs
  $(basename "$0") verify
  $(basename "$0") verify --deep
  $(basename "$0") link
  $(basename "$0") status
EOF
}

# ------------------------------------------------------------------------------
# Entry Point & CLI Argument Parsing
# ------------------------------------------------------------------------------

# Extract global --data-root overrides if present before command
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-root)
            export DATA_ROOT="$2"
            shift 2
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

# If user asked for global help
if [[ "$COMMAND" == "-h" || "$COMMAND" == "--help" ]]; then
    usage
    exit 0
fi

# If user called "help <command>" or "help"
if [[ "$COMMAND" == "help" ]]; then
    if [[ $# -gt 0 ]]; then
        usage_command "$1"
    else
        usage
    fi
    exit 0
fi

# Check if command has -h or --help in its arguments
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage_command "$COMMAND"
        exit 0
    fi
done

# Extract any remaining --data-root flags within command args
CLEAN_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-root)
            export DATA_ROOT="$2"
            shift 2
            ;;
        *)
            CLEAN_ARGS+=("$1")
            shift
            ;;
    esac
done
if [[ ${#CLEAN_ARGS[@]} -gt 0 ]]; then
    set -- "${CLEAN_ARGS[@]}"
else
    set --
fi

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
    *)
        log_error "Unknown command: $COMMAND"
        echo ""
        usage
        exit 1
        ;;
esac
