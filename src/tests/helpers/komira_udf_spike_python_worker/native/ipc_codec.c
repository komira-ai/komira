/*
 * The Arrow IPC subset the engine side of the worker transport writes and
 * reads (docs/design/udf_runtime_interface.md section 5.2: "A payload is
 * Arrow IPC encapsulated messages: a record batch or, for LOAD and OPEN, the
 * schemas"). Test-only spike code.
 *
 * Written: a Schema message (fields of the primitive types listed in
 * type_of), and a RecordBatch message of fixed-width primitive columns
 * (values and validity; a sliced column is re-based to offset 0 as it is
 * copied, since IPC has no array offset). Read: a RecordBatch message of one
 * fixed-width column, with every offset and size checked against the
 * message, because its bytes come from a worker (section 4.4, "The host
 * validates every imported array").
 *
 * The flatbuffers are built front to back: a table's vtable is written just
 * before it, every 8-byte field is 8-byte aligned, and every offset points
 * forward and is patched once its target is written. A message is
 * 0xFFFFFFFF, the metadata length, the flatbuffer and zero padding to a
 * 64-byte boundary, then the body, each body buffer starting on a 64-byte
 * boundary, so a reader can use the buffers in place (section 5.2). Little
 * endian hosts only (a static assertion below).
 *
 * FFI-BOUNDARY. Owners: a pyw_buf's bytes are its holder's (pyw_buf_free).
 * pyw_ipc_decode_column takes `msg` (a malloc block) on success: the array
 * it fills points into it, and the array's release frees the block and the
 * buffer list.
 */
#include <stdlib.h>
#include <string.h>

#include "pyw.h"

_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "the IPC writer assumes a little-endian host");

/* ---- the growable buffer and the control-body reader ---------------------- */

static int grow(struct pyw_buf* b, size_t n) {
  if (b->oom) return 0;
  if (b->len + n <= b->cap) return 1;
  size_t c = b->cap ? b->cap : 256;
  while (c < b->len + n) c *= 2;
  uint8_t* p = realloc(b->p, c);
  if (p == NULL) {
    b->oom = 1;
    return 0;
  }
  b->p = p;
  b->cap = c;
  return 1;
}

void pyw_buf_put(struct pyw_buf* b, const void* src, size_t n) {
  if (n == 0 || !grow(b, n)) return;
  memcpy(b->p + b->len, src, n);
  b->len += n;
}

void pyw_buf_zero(struct pyw_buf* b, size_t n) {
  if (n == 0 || !grow(b, n)) return;
  memset(b->p + b->len, 0, n);
  b->len += n;
}

void pyw_buf_align(struct pyw_buf* b, size_t a) {
  size_t r = b->len % a;
  if (r) pyw_buf_zero(b, a - r);
}

void pyw_buf_u32(struct pyw_buf* b, uint32_t v) { pyw_buf_put(b, &v, 4); }
void pyw_buf_i32(struct pyw_buf* b, int32_t v) { pyw_buf_put(b, &v, 4); }
void pyw_buf_u64(struct pyw_buf* b, uint64_t v) { pyw_buf_put(b, &v, 8); }

void pyw_buf_str(struct pyw_buf* b, const char* s) {
  if (s == NULL) {
    pyw_buf_u32(b, 0xFFFFFFFFu);
    return;
  }
  size_t n = strlen(s);
  pyw_buf_u32(b, (uint32_t)n);
  pyw_buf_put(b, s, n);
}

void pyw_buf_free(struct pyw_buf* b) {
  free(b->p);
  b->p = NULL;
  b->len = b->cap = 0;
}

static int rd_need(struct pyw_rd* r, size_t n) {
  if (r->bad || r->at > r->len || r->len - r->at < n) {
    r->bad = 1;
    return 0;
  }
  return 1;
}

uint32_t pyw_rd_u32(struct pyw_rd* r) {
  uint32_t v = 0;
  if (rd_need(r, 4)) memcpy(&v, r->p + r->at, 4);
  r->at += 4;
  return v;
}

int32_t pyw_rd_i32(struct pyw_rd* r) { return (int32_t)pyw_rd_u32(r); }

int64_t pyw_rd_i64(struct pyw_rd* r) {
  int64_t v = 0;
  if (rd_need(r, 8)) memcpy(&v, r->p + r->at, 8);
  r->at += 8;
  return v;
}

