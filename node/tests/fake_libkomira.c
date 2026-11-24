// A stand-in for libkomira that reports an ABI version and defines the seven
// functions the Node addon resolves, each doing nothing. The tests load it to
// reach the addon's refusals: a library of another major version
// (FAKE_VERSION) and a library without a symbol (FAKE_OMIT_PLAN_RENDER). With FAKE_RECORD_CAPACITY its two result calls write
// the capacity they were given and the length they reported into the result.
// With FAKE_REGISTER_STATUS komira_register_parquet fails with that status, and
// with FAKE_LAST_ERROR (a string literal) the context's last error is that
// text, read with the two-call protocol; without it the last error is empty.
// With FAKE_ECHO_REGISTER komira_register_parquet fails with -3, and its last
// error is `<name>\t<path>`, the two arguments as the call received them, so a
// test reads back what reached the library.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef FAKE_VERSION
#define FAKE_VERSION 1001
#endif
#ifndef FAKE_REGISTER_STATUS
#define FAKE_REGISTER_STATUS 0
#endif
#ifndef FAKE_LAST_ERROR
#define FAKE_LAST_ERROR ""
#endif

#define EXPORT __attribute__((visibility("default")))

EXPORT int32_t komira_abi_version(void) { return FAKE_VERSION; }
static int the_ctx;
EXPORT void *komira_ctx_new(void) { return &the_ctx; }
EXPORT void komira_ctx_free(void *ctx) { (void)ctx; }
static char last_error[4096] = FAKE_LAST_ERROR;
EXPORT int32_t komira_last_error(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  const uint64_t len = strlen(last_error);
  *n = len;
  if (len == 0) return 0;
  if (cap < len) return -4;
  memcpy(b, last_error, len);
  return 0;
}
EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)ctx;
#ifdef FAKE_ECHO_REGISTER
  snprintf(last_error, sizeof last_error, "%s\t%s", name, path);
  return -3;
#else
  (void)name; (void)path; return FAKE_REGISTER_STATUS;
#endif
}
#ifdef FAKE_RECORD_CAPACITY
// The result is 16 bytes: the capacity the caller passed, then the length this
// call reported, each as a little-endian u64. A call with less room than 16
// reports the length and asks for a bigger buffer, as the real library does.
static int32_t record(uint8_t *b, uint64_t cap, uint64_t *n) {
  *n = 16;
  if (cap < 16) return -4;
  for (int i = 0; i < 8; i++) { b[i] = (uint8_t)(cap >> (8 * i)); b[8 + i] = (uint8_t)(16 >> (8 * i)); }
  return 0;
}
#endif
EXPORT int32_t komira_parquet_schema(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx; (void)path;
#ifdef FAKE_RECORD_CAPACITY
  return record(b, cap, n);
#else
  (void)b; (void)cap; *n = 0; return 0;
#endif
}
#ifndef FAKE_OMIT_PLAN_RENDER
EXPORT int32_t komira_plan_render(void *ctx, const uint8_t *p, uint64_t len, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx; (void)p; (void)len;
#ifdef FAKE_RECORD_CAPACITY
  return record(b, cap, n);
#else
  (void)b; (void)cap; *n = 0; return 0;
#endif
}
#endif
