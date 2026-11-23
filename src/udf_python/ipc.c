/*
 * ipc.c: the Arrow IPC messages from this runtime library to its workers,
 * for the types of types.c (nested ones included).
 *
 * Writing: Schema messages (LOAD) and RecordBatch messages (arguments) as
 * flatbuffers laid out front to back: every table's vtable precedes it, every
 * child follows its parent, so each uoffset points forward as the format
 * requires. A Field carries its Type table with the type's parameters and a
 * vector of child Fields. A batch is written in two passes over the type tree,
 * in pre-order: the first checks the host's arrays and plans the nodes, the
 * buffers and the copies that re-base each buffer to offset 0; the second
 * writes the metadata, zeroes the body and runs the copies. Body buffers are
 * UDFPY_ALIGN-aligned in the payload, so the worker can view them in place.
 *
 * The reading of a worker's reply is in ipc_read.c.
 */
#include <stdlib.h>
#include <string.h>

#include "udfpy.h"

/* ---- buffer ---------------------------------------------------------------- */

static int grow(udfpy_buf* b, size_t more) {
  if (b->oom) return -1;
  if (b->n + more <= b->cap) return 0;
  size_t cap = b->cap ? b->cap : 256;
  while (cap < b->n + more) cap *= 2;
  void* p = NULL;
  if (posix_memalign(&p, UDFPY_ALIGN, cap) != 0) {
    b->oom = 1;
    return -1;
  }
  if (b->n) memcpy(p, b->p, b->n);
  free(b->p);
  b->p = (uint8_t*)p;
  b->cap = cap;
  return 0;
}

void udfpy_buf_free(udfpy_buf* b) {
  free(b->p);
  b->p = NULL;
  b->n = b->cap = 0;
}

size_t udfpy_buf_put(udfpy_buf* b, const void* src, size_t n) {
  size_t at = b->n;
  if (grow(b, n) != 0) return at;
  if (n) memcpy(b->p + b->n, src, n);
  b->n += n;
  return at;
}

size_t udfpy_buf_zero(udfpy_buf* b, size_t n) {
  size_t at = b->n;
  if (grow(b, n) != 0) return at;
  memset(b->p + b->n, 0, n);
  b->n += n;
  return at;
}

size_t udfpy_buf_pad(udfpy_buf* b, size_t align) {
  size_t r = b->n % align;
  if (r) udfpy_buf_zero(b, align - r);
  return b->n;
}

void udfpy_buf_u32(udfpy_buf* b, uint32_t v) { udfpy_buf_put(b, &v, 4); }
void udfpy_buf_u64(udfpy_buf* b, uint64_t v) { udfpy_buf_put(b, &v, 8); }

void udfpy_buf_str(udfpy_buf* b, const char* s) {
  uint32_t n = s ? (uint32_t)strlen(s) : 0;
  udfpy_buf_u32(b, n);
  udfpy_buf_put(b, s, n);
}

static void set32(udfpy_buf* b, size_t at, uint32_t v) {
  if (!b->oom) memcpy(b->p + at, &v, 4);
}

static void set_any(udfpy_buf* b, size_t at, const void* v, size_t n) {
  if (!b->oom) memcpy(b->p + at, v, n);
}

/* ---- flatbuffer writer, front to back ------------------------------------- */

typedef struct fb_slot {
  int slot;
  int size; /* 1, 2, 4 or 8; also its alignment */
} fb_slot;

/* A table of `nslots` slots holding the fields `f` (in this order, each
 * aligned to its size). Writes the vtable, then the table, zero-filled;
 * `pos[i]` is field i's position. Returns the table's position. */
