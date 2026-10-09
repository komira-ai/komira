/*
 * The native UDF runtime of docs/design/udf_runtime_interface.md section
 * 1.2: a runtime with no interpreter, a loader that forwards the C ABI to
 * user libraries. Test-only spike code. It is written against
 * komira_udf_runtime.h alone; its id comes from describe, never from a
 * caller.
 *
 * What it does, by entry:
 *   - describe: one fixed set (NATIVE, hosting 0, CONTEXT_PER_THREAD without
 *     thread_affine, global_lock 0, every shape). It reports IN_PROCESS only:
 *     the design lists both transports, and no worker serves this runtime yet.
 *   - validate: form BUNDLE, descriptor version 0 and empty (the descriptor
 *     would name the source language and toolchain, for diagnostics only),
 *     every code role `lib:<os>-<cpu>`, and one for this host's platform
 *     (ERR_UNSUPPORTED naming the platform otherwise). Then it opens that
 *     library (below) and forwards validate to it: the entry and the
 *     signature are the library's to check.
 *   - load: the same checks, then the library's load.
 *   - every later entry: forwarded to the library's table, with the
 *     library's handle wrapped in one of this runtime's.
 *
 * Opening a library (once per sha256 per runtime, under a mutex): read the
 * code object `<code_root>/<hex sha256>` whole, hash the bytes read, and
 * refuse with ERR_CODE_DIGEST unless they match, before anything is mapped
 * (a missing or mismatched object is refused each time, never remembered).
 * The verified bytes are copied into an anonymous memory file and dlopened
 * from it (RTLD_NOW | RTLD_LOCAL), so the bytes loaded are the bytes hashed,
 * whatever happens to the file after it was read. The library is never
 * dlclosed, and its memory file is never closed (open_bytes says why). It
 * must export komira_udf_native_init_v1 and must not export
 * komira_udf_runtime_init_v1, so a runtime and a user library are never
 * confused. Its init gets this runtime's host struct; its table must be ABI
 * major 1 and cover every required entry (a table refused for either is
 * never called again, not even its shutdown); its describe must report
 * runtime_id "komira/native", udf_class NATIVE, threading CONTEXT_PER_THREAD
 * or THREAD_SAFE, global_lock 0, no thread_affine and IN_PROCESS, and at
 * load, the spec's shape. A library refused once is refused again with the
 * same status and message (ERR_LOAD naming the capability, or the digest).
 *
 * Handles: a context holds the library contexts it opened, one per library,
 * opened at its first open_instance of that library's UDF with the same
 * slot, and closed with it. Instances, frames and groups carry the library's
 * table beside the library's handle, so a call costs one more indirect call.
 *
 * The SHA-256 here is FIPS 180-4 written out. The tests compute every
 * expected digest with komira_crypto (AWS-LC) and stage files of the
 * lengths where the padding changes (0, 1, 55, 56, 63, 64, 65, 119, 120,
 * 127, 128 bytes): each must be refused for failing dlopen, never for its
 * digest, so a hash that disagrees with AWS-LC at any of those lengths
 * fails test_native_loader.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "komira_udf_runtime.h"

#define NATIVE_ID "komira/native"
#define LIB_SYMBOL "komira_udf_native_init_v1"
#define RUNTIME_SYMBOL "komira_udf_runtime_init_v1"

#if defined(__linux__)
#define OS_NAME "linux"
#elif defined(__APPLE__)
#define OS_NAME "darwin"
#else
#define OS_NAME "unknown"
#endif
#if defined(__x86_64__)
#define CPU_NAME "x86_64"
#elif defined(__aarch64__)
#define CPU_NAME "aarch64"
#else
#define CPU_NAME "unknown"
#endif
#define HOST_ROLE "lib:" OS_NAME "-" CPU_NAME

/* ---- SHA-256 (FIPS 180-4) --------------------------------------------------- */

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const uint8_t* p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
    uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    k = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += k;
}

