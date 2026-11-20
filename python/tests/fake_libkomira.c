// A stand-in for libkomira with the five functions the Python loader binds.
// The tests load it to reach what the real library never does:
//
// - FAKE_VERSION sets the ABI version it reports (default 1001, which is 1.1):
//   a library of another major version must be refused.
// - FAKE_OMIT_REGISTER leaves out komira_register_parquet: a library without a
//   function the loader binds must be refused by the symbol's name.
// - Otherwise komira_register_parquet takes its `name` as the mode of every
//   later call and answers by it, so one library drives each case of the
//   two-call protocol and of the error path (see `last_error_mode` below):
//   "ok" and "null_ctx" succeed; "null_arg" fails with -2; every other name
//   fails with -3. After "null_ctx", komira_ctx_new returns NULL.
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

EXPORT int32_t komira_abi_version(void) { return FAKE_VERSION; }

EXPORT void *komira_ctx_new(void) { return is("null_ctx") ? NULL : &the_ctx; }

EXPORT void komira_ctx_free(void *ctx) { (void)ctx; }

// The two-call protocol of the real library: the length first, and nothing
// written unless the capacity holds it all.
static int32_t copy_out(const char *text, uint64_t len, uint8_t *b, uint64_t cap, uint64_t *n) {
  *n = len;
  if (cap < len) return -4;
  memcpy(b, text, len);
  return 0;
}

// The last error, by mode:
//   "capacity"   29 bytes of text naming the capacity the call was given
//                ("capacity " and 20 digits): the second call's capacity;
//   "null_arg"   "name is NULL";
//   "utf8"       "caf\xc3\xa9 bad\xff": UTF-8, then a byte that is not;
//   "grow"       4 bytes on the first call, 8 on the second, never written;
//   "shrink"     8 bytes on the first call; the second succeeds with 4;
//   "fail_second" 8 bytes on the first call; the second fails with -1;
//   "unreadable" the call itself fails with -2;
//   otherwise    no text (length 0, success).
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

#ifndef FAKE_OMIT_REGISTER
EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)ctx;
  (void)path;
  snprintf(mode, sizeof mode, "%s", name);
  if (is("ok") || is("null_ctx")) return 0;
  if (is("null_arg")) return -2;
  return -3;
}
#endif