static size_t fb_table(udfpy_buf* b, int nslots, const fb_slot* f, int nf, size_t* pos) {
  uint16_t voff[16] = {0};
  size_t fo[16];
  size_t o = 4;
  for (int i = 0; i < nf; i++) {
    size_t a = (size_t)f[i].size;
    o = (o + a - 1) / a * a;
    fo[i] = o;
    voff[f[i].slot] = (uint16_t)o;
    o += (size_t)f[i].size;
  }
  udfpy_buf_pad(b, 2);
  size_t v = b->n;
  uint16_t head[2] = {(uint16_t)(4 + 2 * nslots), (uint16_t)o};
  udfpy_buf_put(b, head, 4);
  udfpy_buf_put(b, voff, 2 * (size_t)nslots);
  udfpy_buf_pad(b, 8);
  size_t t = b->n;
  int32_t so = (int32_t)(t - v);
  udfpy_buf_put(b, &so, 4);
  udfpy_buf_zero(b, o - 4);
  for (int i = 0; i < nf; i++) pos[i] = t + fo[i];
  return t;
}

/* Point the uoffset at `slot` at `target` (which follows it). */
static void fb_link(udfpy_buf* b, size_t slot, size_t target) { set32(b, slot, (uint32_t)(target - slot)); }

static size_t fb_string(udfpy_buf* b, const char* s) {
  udfpy_buf_pad(b, 4);
  size_t at = b->n;
  udfpy_buf_str(b, s);
  udfpy_buf_zero(b, 1);
  return at;
}

/* A vector of `n` uoffsets; element i's slot is at the result + 4 + 4i. */
static size_t fb_offsets(udfpy_buf* b, uint32_t n) {
  udfpy_buf_pad(b, 4);
  size_t at = b->n;
  udfpy_buf_u32(b, n);
  udfpy_buf_zero(b, 4 * (size_t)n);
  return at;
}

/* A vector of `n` 16-byte structs of two int64s, 8-aligned elements. */
static size_t fb_pairs(udfpy_buf* b, uint32_t n, const int64_t* pairs) {
  while ((b->n + 4) % 8) udfpy_buf_zero(b, 1);
  size_t at = b->n;
  udfpy_buf_u32(b, n);
  udfpy_buf_put(b, pairs, 16 * (size_t)n);
  return at;
}

/* The Type union's ids (Schema.fbs). */
#define U_INT 2
#define U_FLOAT 3
#define U_BINARY 4
#define U_UTF8 5
#define U_BOOL 6
#define U_DECIMAL 7
#define U_DATE 8
#define U_TIMESTAMP 10
#define U_LIST 12
#define U_STRUCT 13
#define U_LARGE_BINARY 19
#define U_LARGE_UTF8 20
#define U_LARGE_LIST 21
#define H_SCHEMA 1
#define H_RECORD_BATCH 3
#define V5 4

static uint8_t union_id(const udfpy_type* t) {
  switch (t->kind) {
    case UDFPY_K_BOOL: return U_BOOL;
    case UDFPY_K_INT: return U_INT;
    case UDFPY_K_FLOAT: return U_FLOAT;
    case UDFPY_K_DATE32: return U_DATE;
    case UDFPY_K_TIMESTAMP: return U_TIMESTAMP;
    case UDFPY_K_DECIMAL: return U_DECIMAL;
    case UDFPY_K_UTF8: return t->width == 4 ? U_UTF8 : U_LARGE_UTF8;
    case UDFPY_K_BINARY: return t->width == 4 ? U_BINARY : U_LARGE_BINARY;
    case UDFPY_K_LIST: return t->width == 4 ? U_LIST : U_LARGE_LIST;
    default: return U_STRUCT;
  }
}

/* Start a message: continuation and a length to patch; the flatbuffer's
 * root uoffset. Returns the root slot; *len_at is the length's position. */
static size_t msg_begin(udfpy_buf* b, size_t* len_at) {
  udfpy_buf_pad(b, 8);
  udfpy_buf_u32(b, 0xFFFFFFFFu);
  *len_at = b->n;
  udfpy_buf_u32(b, 0);
  size_t root = b->n;
  udfpy_buf_zero(b, 4);
  return root;
}

/* End the flatbuffer: pad so the body starts UDFPY_ALIGN-aligned, and patch
 * the metadata length (the flatbuffer and its padding). */
static void msg_end(udfpy_buf* b, size_t len_at) {
  udfpy_buf_pad(b, UDFPY_ALIGN);
  set32(b, len_at, (uint32_t)(b->n - (len_at + 4)));
}