static void sha256(const uint8_t* data, size_t n, uint8_t out[32]) {
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  size_t full = n / 64 * 64;
  for (size_t at = 0; at < full; at += 64) sha256_block(h, data + at);
  uint8_t tail[128] = {0};
  size_t rest = n - full;
  memcpy(tail, data + full, rest);
  tail[rest] = 0x80;
  size_t len = rest < 56 ? 64 : 128;
  uint64_t bits = (uint64_t)n * 8;
  for (int i = 0; i < 8; i++) tail[len - 1 - i] = (uint8_t)(bits >> (8 * i));
  sha256_block(h, tail);
  if (len == 128) sha256_block(h, tail + 64);
  for (int i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(h[i] >> 24);
    out[4 * i + 1] = (uint8_t)(h[i] >> 16);
    out[4 * i + 2] = (uint8_t)(h[i] >> 8);
    out[4 * i + 3] = (uint8_t)h[i];
  }
}

/* ---- handles ---------------------------------------------------------------- */

struct lib { /* one library, by sha256; never dlclosed, never freed before shutdown */
  uint8_t sha[32];
  const komira_udf_runtime* t; /* NULL when refused */
  komira_udf_rt* rt;
  int32_t refusal; /* KOMIRA_UDF_OK, or the status every use returns */
  char why[256];
  struct lib* next;
};

struct komira_udf_rt {
  const komira_udf_host* host;
  pthread_mutex_t mu;
  struct lib* libs;
};

struct komira_udf_udf {
  struct lib* lib;
  komira_udf_udf* inner;
};

struct ctx_lib {
  struct lib* lib;
  komira_udf_context* inner;
};

struct komira_udf_context {
  komira_udf_rt* rt;
  uint32_t slot;
  size_t n, cap;
  struct ctx_lib* libs;
};

struct komira_udf_instance {
  const komira_udf_runtime* t;
  komira_udf_instance* inner;
};

struct komira_udf_frame {
  const komira_udf_runtime* t;
  komira_udf_frame* inner;
};

struct komira_udf_groups {
  const komira_udf_runtime* t;
  komira_udf_groups* inner;
};

/* ---- errors ----------------------------------------------------------------- */

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  e->message = NULL;
  e->release = NULL;
}

static int32_t fail(komira_udf_error* e, int32_t code, const char* msg) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  size_t n = strlen(msg) + 1;
  char* m = malloc(n);
  if (m != NULL) memcpy(m, msg, n);
  e->code = code;
  e->message = m;
  e->user_trace = NULL;
  e->row = -1;
  e->group = -1;
  e->release = m != NULL ? free_error : NULL;
  return code;
}

/* ---- opening a library ------------------------------------------------------ */

static int32_t refuse(struct lib* l, int32_t code, const char* why) {
  l->refusal = code;
  snprintf(l->why, sizeof(l->why), "%s", why);
  return code;
}

/* The bytes of `path`, whole, into a malloc block (*n bytes); NULL on failure. */
static uint8_t* read_all(const char* path, size_t* n) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return NULL;
  size_t cap = 1 << 20, len = 0;
  uint8_t* buf = malloc(cap);
  while (buf != NULL) {
    if (len == cap) {
      uint8_t* grown = realloc(buf, cap * 2);
      if (grown == NULL) {
        free(buf);
        buf = NULL;
        break;
      }
      buf = grown;
      cap *= 2;
    }
    ssize_t got = read(fd, buf + len, cap - len);
    if (got < 0) {
      free(buf);
      buf = NULL;
    } else if (got == 0) {
      break;
    } else {
      len += (size_t)got;
    }
  }
  close(fd);
  *n = len;
  return buf;
}

/* dlopen `bytes` through an anonymous memory file: what is mapped is what
 * was hashed. NULL on failure. The file stays open for the life of the
 * process, as the library stays loaded: the dynamic loader knows a loaded
 * object by the name it was opened with, `/proc/self/fd/<n>`, so a closed
 * descriptor's number, reused for the next library, would name the library
 * already loaded and dlopen would return that one instead. */
