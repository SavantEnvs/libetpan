#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the unittest/ programs built by mayhem/build.sh, each from the directory unittest/Makefile's
# `check` target uses. A test passes when it exits 0 and (unless it is one of the quiet programs)
# prints a success line — a program that was neutered to exit(0) prints nothing and fails.
PASS_RE='(ok|matched|passed|checked|inventory)'
QUIET="activesync/wbxml_test activesync/http_test activesync/sample_test pop3/pop3_test"

run_test() { # <workdir> <path-relative-to-workdir> <name>
  local out rc
  [ -x "$1/$2" ] || { echo "MISSING test binary $1/$2 (mayhem/build.sh should have built it)"; return 1; }
  out="$(cd "$1" && timeout 600 "./$2" 2>&1 </dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "FAIL $3 (exit $rc)"; printf '%s\n' "$out" | tail -5; return 1; fi
  case " $QUIET " in *" $3 "*) echo "PASS $3 (quiet)"; return 0;; esac
  if printf '%s\n' "$out" | grep -Eq "$PASS_RE"; then echo "PASS $3: $(printf '%s\n' "$out" | tail -1 | cut -c1-120)"; return 0; fi
  echo "FAIL $3 (exit 0 but no success output)"; return 1
}

passed=0; failed=0
tally() { if "$@"; then passed=$((passed+1)); else failed=$((failed+1)); fi; }

for t in imap/imap_test imf/imf_test mime/mime_test mime-builder/mime_builder_test \
         mime-parser/mime_parser_serialization_test charset-detection/charset_detection_test \
         plaintext-rendering/plaintext_rendering_test imap-utf7/imap_utf7_test data-types/data_types_test \
         charconv/charconv_test http/http_test feed/feed_http_test activesync/wbxml_test \
         activesync/http_test activesync/sample_test pop3/pop3_test nntp/nntp_test gmail/gmail_test; do
  tally run_test "$SRC/unittest/$(dirname "$t")" "$(basename "$t")" "$t"
done
for t in jmap/jmap_json_test jmap/jmap_http_test jmap/jmap_request_test jmap/jmap_response_test \
         jmap/jmap_call_test jmap/jmap_mailbox_test jmap/jmap_thread_test jmap/jmap_email_test \
         jmap/jmap_blob_test jmap/jmap_session_test; do
  tally run_test "$SRC/unittest" "$t" "$t"
done
tally run_test "$SRC" unittest/smime/smime_low_level_test smime/smime_low_level_test

emit_ctrf "libetpan-unittest" "$passed" "$failed" 0
