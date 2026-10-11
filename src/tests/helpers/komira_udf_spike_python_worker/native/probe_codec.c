/*
 * The engine side's Arrow IPC codec (ipc_codec.c), case by case. Test-only
 * spike code (tests/test_worker_boundary.mojo, group "codec").
 *
 *   - pyw_ipc_decode_column on a good reply and on one malformed copy per
 *     check (section 4.4: the host validates every imported array; section
 *     5.2: it decodes its own copy), including each 8-byte number and each
 *     offset of the flatbuffer with a high byte set (a reader that reads a
 *     field short or long takes them);
 *   - pyw_ipc_decode_column on batches pyarrow wrote (the committed
 *     tests/fixtures/pyarrow_batches.txt, which :test_fixtures regenerates):
 *     another flatbuffer layout, every value and null;
 *   - the writer's bytes, schema and batch, against tests/ipc_golden.txt,
 *     whose messages tests/test_kudf_ipc.py reads with pyarrow; widths and
 *     refused formats;
 *   - pyw_ipc_batch_write re-basing a sliced column at every bit shift, and
 *     reading no byte past a column's buffers; the control-body reader past
 *     its end.
 * Each case is one member of the JSON object (probe_json.h).
 *
 * FFI-BOUNDARY. Every buffer and array here is this file's: decoded arrays
 * are released before the case ends, files read are closed, mapped pages
 * unmapped.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "probe_json.h"
#include "pyw.h"

/* ---- codec --------------------------------------------------------------- */

/* A one-column int64 batch of `n` rows over `values` (from `off`), with
 * `valid` (or NULL) and `nulls`, written by the engine's writer into a
 * malloc block; its size in *len. */
static uint8_t* write_column(const int64_t* values, const uint8_t* valid, int64_t off, int64_t n, int64_t nulls,
                             size_t* len) {
  const void* bufs[2] = {valid, values};
  struct ArrowArray a = {n, nulls, off, 2, 0, bufs, NULL, NULL, NULL, NULL};
  const struct ArrowArray* cols[1] = {&a};
  int w[1] = {8};
  size_t sz = pyw_ipc_batch_size(n, cols, w, 1);
  uint8_t* tmp = aligned_alloc(PYW_ALIGN, (sz + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1));
  if (tmp == NULL) return NULL;
  pyw_ipc_batch_write(tmp, n, cols, w, 1);
  uint8_t* m = malloc(sz);
  if (m != NULL) memcpy(m, tmp, sz);
  free(tmp);
  *len = sz;
  return m;
}

/* Decodes a copy of the first `len` bytes of `msg`: NULL and `out` filled
 * (its release frees the copy), or the reason (the copy freed). */
static const char* decode_copy(const uint8_t* msg, size_t len, struct ArrowArray* out) {
  uint8_t* m = malloc(len ? len : 1);
  if (m == NULL) return "out of memory";
  memcpy(m, msg, len);
  const char* why = pyw_ipc_decode_column(m, len, 8, out);
  if (why != NULL) free(m);
  return why;
}

/* Decodes a copy of `len` bytes placed so that the byte after them is on an
 * unreadable page: a read one byte past the message kills the process. The
 * reason, or "decoded" (the array is not released: its buffers point into
 * the mapping, unmapped here). */