char* pyw_rd_str(struct pyw_rd* r) {
  uint32_t n = pyw_rd_u32(r);
  if (r->bad || n == 0xFFFFFFFFu || !rd_need(r, n)) return NULL;
  char* s = malloc((size_t)n + 1);
  if (s == NULL) {
    r->bad = 1;
    return NULL;
  }
  memcpy(s, r->p + r->at, n);
  s[n] = 0;
  r->at += n;
  return s;
}

/* ---- the flatbuffer builder ---------------------------------------------- */

struct fbf {
  int id;
  int size; /* 1, 2, 4 or 8 */
  uint64_t v;
  int is_offset; /* a uoffset patched later (fb_patch); v unused */
  size_t at;     /* filled by fb_table: the field's position */
};

/* Writes a vtable and then its table; returns the table's position. */
static size_t fb_table(struct pyw_buf* b, struct fbf* f, int n) {
  int max_id = -1, has8 = 0;
  for (int i = 0; i < n; i++) {
    if (f[i].id > max_id) max_id = f[i].id;
    if (f[i].size == 8) has8 = 1;
  }
  size_t rel[16] = {0};
  size_t tsize = 4;
  static const int SIZES[4] = {8, 4, 2, 1};
  for (int s = 0; s < 4; s++)
    for (int i = 0; i < n; i++)
      if (f[i].size == SIZES[s]) {
        rel[i] = tsize;
        tsize += (size_t)f[i].size;
      }
  pyw_buf_align(b, 2);
  size_t vt = b->len;
  size_t vsize = 4 + 2 * (size_t)(max_id + 1);
  size_t t = vt + vsize;
  while (has8 ? (t % 8) != 4 : (t % 4) != 0) t++;
  uint16_t head[2] = {(uint16_t)vsize, (uint16_t)tsize};
  pyw_buf_put(b, head, 4);
  for (int id = 0; id <= max_id; id++) {
    uint16_t o = 0;
    for (int i = 0; i < n; i++)
      if (f[i].id == id) o = (uint16_t)rel[i];
    pyw_buf_put(b, &o, 2);
  }
  pyw_buf_zero(b, t - b->len);
  int32_t so = (int32_t)(t - vt);
  pyw_buf_put(b, &so, 4);
  pyw_buf_zero(b, tsize - 4);
  if (b->oom) return t;
  for (int i = 0; i < n; i++) {
    f[i].at = t + rel[i];
    if (!f[i].is_offset) memcpy(b->p + f[i].at, &f[i].v, (size_t)f[i].size);
  }
  return t;
}

/* The uoffset at `at` points to `target` (which comes after it). */
static void fb_patch(struct pyw_buf* b, size_t at, size_t target) {
  if (b->oom) return;
  uint32_t v = (uint32_t)(target - at);
  memcpy(b->p + at, &v, 4);
}

/* A vector of `count` structs of `size` bytes (8-byte aligned elements). */
static size_t fb_vec_structs(struct pyw_buf* b, const void* data, size_t size, size_t count) {
  while ((b->len + 4) % 8 != 0) pyw_buf_zero(b, 1);
  size_t p = b->len;
  pyw_buf_u32(b, (uint32_t)count);
  pyw_buf_put(b, data, size * count);
  return p;
}

/* A vector of `count` uoffsets, each patched later at p + 4 + 4 * i. */
static size_t fb_vec_offsets(struct pyw_buf* b, size_t count) {
  pyw_buf_align(b, 4);
  size_t p = b->len;
  pyw_buf_u32(b, (uint32_t)count);
  pyw_buf_zero(b, 4 * count);
  return p;
}

static size_t fb_string(struct pyw_buf* b, const char* s) {
  pyw_buf_align(b, 4);
  size_t p = b->len;
  size_t n = s ? strlen(s) : 0;
  pyw_buf_u32(b, (uint32_t)n);
  pyw_buf_put(b, s, n);
  pyw_buf_zero(b, 1);
  return p;
}

/* `meta` framed as an encapsulated message: continuation, length, the
 * flatbuffer, zero padding so the body starts on a 64-byte boundary. */
