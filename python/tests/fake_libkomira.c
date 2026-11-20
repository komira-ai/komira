// A stand-in for libkomira with the nine calls of ABI 1.1 that the Python
// loader binds. The tests load it to reach what the real library never does:
//
// - FAKE_VERSION sets the ABI version it reports (default 1001, which is 1.1):
//   a library of another major version must be refused, any minor accepted.
// - FAKE_ABI_1_0 leaves out the five calls ABI 1.1 added, as a 1.0 library
//   would: it must load, and those calls must raise when used.
// - FAKE_OMIT_REGISTER leaves out komira_register_parquet, and
//   FAKE_OMIT_ABI_VERSION leaves out komira_abi_version: the loader must
//   refuse each by the symbol's name.
// - Otherwise komira_register_parquet takes its `name` as the mode of every
//   later call and answers by it, so one library drives each case of the
//   two-call protocol and of the error path (see komira_last_error below):
//   "ok", "empty_out" and "null_ctx" succeed; "null_arg" fails with -2; every
//   other name fails with -3. After "null_ctx", komira_ctx_new returns NULL.
//   The four output calls fail with the same status; when they succeed they
//   answer with text naming the arguments they were given, and with nothing
//   in "empty_out".
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef FAKE_VERSION
#define FAKE_VERSION 1001
#endif

#define EXPORT __attribute__((visibility("default")))

static char mode[32];
static int the_ctx;

static int is(const char *m) { return strcmp(mode, m) == 0; }

#ifndef FAKE_OMIT_ABI_VERSION
EXPORT int32_t komira_abi_version(void) { return FAKE_VERSION; }
#endif

EXPORT void *komira_ctx_new(void) { return is("null_ctx") ? NULL : &the_ctx; }

EXPORT void komira_ctx_free(void *ctx) { (void)ctx; }

// The two-call protocol of the real library: the length first, and nothing
// written unless the capacity holds it all.
static int32_t copy_out(const char *text, uint64_t len, uint8_t *b, uint64_t cap, uint64_t *n) {
  *n = len;
  if (cap < len) return -4;
  if (len > 0) memcpy(b, text, len);
  return 0;
}

// The last error, by mode:
//   "capacity"    29 bytes of text naming the capacity the call was given
//                 ("capacity " and 20 digits): the second call's capacity;
//   "null_arg"    "name is NULL";
//   "utf8"        "caf\xc3\xa9 bad\xff": UTF-8, then a byte that is not;
//   "grow"        4 bytes on the first call, 8 on the second, never written;
//   "shrink"      8 bytes on the first call; the second succeeds with 4;
//   "fail_second" 8 bytes on the first call; the second fails with -1;
//   "unreadable"  the call itself fails with -2;
//   otherwise     no text (length 0, success).
EXPORT int32_t komira_last_error(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  if (is("capacity")) {
    char text[30];
    snprintf(text, sizeof text, "capacity %020llu", (unsigned long long)cap);
    return copy_out(text, 29, b, cap, n);
  }
  if (is("null_arg")) return copy_out("name is NULL", 12, b, cap, n);
  if (is("utf8")) return copy_out("caf\xc3\xa9 bad\xff", 10, b, cap, n);
  if (is("grow")) {
    *n = cap == 0 ? 4 : 8;
    return -4;
  }
  if (is("shrink")) {
    if (cap == 0) {
      *n = 8;
      return -4;
    }
    memcpy(b, "abcd", 4);
    *n = 4;
    return 0;
  }
  if (is("fail_second")) {
    if (cap == 0) {
      *n = 8;
      return -4;
    }
    return -1;
  }
  if (is("unreadable")) return -2;
  *n = 0;
  return 0;
}

#ifndef FAKE_ABI_1_0

// The status every call of a 1.1 library answers with in this mode.
static int32_t mode_status(void) {
  if (is("ok") || is("empty_out") || is("null_ctx")) return 0;
  if (is("null_arg")) return -2;
  return -3;
}

#ifndef FAKE_OMIT_REGISTER
EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)ctx;
  (void)path;
  snprintf(mode, sizeof mode, "%s", name);
  return mode_status();
}
#endif

// An output call's answer: `text` in "ok", nothing in "empty_out", else the
// mode's failure.
static int32_t answer(const char *text, uint8_t *b, uint64_t cap, uint64_t *n) {
  int32_t status = mode_status();
  if (status != 0) return status;
  if (is("empty_out")) return copy_out("", 0, b, cap, n);
  return copy_out(text, strlen(text), b, cap, n);
}

static char out[512];

EXPORT int32_t komira_parquet_schema(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  snprintf(out, sizeof out, "parquet:%s", path);
  return answer(out, b, cap, n);
}

EXPORT int32_t komira_csv_binding(void *ctx, const char *path, uint8_t delimiter, int32_t has_header,
                                  int32_t all_varchar, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  snprintf(out, sizeof out, "csv:%s:%u:%d:%d", path, (unsigned)delimiter, (int)has_header, (int)all_varchar);
  return answer(out, b, cap, n);
}

EXPORT int32_t komira_json_binding(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  snprintf(out, sizeof out, "json:%s", path);
  return answer(out, b, cap, n);
}

// The plan's length and its bytes in hex, so a NUL byte inside it shows.
EXPORT int32_t komira_plan_render(void *ctx, const uint8_t *plan, uint64_t plan_len, uint8_t *b, uint64_t cap,
                                  uint64_t *n) {
  (void)ctx;
  int k = snprintf(out, sizeof out, "plan:%llu:", (unsigned long long)plan_len);
  for (uint64_t i = 0; i < plan_len && k + 3 < (int)sizeof out; i++) k += snprintf(out + k, sizeof out - k, "%02x", plan[i]);
  return answer(out, b, cap, n);
}

#endif