static const char* decode_guarded(const uint8_t* msg, size_t len) {
  long page = sysconf(_SC_PAGESIZE);
  size_t span = (len + (size_t)page - 1) / (size_t)page * (size_t)page;
  uint8_t* area = mmap(NULL, span + (size_t)page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (area == MAP_FAILED) return "fixture: mmap";
  mprotect(area + span, (size_t)page, PROT_NONE);
  /* the end at the guard; 8-aligned start (the body's buffers keep their
   * alignment when len is a multiple of 8) */
  uint8_t* m = area + span - len;
  memcpy(m, msg, len);
  struct ArrowArray out;
  const char* why = pyw_ipc_decode_column(m, len, 8, &out);
  if (why == NULL) why = "decoded";
  munmap(area, span + (size_t)page);
  return why;
}

/* Replaces the one 16-byte {a, b} pair of int64s in the metadata by
 * {a2, b2}; 0 when the pair is not there exactly once. */
static int patch_pair(uint8_t* msg, int64_t a, int64_t b, int64_t a2, int64_t b2) {
  int32_t meta;
  memcpy(&meta, msg + 4, 4);
  int64_t want[2] = {a, b}, put[2] = {a2, b2};
  int found = -1, count = 0;
  for (int i = 8; i + 16 <= 8 + meta; i += 8)
    if (memcmp(msg + i, want, 16) == 0) {
      found = i;
      count++;
    }
  if (count != 1) return 0;
  memcpy(msg + found, put, 16);
  return 1;
}

/* Flatbuffer positions in a message (from its first byte; the flatbuffer
 * starts at 8): the root table, a table's vtable, and the vtable entry and
 * position of a table's field `id` (0 when absent). */
static size_t fb_root(const uint8_t* m) {
  uint32_t r;
  memcpy(&r, m + 8, 4);
  return 8 + r;
}
static size_t fb_vtable(const uint8_t* m, size_t t) {
  int32_t so;
  memcpy(&so, m + t, 4);
  return (size_t)((int64_t)t - so);
}
static size_t fb_entry(const uint8_t* m, size_t t, int id) { return fb_vtable(m, t) + 4 + 2 * (size_t)id; }
static size_t fb_pos(const uint8_t* m, size_t t, int id) {
  uint16_t off;
  memcpy(&off, m + fb_entry(m, t, id), 2);
  return off ? t + off : 0;
}
/* The RecordBatch table the Message's header field points to. */
static size_t fb_batch(const uint8_t* m) {
  size_t f = fb_pos(m, fb_root(m), 2);
  uint32_t u;
  memcpy(&u, m + f, 4);
  return f + u;
}

/* A copy of `good` (len bytes, metadata `meta`) with 64 more bytes of
 * metadata, holding a new vtable for the RecordBatch table: its own fields,
 * and field 3 (compression) present. The body moves with the metadata, and
 * its buffer offsets are relative to it, so only the vtable differs. */
static uint8_t* with_compression(const uint8_t* good, size_t len, int32_t meta, size_t* len2) {
  uint8_t* m = calloc(1, len + 64);
  if (m == NULL) return NULL;
  memcpy(m, good, 8 + (size_t)meta);
  memcpy(m + 8 + meta + 64, good + 8 + meta, len - 8 - (size_t)meta);
  int32_t meta2 = meta + 64;
  memcpy(m + 4, &meta2, 4);
  size_t rb = fb_batch(m);
  size_t old = fb_vtable(m, rb);
  size_t nv = 8 + (size_t)meta;
  uint16_t vt[6];
  memcpy(vt, m + old, 10); /* vsize, tsize, fields 0 .. 2 */
  vt[0] = 12;
  vt[5] = vt[2]; /* field 3 at field 0's place: present */
  memcpy(m + nv, vt, 12);
  int32_t so = (int32_t)((int64_t)rb - (int64_t)nv);
  memcpy(m + rb, &so, 4);
  *len2 = len + 64;
  return m;
}

/* One malformed copy: the reason decode gave, or "decoded" (released). */
static void refusal(struct pj* j, const char* name, const uint8_t* good, size_t len, size_t use_len,
                    const int64_t* pat) {
  uint8_t* m = malloc(len);
  if (m == NULL) return;
  memcpy(m, good, len);
  int ok = 1;
  if (pat != NULL) ok = patch_pair(m, pat[0], pat[1], pat[2], pat[3]);
  const char* why = ok ? decode_guarded(m, use_len) : "fixture: the pair to patch is not there exactly once";
  pj_case(j, name, ok ? 1 : -1, why, 0);
  free(m);
}

/* A copy of `good` with `n` bytes at `at` replaced by `v` (little endian),
 * decoded: the reason, or "decoded". */
static void refusal_set(struct pj* j, const char* name, const uint8_t* good, size_t len, size_t at, int n,
                        uint64_t v) {
  uint8_t* m = malloc(len);
  if (m == NULL) return;
  memcpy(m, good, len);
  memcpy(m + at, &v, (size_t)n);
  pj_case(j, name, 1, decode_guarded(m, len), 0);
  free(m);
}

static uint64_t get_u(const uint8_t* m, size_t at, int n) {
  uint64_t v = 0;
  memcpy(&v, m + at, (size_t)n);
  return v;
}

/* Each number and offset the decoder reads, with a byte above its value's
 * set: a read one byte short of the field takes the old value and decodes. */
static void high_byte_cases(struct pj* j, const uint8_t* good, size_t len) {
  size_t mt = fb_root(good);
  size_t rb = fb_batch(good);
  size_t bl = fb_pos(good, mt, 3);
  size_t ln = fb_pos(good, rb, 0);
  size_t nv = fb_pos(good, rb, 1), bv = fb_pos(good, rb, 2);
  size_t nodes = nv + (size_t)get_u(good, nv, 4) + 4;
  size_t bufs = bv + (size_t)get_u(good, bv, 4) + 4;
  const uint64_t H8 = 1ull << 56;
  refusal_set(j, "body_len_high", good, len, bl, 8, get_u(good, bl, 8) | H8);
  refusal_set(j, "batch_length_high", good, len, ln, 8, get_u(good, ln, 8) | H8);
  refusal_set(j, "node_length_high", good, len, nodes, 8, get_u(good, nodes, 8) | H8);
  refusal_set(j, "nulls_high", good, len, nodes + 8, 8, get_u(good, nodes + 8, 8) | H8);
  const char* bn[4] = {"validity_offset_high", "validity_length_high", "values_offset_high", "values_length_high"};
  for (int k = 0; k < 4; k++) refusal_set(j, bn[k], good, len, bufs + 8 * (size_t)k, 8, get_u(good, bufs + 8 * (size_t)k, 8) | H8);
  /* 4-byte offsets with bit 24 added; the vtable's 2-byte numbers with
   * bit 8 added. */
  const uint64_t H4 = 1ull << 24;
  refusal_set(j, "root_high", good, len, 8, 4, get_u(good, 8, 4) + H4);
  size_t hp = fb_pos(good, mt, 2);
  refusal_set(j, "header_offset_high", good, len, hp, 4, get_u(good, hp, 4) + H4);
  refusal_set(j, "nodes_offset_high", good, len, nv, 4, get_u(good, nv, 4) + H4);
  refusal_set(j, "buffers_offset_high", good, len, bv, 4, get_u(good, bv, 4) + H4);
  refusal_set(j, "nodes_count_high", good, len, nodes - 4, 4, get_u(good, nodes - 4, 4) + H4);
  refusal_set(j, "batch_soffset_high", good, len, rb, 4, get_u(good, rb, 4) + H4);
  size_t vt = fb_vtable(good, rb);
  refusal_set(j, "field_offset_high", good, len, fb_entry(good, rb, 0), 2, get_u(good, fb_entry(good, rb, 0), 2) + 256);
  refusal_set(j, "field_past_table", good, len, fb_entry(good, rb, 1), 2, get_u(good, vt + 2, 2));
  /* Accepted: a table size with its high byte set (every field is still
   * inside it), and the version as a 2-byte number. */
  refusal_set(j, "table_size_high", good, len, vt + 2, 2, 0x0104); /* 260: its low byte, 4, holds no field */
  size_t vp = fb_pos(good, mt, 0);
  refusal_set(j, "version_high_byte", good, len, vp, 2, 0x0104);
  /* The message frame's edges: a prefix alone, metadata length 0, not a
   * multiple of 8, or one past what the payload holds. */
  int32_t meta;
  memcpy(&meta, good + 4, 4);
  refusal(j, "prefix_only", good, len, 8, NULL);
  refusal_set(j, "meta_zero", good, len, 4, 4, 0);
  refusal_set(j, "meta_unaligned", good, len, 4, 4, (uint64_t)(uint32_t)(meta - 4));
  refusal(j, "meta_exact", good, len, 8 + (size_t)meta + (len - 8 - (size_t)meta), NULL);
}

/* ---- the writer's bytes against tests/ipc_golden.txt --------------------- */

struct golden {
  char name[48];
  char* hex;
};

static int load_golden(const char* path, struct golden* g, int max) {
  FILE* f = fopen(path, "r");
  if (f == NULL) return -1;
  int n = 0;
  char* line = NULL;
  size_t cap = 0;
  while (n < max && getline(&line, &cap, f) > 0) {
    char* sp = strchr(line, ' ');
    if (line[0] == '#' || sp == NULL) continue;
    *sp = 0;
    size_t hl = strcspn(sp + 1, "\r\n");
    snprintf(g[n].name, sizeof(g[n].name), "%s", line);
    g[n].hex = strndup(sp + 1, hl);
    n++;
  }
  free(line);
  fclose(f);
  return n;
}

struct gcheck {
  struct golden g[128];
  int n, checked, wrong;
  struct pj miss; /* name=hex of each mismatch, to read off a failing run */
};

static void golden_one(struct gcheck* c, const char* name, const uint8_t* p, size_t len) {
  char* hex = malloc(2 * len + 1);
  if (hex == NULL) return;
  for (size_t i = 0; i < len; i++) sprintf(hex + 2 * i, "%02x", p[i]);
  hex[2 * len] = 0;
  const char* want = NULL;
  for (int i = 0; i < c->n; i++)
    if (strcmp(c->g[i].name, name) == 0) want = c->g[i].hex;
  c->checked++;
  if (want == NULL || strcmp(want, hex) != 0) {
    c->wrong++;
    pj_add(&c->miss, "%s %s|", name, hex);
  }
  free(hex);
}

/* The physical values and validity the batch fixtures use (the same
 * formulas are in tests/test_kudf_ipc.py). */
static void fill_values(uint8_t* buf, char fmt, int64_t phys) {
  for (int64_t p = 0; p < phys; p++) {
    if (fmt == 'c') ((int8_t*)buf)[p] = (int8_t)(3 * p - 20);
    if (fmt == 's') ((int16_t*)buf)[p] = (int16_t)(301 * p - 1000);
    if (fmt == 'i') ((int32_t*)buf)[p] = (int32_t)(70001 * p - 50);
    if (fmt == 'l') ((int64_t*)buf)[p] = 1000 + 7 * p;
    if (fmt == 'g') ((double*)buf)[p] = (double)p * 0.5 - 1.25;
  }
}

static int valid_at(int64_t p) { return (p * 5) % 7 != 3; }

/* One column of a batch fixture: format, offset, and its validity:
 * 0 none, 1 nulls given, 2 nulls counted (-1), 3 all valid with a bitmap. */
struct colfx {
  char fmt;
  int64_t off;
  int mode;
};

static void golden_batch(struct gcheck* c, const char* name, int64_t n, const struct colfx* fx, int ncols) {
  uint8_t* vals[64] = {0};
  uint8_t* bits[64] = {0};
  struct ArrowArray a[64];
  const void* bufs[64][2];
  const struct ArrowArray* cols[64];
  int w[64];
  for (int k = 0; k < ncols; k++) {
    int64_t phys = fx[k].off + n + 8;
    w[k] = pyw_format_width((char[]){fx[k].fmt, 0});
    vals[k] = calloc((size_t)phys, 8);
    bits[k] = calloc((size_t)(phys + 7) / 8, 1);
    fill_values(vals[k], fx[k].fmt, phys);
    int64_t nulls = 0;
    for (int64_t p = 0; p < phys; p++)
      if (fx[k].mode == 3 || valid_at(p)) bits[k][p >> 3] |= (uint8_t)(1u << (p & 7));
    for (int64_t i = 0; i < n; i++) nulls += !((bits[k][(fx[k].off + i) >> 3] >> ((fx[k].off + i) & 7)) & 1);
    bufs[k][0] = fx[k].mode == 0 ? NULL : bits[k];
    bufs[k][1] = vals[k];
    a[k] = (struct ArrowArray){n, fx[k].mode == 0 || fx[k].mode == 3 ? 0 : fx[k].mode == 2 ? -1 : nulls, fx[k].off,
                               2, 0, bufs[k], NULL, NULL, NULL, NULL};
    cols[k] = &a[k];
  }
  size_t sz = pyw_ipc_batch_size(n, cols, w, ncols);
  uint8_t* out = aligned_alloc(PYW_ALIGN, (sz + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1));
  if (out != NULL) {
    memset(out, 0xEE, sz); /* the writer fills every byte */
    size_t wr = pyw_ipc_batch_write(out, n, cols, w, ncols);
    if (wr != sz) c->wrong++;
    golden_one(c, name, out, sz);
    free(out);
  }
  for (int k = 0; k < ncols; k++) {
    free(vals[k]);
    free(bits[k]);
  }
}

static void golden_cases(struct pj* j) {
  struct gcheck* c = calloc(1, sizeof(*c));
  if (c == NULL) return;
  c->n = load_golden("ipc_golden.txt", c->g, 128);
  pj_open(&c->miss);
  const char* fmts = "cCsSiIlLefgnbuz";
  for (const char* f = fmts; *f; f++)
    for (int nl = 0; nl < 2; nl++) {
      char fmt[2] = {*f, 0}, name[32];
      struct pyw_field fd = {"f", fmt, nl};
      struct pyw_buf b = {0};
      const char* bad = pyw_ipc_schema(&b, &fd, 1);
      snprintf(name, sizeof(name), "S_%c_%d", *f, nl);
      if (bad != NULL) c->wrong++;
      golden_one(c, name, b.p, b.len);
      pyw_buf_free(&b);
    }
  /* Three fields (one without a name), then a second schema after it in
   * the same buffer, as a LOAD body holds them. */
  struct pyw_field three[3] = {{"a", "l", 1}, {"bb", "g", 0}, {NULL, "i", 1}};
  struct pyw_field one[1] = {{"result", "g", 1}};
  struct pyw_buf b = {0};
  pyw_ipc_schema(&b, three, 3);
  golden_one(c, "S_three", b.p, b.len);
  pyw_ipc_schema(&b, one, 1);
  golden_one(c, "S_three_then_result", b.p, b.len);
  pyw_buf_free(&b);
  const int64_t ns[4] = {0, 1, 9, 64};
  const char* modes[4] = {"none", "given", "counted", "allvalid"};
  for (int i = 0; i < 4; i++)
    for (int m = 0; m < 4; m++) {
      char name[48];
      struct colfx fx = {'l', 0, m};
      snprintf(name, sizeof(name), "B1_%lld_%s", (long long)ns[i], modes[m]);
      golden_batch(c, name, ns[i], &fx, 1);
    }
  const struct colfx sliced[1] = {{'l', 13, 2}};
  golden_batch(c, "B1_21_sliced13", 21, sliced, 1);
  const struct colfx mixed[4] = {{'c', 3, 0}, {'s', 5, 1}, {'i', 0, 2}, {'g', 1, 1}};
  golden_batch(c, "B4_13_mixed", 13, mixed, 4);
  /* a first column wider than 64 bytes, then nulls: each buffer's offset
   * follows the padded length of the one before it */
  const struct colfx wide[3] = {{'l', 0, 0}, {'l', 2, 1}, {'c', 0, 2}};
  golden_batch(c, "B3_13_wide", 13, wide, 3);
  /* the most columns the writer takes */
  struct colfx many[64];
  for (int k = 0; k < 64; k++) many[k] = (struct colfx){'c', k % 5, k % 3};
  golden_batch(c, "B64_3_columns", 3, many, 64);
  pj_case(j, "golden", c->n, pj_close(&c->miss), c->wrong * 1000 + c->checked);
  free(c->miss.p);
  for (int i = 0; i < c->n; i++) free(c->g[i].hex);
  free(c);
}

/* Widths, and the formats the writer refuses. */
static void format_cases(struct pj* j) {
  const char* fmts[] = {"c", "C", "s", "S", "e", "i", "I", "f", "l", "L", "g", "n", "b", "u", "z", "", "ll", "+s", NULL};
  const int want[] = {1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0};
  int64_t wrong = 0;
  for (int i = 0; i < 19; i++) wrong += pyw_format_width(fmts[i]) != want[i];
  pj_case(j, "widths", 0, "", wrong);
  const char* refused_fmts[] = {"", "ll", "+s", "tdD", "d:5,2", NULL};
  for (int i = 0; i < 6; i++) {
    struct pyw_field fd = {"x", refused_fmts[i], 1};
    struct pyw_buf b = {0};
    const char* bad = pyw_ipc_schema(&b, &fd, 1);
    char name[32];
    snprintf(name, sizeof(name), "schema_refused_%d", i);
    pj_case(j, name, bad == NULL ? 0 : 1, bad ? bad : "written", (int64_t)b.len);
    pyw_buf_free(&b);
  }
  /* A column count over the writer's 64 writes nothing. */
  struct ArrowArray a = {1, 0, 0, 2, 0, (const void*[]){NULL, (int64_t[]){1}}, NULL, NULL, NULL, NULL};
  const struct ArrowArray* cols[65];
  int w[65];
  for (int i = 0; i < 65; i++) cols[i] = &a, w[i] = 8;
  uint8_t sink[64];
  pj_case(j, "over_64_columns", 0, "", (int64_t)pyw_ipc_batch_size(1, cols, w, 65) * 10 +
                                          (int64_t)pyw_ipc_batch_write(sink, 1, cols, w, 65));
  uint8_t* big = aligned_alloc(PYW_ALIGN, 16384);
  size_t s64 = pyw_ipc_batch_size(1, cols, w, 64);
  pj_case(j, "64_columns", 0, "", (s64 > 0) + (big != NULL && s64 <= 16384 && pyw_ipc_batch_write(big, 1, cols, w, 64) == s64) * 10);
  free(big);
}

/* ---- batches pyarrow wrote ------------------------------------------------- */

static int unhex(const char* h, uint8_t** out, size_t* n) {
  size_t l = strcmp(h, ".") == 0 ? 0 : strlen(h);
  *n = l / 2;
  *out = malloc(*n ? *n : 1);
  if (*out == NULL) return -1;
  for (size_t i = 0; i < *n; i++) {
    unsigned v;
    if (sscanf(h + 2 * i, "%2x", &v) != 1) return -1;
    (*out)[i] = (uint8_t)v;
  }
  return 0;
}

static void pyarrow_cases(struct pj* j) {
  FILE* f = fopen("pyarrow_batches/batches.txt", "r");
  if (f == NULL) {
    pj_case(j, "pyarrow", -1, "pyarrow_batches/batches.txt is missing", 0);
    return;
  }
  char* line = NULL;
  size_t cap = 0;
  int64_t cases = 0, wrong = 0;
  char first_wrong[200] = "";
  while (getline(&line, &cap, f) > 0) {
    char name[64], *mh = NULL, *vh = NULL, *bh = NULL;
    int width;
    long long n, nulls;
    if (sscanf(line, "%63s %d %lld %lld %ms %ms %ms", name, &width, &n, &nulls, &mh, &vh, &bh) != 7) {
      free(mh), free(vh), free(bh);
      continue;
    }
    uint8_t *msg = NULL, *vals = NULL, *bits = NULL;
    size_t ml, vl, bl;
    int bad = unhex(mh, &msg, &ml) || unhex(vh, &vals, &vl) || (strcmp(bh, "-") != 0 && unhex(bh, &bits, &bl));
    cases++;
    struct ArrowArray out;
    const char* why = bad ? "fixture" : pyw_ipc_decode_column(msg, ml, width, &out);
    int miss = why != NULL;
    if (why == NULL) {
      const uint8_t* v = out.buffers[1];
      const uint8_t* b = out.buffers[0];
      miss |= out.length != n || out.null_count != nulls || (nulls > 0) != (b != NULL);
      for (int64_t i = 0; i < n && !miss; i++) {
        int ok = bits == NULL ? 1 : (bits[i >> 3] >> (i & 7)) & 1;
        int got = b == NULL ? 1 : (b[i >> 3] >> (i & 7)) & 1;
        miss |= ok != got || (ok && memcmp(v + i * width, vals + i * width, (size_t)width) != 0);
      }
      out.release(&out); /* frees msg */
    } else {
      free(msg);
    }
    if (!bad && n == 0) {
      /* no body: the message ends where the metadata does; place it at an
       * unreadable page */
      uint8_t *m2 = NULL;
      size_t l2;
      if (unhex(mh, &m2, &l2) == 0) {
        const char* g = decode_guarded(m2, l2);
        miss |= strcmp(g, "decoded") != 0;
      }
      free(m2);
    }
    if (miss && !first_wrong[0]) snprintf(first_wrong, sizeof(first_wrong), "%s: %s", name, why ? why : "values");
    wrong += miss;
    free(vals), free(bits), free(mh), free(vh), free(bh);
  }
  free(line);
  fclose(f);
  pj_case(j, "pyarrow", cases, first_wrong[0] ? first_wrong : "every batch decoded", wrong);
}

/* Cases the sweep found no input for (each named for the decoder check it
 * holds): `good` is the ten-row reply with nulls at rows 1, 4 and 7. */
static void edge_cases(struct pj* j, const uint8_t* good, size_t len, const int64_t* vals) {
  size_t rb = fb_batch(good);
  /* A vector field absent from the RecordBatch: an absent vector has no
   * elements (not one element at position 0). */
  refusal_set(j, "nodes_absent", good, len, fb_entry(good, rb, 1), 2, 0);
  refusal_set(j, "buffers_absent", good, len, fb_entry(good, rb, 2), 2, 0);
  /* Two nodes over the two buffers: one primitive column needs one node
   * and two buffers, both. */
  size_t nv = fb_pos(good, rb, 1);
  size_t nodes = nv + (size_t)get_u(good, nv, 4) + 4;
  refusal_set(j, "two_nodes", good, len, nodes - 4, 4, 2);
  /* A validity bitmap of 1 byte for 9 rows: (9 + 7) / 8 is 2. */
  {
    uint8_t v9[2] = {0xFF & ~(1u << 3), 0x01};
    size_t l9;
    uint8_t* m9 = write_column(vals, v9, 0, 9, 1, &l9);
    if (m9 != NULL) {
      const int64_t short9[4] = {0, 2, 0, 1};
      refusal(j, "validity_short_9_rows", m9, l9, l9, short9);
      free(m9);
    }
  }
  /* The bitmap moved to body offset 160 (inside the body's 192 bytes): the
   * nulls must still be rows 1, 4 and 7. */
  {
    int32_t meta;
    memcpy(&meta, good + 4, 4);
    uint8_t* m = malloc(len);
    if (m != NULL) {
      memcpy(m, good, len);
      uint8_t* body = m + 8 + meta;
      memcpy(body + 160, body, 2);
      memset(body, 0, 2);
      struct ArrowArray out;
      int ok = patch_pair(m, 0, 2, 160, 2);
      const char* why = ok ? decode_copy(m, len, &out) : "fixture: the validity pair is not there once";
      int64_t wrong = 0;
      if (ok && why == NULL) {
        const uint8_t* b = out.buffers[0];
        const int64_t* v = out.buffers[1];
        for (int i = 0; i < 10; i++) {
          int is_valid = b != NULL && ((b[i >> 3] >> (i & 7)) & 1);
          wrong += is_valid != !(i == 1 || i == 4 || i == 7);
          wrong += is_valid && v[i] != vals[i];
        }
        out.release(&out);
        why = "decoded";
      }
      pj_case(j, "validity_at_160", ok ? 0 : -1, why, wrong);
      free(m);
    }
  }
  /* A message of no rows (it ends where its metadata ends) whose root
   * points 2 bytes before that end: reading the table's 4-byte vtable
   * offset there would cross the end (an unreadable page). */
  size_t l0;
  uint8_t* z = write_column(vals, NULL, 0, 0, 0, &l0);
  if (z != NULL) {
    int32_t meta0;
    memcpy(&meta0, z + 4, 4);
    uint32_t root = (uint32_t)meta0 - 2;
    uint8_t* m = malloc(l0);
    if (m != NULL) {
      memcpy(m, z, l0);
      memcpy(m + 8, &root, 4);
      pj_case(j, "root_two_before_end", 1, decode_guarded(m, l0), (int64_t)(l0 - 8 - (size_t)meta0));
      /* The payload cut one byte short of the metadata it declares. */
      memcpy(m, z, l0);
      pj_case(j, "payload_cut_into_meta", 1, decode_guarded(m, l0 - 1), 0);
      free(m);
    }
    free(z);
  }
}

void kpw_codec_cases(struct pj* j) {
  enum { N = 10 };
  int64_t vals[N];
  for (int i = 0; i < N; i++) vals[i] = 100 + i;
  uint8_t valid[2] = {0xFF & ~(1u << 1) & ~(1u << 4) & ~(1u << 7), 0x03}; /* rows 1, 4, 7 null */
  size_t len = 0;
  uint8_t* good = write_column(vals, valid, 0, N, 3, &len);
  if (good == NULL) return;

  /* The good reply: every value, every null, then released. */
  struct ArrowArray out;
  const char* why = decode_copy(good, len, &out);
  int64_t bad = 0;
  if (why == NULL) {
    const int64_t* v = out.buffers[1];
    const uint8_t* b = out.buffers[0];
    bad += out.length != N || out.null_count != 3 || b == NULL;
    for (int i = 0; b != NULL && i < N; i++) {
      int is_valid = (b[i >> 3] >> (i & 7)) & 1;
      bad += is_valid != !(i == 1 || i == 4 || i == 7);
      bad += is_valid && v[i] != 100 + i;
    }
    out.release(&out);
  }
  pj_case(j, "good", why ? 1 : 0, why ? why : "decoded", bad);

  int32_t meta;
  memcpy(&meta, good + 4, 4);
  /* The body: validity at 0 (2 bytes), values at 64 (80 bytes); 192 in all. */
  refusal(j, "prefix_short", good, len, 7, NULL);
  uint8_t* m = malloc(len);
  if (m == NULL) return;
  memcpy(m, good, len);
  m[0] = 0;
  refusal(j, "continuation", m, len, len, NULL);
  memcpy(m, good, len);
  int32_t big = (int32_t)len;
  memcpy(m + 4, &big, 4);
  refusal(j, "meta_past_payload", m, len, len, NULL);
  memcpy(m, good, len);
  uint32_t root = 0x00FFFFFFu;
  memcpy(m + 8, &root, 4);
  refusal(j, "root_offset", m, len, len, NULL);
  free(m);
  refusal(j, "body_truncated", good, len, len - 1, NULL);
  const int64_t values_short[4] = {64, 80, 64, 72};
  refusal(j, "values_short", good, len, len, values_short);
  const int64_t validity_short[4] = {0, 2, 0, 1};
  refusal(j, "validity_short", good, len, len, validity_short);
  const int64_t past_body[4] = {64, 80, 160, 80};
  refusal(j, "buffer_past_body", good, len, len, past_body);
  const int64_t misaligned[4] = {64, 80, 68, 80};
  refusal(j, "misaligned", good, len, len, misaligned);
  const int64_t nulls_over[4] = {N, 3, N, N + 1};
  refusal(j, "nulls_over_length", good, len, len, nulls_over);
  const int64_t node_len[4] = {N, 3, N - 1, 3};
  refusal(j, "node_length", good, len, len, node_len);

  /* The Message table: its version absent or V4, its header type absent or
   * Schema, its header absent; the RecordBatch compressed. */
  m = malloc(len + 64);
  if (m == NULL) return;
  size_t mt = fb_root(good);
  const struct {
    const char* name;
    int id;     /* the Message field changed */
    int absent; /* 1: its vtable entry zeroed; 0: its value set to `v` */
    uint8_t v;
  } msg_cases[5] = {
      {"version_absent", 0, 1, 0},
      {"version_v4", 0, 0, 3},
      {"header_type_absent", 1, 1, 0},
      {"header_type_schema", 1, 0, 1},
      {"header_absent", 2, 1, 0},
  };
  for (int k = 0; k < 5; k++) {
    memcpy(m, good, len);
    if (msg_cases[k].absent) {
      memset(m + fb_entry(m, mt, msg_cases[k].id), 0, 2);
    } else {
      m[fb_pos(m, mt, msg_cases[k].id)] = msg_cases[k].v;
    }
    refusal(j, msg_cases[k].name, m, len, len, NULL);
  }
  free(m);
  size_t lc = 0;
  uint8_t* comp = with_compression(good, len, meta, &lc);
  if (comp != NULL) {
    refusal(j, "compressed", comp, lc, lc, NULL);
    /* The same layout without field 3 still decodes (the case above fails
     * only on field 3). */
    uint16_t vsize = 10;
    memcpy(comp + fb_vtable(comp, fb_batch(comp)), &vsize, 2);
    refusal(j, "uncompressed_moved", comp, lc, lc, NULL);
    free(comp);
  }
  high_byte_cases(j, good, len);
  edge_cases(j, good, len, vals);
  free(good);

  /* A batch of no rows whose metadata ends at its last vector (no padding
   * after it) and whose message ends at an unreadable page: the decoder
   * reads nothing past it. */
  {
    size_t l0;
    uint8_t* z = write_column(vals, NULL, 0, 0, 0, &l0);
    if (z != NULL) {
      size_t rb0 = fb_batch(z);
      size_t bv0 = fb_pos(z, rb0, 2);
      size_t bufs0 = bv0 + (size_t)get_u(z, bv0, 4);
      size_t end0 = bufs0 + 4 + 16 * (size_t)get_u(z, bufs0, 4); /* from the message start */
      int32_t meta0 = (int32_t)(end0 - 8);
      while (meta0 % 8) meta0++;
      memcpy(z + 4, &meta0, 4);
      pj_case(j, "no_rows_tight", meta0, decode_guarded(z, 8 + (size_t)meta0), 0);
      free(z);
    }
  }

  /* Two columns where the reader takes one. */
  {
    const void* bufs[2] = {NULL, vals};
    struct ArrowArray a = {N, 0, 0, 2, 0, bufs, NULL, NULL, NULL, NULL};
    const struct ArrowArray* cols[2] = {&a, &a};
    int w[2] = {8, 8};
    size_t sz = pyw_ipc_batch_size(N, cols, w, 2);
    uint8_t* t = aligned_alloc(PYW_ALIGN, (sz + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1));
    if (t != NULL) {
      pyw_ipc_batch_write(t, N, cols, w, 2);
      refusal(j, "two_columns", t, sz, sz, NULL);
      free(t);
    }
  }

  /* The writer re-basing a slice: every offset 0 .. 17 and lengths across
   * byte edges, a validity pattern with no period of 8, the null count
   * given or left for the writer to count (-1). Mismatching values or bits
   * after a round trip are counted. */
  int64_t src[64];
  uint8_t sv[8];
  for (int i = 0; i < 64; i++) src[i] = 7 * i + 1;
  for (int i = 0; i < 8; i++) sv[i] = (uint8_t)(0xB5 ^ (i * 0x3D));
  int64_t wrong = 0, cases = 0;
  const int64_t lengths[5] = {1, 7, 8, 9, 21};
  for (int64_t off = 0; off < 18; off++)
    for (int li = 0; li < 5; li++)
      for (int given = 0; given < 2; given++) {
        int64_t n = lengths[li], nulls = 0;
        for (int64_t i = 0; i < n; i++) nulls += !((sv[(off + i) >> 3] >> ((off + i) & 7)) & 1);
        size_t l2;
        uint8_t* msg = write_column(src, sv, off, n, given ? nulls : -1, &l2);
        if (msg == NULL) continue;
        cases++;
        const char* w2 = decode_copy(msg, l2, &out);
        free(msg);
        if (w2 != NULL) {
          wrong++;
          continue;
        }
        const int64_t* v = out.buffers[1];
        const uint8_t* b = out.buffers[0];
        int miss = out.null_count != nulls || (nulls > 0) != (b != NULL);
        for (int64_t i = 0; i < n && !miss; i++) {
          int sv_bit = (sv[(off + i) >> 3] >> ((off + i) & 7)) & 1;
          int got = b == NULL ? 1 : (b[i >> 3] >> (i & 7)) & 1;
          miss |= got != sv_bit || (sv_bit && v[i] != src[off + i]);
        }
        if (b != NULL && (n & 7)) miss |= (b[(n - 1) >> 3] >> (n & 7)) != 0; /* spare bits zero */
        wrong += miss;
        out.release(&out);
      }
  pj_case(j, "rebase_shifts", cases == 18 * 5 * 2 ? 0 : -1, "slices written and read back", wrong);

  /* The writer reads no byte past a column's buffers: the bitmap and the
   * values end where an unreadable page starts, at offsets 0 .. 17 and
   * lengths that end on and off a byte edge. A read past either kills the
   * process (SIGSEGV), which fails the test. */
  long page = sysconf(_SC_PAGESIZE);
  uint8_t* area = mmap(NULL, (size_t)page * 4, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  int64_t edge_cases = 0, edge_wrong = 0;
  if (area != MAP_FAILED && mprotect(area + page, (size_t)page, PROT_NONE) == 0 &&
      mprotect(area + 3 * page, (size_t)page, PROT_NONE) == 0) {
    for (int64_t off = 0; off < 18; off++)
      for (int li = 0; li < 5; li++) {
        int64_t n = lengths[li];
        int64_t nbytes = (off + n + 7) / 8;
        uint8_t* bits = area + page - nbytes;
        int64_t* vals = (int64_t*)(area + 3 * page) - (off + n);
        int64_t nulls = 0;
        for (int64_t i = 0; i < nbytes; i++) bits[i] = sv[i % 8];
        for (int64_t i = 0; i < off + n; i++) vals[i] = 3 * i + 5;
        for (int64_t i = 0; i < n; i++) nulls += !((bits[(off + i) >> 3] >> ((off + i) & 7)) & 1);
        size_t l3;
        uint8_t* msg = write_column(vals, bits, off, n, nulls, &l3);
        if (msg == NULL) continue;
        edge_cases++;
        const char* w3 = decode_copy(msg, l3, &out);
        free(msg);
        if (w3 != NULL) {
          edge_wrong++;
          continue;
        }
        const int64_t* v = out.buffers[1];
        const uint8_t* b = out.buffers[0];
        for (int64_t i = 0; i < n; i++) {
          int bit = (bits[(off + i) >> 3] >> ((off + i) & 7)) & 1;
          int got = b == NULL ? 1 : (b[i >> 3] >> (i & 7)) & 1;
          edge_wrong += got != bit || (bit && v[i] != 3 * (off + i) + 5);
        }
        out.release(&out);
      }
  }
  if (area != MAP_FAILED) munmap(area, (size_t)page * 4);
  pj_case(j, "rebase_page_end", edge_cases == 18 * 5 ? 0 : -1, "slices ending at an unreadable page", edge_wrong);

  /* The control-body reader: a string whose length runs past the body, an
   * i64 from 4 bytes, and a NULL string (not an error). */
  uint8_t body[8] = {10, 0, 0, 0, 'a', 'b', 'c', 'd'};
  struct pyw_rd d = {body, sizeof(body), 0, 0};
  char* s = pyw_rd_str(&d);
  pj_case(j, "rd_str_past_end", d.bad ? 1 : 0, s == NULL ? "NULL" : s, d.bad);
  free(s);
  struct pyw_rd d2 = {body, 4, 0, 0};
  (void)pyw_rd_i64(&d2);
  pj_case(j, "rd_i64_short", d2.bad ? 1 : 0, "", d2.bad);
  uint8_t none[4] = {0xFF, 0xFF, 0xFF, 0xFF};
  struct pyw_rd d3 = {none, 4, 0, 0};
  char* s3 = pyw_rd_str(&d3);
  pj_case(j, "rd_str_null", d3.bad ? 1 : 0, s3 == NULL ? "NULL" : s3, d3.bad);
  free(s3);
  /* A short read gives 0: a u32 from 3 bytes, an i64 from 7. */
  uint8_t ones[8];
  memset(ones, 0xFF, sizeof(ones));
  struct pyw_rd d4 = {ones, 3, 0, 0};
  uint32_t u4 = pyw_rd_u32(&d4);
  struct pyw_rd d5 = {ones, 7, 0, 0};
  int64_t i5 = pyw_rd_i64(&d5);
  pj_case(j, "rd_short_zero", d4.bad + d5.bad * 10, "", (int64_t)u4 + i5 * 1000);
  /* Reads that end exactly at an unreadable page: a reader that reads one
   * byte more than its field kills the process. */
  long pg = sysconf(_SC_PAGESIZE);
  uint8_t* edge = mmap(NULL, (size_t)pg * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (edge != MAP_FAILED && mprotect(edge + pg, (size_t)pg, PROT_NONE) == 0) {
    uint8_t* end = edge + pg;
    uint32_t v4 = 0x01020304u;
    int64_t v8 = 0x0102030405060708LL;
    memcpy(end - 4, &v4, 4);
    struct pyw_rd e4 = {end - 4, 4, 0, 0};
    uint32_t g4 = pyw_rd_u32(&e4);
    memcpy(end - 8, &v8, 8);
    struct pyw_rd e8 = {end - 8, 8, 0, 0};
    int64_t g8 = pyw_rd_i64(&e8);
    uint8_t str[7] = {3, 0, 0, 0, 'a', 'b', 'c'};
    memcpy(end - 7, str, 7);
    struct pyw_rd es = {end - 7, 7, 0, 0};
    char* gs = pyw_rd_str(&es);
    int64_t wrong = (g4 != v4) + (g8 != v8) * 10 + (gs == NULL || strcmp(gs, "abc") != 0) * 100 +
                    (e4.bad + e8.bad + es.bad) * 1000;
    free(gs);
    pj_case(j, "rd_at_page_end", 0, "", wrong);
  }
  if (edge != MAP_FAILED) munmap(edge, (size_t)pg * 2);
  golden_cases(j);
  format_cases(j);
  pyarrow_cases(j);
}