static void encapsulate(struct pyw_buf* out, const struct pyw_buf* meta) {
  size_t m = meta->len;
  while ((8 + m) % PYW_ALIGN != 0) m++;
  pyw_buf_u32(out, 0xFFFFFFFFu);
  pyw_buf_i32(out, (int32_t)m);
  pyw_buf_put(out, meta->p, meta->len);
  pyw_buf_zero(out, m - meta->len);
}

/* ---- types --------------------------------------------------------------- */

/* Arrow's Type union: the members this codec writes. */
enum { T_NULL = 1, T_INT = 2, T_FLOAT = 3, T_BINARY = 4, T_UTF8 = 5, T_BOOL = 6 };

/* The union member of `format`, with Int's bit width and signedness or
 * FloatingPoint's precision; 0 when this codec does not write it. */
static int type_of(const char* format, int* bits, int* is_signed, int* precision) {
  if (format == NULL || format[0] == 0 || format[1] != 0) return 0;
  switch (format[0]) {
    case 'n': return T_NULL;
    case 'b': return T_BOOL;
    case 'u': return T_UTF8;
    case 'z': return T_BINARY;
    case 'c': *bits = 8, *is_signed = 1; return T_INT;
    case 'C': *bits = 8, *is_signed = 0; return T_INT;
    case 's': *bits = 16, *is_signed = 1; return T_INT;
    case 'S': *bits = 16, *is_signed = 0; return T_INT;
    case 'i': *bits = 32, *is_signed = 1; return T_INT;
    case 'I': *bits = 32, *is_signed = 0; return T_INT;
    case 'l': *bits = 64, *is_signed = 1; return T_INT;
    case 'L': *bits = 64, *is_signed = 0; return T_INT;
    case 'e': *precision = 0; return T_FLOAT;
    case 'f': *precision = 1; return T_FLOAT;
    case 'g': *precision = 2; return T_FLOAT;
    default: return 0;
  }
}

int pyw_format_width(const char* format) {
  if (format == NULL || format[0] == 0 || format[1] != 0) return 0;
  switch (format[0]) {
    case 'c': case 'C': return 1;
    case 's': case 'S': case 'e': return 2;
    case 'i': case 'I': case 'f': return 4;
    case 'l': case 'L': case 'g': return 8;
    default: return 0;
  }
}

/* ---- Schema -------------------------------------------------------------- */

const char* pyw_ipc_schema(struct pyw_buf* out, const struct pyw_field* f, int n) {
  for (int i = 0; i < n; i++) {
    int bits = 0, sg = 0, prec = 0;
    if (type_of(f[i].format, &bits, &sg, &prec) == 0) return f[i].format ? f[i].format : "(no format)";
  }
  struct pyw_buf fb = {0};
  pyw_buf_zero(&fb, 4); /* the root uoffset */
  struct fbf m[4] = {{0, 2, 4, 0, 0}, {1, 1, 1, 0, 0}, {2, 4, 0, 1, 0}, {3, 8, 0, 0, 0}};
  size_t mt = fb_table(&fb, m, 4); /* Message: version V5, header Schema, bodyLength 0 */
  fb_patch(&fb, 0, mt);
  struct fbf s[2] = {{0, 2, 0, 0, 0}, {1, 4, 0, 1, 0}}; /* Schema: endianness Little, fields */
  size_t st = fb_table(&fb, s, 2);
  fb_patch(&fb, m[2].at, st);
  size_t fv = fb_vec_offsets(&fb, (size_t)n);
  fb_patch(&fb, s[1].at, fv);
  for (int i = 0; i < n; i++) {
    int bits = 0, sg = 0, prec = 0;
    int tt = type_of(f[i].format, &bits, &sg, &prec);
    /* Field: name, nullable, type_type, type, children (an empty vector:
     * Arrow's reader refuses a field without one). */
    struct fbf fd[5] = {{0, 4, 0, 1, 0}, {1, 1, f[i].nullable ? 1u : 0u, 0, 0}, {2, 1, (uint64_t)tt, 0, 0},
                        {3, 4, 0, 1, 0}, {5, 4, 0, 1, 0}};
    size_t ft = fb_table(&fb, fd, 5);
    fb_patch(&fb, fv + 4 + 4 * (size_t)i, ft);
    fb_patch(&fb, fd[0].at, fb_string(&fb, f[i].name ? f[i].name : ""));
    size_t tt_pos;
    if (tt == T_INT) {
      struct fbf it[2] = {{0, 4, (uint64_t)(uint32_t)bits, 0, 0}, {1, 1, (uint64_t)sg, 0, 0}};
      tt_pos = fb_table(&fb, it, 2);
    } else if (tt == T_FLOAT) {
      struct fbf fp[1] = {{0, 2, (uint64_t)prec, 0, 0}};
      tt_pos = fb_table(&fb, fp, 1);
    } else {
      tt_pos = fb_table(&fb, NULL, 0);
    }
    fb_patch(&fb, fd[3].at, tt_pos);
    fb_patch(&fb, fd[4].at, fb_vec_offsets(&fb, 0));
  }
  if (fb.oom) out->oom = 1;
  else encapsulate(out, &fb);
  pyw_buf_free(&fb);
  return NULL;
}

