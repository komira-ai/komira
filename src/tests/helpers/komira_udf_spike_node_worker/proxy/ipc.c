/*
 * ipc.c: the Arrow IPC messages of the worker transport, engine side, for
 * the primitive types the conformance cases use (int64 'l', float64 'g',
 * int32 'i') in a struct of columns. Test-only spike code.
 *
 * Writing: Schema messages (LOAD, VALIDATE) and RecordBatch messages
 * (arguments, frame inputs, aggregate inputs) as flatbuffers laid out front
 * to back: every table's vtable precedes it, every child follows its parent,
 * so each uoffset points forward as the format requires. Body buffers are
 * KUDFW_ALIGN-aligned in the payload, so the worker can view them in place.
 *
 * Reading: a worker's RecordBatch message. The worker is the boundary of
 * untrusted code, so every flatbuffer offset is bounds-checked, the layout
 * is checked against the bound schema (one node and two buffers per column,
 * node lengths, null counts, buffer sizes for the length), and every buffer
 * against the body before a pointer into it is formed (design section 4.4).
 * The arrays borrow the payload, which the proxy already copied out of the
 * channel (section 5.2: the engine copies each worker-to-engine payload).
 */
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "kudfw.h"

/* ---- buffer ---------------------------------------------------------------- */

static int grow(kudfw_buf* b, size_t more) {
  if (b->oom) return -1;
  if (b->n + more <= b->cap) return 0;
  size_t cap = b->cap ? b->cap : 256;
  while (cap < b->n + more) cap *= 2;
  void* p = NULL;
  if (posix_memalign(&p, KUDFW_ALIGN, cap) != 0) {
    b->oom = 1;
    return -1;
  }
  if (b->n) memcpy(p, b->p, b->n);
  free(b->p);
  b->p = (uint8_t*)p;
  b->cap = cap;
  return 0;
}

void kudfw_buf_free(kudfw_buf* b) {
  free(b->p);
  b->p = NULL;
  b->n = b->cap = 0;
}

size_t kudfw_buf_put(kudfw_buf* b, const void* src, size_t n) {
  size_t at = b->n;
  if (grow(b, n) != 0) return at;
  if (n) memcpy(b->p + b->n, src, n);
  b->n += n;
  return at;
}

size_t kudfw_buf_zero(kudfw_buf* b, size_t n) {
  size_t at = b->n;
  if (grow(b, n) != 0) return at;
  memset(b->p + b->n, 0, n);
  b->n += n;
  return at;
}

size_t kudfw_buf_pad(kudfw_buf* b, size_t align) {
  size_t r = b->n % align;
  if (r) kudfw_buf_zero(b, align - r);
  return b->n;
}

void kudfw_buf_u32(kudfw_buf* b, uint32_t v) { kudfw_buf_put(b, &v, 4); }
void kudfw_buf_u64(kudfw_buf* b, uint64_t v) { kudfw_buf_put(b, &v, 8); }

void kudfw_buf_str(kudfw_buf* b, const char* s) {
  uint32_t n = s ? (uint32_t)strlen(s) : 0;
  kudfw_buf_u32(b, n);
  kudfw_buf_put(b, s, n);
}

static void set32(kudfw_buf* b, size_t at, uint32_t v) {
  if (!b->oom) memcpy(b->p + at, &v, 4);
}