/* The Message table: body length (slot 3), header (2), custom metadata (4),
 * version (0), header type (1). *header_slot and *kv_slot are to link. */
static size_t msg_table(udfpy_buf* b, uint8_t header_type, int64_t body_len, size_t* header_slot,
                        size_t* kv_slot) {
  fb_slot f[5] = {{3, 8}, {2, 4}, {4, 4}, {0, 2}, {1, 1}};
  size_t pos[5];
  size_t t = fb_table(b, 5, f, 5, pos);
  set_any(b, pos[0], &body_len, 8);
  *header_slot = pos[1];
  *kv_slot = pos[2];
  int16_t v5 = V5;
  set_any(b, pos[3], &v5, 2);
  set_any(b, pos[4], &header_type, 1);
  return t;
}

/* The same table without custom metadata (slots 3, 2, 0, 1). */
static size_t msg_table_short(udfpy_buf* b, uint8_t header_type, int64_t body_len, size_t* header_slot) {
  fb_slot f[4] = {{3, 8}, {2, 4}, {0, 2}, {1, 1}};
  size_t pos[4];
  size_t t = fb_table(b, 5, f, 4, pos);
  set_any(b, pos[0], &body_len, 8);
  *header_slot = pos[1];
  int16_t v5 = V5;
  set_any(b, pos[2], &v5, 2);
  set_any(b, pos[3], &header_type, 1);
  return t;
}

/* The Type table of node `t`, linked from `slot`: its parameters, or an empty
 * table for a type that has none. */
static void type_table(udfpy_buf* b, size_t slot, const udfpy_type* t) {
  size_t at;
  size_t tp[3];
  switch (t->kind) {
    case UDFPY_K_INT: {
      fb_slot tf[2] = {{0, 4}, {1, 1}};
      at = fb_table(b, 2, tf, 2, tp);
      int32_t bits = (int32_t)t->width * 8;
      uint8_t sig = 1;
      set_any(b, tp[0], &bits, 4);
      set_any(b, tp[1], &sig, 1);
      break;
    }
    case UDFPY_K_FLOAT: {
      fb_slot tf[1] = {{0, 2}};
      at = fb_table(b, 1, tf, 1, tp);
      int16_t precision = t->width == 4 ? 1 : 2; /* SINGLE, DOUBLE */
      set_any(b, tp[0], &precision, 2);
      break;
    }
    case UDFPY_K_DECIMAL: {
      fb_slot tf[3] = {{0, 4}, {1, 4}, {2, 4}};
      at = fb_table(b, 3, tf, 3, tp);
      int32_t bits = 128;
      set_any(b, tp[0], &t->precision, 4);
      set_any(b, tp[1], &t->scale, 4);
      set_any(b, tp[2], &bits, 4);
      break;
    }
    case UDFPY_K_DATE32: {
      fb_slot tf[1] = {{0, 2}};
      at = fb_table(b, 1, tf, 1, tp);
      int16_t unit = 0; /* DAY */
      set_any(b, tp[0], &unit, 2);
      break;
    }
    case UDFPY_K_TIMESTAMP: {
      fb_slot tf[2] = {{0, 2}, {1, 4}};
      int has_tz = t->tz[0] != 0;
      at = fb_table(b, has_tz ? 2 : 1, tf, has_tz ? 2 : 1, tp);
      int16_t unit = (int16_t)t->unit;
      set_any(b, tp[0], &unit, 2);
      if (has_tz) fb_link(b, tp[1], fb_string(b, t->tz));
      break;
    }
    default:
      at = fb_table(b, 0, NULL, 0, tp);
      break;
  }
  fb_link(b, slot, at);
}