/* ---- RecordBatch, written ------------------------------------------------- */

struct ipc_node {
  int64_t length, null_count;
};
struct ipc_buffer {
  int64_t offset, length;
};

static int64_t pad64(int64_t n) { return (n + (int64_t)PYW_ALIGN - 1) & ~(int64_t)(PYW_ALIGN - 1); }

static int bit_at(const uint8_t* v, int64_t i) { return (v[i >> 3] >> (i & 7)) & 1; }

static int64_t nulls_of(const struct ArrowArray* a, int64_t length) {
  const uint8_t* v = a->n_buffers > 0 ? (const uint8_t*)a->buffers[0] : NULL;
  if (v == NULL) return 0;
  if (a->null_count >= 0) return a->null_count;
  int64_t n = 0;
  for (int64_t i = 0; i < length; i++) n += !bit_at(v, a->offset + i);
  return n;
}

/* The metadata of a batch; fills nodes and buffers; returns the body size. */
static int64_t batch_layout(int64_t length, const struct ArrowArray* const* cols, const int* widths, int n,
                            struct ipc_node* nodes, struct ipc_buffer* bufs) {
  int64_t at = 0;
  for (int i = 0; i < n; i++) {
    int64_t nc = nulls_of(cols[i], length);
    nodes[i].length = length;
    nodes[i].null_count = nc;
    bufs[2 * i].offset = at;
    bufs[2 * i].length = nc > 0 ? (length + 7) / 8 : 0;
    at += pad64(bufs[2 * i].length);
    bufs[2 * i + 1].offset = at;
    bufs[2 * i + 1].length = length * widths[i];
    at += pad64(bufs[2 * i + 1].length);
  }
  return at;
}

static void batch_meta(struct pyw_buf* fb, int64_t length, int n, const struct ipc_node* nodes,
                       const struct ipc_buffer* bufs, int64_t body) {
  pyw_buf_zero(fb, 4);
  struct fbf m[4] = {{0, 2, 4, 0, 0}, {1, 1, 3, 0, 0}, {2, 4, 0, 1, 0}, {3, 8, (uint64_t)body, 0, 0}};
  size_t mt = fb_table(fb, m, 4); /* Message: version V5, header RecordBatch */
  fb_patch(fb, 0, mt);
  struct fbf rb[3] = {{0, 8, (uint64_t)length, 0, 0}, {1, 4, 0, 1, 0}, {2, 4, 0, 1, 0}};
  size_t rt = fb_table(fb, rb, 3);
  fb_patch(fb, m[2].at, rt);
  fb_patch(fb, rb[1].at, fb_vec_structs(fb, nodes, sizeof(struct ipc_node), (size_t)n));
  fb_patch(fb, rb[2].at, fb_vec_structs(fb, bufs, sizeof(struct ipc_buffer), 2 * (size_t)n));
}

#define MAX_COLS 64

size_t pyw_ipc_batch_size(int64_t length, const struct ArrowArray* const* cols, const int* widths, int n) {
  struct ipc_node nodes[MAX_COLS];
  struct ipc_buffer bufs[2 * MAX_COLS];
  if (n > MAX_COLS) return 0;
  int64_t body = batch_layout(length, cols, widths, n, nodes, bufs);
  struct pyw_buf fb = {0};
  batch_meta(&fb, length, n, nodes, bufs, body);
  size_t meta = fb.len;
  int oom = fb.oom;
  pyw_buf_free(&fb);
  if (oom) return 0;
  while ((8 + meta) % PYW_ALIGN != 0) meta++;
  return 8 + meta + (size_t)body;
}

