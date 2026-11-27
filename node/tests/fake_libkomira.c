// A stand-in for libkomira that reports an ABI version and defines the seven
// functions the Node addon resolves from every library of ABI 1, each doing
// nothing. The tests load it to
// reach the addon's refusals: a library of another major version
// (FAKE_VERSION) and a library without a symbol (FAKE_OMIT_PLAN_RENDER). With FAKE_RECORD_CAPACITY its two result calls write
// the capacity they were given and the length they reported into the result.
// With FAKE_REGISTER_STATUS komira_register_parquet fails with that status, and
// with FAKE_LAST_ERROR (a string literal) the context's last error is that
// text, read with the two-call protocol; without it the last error is empty.
// With FAKE_ECHO_REGISTER komira_register_parquet fails with -3, and its last
// error is `<name>\t<path>`, the two arguments as the call received them, so a
// test reads back what reached the library.
//
// The calls later minors added, each exported only when asked for, so a
// library may lack one its version promises:
// - FAKE_OPTIONS exports komira_ctx_new_with_options (ABI 1.4). Each context
//   it makes holds the text of the call that made it,
//   `komira_ctx_new_with_options(<workers>, <budget>)`, and komira_ctx_new's
//   holds `komira_ctx_new()`. A worker count of 3 is one the stand-in's
//   engine cannot start with: the call returns NULL.
// - FAKE_ERROR_CODES exports komira_last_error_code and komira_last_error_step
//   (ABI 1.7), which answer the code and step the last refusal set.
// - komira_sql_stream (ABI 1.3) is exported by every build of version 1.3 or
//   later, refusing every query with -3, unless FAKE_OMIT_SQL_STREAM.
// With FAKE_SCRIPTED komira_register_parquet answers by its `name`:
//   "refuse <status> <step> [<code>]"  fails with that status, step number
//       and code, and the last error `stand-in refusal status <status> step
//       <step> code <code>`;
//   "ctx"  fails with -3, no code and no step, and the context's text as the
//       last error: how the session's context was made;
//   any other name succeeds and clears the last error.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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
#if FAKE_VERSION % 1000 >= 3 && !defined(FAKE_OMIT_SQL_STREAM)
EXPORT int32_t komira_sql_stream(void *ctx, const char *sql, void *out) {
  (void)ctx; (void)sql; (void)out;
  return -3;
}
#endif
static char the_ctx[] = "komira_ctx_new()";
EXPORT void *komira_ctx_new(void) { return the_ctx; }
EXPORT void komira_ctx_free(void *ctx) {
  if (ctx != the_ctx) free(ctx);
}
#ifdef FAKE_OPTIONS
EXPORT void *komira_ctx_new_with_options(int64_t workers, int64_t budget) {
  if (workers == 3) return NULL;
  char *ctx = malloc(96);
  if (ctx != NULL) {
    snprintf(ctx, 96, "komira_ctx_new_with_options(%lld, %lld)", (long long)workers, (long long)budget);
  }
  return ctx;
}
#endif
static char last_error[4096] = FAKE_LAST_ERROR;
#if defined(FAKE_ERROR_CODES) || defined(FAKE_SCRIPTED)
static char err_code[256];
static int32_t err_step;
#endif
#ifdef FAKE_ERROR_CODES
EXPORT int32_t komira_last_error_code(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  const uint64_t len = strlen(err_code);
  *n = len;
  if (len == 0) return 0;
  if (cap < len) return -4;
  memcpy(b, err_code, len);
  return 0;
}
EXPORT int32_t komira_last_error_step(void *ctx) {
  (void)ctx;
  return err_step;
}
#endif
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
#if defined(FAKE_SCRIPTED)
  (void)path;
  int status = 0, step = 0;
  err_code[0] = '\0';
  err_step = 0;
  if (sscanf(name, "refuse %d %d %255s", &status, &step, err_code) >= 2) {
    err_step = step;
    snprintf(last_error, sizeof last_error, "stand-in refusal status %d step %d code %s", status, step, err_code);
    return status;
  }
  if (strcmp(name, "ctx") == 0) {
    snprintf(last_error, sizeof last_error, "%s", (const char *)ctx);
    return -3;
  }
  last_error[0] = '\0';
  return 0;
#elif defined(FAKE_ECHO_REGISTER)
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