static void* open_bytes(const uint8_t* bytes, size_t n) {
#if defined(__linux__)
  int fd = memfd_create("komira-udf-native-library", MFD_CLOEXEC);
  if (fd < 0) return NULL;
  size_t at = 0;
  while (at < n) {
    ssize_t put = write(fd, bytes + at, n - at);
    if (put <= 0) {
      close(fd);
      return NULL;
    }
    at += (size_t)put;
  }
  char path[64];
  snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
  void* h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (h == NULL) close(fd);
  return h;
#else
  (void)bytes;
  (void)n;
  return NULL;
#endif
}

/* The library's own describe, held to what this runtime can bind. */
static int32_t check_library(struct lib* l) {
  komira_udf_capabilities c;
  memset(&c, 0, sizeof(c));
  c.struct_size = sizeof(c);
  if (l->t->describe(l->rt, &c) != KOMIRA_UDF_OK)
    return refuse(l, KOMIRA_UDF_ERR_LOAD, "the library's describe failed");
  char why[200];
  why[0] = 0;
  if (c.runtime_id == NULL || strcmp(c.runtime_id, NATIVE_ID) != 0)
    snprintf(why, sizeof(why), "the library reports runtime_id '%s', not '" NATIVE_ID "'",
             c.runtime_id ? c.runtime_id : "");
  else if (c.udf_class != KOMIRA_UDF_CLASS_NATIVE)
    snprintf(why, sizeof(why), "the library reports udf_class %u, not NATIVE", c.udf_class);
  else if (c.threading != KOMIRA_UDF_CONTEXT_PER_THREAD && c.threading != KOMIRA_UDF_THREAD_SAFE)
    snprintf(why, sizeof(why), "the library reports threading %u, not CONTEXT_PER_THREAD or THREAD_SAFE",
             c.threading);
  else if (c.global_lock != 0)
    snprintf(why, sizeof(why), "the library reports global_lock %u", c.global_lock);
  else if (c.thread_affine != 0)
    snprintf(why, sizeof(why), "the library reports thread_affine %u", c.thread_affine);
  else if ((c.transports & KOMIRA_UDF_TRANSPORT_IN_PROCESS) == 0)
    snprintf(why, sizeof(why), "the library's transports lack IN_PROCESS");
  if (why[0] != 0) return refuse(l, KOMIRA_UDF_ERR_LOAD, why);
  return KOMIRA_UDF_OK;
}

/* The library of `sha` under `root` (rt->mu held). A verified library is
 * kept, by sha256, with its init's table or the refusal of its describe; a
 * code object that is missing or whose bytes do not match is refused into
 * `why` and not kept, so a later spec can name a good copy. */
