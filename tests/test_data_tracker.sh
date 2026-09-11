#!/usr/bin/env bash
# ==============================================================================
# test_data_tracker.sh - Comprehensive Test Suite for Data Tracking Workflow
#
# Validates:
# 1. Bootstrap / init
# 2. Multi-line checksum parsing (GNU & BSD formats)
# 3. Symlink provisioning
# 4. Tier 1 Fast Handshake verification
# 5. Stale Checksum Guard (mtime detection)
# 6. Hash mismatch detection
# 7. Update command (--update)
# 8. Relocate command (--relocate)
# 9. Tier 2 Deep Cryptographic verification (--deep) & silent corruption detection
# 10. Git pre-commit hook enforcement
# ==============================================================================

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
TRACKER="${PROJECT_ROOT}/scripts/data_tracker.sh"

PASSED_TESTS=0
FAILED_TESTS=0

# Create isolated test environment inside workspace
mkdir -p "${PROJECT_ROOT}/.test_tmp"
MOCK_ROOT="${PROJECT_ROOT}/.test_tmp/mock_data_root"
BACKUP_POINTERS="${PROJECT_ROOT}/.test_tmp/pointers_backup"
BACKUP_ENV="${PROJECT_ROOT}/.test_tmp/env_backup"
rm -rf "$MOCK_ROOT"
mkdir -p "$MOCK_ROOT"

cleanup() {
    # Restore original pointers and env
    if [[ -f "$BACKUP_POINTERS" ]]; then
        cp "$BACKUP_POINTERS" "${PROJECT_ROOT}/local_pointers.tsv" 2>/dev/null || true
    fi
    if [[ -f "$BACKUP_ENV" ]]; then
        cp "$BACKUP_ENV" "${PROJECT_ROOT}/.env" 2>/dev/null || true
    fi
    rm -rf "${PROJECT_ROOT}/.test_tmp"
    rm -rf "${PROJECT_ROOT}/analyses" "${PROJECT_ROOT}/references" "${PROJECT_ROOT}/experiments" "${PROJECT_ROOT}/raw_data" "${PROJECT_ROOT}/Bigwigs" "${PROJECT_ROOT}/Bigwigs_Abs" "${PROJECT_ROOT}/Bigwigs_Junk" "${PROJECT_ROOT}/Cohort_50" "${PROJECT_ROOT}/Perf_50" "${PROJECT_ROOT}/ref_genome.fa.gz" "${PROJECT_ROOT}/collision_a.bam" "${PROJECT_ROOT}/collision_b.bam" 2>/dev/null || true
}
trap cleanup EXIT

# Backup current repo state
cp "${PROJECT_ROOT}/local_pointers.tsv" "$BACKUP_POINTERS"
[[ -f "${PROJECT_ROOT}/.env" ]] && cp "${PROJECT_ROOT}/.env" "$BACKUP_ENV" || rm -f "${PROJECT_ROOT}/.env"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

