#!/usr/bin/env bash
# ==============================================================================
# generate_checksums.sh - Portable Upstream Checksum & Manifest Generator
#
# Mac & Linux compatible (Bash 3.2+).
# Recursively scans external/upstream raw data directories, computes cryptographic
# hashes, and outputs a clean, relative-path TSV manifest (checksums.tsv).
#
# Columns:
# 1. relative_path  (relative to target directory)
# 2. hash           (md5 or sha256)
# 3. size_bytes     (integer file size)
# 4. modified_date  (ISO-style timestamp)
# ==============================================================================

set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

if [[ ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# Cross-platform file modification time (epoch seconds)
get_mtime() {
    local f="$1"
    if stat -c %Y "$f" >/dev/null 2>&1; then
        stat -c %Y "$f" # Linux GNU
    elif stat -f %m "$f" >/dev/null 2>&1; then
        stat -f %m "$f" # macOS BSD
    else
        python3 -c "import os, sys; print(int(os.path.getmtime(sys.argv[1])))" "$f" 2>/dev/null
    fi
}

# Cross-platform file size in bytes
get_size() {
    local f="$1"
    if stat -c %s "$f" >/dev/null 2>&1; then
        stat -c %s "$f" # Linux GNU
    elif stat -f %z "$f" >/dev/null 2>&1; then
        stat -f %z "$f" # macOS BSD
    else
        python3 -c "import os, sys; print(os.path.getsize(sys.argv[1]))" "$f" 2>/dev/null
    fi
}

# Cross-platform epoch to formatted date
format_date() {
    local epoch="$1"
    if date -r "$epoch" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
        date -r "$epoch" "+%Y-%m-%d %H:%M:%S" # macOS BSD
    else
        date -d "@$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$epoch" # Linux GNU
    fi
}

# Cross-platform cryptographic hash calculation
compute_hash() {
    local f="$1"
    local algo="$2"

    if [[ "$algo" == "md5" ]]; then
        if command -v md5sum >/dev/null 2>&1; then
            md5sum "$f" | awk '{print tolower($1)}'
        elif command -v md5 >/dev/null 2>&1; then
            md5 -q "$f" | awk '{print tolower($1)}'
        else
            python3 -c "import hashlib, sys; print(hashlib.md5(open(sys.argv[1],'rb').read()).hexdigest())" "$f"
        fi
    elif [[ "$algo" == "sha256" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$f" | awk '{print tolower($1)}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$f" | awk '{print tolower($1)}'
        else
            python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$f"
        fi
    else
        log_error "Unsupported algorithm: $algo. Use 'md5' or 'sha256'."
        exit 1
    fi
}

usage() {
    cat << EOF
Usage: $(basename "$0") <target_directory> [options]

Recursively computes hashes for files in <target_directory> and generates
a clean relative-path checksum TSV file suitable for data tracking.

Options:
  -o, --output <filename>    Output filename (default: checksums.tsv inside target_directory)
  -a, --algo <md5|sha256>    Hash algorithm (default: md5)
  -p, --pattern <glob>       File pattern to match (e.g., "*.bam", "*.fastq.gz")
  --include-all              Include all regular files (default skips hidden, .md5, .sha256, and .log files)
  -h, --help                 Show this help message

Examples:
  $(basename "$0") /path/to/project_2026
  $(basename "$0") /path/to/project_2026 -o source_checksums.tsv -a sha256
  $(basename "$0") /path/to/project_2026 -p "*.bam"
EOF
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
TARGET_DIR=""
OUTPUT_FILE=""
ALGO="md5"
PATTERN=""
INCLUDE_ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -a|--algo)
            ALGO="$2"
            shift 2
            ;;
        -p|--pattern)
            PATTERN="$2"
            shift 2
            ;;
        --include-all)
            INCLUDE_ALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$TARGET_DIR" ]]; then
                TARGET_DIR="$1"
            else
                log_error "Unexpected argument: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="."
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    log_error "Target directory does not exist: $TARGET_DIR"
    exit 1
fi

# Resolve target directory to absolute path
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Default output file
if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="${TARGET_DIR}/checksums.tsv"
else
    # If not absolute, put it relative to current working directory
    if [[ "$OUTPUT_FILE" != /* ]]; then
        OUTPUT_FILE="$(pwd)/${OUTPUT_FILE}"
    fi
    out_dir="$(cd "$(dirname "$OUTPUT_FILE")" 2>/dev/null && pwd || dirname "$OUTPUT_FILE")"
    OUTPUT_FILE="${out_dir}/$(basename "$OUTPUT_FILE")"
fi

OUTPUT_BASENAME="$(basename "$OUTPUT_FILE")"

ALGO_UPPER="$(echo "$ALGO" | tr '[:lower:]' '[:upper:]')"
printf "\n${BOLD}============================================================${NC}\n"
printf "${BOLD}Generating Upstream Checksum Manifest (${ALGO_UPPER})${NC}\n"
printf "Target directory: %s\n" "$TARGET_DIR"
printf "Output manifest:  %s\n" "$OUTPUT_FILE"
[[ -n "$PATTERN" ]] && printf "Filter pattern:   %s\n" "$PATTERN"
printf "${BOLD}============================================================${NC}\n\n"

# Temporary file to build manifest
TMP_OUT="$(mktemp "${TARGET_DIR}/checksums.tmp.XXXXXX")"
printf "relative_path\thash\tsize_bytes\tmodified_date\n" > "$TMP_OUT"

TOTAL_FILES=0
TOTAL_BYTES=0

# Scan files
while IFS= read -r filepath; do
    # Skip if file is the output manifest or temp files
    local_base="$(basename "$filepath")"
    if [[ "$filepath" == "$OUTPUT_FILE" || ( "$local_base" == "$OUTPUT_BASENAME" && "$(dirname "$filepath")" == "$(dirname "$OUTPUT_FILE")" ) || "$local_base" == checksums.tmp.* ]]; then
        continue
    fi

    # Compute relative path from TARGET_DIR
    rel_path="${filepath#"${TARGET_DIR}/"}"

    # Skip hidden files and hidden directories unless --include-all is specified
    if [[ $INCLUDE_ALL -eq 0 && ("$local_base" == .* || "$rel_path" == .* || "$rel_path" == *"/."*) ]]; then
        continue
    fi

    # Skip checksum (.md5, .sha256, etc.) and log (.log) files unless specified
    local_lower="$(echo "$local_base" | tr '[:upper:]' '[:lower:]')"
    if [[ $INCLUDE_ALL -eq 0 ]]; then
        case "$local_lower" in
            *.md5|*.md5sum|*.sha256|*.sha256sum|*.sha2|*.log)
                continue
                ;;
        esac
    fi

    # Calculate metrics
    file_size=$(get_size "$filepath")
    file_mtime=$(get_mtime "$filepath")
    file_date=$(format_date "$file_mtime")

    printf "  Hashing: %s ... " "$rel_path"
    file_hash=$(compute_hash "$filepath" "$ALGO")
    printf "%s\n" "$file_hash"

    printf "%s\t%s\t%s\t%s\n" "$rel_path" "$file_hash" "$file_size" "$file_date" >> "$TMP_OUT"

    TOTAL_FILES=$((TOTAL_FILES + 1))
    TOTAL_BYTES=$((TOTAL_BYTES + file_size))

done < <(
    if [[ -n "$PATTERN" ]]; then
        find "$TARGET_DIR" -type f -name "$PATTERN" | sort
    else
        find "$TARGET_DIR" -type f | sort
    fi
)

# Move tmp file to final output
mv "$TMP_OUT" "$OUTPUT_FILE"

# Ensure output file mtime is newer than or equal to current time (satisfies Stale Guard)
touch "$OUTPUT_FILE"

printf "\n${GREEN}[SUCCESS]${NC} Manifest generated successfully!\n"
printf "  Total files: %d\n" "$TOTAL_FILES"
printf "  Total size:  %s bytes\n" "$TOTAL_BYTES"
printf "  Output:      %s\n\n" "$OUTPUT_FILE"