/* `n` bits of `src` from bit `off`, to `dst` from bit 0; the last byte's
 * spare bits zero. Reads only the bytes holding bits off .. off + n - 1. */
static void copy_bits(uint8_t* dst, const uint8_t* src, int64_t off, int64_t n) {
  int64_t nbytes = (n + 7) / 8;
  int64_t first = off >> 3;
  int64_t last = (off + n - 1) >> 3; /* the last source byte read */
  int sh = (int)(off & 7);
  for (int64_t k = 0; k < nbytes; k++) {
    int64_t i = first + k;
    unsigned v = (unsigned)src[i] >> sh;
    if (sh != 0 && i + 1 <= last) v |= (unsigned)src[i + 1] << (8 - sh);
    dst[k] = (uint8_t)v;
  }
  if (n & 7) dst[nbytes - 1] &= (uint8_t)((1u << (n & 7)) - 1);
}

size_t pyw_ipc_batch_write(uint8_t* dst, int64_t length, const struct ArrowArray* const* cols, const int* widths,
                           int n) {
  struct ipc_node nodes[MAX_COLS];
  struct ipc_buffer bufs[2 * MAX_COLS];
  if (n > MAX_COLS) return 0;
  int64_t body = batch_layout(length, cols, widths, n, nodes, bufs);
  struct pyw_buf fb = {0};
  batch_meta(&fb, length, n, nodes, bufs, body);
  if (fb.oom) {
    pyw_buf_free(&fb);
    return 0;
  }
  size_t meta = fb.len;
  while ((8 + meta) % PYW_ALIGN != 0) meta++;
  uint32_t cont = 0xFFFFFFFFu;
  int32_t ml = (int32_t)meta;
  memcpy(dst, &cont, 4);
  memcpy(dst + 4, &ml, 4);
  memcpy(dst + 8, fb.p, fb.len);
  memset(dst + 8 + fb.len, 0, meta - fb.len);
  pyw_buf_free(&fb);
  uint8_t* b = dst + 8 + meta;
  memset(b, 0, (size_t)body); /* padding never carries stale bytes */
  for (int i = 0; i < n; i++) {
    const struct ArrowArray* a = cols[i];
    if (bufs[2 * i].length > 0) copy_bits(b + bufs[2 * i].offset, (const uint8_t*)a->buffers[0], a->offset, length);
    if (length > 0)
      memcpy(b + bufs[2 * i + 1].offset, (const uint8_t*)a->buffers[1] + a->offset * widths[i],
             (size_t)(length * widths[i]));
  }
  return 8 + meta + (size_t)body;
}

/* ---- RecordBatch, read ---------------------------------------------------- */

struct fbr {
  const uint8_t* p;
  size_t len;
  int bad;
};

static uint64_t rd(struct fbr* r, size_t at, size_t n) {
  uint64_t v = 0;
  if (r->bad || at > r->len || r->len - at < n) {
    r->bad = 1;
    return 0;
  }
  memcpy(&v, r->p + at, n);
  return v;
}

/* The position a uoffset at `at` points to. */
static size_t deref(struct fbr* r, size_t at) {
  size_t t = at + (size_t)(uint32_t)rd(r, at, 4);
  if (t >= r->len) r->bad = 1;
  return r->bad ? 0 : t;
}

/* The position of field `id` of the table at `t`, or 0 when absent. */
static size_t field(struct fbr* r, size_t t, int id) {
  int32_t so = (int32_t)(uint32_t)rd(r, t, 4);
  int64_t vt = (int64_t)t - so;
  if (r->bad || vt < 0 || (size_t)vt + 4 > r->len) {
    r->bad = 1;
    return 0;
  }
  size_t vsize = (size_t)rd(r, (size_t)vt, 2);
  size_t tsize = (size_t)rd(r, (size_t)vt + 2, 2);
  size_t slot = 4 + 2 * (size_t)id;
  if (slot + 2 > vsize) return 0;
  size_t off = (size_t)rd(r, (size_t)vt + slot, 2);
  if (off == 0) return 0;
  if (off >= tsize || t + off >= r->len) {
    r->bad = 1;
    return 0;
  }
  return t + off;
}

