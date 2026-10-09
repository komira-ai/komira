/*
 * Arrow C Data helpers of the reference runtimes (echo_runtime.c): reading
 * an input array's rows and building output arrays that free themselves.
 * Static functions, included once by each build of echo_runtime.c, which
 * defines BROKEN (0 or 1) before including this file.
 */
#ifndef KOMIRA_UDF_ECHO_ARROW_H
#define KOMIRA_UDF_ECHO_ARROW_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "komira_udf_runtime.h"

/* ---- reading inputs ------------------------------------------------------ */

static int64_t off_of(const struct ArrowArray* a) { return BROKEN ? 0 : a->offset; } /* BROKEN (5) */

static int is_valid(const struct ArrowArray* a, int64_t r) {
  const uint8_t* v = (const uint8_t*)a->buffers[0];
  int64_t at = off_of(a) + r;
  return v == NULL || ((v[at >> 3] >> (at & 7)) & 1);
}

static int64_t i64_at(const struct ArrowArray* a, int64_t r) {
  return ((const int64_t*)a->buffers[1])[off_of(a) + r];
}

static double f64_at(const struct ArrowArray* a, int64_t r) {
  return ((const double*)a->buffers[1])[off_of(a) + r];
}

static int32_t i32_at(const struct ArrowArray* a, int64_t r) {
  return ((const int32_t*)a->buffers[1])[off_of(a) + r];
}

static void release_array(struct ArrowArray* a) {
  if (a->release != NULL) a->release(a);
}

/* ---- building outputs ---------------------------------------------------- */

/* One malloc block per primitive array: its two-entry buffer list, the
 * validity bitmap, the values. The release frees the block. */
struct col_block {
  const void* bufs[2];
};

static void release_col(struct ArrowArray* a) {
  free(a->private_data);
  a->release = NULL;
}

static void set_cpu(struct ArrowDeviceArray* d) {
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  d->sync_event = NULL;
  d->reserved[0] = d->reserved[1] = d->reserved[2] = 0;
}

/* A primitive array of `n` rows of 8-byte values, every row valid; the
 * caller writes *data and clears validity bits for nulls. */
static int make_col(struct ArrowArray* a, int64_t n, uint8_t** validity, void** data) {
  size_t vbytes = (size_t)((n + 7) / 8);
  struct col_block* b = malloc(sizeof(struct col_block) + vbytes + (size_t)n * 8 + 8);
  if (b == NULL) return 0;
  uint8_t* v = (uint8_t*)(b + 1);
  memset(v, 0xFF, vbytes);
  void* d = (void*)(((uintptr_t)(v + vbytes) + 7) & ~(uintptr_t)7);
  b->bufs[0] = v;
  b->bufs[1] = d;
  a->length = n;
  a->null_count = 0;
  a->offset = 0;
  a->n_buffers = 2;
  a->n_children = 0;
  a->buffers = b->bufs;
  a->children = NULL;
  a->dictionary = NULL;
  a->release = release_col;
  a->private_data = b;
  *validity = v;
  *data = d;
  return 1;
}

static void set_null(struct ArrowArray* a, uint8_t* v, int64_t r) {
  v[r >> 3] &= (uint8_t)~(1u << (r & 7));
  a->null_count++;
}

static void release_struct(struct ArrowArray* a) {
  for (int64_t i = 0; i < a->n_children; i++) {
    release_array(a->children[i]);
    free(a->children[i]);
  }
  free(a->private_data);
  a->release = NULL;
}

/* A struct array of `n` rows whose `k` children the caller fills. */
static int make_struct(struct ArrowArray* a, int64_t n, int64_t k) {
  size_t bytes = sizeof(void*) + (size_t)k * sizeof(struct ArrowArray*);
  void** b = calloc(1, bytes);
  if (b == NULL) return 0;
  struct ArrowArray** kids = (struct ArrowArray**)(b + 1);
  for (int64_t i = 0; i < k; i++) {
    kids[i] = calloc(1, sizeof(struct ArrowArray));
  }
  a->length = n;
  a->null_count = 0;
  a->offset = 0;
  a->n_buffers = 1;
  a->n_children = k;
  a->buffers = (const void**)b; /* b[0] == NULL: no validity */
  a->children = k > 0 ? kids : NULL;
  a->dictionary = NULL;
  a->release = release_struct;
  a->private_data = b;
  return 1;
}

#endif /* KOMIRA_UDF_ECHO_ARROW_H */