/* The Field table of node `ti`, linked from `slot`, then its children's. */
static void field_table(udfpy_buf* b, size_t slot, const udfpy_schema* s, int ti) {
  const udfpy_type* t = &s->t[ti];
  /* Field: name (0), nullable (1), type_type (2), type (3), children (5) */
  fb_slot f[5] = {{0, 4}, {3, 4}, {5, 4}, {1, 1}, {2, 1}};
  size_t pos[5];
  size_t ft = fb_table(b, 7, f, 5, pos);
  fb_link(b, slot, ft);
  uint8_t nullable = t->nullable ? 1 : 0;
  uint8_t tt = union_id(t);
  set_any(b, pos[3], &nullable, 1);
  set_any(b, pos[4], &tt, 1);
  fb_link(b, pos[0], fb_string(b, t->name));
  type_table(b, pos[1], t);
  size_t vec = fb_offsets(b, (uint32_t)t->n_children);
  fb_link(b, pos[2], vec);
  int child = ti + 1;
  for (int i = 0; i < t->n_children; i++) {
    field_table(b, vec + 4 + 4 * (size_t)i, s, child);
    child = s->t[child].next;
  }
}

void udfpy_ipc_schema(udfpy_buf* b, const udfpy_schema* s, int n_kv, const char* const* keys,
                      const char* const* values) {
  size_t len_at;
  size_t root = msg_begin(b, &len_at);
  size_t header_slot, kv_slot = 0;
  size_t mt = n_kv > 0 ? msg_table(b, H_SCHEMA, 0, &header_slot, &kv_slot)
                       : msg_table_short(b, H_SCHEMA, 0, &header_slot);
  fb_link(b, root, mt);
  /* Schema: fields (1) */
  fb_slot sf[1] = {{1, 4}};
  size_t sp[1];
  size_t st = fb_table(b, 4, sf, 1, sp);
  fb_link(b, header_slot, st);
  size_t vec = fb_offsets(b, (uint32_t)s->n);
  fb_link(b, sp[0], vec);
  int ti = 0;
  for (int i = 0; i < s->n; i++) {
    field_table(b, vec + 4 + 4 * (size_t)i, s, ti);
    ti = s->t[ti].next;
  }
  if (n_kv > 0) {
    size_t kv = fb_offsets(b, (uint32_t)n_kv);
    fb_link(b, kv_slot, kv);
    for (int i = 0; i < n_kv; i++) {
      fb_slot kf[2] = {{0, 4}, {1, 4}};
      size_t kp[2];
      size_t kt = fb_table(b, 2, kf, 2, kp);
      fb_link(b, kv + 4 + 4 * (size_t)i, kt);
      fb_link(b, kp[0], fb_string(b, keys[i]));
      fb_link(b, kp[1], fb_string(b, values[i]));
    }
  }
  msg_end(b, len_at);
}

/* ---- RecordBatch, written ----------------------------------------------- */

#define MAX_REGIONS (3 * UDFPY_MAX_NODES)
/* The body's size stays far below what a flatbuffer int64 or an allocation
 * can hold, so no size computation below wraps. */
#define MAX_BODY ((size_t)INT64_MAX / 4)

enum { OP_COPY, OP_BITS, OP_OFFSETS };

/* One copy into the body, planned by the first pass and run by the second. */
typedef struct op {
  int kind;
  const uint8_t* src;
  int64_t p;     /* OP_BITS: the first bit; OP_OFFSETS: the first entry */
  int64_t n;     /* OP_BITS: bits; OP_OFFSETS: entries minus one */
  size_t len;    /* OP_COPY: bytes */
  size_t w;      /* OP_OFFSETS: the offset width */
  int64_t first; /* OP_OFFSETS: the first offset, subtracted from each */
  size_t dst;    /* the position in the body */
} op;

typedef struct plan {
  int64_t nodes[2 * UDFPY_MAX_NODES]; /* (length, null count) per node */
  int n_nodes;
  int64_t regions[2 * MAX_REGIONS]; /* (offset, length) per buffer */
  int n_regions;
  op ops[MAX_REGIONS];
  int n_ops;
  size_t body;
  const char* why;
} plan;

static size_t pad_to(size_t n, size_t a) { return (n + a - 1) / a * a; }

/* The bytes that hold `n` bits (n >= 0, without overflow). */
static size_t bit_bytes(int64_t n) { return (size_t)n / 8 + ((size_t)n % 8 != 0); }