/* A vector field's element count and first element, checked to fit. */
static size_t vec(struct fbr* r, size_t t, int id, size_t elem, size_t* count) {
  size_t f = field(r, t, id);
  *count = 0;
  if (f == 0) return 0;
  size_t v = deref(r, f);
  size_t c = (size_t)(uint32_t)rd(r, v, 4);
  if (r->bad || c > (r->len - v - 4) / elem) {
    r->bad = 1;
    return 0;
  }
  *count = c;
  return v + 4;
}

struct col_block {
  const void* bufs[2];
  uint8_t* msg;
};

static void release_decoded(struct ArrowArray* a) {
  struct col_block* cb = a->private_data;
  free(cb->msg);
  free(cb);
  a->release = NULL;
}

const char* pyw_ipc_decode_column(uint8_t* msg, size_t len, int width, struct ArrowArray* out) {
  if (len < 8) return "a reply payload shorter than a message prefix";
  uint32_t cont;
  int32_t meta;
  memcpy(&cont, msg, 4);
  memcpy(&meta, msg + 4, 4);
  if (cont != 0xFFFFFFFFu) return "a reply payload without the IPC continuation marker";
  if (meta <= 0 || (size_t)meta > len - 8 || meta % 8 != 0) return "a metadata length outside the payload";
  struct fbr r = {msg + 8, (size_t)meta, 0};
  size_t mt = deref(&r, 0);
  size_t fv = field(&r, mt, 0);
  size_t fh = field(&r, mt, 1);
  size_t fb = field(&r, mt, 2);
  size_t fl = field(&r, mt, 3);
  if (r.bad) return "the message flatbuffer is malformed";
  if (fv == 0 || (int16_t)rd(&r, fv, 2) != 4) return "the message is not metadata version V5";
  if (fh == 0 || rd(&r, fh, 1) != 3 || fb == 0) return "the message is not a record batch";
  int64_t body_len = fl ? (int64_t)rd(&r, fl, 8) : 0;
  size_t room = len - 8 - (size_t)meta;
  if (body_len < 0 || (uint64_t)body_len > room) return "the body length runs past the payload";
  size_t rb = deref(&r, fb);
  size_t fln = field(&r, rb, 0);
  int64_t length = fln ? (int64_t)rd(&r, fln, 8) : 0;
  size_t n_nodes = 0, n_bufs = 0;
  size_t nodes = vec(&r, rb, 1, 16, &n_nodes);
  size_t bufs = vec(&r, rb, 2, 16, &n_bufs);
  if (field(&r, rb, 3) != 0) return "a compressed record batch";
  if (r.bad) return "the record batch flatbuffer is malformed";
  if (n_nodes != 1 || n_bufs != 2) return "the record batch is not one primitive column";
  int64_t node_len = (int64_t)rd(&r, nodes, 8);
  int64_t nulls = (int64_t)rd(&r, nodes + 8, 8);
  int64_t off[2], blen[2];
  for (int i = 0; i < 2; i++) {
    off[i] = (int64_t)rd(&r, bufs + 16 * (size_t)i, 8);
    blen[i] = (int64_t)rd(&r, bufs + 16 * (size_t)i + 8, 8);
  }
  if (r.bad) return "the record batch flatbuffer is malformed";
  if (length < 0 || node_len != length) return "the column's length is not the batch's";
  if (nulls < 0 || nulls > length) return "the column's null count is outside 0 .. length";
  for (int i = 0; i < 2; i++)
    if (off[i] < 0 || blen[i] < 0 || off[i] > body_len || blen[i] > body_len - off[i])
      return "a buffer runs past the body";
  if (length > blen[1] / width) return "the values buffer is shorter than the column";
  if (nulls > 0 && blen[0] < (length + 7) / 8) return "the validity bitmap is shorter than the column";
  uint8_t* body = msg + 8 + meta;
  if (((uintptr_t)(body + off[1])) % (uintptr_t)width != 0) return "the values buffer is not aligned to its width";
  struct col_block* cb = malloc(sizeof(*cb));
  if (cb == NULL) return "out of memory";
  cb->bufs[0] = nulls > 0 ? body + off[0] : NULL;
  cb->bufs[1] = body + off[1];
  cb->msg = msg;
  memset(out, 0, sizeof(*out));
  out->length = length;
  out->null_count = nulls;
  out->n_buffers = 2;
  out->buffers = cb->bufs;
  out->release = release_decoded;
  out->private_data = cb;
  return NULL;
}
