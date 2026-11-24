/*
 * ipc_read.c: the checked reading of a worker's reply, an Arrow IPC
 * RecordBatch message, for every type the runtime carries (README "Types"),
 * nested types included.
 *
 * The worker is the boundary of untrusted code, so every flatbuffer offset is
 * bounds-checked, the layout is checked against the bound schema, and every
 * buffer against the body before a pointer into it is formed (design section
 * 4.4). The expected number of FieldNodes and Buffers is computed from the
 * schema's type tree and must match the message exactly. The tree is then
 * walked in pre-order with one cursor over the FieldNodes and one over the
 * Buffers, and each node is checked on its own: its length against what its
 * parent implies, its null count, each buffer's bounds, its validity bitmap,
 * its values (width, alignment), its offsets (entries, alignment, order, the
 * extent they address) and, for a utf8 type, each value's encoding. Lengths
 * and sizes are compared by division, never by a product a worker's number
 * could wrap.
 *
 * The result is one ArrowArray per node, each with its own private data (a
 * reference on the hold, its buffer pointers, its children), so a consumer
 * may move a child out of its parent. The arrays borrow the payload, which
 * was already copied out of the channel; the hold keeps it alive until the
 * last array is released. A refusal releases everything built so far.
 */
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "udfpy.h"

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

udfpy_hold* udfpy_hold_new(uint8_t* payload, size_t bytes, const komira_udf_host* host) {
  udfpy_hold* h = (udfpy_hold*)calloc(1, sizeof(*h));
  if (h == NULL) return NULL;
  atomic_init(&h->refs, 1);
  h->payload = payload;
  h->bytes = bytes;
  h->host = host;
  return h;
}

void udfpy_hold_drop(udfpy_hold* h) {
  if (h == NULL) return;
  if (atomic_fetch_sub_explicit(&h->refs, 1, memory_order_acq_rel) != 1) return;
  if (h->host != NULL && h->host->mem_release != NULL) h->host->mem_release(h->host->host_data, (int64_t)h->bytes);
  free(h->payload);
  free(h);
}

static void hold_ref(udfpy_hold* h) { atomic_fetch_add_explicit(&h->refs, 1, memory_order_relaxed); }

/* What one decoded node owns: its reference on the hold, the buffer pointers
 * its array points at, and the array of pointers to its children. */
typedef struct node_priv {
  udfpy_hold* hold;
  const void* bufs[3];
  struct ArrowArray** kids;
} node_priv;

/* Releases the children whose release is set, frees every child's struct (a
 * consumer that moved one out left only its release cleared), then drops the
 * node's own reference. A node that failed half way is released the same
 * way: a child not yet allocated is a NULL pointer. */
static void release_node(struct ArrowArray* a) {
  node_priv* p = (node_priv*)a->private_data;
  for (int64_t i = 0; i < a->n_children; i++) {
    struct ArrowArray* c = p->kids[i];
    if (c != NULL && c->release != NULL) c->release(c);
    free(c);
  }
  free(p->kids);
  udfpy_hold_drop(p->hold);
  free(p);
  a->release = NULL;
}

/* An offsets buffer of a length-0 node may be empty; the array then points at
 * this zero, which reads as the one offset of either width. */
static const int64_t zero_offset = 0;

typedef struct region {
  int64_t off, len;
} region;

typedef struct reader {
  fbr* r;
  size_t nv, bv; /* the node and buffer vectors */
  int node, buf; /* the cursors */
  const uint8_t* body;
  int64_t body_len;
  const udfpy_schema* s;
  udfpy_hold* hold;
  const char* why;
} reader;

static int bit(const uint8_t* v, int64_t i) { return (v[i >> 3] >> (i & 7)) & 1; }

/* The bytes of a bitmap of `n` bits; no product, no sum a large `n` could wrap. */
static int64_t bytes_for_bits(int64_t n) { return n / 8 + (n % 8 != 0); }

static int buffers_of(const udfpy_type* t) {
  switch (t->kind) {
    case UDFPY_K_UTF8:
    case UDFPY_K_BINARY:
      return 3;
    case UDFPY_K_STRUCT:
      return 1;
    default: /* fixed width, boolean, list */
      return 2;
  }
}

/* Whether `s[0..n)` is well-formed UTF-8: no overlong form, no surrogate
 * (U+D800..U+DFFF), nothing above U+10FFFF, no truncated sequence. */