static int plan_fail(plan* pl, const char* why) {
  pl->why = why;
  return -1;
}

/* Reserve a buffer of `len` bytes, padded, in the body; *off is its position. */
static int reserve(plan* pl, size_t len, size_t* off) {
  if (len > MAX_BODY || pl->body > MAX_BODY - pad_to(len, UDFPY_ALIGN))
    return plan_fail(pl, "an argument column is too large for the transport");
  *off = pl->body;
  pl->regions[2 * pl->n_regions] = (int64_t)pl->body;
  pl->regions[2 * pl->n_regions + 1] = (int64_t)len;
  pl->n_regions++;
  pl->body += pad_to(len, UDFPY_ALIGN);
  return 0;
}

static op* add_op(plan* pl, int kind, size_t dst) {
  op* o = &pl->ops[pl->n_ops++];
  memset(o, 0, sizeof(*o));
  o->kind = kind;
  o->dst = dst;
  return o;
}

/* The number of zero bits among bits [p, p + n) of `v`. */
static int64_t count_nulls(const uint8_t* v, int64_t p, int64_t n) {
  int64_t ones = 0, i = p, end = p + n;
  while (i < end && (i & 7)) {
    ones += (v[i >> 3] >> (i & 7)) & 1;
    i++;
  }
  while (i + 8 <= end) {
    ones += __builtin_popcount(v[i >> 3]);
    i += 8;
  }
  while (i < end) {
    ones += (v[i >> 3] >> (i & 7)) & 1;
    i++;
  }
  return n - ones;
}

/* Copy bits [p, p + n) of `src` to bits [0, n) of `dst`, which is zeroed; the
 * bits of the last byte past `n` stay zero. */
static void copy_bits(uint8_t* dst, const uint8_t* src, int64_t p, int64_t n) {
  size_t nbytes = bit_bytes(n);
  size_t k0 = (size_t)(p >> 3);
  size_t end = bit_bytes(p + n); /* the source bytes that hold the range */
  unsigned sh = (unsigned)(p & 7);
  for (size_t k = 0; k < nbytes; k++) {
    unsigned lo = (unsigned)src[k0 + k] >> sh;
    unsigned hi = sh != 0 && k0 + k + 1 < end ? (unsigned)src[k0 + k + 1] << (8 - sh) : 0;
    dst[k] = (uint8_t)(lo | hi);
  }
  if (n % 8 != 0) dst[nbytes - 1] &= (uint8_t)((1u << (n % 8)) - 1u);
}

static int64_t offset_at(const uint8_t* offs, size_t w, int64_t i) {
  if (w == 4) {
    int32_t v;
    memcpy(&v, offs + (size_t)i * 4, 4);
    return v;
  }
  int64_t v;
  memcpy(&v, offs + (size_t)i * 8, 8);
  return v;
}

/* Check offsets [p, p + n] of `offs` (n + 1 entries): the first is not
 * negative and none decreases. */
static int check_offsets(plan* pl, const uint8_t* offs, size_t w, int64_t p, int64_t n) {
  int64_t prev = offset_at(offs, w, p);
  if (prev < 0) return plan_fail(pl, "an argument column has offsets that decrease or are negative");
  for (int64_t i = 1; i <= n; i++) {
    int64_t cur = offset_at(offs, w, p + i);
    if (cur < prev) return plan_fail(pl, "an argument column has offsets that decrease or are negative");
    prev = cur;
  }
  return 0;
}

static int is_primitive(const udfpy_type* t) {
  return t->kind != UDFPY_K_UTF8 && t->kind != UDFPY_K_BINARY && t->kind != UDFPY_K_LIST && t->kind != UDFPY_K_STRUCT;
}

static int expected_buffers(const udfpy_type* t) {
  switch (t->kind) {
    case UDFPY_K_UTF8:
    case UDFPY_K_BINARY: return 3;
    case UDFPY_K_STRUCT: return 1;
    default: return 2;
  }
}