static int32_t open_library(komira_udf_rt* rt, const char* root, const uint8_t sha[32], struct lib** out,
                            char* why, size_t why_len) {
  *out = NULL;
  for (struct lib* l = rt->libs; l != NULL; l = l->next)
    if (memcmp(l->sha, sha, 32) == 0) {
      *out = l;
      return KOMIRA_UDF_OK;
    }
  char path[4096];
  int at = snprintf(path, sizeof(path), "%s/", root);
  for (int i = 0; i < 32 && at > 0 && (size_t)at + 2 < sizeof(path); i++)
    at += snprintf(path + at, sizeof(path) - (size_t)at, "%02x", sha[i]);
  size_t n = 0;
  uint8_t* bytes = read_all(path, &n);
  if (bytes == NULL) {
    snprintf(why, why_len, "the code object is missing or unreadable: %s", path);
    return KOMIRA_UDF_ERR_LOAD;
  }
  uint8_t got[32];
  sha256(bytes, n, got);
  if (memcmp(got, sha, 32) != 0) {
    free(bytes);
    snprintf(why, why_len, "the library's bytes do not match its sha256; it was not loaded");
    return KOMIRA_UDF_ERR_CODE_DIGEST;
  }
  struct lib* l = calloc(1, sizeof(*l));
  if (l == NULL) {
    free(bytes);
    snprintf(why, why_len, "load: out of memory");
    return KOMIRA_UDF_ERR_OUT_OF_MEMORY;
  }
  memcpy(l->sha, sha, 32);
  l->next = rt->libs;
  rt->libs = l;
  *out = l;
  void* h = open_bytes(bytes, n);
  free(bytes);
  if (h == NULL) {
    refuse(l, KOMIRA_UDF_ERR_LOAD, "dlopen of the verified library failed");
    return KOMIRA_UDF_OK;
  }
  typedef const komira_udf_runtime* (*init_fn)(const komira_udf_host*, komira_udf_rt**, komira_udf_error*);
  init_fn init = (init_fn)dlsym(h, LIB_SYMBOL);
  if (dlsym(h, RUNTIME_SYMBOL) != NULL) {
    refuse(l, KOMIRA_UDF_ERR_LOAD, "the library exports " RUNTIME_SYMBOL ": it is a runtime, not a native UDF library");
    return KOMIRA_UDF_OK;
  }
  if (init == NULL) {
    refuse(l, KOMIRA_UDF_ERR_LOAD, "the library does not export " LIB_SYMBOL);
    return KOMIRA_UDF_OK;
  }
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  l->t = init(rt->host, &l->rt, &e);
  if (l->t == NULL) {
    char msg[256];
    snprintf(msg, sizeof(msg), "the library's init failed: %s", e.message ? e.message : "no message");
    if (e.release != NULL) e.release(&e);
    refuse(l, KOMIRA_UDF_ERR_LOAD, msg);
    return KOMIRA_UDF_OK;
  }
  const char* bad_table = NULL;
  if (l->t->abi_major != KOMIRA_UDF_ABI_MAJOR)
    bad_table = "the library's table is not ABI major 1";
  else if (l->t->struct_size < offsetof(komira_udf_runtime, memory_report))
    bad_table = "the library's table struct_size ends before a required entry";
  if (bad_table != NULL) {
    /* No entry of this table is called, shutdown included: a table of
     * another major has another layout, and a short one has no shutdown
     * entry. The library's handle is left as it is (the library stays
     * mapped for good anyway). */
    refuse(l, KOMIRA_UDF_ERR_ABI, bad_table);
    l->t = NULL;
    return KOMIRA_UDF_OK;
  }
  if (check_library(l) != KOMIRA_UDF_OK) {
    l->t->shutdown(l->rt);
    l->t = NULL;
  }
  return KOMIRA_UDF_OK;
}

/* ---- validate / load -------------------------------------------------------- */

static int role_ok(const char* r) {
  if (r == NULL || strncmp(r, "lib:", 4) != 0) return 0;
  const char* dash = strchr(r + 4, '-');
  return dash != NULL && dash > r + 4 && dash[1] != 0;
}

/* The checks this runtime owns, then the library of this host's platform:
 * *out is it, or NULL with the status returned. */
static int32_t resolve(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e, struct lib** out) {
  *out = NULL;
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return fail(e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's");
  if (s->form != KOMIRA_UDF_FORM_BUNDLE)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "a native UDF's code form is BUNDLE");
  if (s->descriptor_version > 0)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here");
  if (s->descriptor_len != 0)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical");
  if (s->n_code > 0 && (s->code_roles == NULL || s->code_sha256 == NULL || s->code_root == NULL))
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "the code list has no roles, digests or root");
  size_t pick = s->n_code;
  for (size_t i = 0; i < s->n_code; i++) {
    if (!role_ok(s->code_roles[i]))
      return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "a code role is not lib:<os>-<cpu>");
    if (strcmp(s->code_roles[i], HOST_ROLE) == 0 && pick == s->n_code) pick = i;
  }
  if (pick == s->n_code)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "no library for this host's platform, " HOST_ROLE);
  struct lib* l = NULL;
  char why[4200];
  pthread_mutex_lock(&rt->mu);
  int32_t rc = open_library(rt, s->code_root, s->code_sha256[pick], &l, why, sizeof(why));
  pthread_mutex_unlock(&rt->mu);
  if (rc != KOMIRA_UDF_OK) return fail(e, rc, why);
  if (l->refusal != KOMIRA_UDF_OK) return fail(e, l->refusal, l->why);
  *out = l;
  return KOMIRA_UDF_OK;
}