static int utf8_valid(const uint8_t* s, size_t n) {
  size_t i = 0;
  while (i < n) {
    uint8_t c = s[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    size_t need; /* continuation bytes after the lead */
    uint8_t lo = 0x80, hi = 0xBF; /* the range of the first continuation */
    if (c >= 0xC2 && c <= 0xDF) {
      need = 1;
    } else if (c >= 0xE0 && c <= 0xEF) {
      need = 2;
      if (c == 0xE0) lo = 0xA0;
      else if (c == 0xED) hi = 0x9F;
    } else if (c >= 0xF0 && c <= 0xF4) {
      need = 3;
      if (c == 0xF0) lo = 0x90;
      else if (c == 0xF4) hi = 0x8F;
    } else {
      return 0;
    }
    if (n - i <= need) return 0;
    if (s[i + 1] < lo || s[i + 1] > hi) return 0;
    for (size_t k = 2; k <= need; k++)
      if ((s[i + k] & 0xC0) != 0x80) return 0;
    i += need + 1;
  }
  return 1;
}

static int64_t offset_at(const void* offs, int w, int64_t i) {
  if (w == 4) {
    int32_t v;
    memcpy(&v, (const uint8_t*)offs + 4 * (size_t)i, 4);
    return v;
  }
  int64_t v;
  memcpy(&v, (const uint8_t*)offs + 8 * (size_t)i, 8);
  return v;
}

/* The checks of an offsets buffer `ob` of a node of `len` values, offsets of
 * `w` bytes: (len + 1) entries, aligned to `w`, the first not negative, none
 * smaller than the one before. A length-0 node may have no offsets at all.
 * On success *offs is what the array points at and *last the final offset
 * (the extent the offsets address); NULL, or the refusal text. */
static const char* check_offsets(const reader* d, const region* ob, int w, int64_t len, const void** offs,
                                 int64_t* last) {
  if (len == 0 && ob->len == 0) {
    *offs = &zero_offset;
    *last = 0;
    return NULL;
  }
  int64_t entries = ob->len / w;
  if (entries < 1 || entries - 1 < len) return "an offsets buffer is shorter than the column";
  const uint8_t* p = d->body + ob->off;
  if (((uintptr_t)p) % (uintptr_t)w != 0) return "an offsets buffer is not aligned to its type";
  int64_t prev = offset_at(p, w, 0);
  if (prev < 0) return "offsets decrease or are negative";
  for (int64_t i = 1; i <= len; i++) {
    int64_t o = offset_at(p, w, i);
    if (o < prev) return "offsets decrease or are negative";
    prev = o;
  }
  *offs = p;
  *last = prev;
  return NULL;
}

/* Every non-null value of a utf8 node is valid UTF-8. The offsets have been
 * checked, and the data holds at least the last of them. */
static int utf8_values_valid(const uint8_t* valid, int64_t len, const void* offs, int w, const uint8_t* data) {
  for (int64_t i = 0; i < len; i++) {
    if (valid != NULL && !bit(valid, i)) continue;
    int64_t from = offset_at(offs, w, i), to = offset_at(offs, w, i + 1);
    if (!utf8_valid(data + from, (size_t)(to - from))) return 0;
  }
  return 1;
}

/* Decode the node at schema index `ti` into the zeroed `a`, then its subtree.
 * Its length must be `want` (`exact`) or at least `want`, else `len_why`. On
 * -1, d->why is set and nothing is left in `a` and below it. */
static int decode_node(reader* d, int ti, int64_t want, int exact, const char* len_why, struct ArrowArray* a) {
  const udfpy_type* t = &d->s->t[ti];
  int nb = buffers_of(t);
  size_t np = d->nv + 4 + 16 * (size_t)d->node;
  int64_t len = r64(d->r, np);
  int64_t nulls = r64(d->r, np + 8);
  region b[3];
  for (int k = 0; k < nb; k++) {
    size_t bp = d->bv + 4 + 16 * (size_t)(d->buf + k);
    b[k].off = r64(d->r, bp);
    b[k].len = r64(d->r, bp + 8);
  }
  d->node++;
  d->buf += nb;

  const char* bad = NULL;
  if (exact ? len != want : len < want) bad = len_why;
  else if (nulls < 0 || nulls > len) bad = "a column's null count is out of range";
  for (int k = 0; bad == NULL && k < nb; k++)
    if (b[k].off < 0 || b[k].len < 0 || b[k].off > d->body_len - b[k].len) bad = "a buffer lies outside the body";

  const void* offs = NULL;
  int64_t last = 0;
  int w = t->width;
  if (bad == NULL) {
    switch (t->kind) {
      case UDFPY_K_BOOL:
        if (b[1].len < bytes_for_bits(len)) bad = "a boolean values bitmap is shorter than the column";
        break;
      case UDFPY_K_UTF8:
      case UDFPY_K_BINARY:
      case UDFPY_K_LIST:
      case UDFPY_K_STRUCT:
        break;
      default: /* fixed width */
        /* b[1].len / w, not len * w: the worker's row count can be large
         * enough to wrap the product. Past this check len <= b[1].len / w <=
         * body_len, so a bitmap's byte count cannot overflow either. */
        if (b[1].len / w < len) bad = "a values buffer is shorter than the column";
        break;
    }
  }
  if (bad == NULL && nulls > 0 && b[0].len < bytes_for_bits(len)) bad = "a validity bitmap is shorter than the column";
  if (bad == NULL) {
    switch (t->kind) {
      case UDFPY_K_UTF8:
      case UDFPY_K_BINARY:
      case UDFPY_K_LIST:
        bad = check_offsets(d, &b[1], w, len, &offs, &last);
        if (bad == NULL && t->kind != UDFPY_K_LIST && last > b[2].len) bad = "an offset runs past the data";
        if (bad == NULL && t->kind == UDFPY_K_UTF8 &&
            !utf8_values_valid(nulls > 0 ? d->body + b[0].off : NULL, len, offs, w, d->body + b[2].off))
          bad = "a string is not valid UTF-8";
        break;
      case UDFPY_K_BOOL:
      case UDFPY_K_STRUCT:
        break;
      default: {
        int al = w < 8 ? w : 8;
        if (((uintptr_t)(d->body + b[1].off)) % (uintptr_t)al != 0) bad = "a values buffer is not aligned to its type";
        break;
      }
    }
  }
  if (bad != NULL) {
    d->why = bad;
    return -1;
  }

  node_priv* p = (node_priv*)calloc(1, sizeof(*p));
  if (p != NULL && t->n_children > 0) {
    p->kids = (struct ArrowArray**)calloc((size_t)t->n_children, sizeof(*p->kids));
    if (p->kids == NULL) {
      free(p);
      p = NULL;
    }
  }
  if (p == NULL) {
    d->why = "out of memory";
    return -1;
  }
  hold_ref(d->hold);
  p->hold = d->hold;
  p->bufs[0] = nulls > 0 ? d->body + b[0].off : NULL;
  switch (t->kind) {
    case UDFPY_K_UTF8:
    case UDFPY_K_BINARY:
      p->bufs[1] = offs;
      p->bufs[2] = d->body + b[2].off;
      break;
    case UDFPY_K_LIST:
      p->bufs[1] = offs;
      break;
    case UDFPY_K_STRUCT:
      break;
    default: /* fixed width, boolean */
      p->bufs[1] = d->body + b[1].off;
      break;
  }
  memset(a, 0, sizeof(*a));
  a->length = len;
  a->null_count = nulls;
  a->n_buffers = nb;
  a->buffers = p->bufs;
  a->n_children = t->n_children;
  a->children = p->kids;
  a->release = release_node;
  a->private_data = p;

  int ci = ti + 1;
  for (int i = 0; i < t->n_children; i++) {
    struct ArrowArray* c = (struct ArrowArray*)calloc(1, sizeof(*c));
    if (c == NULL) {
      d->why = "out of memory";
      a->release(a);
      return -1;
    }
    p->kids[i] = c;
    int rc = t->kind == UDFPY_K_LIST
                 ? decode_node(d, ci, last, 0, "a list child is shorter than its offsets", c)
                 : decode_node(d, ci, len, 1, "a struct child's length differs from the struct's", c);
    if (rc != 0) {
      a->release(a);
      return -1;
    }
    ci = d->s->t[ci].next;
  }
  return 0;
}

int udfpy_ipc_decode(const uint8_t* msg, size_t len, const udfpy_schema* s, int64_t* length, udfpy_hold* hold,
                     struct ArrowArray* cols, const char** why) {
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
  if (r.bad || htype != 3 /* RecordBatch */ || hs == 0) {
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
  /* The counts the bound types imply: one node per type node, and the
   * buffers each kind has. */
  uint32_t want_bufs = 0;
  for (int i = 0; i < s->n_nodes; i++) want_bufs += (uint32_t)buffers_of(&s->t[i]);
  if (n_nodes != (uint32_t)s->n_nodes || n_bufs != want_bufs) {
    *why = "the RecordBatch's columns or buffers differ from the bound schema";
    return -1;
  }
  if (body_len < 0 || (size_t)body_len > len - 8 - meta) {
    *why = "the RecordBatch body is longer than the payload";
    return -1;
  }
  if ((size_t)nv + 4 + 16 * (size_t)n_nodes > r.n || (size_t)bv + 4 + 16 * (size_t)n_bufs > r.n) {
    *why = "a node or buffer vector runs past the metadata";
    return -1;
  }
  reader d = {&r, nv, bv, 0, 0, msg + 8 + meta, body_len, s, hold, NULL};
  int ti = 0;
  for (int i = 0; i < s->n; i++) {
    if (decode_node(&d, ti, rows, 1, "a column's length differs from the batch's", &cols[i]) != 0) {
      *why = d.why;
      for (int k = 0; k < i; k++) cols[k].release(&cols[k]);
      return -1;
    }
    ti = s->t[ti].next;
  }
  *length = rows;
  return 0;
}

/* ---- the host's `out` ------------------------------------------------------ */

static void set_cpu(struct ArrowDeviceArray* out) {
  out->device_id = -1;
  out->device_type = ARROW_DEVICE_CPU;
  out->sync_event = NULL;
  memset(out->reserved, 0, sizeof(out->reserved));
}

void udfpy_out_column(struct ArrowDeviceArray* out, struct ArrowArray* col) {
  memset(out, 0, sizeof(*out));
  set_cpu(out);
  out->array = *col;
  col->release = NULL;
}