/* Visit node `ti` of the type tree, array `a`, rows [start, start + n) of it:
 * pass 1 of the batch. Records the node, its buffers and the copies that
 * re-base them to offset 0, then the children's, in pre-order. */
static int visit(plan* pl, const udfpy_schema* s, int ti, const struct ArrowArray* a, int64_t start, int64_t n) {
  const udfpy_type* t = &s->t[ti];
  const char* shape = is_primitive(t) ? "an argument column is not a primitive array of the batch's length"
                                      : "an argument column is not an array of its bound type and the batch's length";
  int64_t want_children = t->kind == UDFPY_K_LIST ? 1 : t->kind == UDFPY_K_STRUCT ? t->n_children : 0;
  if (a == NULL || a->release == NULL || a->n_buffers != expected_buffers(t) || a->n_children != want_children ||
      a->length < 0 || a->offset < 0 || a->offset > INT64_MAX - a->length || a->dictionary != NULL ||
      (a->n_buffers > 0 && a->buffers == NULL) || (a->n_children > 0 && a->children == NULL))
    return plan_fail(pl, shape);
  if (start < 0 || n < 0 || start > a->length || n > a->length - start)
    return plan_fail(pl, "a nested argument column is shorter than its parent's range");
  if (pl->n_nodes >= UDFPY_MAX_NODES) return plan_fail(pl, "an argument column has more nodes than its bound type");
  int64_t p = a->offset + start;
  const uint8_t* valid = (const uint8_t*)a->buffers[0];
  int64_t nulls = valid != NULL ? count_nulls(valid, p, n) : 0;
  pl->nodes[2 * pl->n_nodes] = n;
  pl->nodes[2 * pl->n_nodes + 1] = nulls;
  pl->n_nodes++;
  size_t off;
  if (reserve(pl, nulls > 0 ? bit_bytes(n) : 0, &off) != 0) return -1;
  if (nulls > 0) {
    op* o = add_op(pl, OP_BITS, off);
    o->src = valid;
    o->p = p;
    o->n = n;
  }
  switch (t->kind) {
    case UDFPY_K_STRUCT: {
      int child = ti + 1;
      for (int i = 0; i < t->n_children; i++) {
        if (visit(pl, s, child, a->children[i], p, n) != 0) return -1;
        child = s->t[child].next;
      }
      return 0;
    }
    case UDFPY_K_BOOL: {
      size_t len = bit_bytes(n);
      if (n > 0 && a->buffers[1] == NULL) return plan_fail(pl, "an argument column has no values buffer");
      if (reserve(pl, len, &off) != 0) return -1;
      if (n > 0) {
        op* o = add_op(pl, OP_BITS, off);
        o->src = (const uint8_t*)a->buffers[1];
        o->p = p;
        o->n = n;
      }
      return 0;
    }
    case UDFPY_K_UTF8:
    case UDFPY_K_BINARY:
    case UDFPY_K_LIST: {
      size_t w = t->width;
      const uint8_t* offs = (const uint8_t*)a->buffers[1];
      int64_t first = 0, last = 0;
      if (n > 0) {
        if (offs == NULL) return plan_fail(pl, "an argument column has no offsets buffer");
        if (check_offsets(pl, offs, w, p, n) != 0) return -1;
        first = offset_at(offs, w, p);
        last = offset_at(offs, w, p + n);
      }
      size_t olen;
      if (__builtin_mul_overflow((size_t)n + 1, w, &olen)) return plan_fail(pl, "an argument column is too large for the transport");
      if (reserve(pl, olen, &off) != 0) return -1;
      if (n > 0) {
        op* o = add_op(pl, OP_OFFSETS, off);
        o->src = offs;
        o->p = p;
        o->n = n;
        o->w = w;
        o->first = first;
      }
      if (t->kind == UDFPY_K_LIST) return visit(pl, s, ti + 1, a->children[0], first, last - first);
      const uint8_t* data = (const uint8_t*)a->buffers[2];
      if (last > first && data == NULL) return plan_fail(pl, "an argument column has no data buffer");
      if (reserve(pl, (size_t)(last - first), &off) != 0) return -1;
      if (last > first) {
        op* o = add_op(pl, OP_COPY, off);
        o->src = data + first;
        o->len = (size_t)(last - first);
      }
      return 0;
    }
    default: {
      size_t w = t->width, len;
      if (n > 0 && a->buffers[1] == NULL) return plan_fail(pl, "an argument column has no values buffer");
      size_t pw;
      if (__builtin_mul_overflow((size_t)n, w, &len) || __builtin_mul_overflow((size_t)p, w, &pw))
        return plan_fail(pl, "an argument column is too large for the transport");
      if (reserve(pl, len, &off) != 0) return -1;
      if (n > 0) {
        op* o = add_op(pl, OP_COPY, off);
        o->src = (const uint8_t*)a->buffers[1] + pw;
        o->len = len;
      }
      return 0;
    }
  }
}