static int32_t native_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  (void)rt;
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  c->runtime_id = NATIVE_ID;
  c->runtime_abi = "abi1";
  c->max_descriptor_version = 0;
  c->shapes = KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN |
              KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED |
              KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_AGG_MERGEABLE | KOMIRA_UDF_SHAPE_STEP;
  c->threading = KOMIRA_UDF_CONTEXT_PER_THREAD;
  c->thread_affine = 0;
  c->transports = KOMIRA_UDF_TRANSPORT_IN_PROCESS;
  c->hosting = KOMIRA_UDF_HOSTING_NONE;
  c->devices = KOMIRA_UDF_DEVICE_CPU;
  c->features = 0;
  c->udf_class = KOMIRA_UDF_CLASS_NATIVE;
  c->global_lock = 0;
  return KOMIRA_UDF_OK;
}

static int32_t native_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  struct lib* l;
  int32_t rc = resolve(rt, s, e, &l);
  if (rc != KOMIRA_UDF_OK) return rc;
  return l->t->validate(l->rt, s, e);
}

static int32_t native_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* e) {
  struct lib* l;
  int32_t rc = resolve(rt, s, e, &l);
  if (rc != KOMIRA_UDF_OK) return rc;
  komira_udf_capabilities c;
  memset(&c, 0, sizeof(c));
  c.struct_size = sizeof(c);
  if (l->t->describe(l->rt, &c) != KOMIRA_UDF_OK || ((uint32_t)s->shape & c.shapes) == 0)
    return fail(e, KOMIRA_UDF_ERR_LOAD, "the library's shapes lack the spec's shape");
  komira_udf_udf* u = calloc(1, sizeof(*u));
  if (u == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory");
  rc = l->t->load(l->rt, s, &u->inner, e);
  if (rc != KOMIRA_UDF_OK) {
    free(u);
    return rc;
  }
  u->lib = l;
  *out = u;
  return KOMIRA_UDF_OK;
}

static void native_unload(komira_udf_udf* u) {
  u->lib->t->unload(u->inner);
  free(u);
}

/* ---- contexts and instances ------------------------------------------------- */

static int32_t native_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* e) {
  komira_udf_context* c = calloc(1, sizeof(*c));
  if (c == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory");
  c->rt = rt;
  c->slot = slot;
  *out = c;
  return KOMIRA_UDF_OK;
}

static void native_close_context(komira_udf_context* c) {
  for (size_t i = 0; i < c->n; i++) c->libs[i].lib->t->close_context(c->libs[i].inner);
  free(c->libs);
  free(c);
}

/* The library context of `l` inside `c`, opened at first use with c's slot. */
static int32_t lib_context(komira_udf_context* c, struct lib* l, komira_udf_context** out, komira_udf_error* e) {
  for (size_t i = 0; i < c->n; i++)
    if (c->libs[i].lib == l) {
      *out = c->libs[i].inner;
      return KOMIRA_UDF_OK;
    }
  if (c->n == c->cap) {
    size_t cap = c->cap ? c->cap * 2 : 4;
    struct ctx_lib* grown = realloc(c->libs, cap * sizeof(*grown));
    if (grown == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory");
    c->libs = grown;
    c->cap = cap;
  }
  komira_udf_context* inner = NULL;
  int32_t rc = l->t->open_context(l->rt, c->slot, &inner, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  c->libs[c->n].lib = l;
  c->libs[c->n].inner = inner;
  c->n++;
  *out = inner;
  return KOMIRA_UDF_OK;
}

static int32_t native_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                    komira_udf_error* e) {
  komira_udf_context* lc = NULL;
  int32_t rc = lib_context(c, u->lib, &lc, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  komira_udf_instance* i = calloc(1, sizeof(*i));
  if (i == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory");
  rc = u->lib->t->open_instance(lc, u->inner, &i->inner, e);
  if (rc != KOMIRA_UDF_OK) {
    free(i);
    return rc;
  }
  i->t = u->lib->t;
  *out = i;
  return KOMIRA_UDF_OK;
}

static void native_close_instance(komira_udf_instance* i) {
  i->t->close_instance(i->inner);
  free(i);
}

/* ---- calls: forwarded --------------------------------------------------------- */

static int32_t native_call_batch(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArray* args,
                                 struct ArrowDeviceArray* out, komira_udf_error* e) {
  return i->t->call_batch(i->inner, call, args, out, e);
}

static int32_t native_frame_open(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArrayStream* in,
                                 komira_udf_frame** out, komira_udf_error* e) {
  komira_udf_frame* f = calloc(1, sizeof(*f));
  if (f == NULL) {
    /* `in` is moved in whatever the status: release it here. */
    if (in->release != NULL) in->release(in);
    return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "frame_open: out of memory");
  }
  int32_t rc = i->t->frame_open(i->inner, call, in, &f->inner, e);
  if (rc != KOMIRA_UDF_OK) {
    free(f);
    return rc;
  }
  f->t = i->t;
  *out = f;
  return KOMIRA_UDF_OK;
}

static int32_t native_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                                 komira_udf_error* e) {
  return f->t->frame_next(f->inner, call, out, e);
}

static void native_frame_close(komira_udf_frame* f) {
  f->t->frame_close(f->inner);
  free(f);
}

static int32_t native_agg_open(komira_udf_instance* i, komira_udf_groups** out, komira_udf_error* e) {
  komira_udf_groups* g = calloc(1, sizeof(*g));
  if (g == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg_open: out of memory");
  int32_t rc = i->t->agg_open(i->inner, &g->inner, e);
  if (rc != KOMIRA_UDF_OK) {
    free(g);
    return rc;
  }
  g->t = i->t;
  *out = g;
  return KOMIRA_UDF_OK;
}

static int32_t native_agg_update(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* args,
                                 struct ArrowDeviceArray* gids, uint32_t n, komira_udf_error* e) {
  return g->t->agg_update(g->inner, c, args, gids, n, e);
}

static int32_t native_agg_merge(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* states,
                                struct ArrowDeviceArray* gids, uint32_t n, komira_udf_error* e) {
  return g->t->agg_merge(g->inner, c, states, gids, n, e);
}

static int32_t native_agg_state(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return g->t->agg_state(g->inner, n, out, e);
}

static int32_t native_agg_finish(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return g->t->agg_finish(g->inner, n, out, e);
}

static void native_agg_close(komira_udf_groups* g) {
  g->t->agg_close(g->inner);
  free(g);
}

/* Every library's shutdown, then this runtime's; the libraries stay mapped. */
static void native_shutdown(komira_udf_rt* rt) {
  struct lib* l = rt->libs;
  while (l != NULL) {
    struct lib* next = l->next;
    if (l->t != NULL) l->t->shutdown(l->rt);
    free(l);
    l = next;
  }
  pthread_mutex_destroy(&rt->mu);
  free(rt);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    native_describe,
    native_validate,
    native_load,
    native_unload,
    native_open_context,
    native_close_context,
    native_open_instance,
    native_close_instance,
    native_call_batch,
    native_frame_open,
    native_frame_next,
    native_frame_close,
    native_agg_open,
    native_agg_update,
    native_agg_merge,
    native_agg_state,
    native_agg_finish,
    native_agg_close,
    native_shutdown,
    NULL, /* memory_report: the MEMORY_REPORT feature is not reported */
};

const komira_udf_runtime* komira_udf_native_rt_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                       komira_udf_error* e) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host) || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    fail(e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1");
    return NULL;
  }
  komira_udf_rt* r = calloc(1, sizeof(*r));
  if (r == NULL) {
    fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory");
    return NULL;
  }
  pthread_mutex_init(&r->mu, NULL);
  r->host = host;
  *rt = r;
  return &TABLE;
}
