#!/usr/bin/env bash
#
# mayhem/build.sh — build libetpan twice (normal flags for the unit tests, sanitized for the fuzz
# harnesses), the IMAP/JMAP response-parser libFuzzer harnesses (+ standalone reproducers), and the
# project's unittest/ programs that mayhem/test.sh runs.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Unit-test programs (unittest/Makefile) that need no optional library missing from the image;
# mailpgp needs librnp >= 0.17.2 (Debian ships older), so it is excluded and configured out.
TESTS="imap/imap_test imf/imf_test mime/mime_test mime-builder/mime_builder_test
mime-parser/mime_parser_serialization_test charset-detection/charset_detection_test
plaintext-rendering/plaintext_rendering_test imap-utf7/imap_utf7_test data-types/data_types_test
charconv/charconv_test http/http_test feed/feed_http_test activesync/wbxml_test
activesync/http_test activesync/sample_test pop3/pop3_test nntp/nntp_test gmail/gmail_test
jmap/jmap_json_test jmap/jmap_http_test jmap/jmap_request_test jmap/jmap_response_test
jmap/jmap_call_test jmap/jmap_mailbox_test jmap/jmap_thread_test jmap/jmap_email_test
jmap/jmap_blob_test jmap/jmap_session_test smime/smime_low_level_test"

configure_and_make() { # <CFLAGS> <LDFLAGS>
  # Clean any previous configuration so the script is re-runnable on a built tree.
  if [ -f Makefile ]; then make clean >/dev/null 2>&1 || true; fi
  ./autogen.sh CC="$CC" CFLAGS="$1" LDFLAGS="$2" --with-rnp=no --disable-db --enable-static --disable-shared
  make stamp-prepare && make -j"$MAYHEM_JOBS" -C src
}

# 1) Test build with the project's NORMAL flags; the unit-test programs link libetpan.a statically,
#    so they survive the sanitized rebuild below.
configure_and_make "-g -O2 $COVERAGE_FLAGS" "$COVERAGE_FLAGS"
(cd unittest && env -u CFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" LIBETPAN_TEST_DEPENDENCY= CFLAGS="-Wall -Wextra -Werror -g $COVERAGE_FLAGS" $TESTS)

# 2) Sanitized project build (ASan+UBSan halting, DWARF 3, libFuzzer coverage instrumentation in the
#    library itself) for the fuzz harnesses. UBSan's `function` check is relaxed: the IMAP parser calls
#    mailimap_cont_req_or_resp_data_parse_progress through a differently-typed function pointer
#    (mailimap_parser.c:995) on every response, which would abort every input.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=function $DEBUG_FLAGS -O1"
configure_and_make "$FUZZ_CFLAGS" "$SANITIZER_FLAGS"

INC="-I$SRC -I$SRC/include -I$SRC/src/data-types -I$SRC/src/low-level/imap -I$SRC/src/low-level/jmap -I$SRC/src/low-level/imf -I$SRC/src/low-level/mime -I$SRC/src/main"
LIBS="$SRC/src/.libs/libetpan.a $(pkg-config --libs icu-uc 2>/dev/null) -lsasl2 -lssl -lcrypto -lcurl -ljson-c -lxml2 -lz -lpthread -lm"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o /tmp/lsan_off.o

# fuzz_imap_response: upstream's tests/fuzz harness as-is. fuzz_jmap_response: a copy in
# mayhem/harnesses that adds the missing mailjmap_types.h include (upstream's does not compile).
for h in fuzz_imap_response fuzz_jmap_response; do
  src=tests/fuzz/$h.c; [ -f "mayhem/harnesses/$h.c" ] && src=mayhem/harnesses/$h.c
  $CC $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS -O1 $INC $LIB_FUZZING_ENGINE \
      "$src" /tmp/lsan_off.o $LIBS -o "/mayhem/$h"
  $CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=function $DEBUG_FLAGS -O1 $INC "$STANDALONE_FUZZ_MAIN" \
      "$src" /tmp/lsan_off.o $LIBS -o "/mayhem/$h-standalone"
done