/* Pass 2: run a planned copy into the zeroed body. */
static void run_op(const op* o, uint8_t* body) {
  uint8_t* d = body + o->dst;
  switch (o->kind) {
    case OP_COPY:
      memcpy(d, o->src, o->len);
      break;
    case OP_BITS:
      copy_bits(d, o->src, o->p, o->n);
      break;
    default:
      for (int64_t i = 0; i <= o->n; i++) {
        int64_t v = offset_at(o->src, o->w, o->p + i) - o->first;
        if (o->w == 4) {
          int32_t x = (int32_t)v;
          memcpy(d + (size_t)i * 4, &x, 4);
        } else {
          memcpy(d + (size_t)i * 8, &v, 8);
        }
      }
      break;
  }
}

/* Pass 1 over every column: the plan of nodes, buffers and copies. */
static int plan_columns(plan* pl, int64_t length, const udfpy_schema* s, const struct ArrowArray* const* cols) {
  int ti = 0;
  for (int i = 0; i < s->n; i++) {
    const struct ArrowArray* c = cols[i];
    if (c == NULL || c->length != length)
      return plan_fail(pl, is_primitive(&s->t[ti]) ? "an argument column is not a primitive array of the batch's length"
                                                  : "an argument column is not an array of its bound type and the batch's length");
    if (visit(pl, s, ti, c, 0, length) != 0) return -1;
    ti = s->t[ti].next;
  }
  return 0;
}

int udfpy_ipc_batch(udfpy_buf* b, int64_t length, const udfpy_schema* s, const struct ArrowArray* const* cols,
                    const char** why) {
  if (s->n > UDFPY_MAX_FIELDS) {
    *why = "more columns than the transport carries";
    return -1;
  }
  plan* pl = (plan*)calloc(1, sizeof(*pl));
  if (pl == NULL) {
    *why = "out of memory";
    return -1;
  }
  if (plan_columns(pl, length, s, cols) != 0) {
    *why = pl->why;
    free(pl);
    return -1;
  }
  size_t len_at;
  size_t root = msg_begin(b, &len_at);
  size_t header_slot;
  size_t mt = msg_table_short(b, H_RECORD_BATCH, (int64_t)pl->body, &header_slot);
  fb_link(b, root, mt);
  /* RecordBatch: length (0), nodes (1), buffers (2) */
  fb_slot rf[3] = {{0, 8}, {1, 4}, {2, 4}};
  size_t rp[3];
  size_t rt = fb_table(b, 5, rf, 3, rp);
  fb_link(b, header_slot, rt);
  set_any(b, rp[0], &length, 8);
  fb_link(b, rp[1], fb_pairs(b, (uint32_t)pl->n_nodes, pl->nodes));
  fb_link(b, rp[2], fb_pairs(b, (uint32_t)pl->n_regions, pl->regions));
  msg_end(b, len_at);
  size_t base = b->n;
  udfpy_buf_zero(b, pl->body);
  if (b->oom) {
    *why = "out of memory";
    free(pl);
    return -1;
  }
  for (int i = 0; i < pl->n_ops; i++) run_op(&pl->ops[i], b->p + base);
  free(pl);
  return 0;
}