test_assert() {
    local test_name="$1"
    local status="$2"
    if [[ "$status" -eq 0 ]]; then
        printf "${GREEN}✓ PASS:${NC} %s\n" "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        printf "${RED}✗ FAIL:${NC} %s\n" "$test_name"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

printf "\n${BOLD}============================================================${NC}\n"
printf "${BOLD}Starting Data-Tracker Automated Verification Suite${NC}\n"
printf "${BOLD}============================================================${NC}\n\n"

# ------------------------------------------------------------------------------
# 1. Setup Mock Upstream Repository
# ------------------------------------------------------------------------------
mkdir -p "${MOCK_ROOT}/cohort_a/bams"
mkdir -p "${MOCK_ROOT}/cohort_a/fastqs"
mkdir -p "${MOCK_ROOT}/references"

# Create mock data files
echo "MOCK BAM CONTENT SAMPLE 1" > "${MOCK_ROOT}/cohort_a/bams/sample1.bam"
echo "MOCK FASTQ READS R1" > "${MOCK_ROOT}/cohort_a/fastqs/sample1_R1.fastq.gz"
echo "MOCK REFERENCE GENOME FASTA" > "${MOCK_ROOT}/references/genome.fa.gz"

# Generate hashes
HASH_BAM=$(md5 -q "${MOCK_ROOT}/cohort_a/bams/sample1.bam" 2>/dev/null || md5sum "${MOCK_ROOT}/cohort_a/bams/sample1.bam" | awk '{print $1}')
HASH_FQ=$(md5 -q "${MOCK_ROOT}/cohort_a/fastqs/sample1_R1.fastq.gz" 2>/dev/null || md5sum "${MOCK_ROOT}/cohort_a/fastqs/sample1_R1.fastq.gz" | awk '{print $1}')
HASH_REF=$(shasum -a 256 "${MOCK_ROOT}/references/genome.fa.gz" 2>/dev/null || sha256sum "${MOCK_ROOT}/references/genome.fa.gz" | awk '{print $1}')

# Small sleep to ensure checksum files have newer mtime than data
sleep 1

# Multi-line checksum file in cohort_a/checksums.md5
cat << EOF > "${MOCK_ROOT}/cohort_a/checksums.md5"
# Multi-line upstream checksums
${HASH_BAM}  bams/sample1.bam
${HASH_FQ}  fastqs/sample1_R1.fastq.gz
0123456789abcdef0123456789abcdef  other_unrelated_file.bam
EOF

# Single-line checksum for references
cat << EOF > "${MOCK_ROOT}/references/sha256sum.txt"
${HASH_REF}  genome.fa.gz
EOF

export DATA_ROOT="$MOCK_ROOT"

# ------------------------------------------------------------------------------
# Test 1: Bootstrap / Init
# ------------------------------------------------------------------------------
"$TRACKER" init >/dev/null 2>&1
test_assert "Project initialization provisions raw_data/ and local_pointers.tsv" $?

# Write MOCK_ROOT to .env so .env loading is tested
echo "DATA_ROOT=${MOCK_ROOT}" > "${PROJECT_ROOT}/.env"

# ------------------------------------------------------------------------------
# Test 2: Add pointers from multi-line checksum file
# ------------------------------------------------------------------------------
"$TRACKER" add sample1.bam cohort_a/bams/sample1.bam cohort_a/checksums.md5 >/dev/null 2>&1
test_assert "Add sample1.bam and parse from multi-line checksum file" $?

"$TRACKER" add sample1_R1.fq.gz cohort_a/fastqs/sample1_R1.fastq.gz cohort_a/checksums.md5 >/dev/null 2>&1
test_assert "Add sample1_R1.fq.gz from same multi-line checksum file" $?

"$TRACKER" add ref_genome.fa.gz references/genome.fa.gz references/sha256sum.txt >/dev/null 2>&1
test_assert "Add SHA256 reference from separate directory" $?

# ------------------------------------------------------------------------------
# Test 3: Verify symlink creation
# ------------------------------------------------------------------------------
test -L "${PROJECT_ROOT}/raw_data/sample1.bam" && test -e "${PROJECT_ROOT}/raw_data/sample1.bam"
test_assert "Symlink raw_data/sample1.bam is valid and targets real data" $?

# ------------------------------------------------------------------------------
# Test 4: Tier 1 Fast Verification Pass
# ------------------------------------------------------------------------------
"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 Fast Handshake passes on intact data & metadata" $?

# ------------------------------------------------------------------------------
# Test 5: Stale Checksum Guard Detection
# ------------------------------------------------------------------------------
# Modify sample1.bam so mtime(data) > mtime(checksum)
sleep 1
touch "${MOCK_ROOT}/cohort_a/bams/sample1.bam"

if "$TRACKER" verify >/dev/null 2>&1; then
    test_assert "Stale Checksum Guard flags binary modified after checksum" 1
else
    test_assert "Stale Checksum Guard flags binary modified after checksum" 0
fi

# Fix stale checksum by touching checksum file
sleep 1
touch "${MOCK_ROOT}/cohort_a/checksums.md5"
"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 passes once checksum file timestamp is refreshed" $?

# ------------------------------------------------------------------------------
# Test 6: Hash Mismatch Detection
# ------------------------------------------------------------------------------
# Tamper with upstream checksum file
sed -i.bak 's/'"${HASH_BAM}"'/deadbeefdeadbeefdeadbeefdeadbeef/' "${MOCK_ROOT}/cohort_a/checksums.md5"
rm -f "${MOCK_ROOT}/cohort_a/checksums.md5.bak"
touch "${MOCK_ROOT}/cohort_a/checksums.md5"

if "$TRACKER" verify >/dev/null 2>&1; then
    test_assert "Tier 1 detects hash mismatch between TSV and upstream metadata" 1
else
    test_assert "Tier 1 detects hash mismatch between TSV and upstream metadata" 0
fi

# ------------------------------------------------------------------------------
# Test 7: Update Command (--update)
# ------------------------------------------------------------------------------
# Legitimate update: intentionally adopt the new upstream hash
"$TRACKER" update sample1.bam >/dev/null 2>&1
test_assert "Update command updates locked_hash in TSV" $?

# ------------------------------------------------------------------------------
# Test 8: Tier 2 Deep Verification (Cryptographic Calculation)
# ------------------------------------------------------------------------------
# In step 6/7 we put a dummy hash deadbeef...
# The metadata matched TSV, but the actual binary has HASH_BAM!
# Tier 1 passed because text hashes matched.
# Tier 2 (--deep) MUST catch that the actual binary content doesn't match deadbeef!
if "$TRACKER" verify --deep >/dev/null 2>&1; then
    test_assert "Tier 2 Deep Verification catches tampered hash vs binary content" 1
else
    test_assert "Tier 2 Deep Verification catches tampered hash vs binary content" 0
fi

# Restore legitimate hash in checksum and update
cat << EOF > "${MOCK_ROOT}/cohort_a/checksums.md5"
${HASH_BAM}  bams/sample1.bam
${HASH_FQ}  fastqs/sample1_R1.fastq.gz
EOF
touch "${MOCK_ROOT}/cohort_a/checksums.md5"
"$TRACKER" update sample1.bam >/dev/null 2>&1

"$TRACKER" verify --deep >/dev/null 2>&1
test_assert "Tier 2 Deep Verification passes on genuine binary and metadata" $?

# ------------------------------------------------------------------------------
# Test 9: Relocate Command (--relocate)
# ------------------------------------------------------------------------------
# Simulate upstream server reorganization: mv cohort_a -> cohort_archive_2026
mv "${MOCK_ROOT}/cohort_a" "${MOCK_ROOT}/cohort_archive_2026"

"$TRACKER" relocate "cohort_a/" "cohort_archive_2026/" >/dev/null 2>&1
test_assert "Relocate batch updates paths in TSV" $?

"$TRACKER" verify >/dev/null 2>&1
test_assert "Verification passes after server relocation" $?

# ------------------------------------------------------------------------------
# Test 10: Upstream Checksum Generator & Higher-Level Checksum Parsing
# ------------------------------------------------------------------------------
# Setup a nested study with subdirectories
mkdir -p "${MOCK_ROOT}/study_b/subfolder"
mkdir -p "${MOCK_ROOT}/study_b/batch_dir"
echo "STUDY B NESTED BAM" > "${MOCK_ROOT}/study_b/subfolder/nested.bam"
echo "STUDY B BATCH 1" > "${MOCK_ROOT}/study_b/batch_dir/b1.fastq.gz"
echo "STUDY B BATCH 2" > "${MOCK_ROOT}/study_b/batch_dir/b2.fastq.gz"

# Run generate_checksums.sh to create study_b/checksums.tsv at higher level
"${PROJECT_ROOT}/scripts/generate_checksums.sh" "${MOCK_ROOT}/study_b" >/dev/null 2>&1
test -f "${MOCK_ROOT}/study_b/checksums.tsv"
test_assert "generate_checksums.sh creates checksums.tsv in target directory" $?

# Add single file referencing higher-level checksum file and nested destination symlink
"$TRACKER" add "Resources/nested.bam" "study_b/subfolder/nested.bam" "study_b/checksums.tsv" >/dev/null 2>&1
test_assert "Add file with higher-level checksum TSV and nested destination symlink" $?

test -L "${PROJECT_ROOT}/raw_data/Resources/nested.bam" && test -e "${PROJECT_ROOT}/raw_data/Resources/nested.bam"
test_assert "Nested symlink raw_data/Resources/nested.bam created successfully" $?

# ------------------------------------------------------------------------------
# Test 11: Batch Adding (add-batch)
# ------------------------------------------------------------------------------
"$TRACKER" add-batch "batch_links" "study_b/batch_dir" "study_b/checksums.tsv" -p "*.fastq.gz" >/dev/null 2>&1
test_assert "add-batch registers multiple files matching pattern" $?

test -L "${PROJECT_ROOT}/raw_data/batch_links/b1.fastq.gz" && test -L "${PROJECT_ROOT}/raw_data/batch_links/b2.fastq.gz"
test_assert "Batch symlinks raw_data/batch_links/b1 and b2 exist and point to data" $?

# Verify all pointers including batch and nested pointers
"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 Fast Handshake passes with hierarchical TSV and batch pointers" $?

# ------------------------------------------------------------------------------
# Test 12: Scattered Symlinks (Repository-Relative with SYMLINK_DIR=.)
# ------------------------------------------------------------------------------
export SYMLINK_DIR="."
"$TRACKER" add "analyses/01_qc/inputs/scattered_sample.bam" "cohort_archive_2026/bams/sample1.bam" "cohort_archive_2026/checksums.md5" >/dev/null 2>&1
test_assert "Scattered pointer added with repository-relative path" $?

test -L "${PROJECT_ROOT}/analyses/01_qc/inputs/scattered_sample.bam" && test -e "${PROJECT_ROOT}/analyses/01_qc/inputs/scattered_sample.bam"
test_assert "Scattered symlink created in analyses/01_qc/inputs/ and points to data" $?

"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 Fast Handshake passes with scattered symlinks" $?

"$TRACKER" status >/dev/null 2>&1
test_assert "Status command runs and inspects scattered symlinks cleanly" $?

# ------------------------------------------------------------------------------
# Test 13: Multi-Mount Named Roots Architecture (REF_ROOT)
# ------------------------------------------------------------------------------
MOCK_REF_ROOT="${PROJECT_ROOT}/.test_tmp/mock_ref_root"
mkdir -p "${MOCK_REF_ROOT}/genomes"
echo "MOCK HG38 FASTA CONTENT" > "${MOCK_REF_ROOT}/genomes/hg38.fa"
HASH_HG38=$(md5 -q "${MOCK_REF_ROOT}/genomes/hg38.fa" 2>/dev/null || md5sum "${MOCK_REF_ROOT}/genomes/hg38.fa" | awk '{print $1}')
sleep 1
printf "genomes/hg38.fa\t%s\n" "$HASH_HG38" > "${MOCK_REF_ROOT}/genomes/checksums.tsv"

export REF_ROOT="$MOCK_REF_ROOT"
"$TRACKER" add "references/hg38.fa" "REF_ROOT:genomes/hg38.fa" "REF_ROOT:genomes/checksums.tsv" >/dev/null 2>&1
test_assert "Add pointer using named root syntax (REF_ROOT:...)" $?

test -L "${PROJECT_ROOT}/references/hg38.fa" && test -e "${PROJECT_ROOT}/references/hg38.fa"
test_assert "Symlink references/hg38.fa created and targets secondary mount" $?

"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 Handshake verifies across both DATA_ROOT and REF_ROOT" $?

"$TRACKER" verify --deep >/dev/null 2>&1
test_assert "Tier 2 Deep Verification passes across multiple storage roots" $?

# Test that unsetting REF_ROOT causes verify to fail
STATUS_UNMOUNTED=0
REF_ROOT="/nonexistent/unmounted/path" "$TRACKER" verify >/dev/null 2>&1 || STATUS_UNMOUNTED=$?
if [[ "$STATUS_UNMOUNTED" -ne 0 ]]; then
    test_assert "Verify fails when a configured secondary storage root is unmounted" 0
else
    test_assert "Verify fails when a configured secondary storage root is unmounted" 1
fi
export REF_ROOT="$MOCK_REF_ROOT"

# ------------------------------------------------------------------------------
# Test 14: Automated Project Adoption (adopt / scan)
# ------------------------------------------------------------------------------
# Create pre-existing scattered symlink manually
mkdir -p "${PROJECT_ROOT}/experiments/pilot/inputs"
ln -sfn "${MOCK_ROOT}/cohort_archive_2026/fastqs/sample1_R1.fastq.gz" "${PROJECT_ROOT}/experiments/pilot/inputs/pilot_R1.fastq.gz"

"$TRACKER" adopt >/dev/null 2>&1
test_assert "adopt command scans project and registers pre-existing symlinks" $?

grep -q "experiments/pilot/inputs/pilot_R1.fastq.gz" "${PROJECT_ROOT}/local_pointers.tsv"
test_assert "local_pointers.tsv records adopted symlink with locked hash" $?

"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 verify passes with newly adopted pointer" $?

# ------------------------------------------------------------------------------
# Test 15: Adoption Reporting & Targeted Filtering Flags
# ------------------------------------------------------------------------------
# Create scenarios:
# 1. Missing checksum: file without checksum manifest
mkdir -p "${MOCK_ROOT}/unmanifested"
echo "NO CHECKSUM DATA" > "${MOCK_ROOT}/unmanifested/no_meta.bam"
mkdir -p "${PROJECT_ROOT}/experiments/test_report"
ln -sfn "${MOCK_ROOT}/unmanifested/no_meta.bam" "${PROJECT_ROOT}/experiments/test_report/no_meta.bam"

# 2. Unmatched storage root: file completely outside DATA_ROOT and REF_ROOT
MOCK_OTHER_ROOT="${PROJECT_ROOT}/.test_tmp/other_outside_root"
mkdir -p "${MOCK_OTHER_ROOT}"
echo "OTHER ROOT DATA" > "${MOCK_OTHER_ROOT}/outside.bam"
ln -sfn "${MOCK_OTHER_ROOT}/outside.bam" "${PROJECT_ROOT}/experiments/test_report/outside.bam"

# 3. Broken symlink
ln -sfn "/nonexistent/storage/path/broken.bam" "${PROJECT_ROOT}/experiments/test_report/broken.bam"

# Test --missing-checksums filter
MISSING_OUT=$("$TRACKER" adopt --missing-checksums)
echo "$MISSING_OUT" | grep -q "experiments/test_report/no_meta.bam"
test_assert "adopt --missing-checksums outputs symlinks lacking upstream manifests" $?

# Test --missing-checksum-dirs filter
MISSING_DIRS_OUT=$("$TRACKER" adopt --missing-checksum-dirs)
echo "$MISSING_DIRS_OUT" | grep -q "${MOCK_ROOT}/unmanifested"
test_assert "adopt --missing-checksum-dirs outputs unique directories needing checksums" $?

# Test --unmatched filter
UNMATCHED_OUT=$("$TRACKER" adopt --unmatched)
echo "$UNMATCHED_OUT" | grep -q "experiments/test_report/outside.bam"
test_assert "adopt --unmatched outputs symlinks outside active roots" $?

# Test --broken filter
BROKEN_OUT=$("$TRACKER" adopt --broken)
echo "$BROKEN_OUT" | grep -q "experiments/test_report/broken.bam"
test_assert "adopt --broken outputs dangling symlinks" $?

# Test --report detailed breakdown
REPORT_OUT=$("$TRACKER" adopt --dry-run --report 2>&1)
echo "$REPORT_OUT" | grep -q "Detailed Adoption Report & Action Items"
test_assert "adopt --report renders detailed itemized report banner" $?
echo "$REPORT_OUT" | grep -q "Missing Upstream Checksums"
test_assert "adopt --report categorizes missing checksums" $?
echo "$REPORT_OUT" | grep -q "Unmatched Storage Roots"
test_assert "adopt --report categorizes unmatched roots" $?
echo "$REPORT_OUT" | grep -q "Broken / Dangling Symlinks"
test_assert "adopt --report categorizes broken symlinks" $?

# Cleanup test_report symlinks so they don't break subsequent verify
rm -rf "${PROJECT_ROOT}/experiments/test_report"

# ------------------------------------------------------------------------------
# Test 16: Recursive Batch Add (add-batch -r) with Real Directories
# ------------------------------------------------------------------------------
# Setup nested upstream study folder
mkdir -p "${MOCK_ROOT}/nested_study/sub1/sub2"
echo "BIGWIG CONTENT 1" > "${MOCK_ROOT}/nested_study/sub1/sub2/track1.bw"
echo "BIGWIG CONTENT 2" > "${MOCK_ROOT}/nested_study/sub1/track2.bw"
echo "OTHER CONTENT TXT" > "${MOCK_ROOT}/nested_study/sub1/notes.txt"

# Generate upstream checksums
bash "${PROJECT_ROOT}/scripts/generate_checksums.sh" "${MOCK_ROOT}/nested_study" >/dev/null 2>&1

# Run recursive batch add filtering for *.bw
"$TRACKER" add-batch "Bigwigs" "nested_study" "nested_study/checksums.tsv" -r -p "*.bw" >/dev/null 2>&1
test_assert "add-batch -r recursively registers nested files" $?

# Verify that intermediate directories are REAL physical directories (not symlinks)
if [[ -d "${PROJECT_ROOT}/Bigwigs" && ! -L "${PROJECT_ROOT}/Bigwigs" && \
      -d "${PROJECT_ROOT}/Bigwigs/sub1" && ! -L "${PROJECT_ROOT}/Bigwigs/sub1" && \
      -d "${PROJECT_ROOT}/Bigwigs/sub1/sub2" && ! -L "${PROJECT_ROOT}/Bigwigs/sub1/sub2" ]]; then
    test_assert "add-batch -r creates real physical local directories (not directory symlinks)" 0
else
    test_assert "add-batch -r creates real physical local directories (not directory symlinks)" 1
fi

# Verify that leaf files are valid symlinks pointing to real data
if [[ -L "${PROJECT_ROOT}/Bigwigs/sub1/sub2/track1.bw" && -e "${PROJECT_ROOT}/Bigwigs/sub1/sub2/track1.bw" && \
      -L "${PROJECT_ROOT}/Bigwigs/sub1/track2.bw" && -e "${PROJECT_ROOT}/Bigwigs/sub1/track2.bw" && \
      ! -e "${PROJECT_ROOT}/Bigwigs/sub1/notes.txt" ]]; then
    test_assert "add-batch -r provisions individual leaf file symlinks matching filter pattern" 0
else
    test_assert "add-batch -r provisions individual leaf file symlinks matching filter pattern" 1
fi

# Verify that Tier 1 verification passes on the recursively added pointers
if "$TRACKER" verify >/dev/null 2>&1; then
    test_assert "Tier 1 Fast Handshake passes on recursively added batch pointers" 0
else
    test_assert "Tier 1 Fast Handshake passes on recursively added batch pointers" 1
fi

# Test add-batch with flag placed first (-r dest ...) and absolute paths matching root
"$TRACKER" add-batch -r "Bigwigs_Abs" "${MOCK_ROOT}/nested_study" "${MOCK_ROOT}/nested_study/checksums.tsv" -p "*.bw" >/dev/null 2>&1
test_assert "add-batch accepts flags first (-r dest ...) and auto-normalizes absolute paths" $?

# Inject OS junk files (.DS_Store, Thumbs.db, AppleDouble ._*) into upstream directory
echo "DS_STORE JUNK" > "${MOCK_ROOT}/nested_study/.DS_Store"
echo "THUMBS JUNK" > "${MOCK_ROOT}/nested_study/sub1/Thumbs.db"
echo "APPLEDOUBLE JUNK" > "${MOCK_ROOT}/nested_study/sub1/._track2.bw"

# Verify add-batch safely skips them and does not fail on missing checksums
"$TRACKER" add-batch -r "Bigwigs_Junk" "${MOCK_ROOT}/nested_study" "${MOCK_ROOT}/nested_study/checksums.tsv" >/dev/null 2>&1
test_assert "add-batch ignores .DS_Store, AppleDouble ._*, and OS metadata files" $?

# Verify single-pass batch import handles 50 nested files cleanly and quickly
mkdir -p "${MOCK_ROOT}/large_cohort/sub1" "${MOCK_ROOT}/large_cohort/sub2" "${MOCK_ROOT}/large_cohort/sub3"
for i in $(seq 1 50); do
    sub=$(( (i % 3) + 1 ))
    echo "content $i" > "${MOCK_ROOT}/large_cohort/sub${sub}/f_${i}.txt"
done
(
    for sub in 1 2 3; do
        for f in "${MOCK_ROOT}/large_cohort/sub${sub}"/*.txt; do
            rel_f="sub${sub}/$(basename "$f")"
            h=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | awk '{print $1}')
            printf "%s\t%s\n" "$rel_f" "$h"
        done
    done
) > "${MOCK_ROOT}/large_cohort/checksums.tsv"
"$TRACKER" add-batch -r "Cohort_50" "${MOCK_ROOT}/large_cohort" "${MOCK_ROOT}/large_cohort/checksums.tsv" >/dev/null 2>&1
test_assert "add-batch -r processes high-volume cohort (50 files) in single pass" $?
test_assert "high-volume batch registered all 50 files in local_pointers.tsv" $([ $(grep -c "^Cohort_50/" "${PROJECT_ROOT}/local_pointers.tsv") -eq 50 ] && echo 0 || echo 1)


# ------------------------------------------------------------------------------
# Test 17: Directory Symlink Detection & Flagging in adopt
# ------------------------------------------------------------------------------
# Create an accidental directory symlink (pointing to a folder, not a file)
mkdir -p "${PROJECT_ROOT}/experiments"
ln -sfn "${MOCK_ROOT}/nested_study" "${PROJECT_ROOT}/experiments/dir_symlink"

# Test adopt --directory-symlinks filter
DIR_SYMLINK_OUT=$("$TRACKER" adopt --directory-symlinks)
echo "$DIR_SYMLINK_OUT" | grep -q "experiments/dir_symlink"
test_assert "adopt --directory-symlinks flags symlinks pointing to directories" $?

# Test adopt --report includes Directory Symlinks warning and remediation
DIR_REPORT_OUT=$("$TRACKER" adopt --dry-run --report 2>&1)
echo "$DIR_REPORT_OUT" | grep -q "Directory Symlinks"
test_assert "adopt --report contains Directory Symlinks warning section" $?
echo "$DIR_REPORT_OUT" | grep -q -- "-r"
test_assert "adopt --report provides actionable remediation using add-batch -r" $?

# Clean up accidental directory symlink
rm -f "${PROJECT_ROOT}/experiments/dir_symlink"

# ------------------------------------------------------------------------------
# Test 18: Command-Specific Help Menus
# ------------------------------------------------------------------------------
# Test data_tracker.sh help add-batch
HELP_BATCH=$("$TRACKER" help add-batch)
echo "$HELP_BATCH" | grep -q "Usage: data_tracker.sh add-batch" && echo "$HELP_BATCH" | grep -q -- "-r, --recursive"
test_assert "help add-batch outputs detailed usage and recursive options" $?

# Test data_tracker.sh add-batch -h
HELP_BATCH_SHORT=$("$TRACKER" add-batch -h)
echo "$HELP_BATCH_SHORT" | grep -q "Usage: data_tracker.sh add-batch"
test_assert "add-batch -h flag triggers command-specific help" $?

# Test data_tracker.sh add-batch --help
HELP_BATCH_LONG=$("$TRACKER" add-batch --help)
echo "$HELP_BATCH_LONG" | grep -q "Usage: data_tracker.sh add-batch"
test_assert "add-batch --help flag triggers command-specific help" $?

# Test data_tracker.sh help adopt
HELP_ADOPT=$("$TRACKER" help adopt)
echo "$HELP_ADOPT" | grep -q -- "--directory-symlinks"
test_assert "help adopt documents directory symlink filters" $?

# Test data_tracker.sh verify --help
HELP_VERIFY=$("$TRACKER" verify --help)
echo "$HELP_VERIFY" | grep -q "Tier 1 (Fast Handshake"
test_assert "verify --help documents verification tiers" $?

# Test data_tracker.sh help status
HELP_STATUS=$("$TRACKER" help status)
echo "$HELP_STATUS" | grep -q -- "-v, --verbose"
test_assert "help status documents -v and --verbose flags" $?

# ------------------------------------------------------------------------------
# Test 19: Status Command Summary & Verbose Mode
# ------------------------------------------------------------------------------
# Provision links so all pointers match active project state
"$TRACKER" link >/dev/null 2>&1

STATUS_DEFAULT_OUT=$("$TRACKER" status)
echo "$STATUS_DEFAULT_OUT" | grep -q "Pointers Summary:" && \
echo "$STATUS_DEFAULT_OUT" | grep -q "healthy (OK)" && \
! echo "$STATUS_DEFAULT_OUT" | grep -q "LINK NAME"
test_assert "Status default outputs summary and suppresses table when all OK" $?

STATUS_VERBOSE_OUT=$("$TRACKER" status -v)
echo "$STATUS_VERBOSE_OUT" | grep -q "Pointers Summary:" && \
echo "$STATUS_VERBOSE_OUT" | grep -q "LINK NAME"
test_assert "Status -v outputs full table and summary" $?

# Break one symlink to test partial issue reporting in default mode
TEST_BROKEN_LINK=$(awk -F'\t' 'NR==2 {print $1}' "${PROJECT_ROOT}/local_pointers.tsv")
if [[ "$SYMLINK_DIR" == "$PROJECT_ROOT" ]]; then
    TARGET_LINK_PATH="${PROJECT_ROOT}/${TEST_BROKEN_LINK}"
else
    TARGET_LINK_PATH="${PROJECT_ROOT}/raw_data/${TEST_BROKEN_LINK}"
fi
rm -f "$TARGET_LINK_PATH"

STATUS_ISSUE_OUT=$("$TRACKER" status)
echo "$STATUS_ISSUE_OUT" | grep -q "Pointers Summary:" && \
echo "$STATUS_ISSUE_OUT" | grep -q "Pointers Requiring Attention" && \
echo "$STATUS_ISSUE_OUT" | grep -q "$TEST_BROKEN_LINK"
test_assert "Status default lists only problematic files when issues are present" $?

# Restore symlink and check that status recovers
"$TRACKER" link >/dev/null 2>&1
STATUS_RECOVER_OUT=$("$TRACKER" status)
echo "$STATUS_RECOVER_OUT" | grep -q "healthy (OK)" && \
! echo "$STATUS_RECOVER_OUT" | grep -q "Pointers Requiring Attention"
test_assert "Status returns to clean summary after restoring symlinks" $?

# Verify Git Hook status reporting in status output
echo "$STATUS_RECOVER_OUT" | grep -q "Git Hook:" && \
echo "$STATUS_RECOVER_OUT" | grep -q "\[INSTALLED\]"
test_assert "Status inspects and reports Git pre-commit hook as INSTALLED" $?

# Verify NOT INSTALLED detection when core.hooksPath is empty
STATUS_UNINSTALLED_OUT=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="core.hooksPath" GIT_CONFIG_VALUE_0="" "$TRACKER" status)
echo "$STATUS_UNINSTALLED_OUT" | grep -q "Git Hook:" && \
echo "$STATUS_UNINSTALLED_OUT" | grep -q "\[NOT INSTALLED\]"
test_assert "Status flags Git pre-commit hook as NOT INSTALLED when unconfigured" $?

# Verify BROKEN detection when core.hooksPath points to missing directory
STATUS_BROKEN_HOOK_OUT=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="core.hooksPath" GIT_CONFIG_VALUE_0=".missing_hooks" "$TRACKER" status)
echo "$STATUS_BROKEN_HOOK_OUT" | grep -q "\[BROKEN\]"
test_assert "Status flags Git pre-commit hook as BROKEN when target is missing" $?

# ------------------------------------------------------------------------------
# Test 20: Basename Collision Disambiguation Across Subdirectories
# ------------------------------------------------------------------------------
# Create files with identical basenames in different subdirectories
mkdir -p "${MOCK_ROOT}/collision_study/sub_a" "${MOCK_ROOT}/collision_study/sub_b"
echo "COLLISION SAMPLE A" > "${MOCK_ROOT}/collision_study/sub_a/data.bam"
echo "COLLISION SAMPLE B DIFFERENT CONTENT" > "${MOCK_ROOT}/collision_study/sub_b/data.bam"
HASH_COLL_A=$(md5 -q "${MOCK_ROOT}/collision_study/sub_a/data.bam" 2>/dev/null || md5sum "${MOCK_ROOT}/collision_study/sub_a/data.bam" | awk '{print $1}')
HASH_COLL_B=$(md5 -q "${MOCK_ROOT}/collision_study/sub_b/data.bam" 2>/dev/null || md5sum "${MOCK_ROOT}/collision_study/sub_b/data.bam" | awk '{print $1}')
sleep 1

# Single manifest where sub_a/data.bam appears BEFORE sub_b/data.bam
cat << EOF > "${MOCK_ROOT}/collision_study/checksums.tsv"
sub_a/data.bam	${HASH_COLL_A}
sub_b/data.bam	${HASH_COLL_B}
EOF

"$TRACKER" add "collision_a.bam" "collision_study/sub_a/data.bam" "collision_study/checksums.tsv" >/dev/null 2>&1
"$TRACKER" add "collision_b.bam" "collision_study/sub_b/data.bam" "collision_study/checksums.tsv" >/dev/null 2>&1

# Verify must correctly resolve both without false HASH MISMATCH
"$TRACKER" verify >/dev/null 2>&1
test_assert "Tier 1 verify accurately resolves identical basenames in different subdirs" $?

# Verify verify -q (quiet mode) passes cleanly and produces no stdout on success
VERIFY_QUIET_OUT=$("$TRACKER" verify -q)
test_assert "Tier 1 verify -q runs cleanly and outputs nothing on success" $([ -z "$VERIFY_QUIET_OUT" ] && echo 0 || echo 1)

# ------------------------------------------------------------------------------
# Test 21: High-Volume Verification Performance (< 1s for 100+ pointers)
# ------------------------------------------------------------------------------
mkdir -p "${MOCK_ROOT}/perf_cohort"
for i in $(seq 1 50); do
    echo "perf content $i" > "${MOCK_ROOT}/perf_cohort/f_${i}.txt"
done
sleep 1
(
    for f in "${MOCK_ROOT}/perf_cohort"/*.txt; do
        rel_f="$(basename "$f")"
        h=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | awk '{print $1}')
        printf "%s\t%s\n" "$rel_f" "$h"
    done
) > "${MOCK_ROOT}/perf_cohort/checksums.tsv"

"$TRACKER" add-batch "Perf_50" "perf_cohort" "perf_cohort/checksums.tsv" >/dev/null 2>&1

# Measure verify execution time across all tracked pointers (now over 100 pointers)
TEST_PY="python3"
if /usr/bin/python3 -c "import sys" >/dev/null 2>&1; then
    TEST_PY="/usr/bin/python3"
fi

PERF_START=$("$TEST_PY" -c 'import time; print(time.time())')
"$TRACKER" verify -q
PERF_END=$("$TEST_PY" -c 'import time; print(time.time())')
PERF_ELAPSED=$("$TEST_PY" -c "print(round($PERF_END - $PERF_START, 3))")
PERF_FAST=$("$TEST_PY" -c "print(1 if ($PERF_END - $PERF_START) < 1.0 else 0)")

test_assert "Tier 1 handshake completes in under 1 second (${PERF_ELAPSED}s for 100+ pointers)" $([ "$PERF_FAST" -eq 1 ] && echo 0 || echo 1)

# ------------------------------------------------------------------------------
# Test 22: Git Pre-Commit Hook Integration
# ------------------------------------------------------------------------------
# Pre-commit hook should pass right now
if bash "${PROJECT_ROOT}/.githooks/pre-commit" >/dev/null 2>&1; then
    test_assert "Git pre-commit hook passes when all data pointers are valid" 0
else
    test_assert "Git pre-commit hook passes when all data pointers are valid" 1
fi

# Pre-commit hook should abort if file is missing
rm "${MOCK_ROOT}/references/genome.fa.gz"
if bash "${PROJECT_ROOT}/.githooks/pre-commit" >/dev/null 2>&1; then
    test_assert "Git pre-commit hook aborts commit when data is missing" 1
else
    test_assert "Git pre-commit hook aborts commit when data is missing" 0
fi

# ------------------------------------------------------------------------------
# Results Summary
# ------------------------------------------------------------------------------
printf "\n${BOLD}============================================================${NC}\n"
printf "${BOLD}Test Results: %d Passed, %d Failed${NC}\n" "$PASSED_TESTS" "$FAILED_TESTS"
printf "${BOLD}============================================================${NC}\n"

if [[ $FAILED_TESTS -gt 0 ]]; then
    exit 1
fi