static void set_any(kudfw_buf* b, size_t at, const void* v, size_t n) {
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
static size_t fb_table(kudfw_buf* b, int nslots, const fb_slot* f, int nf, size_t* pos) {
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
  kudfw_buf_pad(b, 2);
  size_t v = b->n;
  uint16_t head[2] = {(uint16_t)(4 + 2 * nslots), (uint16_t)o};
  kudfw_buf_put(b, head, 4);
  kudfw_buf_put(b, voff, 2 * (size_t)nslots);
  kudfw_buf_pad(b, 8);
  size_t t = b->n;
  int32_t so = (int32_t)(t - v);
  kudfw_buf_put(b, &so, 4);
  kudfw_buf_zero(b, o - 4);
  for (int i = 0; i < nf; i++) pos[i] = t + fo[i];
  return t;
}

/* Point the uoffset at `slot` at `target` (which follows it). */
static void fb_link(kudfw_buf* b, size_t slot, size_t target) { set32(b, slot, (uint32_t)(target - slot)); }

static size_t fb_string(kudfw_buf* b, const char* s) {
  kudfw_buf_pad(b, 4);
  size_t at = b->n;
  kudfw_buf_str(b, s);
  kudfw_buf_zero(b, 1);
  return at;
}

/* A vector of `n` uoffsets; element i's slot is at the result + 4 + 4i. */
static size_t fb_offsets(kudfw_buf* b, uint32_t n) {
  kudfw_buf_pad(b, 4);
  size_t at = b->n;
  kudfw_buf_u32(b, n);
  kudfw_buf_zero(b, 4 * (size_t)n);
  return at;
}

/* A vector of `n` 16-byte structs of two int64s, 8-aligned elements. */
static size_t fb_pairs(kudfw_buf* b, uint32_t n, const int64_t* pairs) {
  while ((b->n + 4) % 8) kudfw_buf_zero(b, 1);
  size_t at = b->n;
  kudfw_buf_u32(b, n);
  kudfw_buf_put(b, pairs, 16 * (size_t)n);
  return at;
}

#define T_INT 2
#define T_FLOAT 3
#define T_STRUCT 13
#define H_SCHEMA 1
#define H_RECORD_BATCH 3
#define V5 4

static int fmt_width(char f) { return f == 'i' ? 4 : 8; }

/* Start a message: continuation and a length to patch; the flatbuffer's
 * root uoffset. Returns the root slot; *len_at is the length's position. */
static size_t msg_begin(kudfw_buf* b, size_t* len_at) {
  kudfw_buf_pad(b, 8);
  kudfw_buf_u32(b, 0xFFFFFFFFu);
  *len_at = b->n;
  kudfw_buf_u32(b, 0);
  size_t root = b->n;
  kudfw_buf_zero(b, 4);
  return root;
}

/* End the flatbuffer: pad so the body starts KUDFW_ALIGN-aligned, and patch
 * the metadata length (the flatbuffer and its padding). */
static void msg_end(kudfw_buf* b, size_t len_at) {
  kudfw_buf_pad(b, KUDFW_ALIGN);
  set32(b, len_at, (uint32_t)(b->n - (len_at + 4)));
}

/* The Message table: body length (slot 3), header (2), custom metadata (4),
 * version (0), header type (1). *header_slot and *kv_slot are to link. */
static size_t msg_table(kudfw_buf* b, uint8_t header_type, int64_t body_len, size_t* header_slot,
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
static size_t msg_table_short(kudfw_buf* b, uint8_t header_type, int64_t body_len, size_t* header_slot) {
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

static void field_table(kudfw_buf* b, size_t slot, const kudfw_field* fl) {
  /* Field: name (0), nullable (1), type_type (2), type (3), children (5) */
  fb_slot f[5] = {{0, 4}, {3, 4}, {5, 4}, {1, 1}, {2, 1}};
  size_t pos[5];
  size_t t = fb_table(b, 7, f, 5, pos);
  fb_link(b, slot, t);
  uint8_t nullable = fl->nullable ? 1 : 0;
  uint8_t tt = fl->fmt == 'g' ? T_FLOAT : T_INT;
  set_any(b, pos[3], &nullable, 1);
  set_any(b, pos[4], &tt, 1);
  fb_link(b, pos[0], fb_string(b, fl->name));
  if (tt == T_FLOAT) {
    fb_slot tf[1] = {{0, 2}};
    size_t tp[1];
    size_t tt_at = fb_table(b, 1, tf, 1, tp);
    int16_t dbl = 2;
    set_any(b, tp[0], &dbl, 2);
    fb_link(b, pos[1], tt_at);
  } else {
    fb_slot tf[2] = {{0, 4}, {1, 1}};
    size_t tp[2];
    size_t tt_at = fb_table(b, 2, tf, 2, tp);
    int32_t bits = fl->fmt == 'i' ? 32 : 64;
    uint8_t sig = 1;
    set_any(b, tp[0], &bits, 4);
    set_any(b, tp[1], &sig, 1);
    fb_link(b, pos[1], tt_at);
  }
  fb_link(b, pos[2], fb_offsets(b, 0));
}

void kudfw_ipc_schema(kudfw_buf* b, const kudfw_schema* s, int n_kv, const char* const* keys,
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
  for (int i = 0; i < s->n; i++) field_table(b, vec + 4 + 4 * (size_t)i, &s->f[i]);
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

static int bit(const uint8_t* v, int64_t i) { return (v[i >> 3] >> (i & 7)) & 1; }

static size_t pad_to(size_t n, size_t a) { return (n + a - 1) / a * a; }

int kudfw_ipc_batch(kudfw_buf* b, int64_t length, int n, const struct ArrowArray* const* cols,
                    const char* fmts, const char** why) {
  if (n > KUDFW_MAX_FIELDS) {
    *why = "more columns than the transport carries";
    return -1;
  }
  int64_t nulls[KUDFW_MAX_FIELDS];
  int64_t regions[2 * KUDFW_MAX_FIELDS * 2];
  int64_t nodes[2 * KUDFW_MAX_FIELDS];
  size_t body = 0;
  for (int i = 0; i < n; i++) {
    const struct ArrowArray* c = cols[i];
    if (c == NULL || c->release == NULL || c->n_buffers != 2 || c->n_children != 0 || c->length != length ||
        c->offset < 0) {
      *why = "an argument column is not a primitive array of the batch's length";
      return -1;
    }
    if (fmts[i] != 'l' && fmts[i] != 'g' && fmts[i] != 'i') {
      *why = "an argument type the transport does not carry";
      return -1;
    }
    const uint8_t* v = (const uint8_t*)c->buffers[0];
    int64_t k = 0;
    if (v != NULL)
      for (int64_t r = 0; r < length; r++) k += !bit(v, c->offset + r);
    nulls[i] = k;
    size_t vlen = k > 0 ? (size_t)((length + 7) / 8) : 0;
    size_t dlen = (size_t)length * (size_t)fmt_width(fmts[i]);
    nodes[2 * i] = length;
    nodes[2 * i + 1] = k;
    regions[4 * i] = (int64_t)body;
    regions[4 * i + 1] = (int64_t)vlen;
    body += pad_to(vlen, KUDFW_ALIGN);
    regions[4 * i + 2] = (int64_t)body;
    regions[4 * i + 3] = (int64_t)dlen;
    body += pad_to(dlen, KUDFW_ALIGN);
  }
  size_t len_at;
  size_t root = msg_begin(b, &len_at);
  size_t header_slot;
  size_t mt = msg_table_short(b, H_RECORD_BATCH, (int64_t)body, &header_slot);
  fb_link(b, root, mt);
  /* RecordBatch: length (0), nodes (1), buffers (2) */
  fb_slot rf[3] = {{0, 8}, {1, 4}, {2, 4}};
  size_t rp[3];
  size_t rt = fb_table(b, 5, rf, 3, rp);
  fb_link(b, header_slot, rt);
  set_any(b, rp[0], &length, 8);
  fb_link(b, rp[1], fb_pairs(b, (uint32_t)n, nodes));
  fb_link(b, rp[2], fb_pairs(b, (uint32_t)(2 * n), regions));
  msg_end(b, len_at);
  size_t base = b->n;
  kudfw_buf_zero(b, body);
  if (b->oom) {
    *why = "out of memory";
    return -1;
  }
  for (int i = 0; i < n; i++) {
    const struct ArrowArray* c = cols[i];
    int w = fmt_width(fmts[i]);
    if (nulls[i] > 0) {
      const uint8_t* v = (const uint8_t*)c->buffers[0];
      uint8_t* d = b->p + base + (size_t)regions[4 * i];
      for (int64_t r = 0; r < length; r++)
        if (bit(v, c->offset + r)) d[r >> 3] |= (uint8_t)(1u << (r & 7));
    }
    if (length > 0) {
      const uint8_t* src = (const uint8_t*)c->buffers[1];
      if (src == NULL) {
        *why = "an argument column has no values buffer";
        return -1;
      }
      memcpy(b->p + base + (size_t)regions[4 * i + 2], src + (size_t)c->offset * (size_t)w, (size_t)length * (size_t)w);
    }
  }
  return 0;
}

/* ---- flatbuffer reader, bounds-checked ------------------------------------ */

typedef struct fbr {
  const uint8_t* p;
  size_t n;
  int bad;
} fbr;

static uint32_t r32(fbr* r, size_t at) {
  uint32_t v = 0;
  if (at + 4 > r->n) {
    r->bad = 1;
    return 0;
  }
  memcpy(&v, r->p + at, 4);
  return v;
}

static uint16_t r16(fbr* r, size_t at) {
  uint16_t v = 0;
  if (at + 2 > r->n) {
    r->bad = 1;
    return 0;
  }
  memcpy(&v, r->p + at, 2);
  return v;
}

static int64_t r64(fbr* r, size_t at) {
  int64_t v = 0;
  if (at + 8 > r->n) {
    r->bad = 1;
    return 0;
  }
  memcpy(&v, r->p + at, 8);
  return v;
}

static size_t deref(fbr* r, size_t at) {
  size_t t = at + r32(r, at);
  if (t >= r->n) r->bad = 1;
  return r->bad ? 0 : t;
}

/* The position of `slot` in table `t`, or 0 when absent. */
static size_t field_at(fbr* r, size_t t, int slot) {
  int32_t so = (int32_t)r32(r, t);
  if (r->bad) return 0;
  int64_t v = (int64_t)t - so;
  if (v < 0 || (size_t)v + 4 > r->n) {
    r->bad = 1;
    return 0;
  }
  uint16_t vs = r16(r, (size_t)v);
  if ((size_t)(4 + 2 * slot) + 2 > vs) return 0;
  uint16_t fo = r16(r, (size_t)v + 4 + 2 * (size_t)slot);
  if (fo == 0) return 0;
  if (t + fo >= r->n) {
    r->bad = 1;
    return 0;
  }
  return t + fo;
}

/* ---- RecordBatch, read --------------------------------------------------- */

kudfw_hold* kudfw_hold_new(uint8_t* payload, size_t bytes, const komira_udf_host* host) {
  kudfw_hold* h = (kudfw_hold*)calloc(1, sizeof(*h));
  if (h == NULL) return NULL;
  atomic_init(&h->refs, 1);
  h->payload = payload;
  h->bytes = bytes;
  h->host = host;
  return h;
}

void kudfw_hold_drop(kudfw_hold* h) {
  if (h == NULL) return;
  if (atomic_fetch_sub_explicit(&h->refs, 1, memory_order_acq_rel) != 1) return;
  if (h->host != NULL && h->host->mem_release != NULL) h->host->mem_release(h->host->host_data, (int64_t)h->bytes);
  free(h->payload);
  free(h);
}

static void hold_ref(kudfw_hold* h) { atomic_fetch_add_explicit(&h->refs, 1, memory_order_relaxed); }

typedef struct col_priv {
  kudfw_hold* hold;
  const void* bufs[2];
} col_priv;

static void release_col(struct ArrowArray* a) {
  col_priv* p = (col_priv*)a->private_data;
  kudfw_hold_drop(p->hold);
  free(p);
  a->release = NULL;
}

int kudfw_ipc_decode(const uint8_t* msg, size_t len, const kudfw_field* fields, int n, int64_t* length,
                     kudfw_hold* hold, struct ArrowArray* cols, const char** why) {
  if (len < 8 || r32(&(fbr){msg, len, 0}, 0) != 0xFFFFFFFFu) {
    *why = "the reply is not an IPC message (no continuation marker)";
    return -1;
  }
  uint32_t meta = 0;
  memcpy(&meta, msg + 4, 4);
  if ((size_t)meta > len - 8 || meta % 8 != 0) {
    *why = "the IPC metadata length is past the payload or not a multiple of 8";
    return -1;
  }
  fbr r = {msg + 8, meta, 0};
  size_t m = deref(&r, 0);
  size_t ht = field_at(&r, m, 1);
  uint8_t htype = ht ? r.p[ht] : 0;
  size_t hs = field_at(&r, m, 2);
  size_t bl = field_at(&r, m, 3);
  int64_t body_len = bl ? r64(&r, bl) : 0;
  if (r.bad || htype != H_RECORD_BATCH || hs == 0) {
    *why = "the IPC message is not a RecordBatch";
    return -1;
  }
  size_t rb = deref(&r, hs);
  size_t lf = field_at(&r, rb, 0);
  int64_t rows = lf ? r64(&r, lf) : 0;
  size_t nf = field_at(&r, rb, 1);
  size_t bf = field_at(&r, rb, 2);
  if (field_at(&r, rb, 3) != 0) {
    *why = "the RecordBatch is compressed";
    return -1;
  }
  size_t nv = nf ? deref(&r, nf) : 0;
  size_t bv = bf ? deref(&r, bf) : 0;
  uint32_t n_nodes = nf ? r32(&r, nv) : 0;
  uint32_t n_bufs = bf ? r32(&r, bv) : 0;
  if (r.bad || rows < 0) {
    *why = "the RecordBatch metadata is malformed";
    return -1;
  }
  if (n_nodes != (uint32_t)n || n_bufs != 2u * (uint32_t)n) {
    *why = "the RecordBatch's columns or buffers differ from the bound schema";
    return -1;
  }
  if (body_len < 0 || (size_t)body_len > len - 8 - meta) {
    *why = "the RecordBatch body is longer than the payload";
    return -1;
  }
  if ((size_t)nv + 4 + 16 * (size_t)n > r.n || (size_t)bv + 4 + 32 * (size_t)n > r.n) {
    *why = "a node or buffer vector runs past the metadata";
    return -1;
  }
  const uint8_t* body = msg + 8 + meta;
  int built = 0;
  for (int i = 0; i < n; i++) {
    int64_t nlen = r64(&r, nv + 4 + 16 * (size_t)i);
    int64_t nnull = r64(&r, nv + 4 + 16 * (size_t)i + 8);
    int64_t vo = r64(&r, bv + 4 + 32 * (size_t)i), vl = r64(&r, bv + 4 + 32 * (size_t)i + 8);
    int64_t dofs = r64(&r, bv + 4 + 32 * (size_t)i + 16), dl = r64(&r, bv + 4 + 32 * (size_t)i + 24);
    int w = fmt_width(fields[i].fmt);
    const char* bad = NULL;
    if (nlen != rows) bad = "a column's length differs from the batch's";
    else if (nnull < 0 || nnull > nlen) bad = "a column's null count is out of range";
    else if (vo < 0 || vl < 0 || dofs < 0 || dl < 0 || vo > body_len - vl || dofs > body_len - dl)
      bad = "a buffer lies outside the body";
    /* dl / w, not nlen * w: the worker's row count can be large enough to
     * wrap the product. Past this check nlen <= dl / w <= body_len, so the
     * bitmap's (nlen + 7) / 8 cannot overflow either. */
    else if (dl / w < nlen) bad = "a values buffer is shorter than the column";
    else if (nnull > 0 && vl < (nlen + 7) / 8) bad = "a validity bitmap is shorter than the column";
    else if (((uintptr_t)(body + dofs)) % (uintptr_t)w != 0) bad = "a values buffer is not aligned to its type";
    if (bad != NULL) {
      *why = bad;
      for (int k = 0; k < built; k++) cols[k].release(&cols[k]);
      return -1;
    }
    col_priv* p = (col_priv*)calloc(1, sizeof(*p));
    if (p == NULL) {
      *why = "out of memory";
      for (int k = 0; k < built; k++) cols[k].release(&cols[k]);
      return -1;
    }
    hold_ref(hold);
    p->hold = hold;
    p->bufs[0] = nnull > 0 ? body + vo : NULL;
    p->bufs[1] = body + dofs;
    struct ArrowArray* a = &cols[i];
    memset(a, 0, sizeof(*a));
    a->length = nlen;
    a->null_count = nnull;
    a->n_buffers = 2;
    a->buffers = p->bufs;
    a->release = release_col;
    a->private_data = p;
    built++;
  }
  *length = rows;
  return 0;
}

/* ---- the host's `out` ------------------------------------------------------ */

typedef struct struct_priv {
  kudfw_hold* hold;
  const void* bufs[1];
  int n;
  struct ArrowArray** ptrs;
  struct ArrowArray* children;
} struct_priv;

static void release_struct(struct ArrowArray* a) {
  struct_priv* p = (struct_priv*)a->private_data;
  for (int i = 0; i < p->n; i++)
    if (p->children[i].release != NULL) p->children[i].release(&p->children[i]);
  kudfw_hold_drop(p->hold);
  free(p->children);
  free(p->ptrs);
  free(p);
  a->release = NULL;
}

static void set_cpu(struct ArrowDeviceArray* out) {
  out->device_id = -1;
  out->device_type = ARROW_DEVICE_CPU;
  out->sync_event = NULL;
  memset(out->reserved, 0, sizeof(out->reserved));
}

void kudfw_out_struct(struct ArrowDeviceArray* out, int64_t length, int n, struct ArrowArray* cols,
                      kudfw_hold* hold) {
  struct_priv* p = (struct_priv*)calloc(1, sizeof(*p));
  struct ArrowArray* children = (struct ArrowArray*)calloc((size_t)(n > 0 ? n : 1), sizeof(*children));
  struct ArrowArray** ptrs = (struct ArrowArray**)calloc((size_t)(n > 0 ? n : 1), sizeof(*ptrs));
  memset(out, 0, sizeof(*out));
  set_cpu(out);
  if (p == NULL || children == NULL || ptrs == NULL) {
    free(p);
    free(children);
    free(ptrs);
    for (int i = 0; i < n; i++) cols[i].release(&cols[i]);
    return; /* out->array.release stays NULL: the caller reports OOM */
  }
  for (int i = 0; i < n; i++) {
    children[i] = cols[i];
    cols[i].release = NULL;
    ptrs[i] = &children[i];
  }
  hold_ref(hold);
  p->hold = hold;
  p->n = n;
  p->ptrs = ptrs;
  p->children = children;
  out->array.length = length;
  out->array.n_buffers = 1;
  out->array.buffers = p->bufs;
  out->array.n_children = n;
  out->array.children = ptrs;
  out->array.release = release_struct;
  out->array.private_data = p;
}

void kudfw_out_column(struct ArrowDeviceArray* out, struct ArrowArray* col) {
  memset(out, 0, sizeof(*out));
  set_cpu(out);
  out->array = *col;
  col->release = NULL;
}

/* ---- bound schemas -------------------------------------------------------- */

static int leaf(const struct ArrowSchema* s, kudfw_field* f, const char** why) {
  if (s == NULL || s->format == NULL || s->format[0] == 0 || s->format[1] != 0 ||
      (s->format[0] != 'l' && s->format[0] != 'g' && s->format[0] != 'i') || s->n_children != 0) {
    *why = "a type the worker transport does not carry (int64, float64 and int32 only)";
    return -1;
  }
  f->fmt = s->format[0];
  f->nullable = (s->flags & ARROW_FLAG_NULLABLE) != 0;
  size_t k = s->name ? strlen(s->name) : 0;
  if (k >= sizeof(f->name)) {
    *why = "a field name longer than 63 bytes";
    return -1;
  }
  memcpy(f->name, s->name ? s->name : "", k + 1);
  return 0;
}

int kudfw_schema_read(const struct ArrowSchema* s, kudfw_schema* out, const char** why) {
  memset(out, 0, sizeof(*out));
  if (s == NULL) return 0;
  if (s->format != NULL && strcmp(s->format, "+s") == 0) {
    if (s->n_children > KUDFW_MAX_FIELDS) {
      *why = "more fields than the transport carries";
      return -1;
    }
    out->is_struct = 1;
    out->n = (int)s->n_children;
    for (int i = 0; i < out->n; i++)
      if (leaf(s->children[i], &out->f[i], why) != 0) return -1;
    return 0;
  }
  out->n = 1;
  return leaf(s, &out->f[0], why);
}
