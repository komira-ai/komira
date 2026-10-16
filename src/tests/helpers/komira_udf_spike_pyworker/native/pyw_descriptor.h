/*
 * A producer's descriptor for the specs this package's C probes and engine
 * loop build: the spike descriptor, version 1 (komira_udf_spike_descriptor.h),
 * in canonical protobuf form. It records the entry, the shape bits, each
 * argument's format and the result's format: what the runtime library's
 * validate compares with the spec. Names are left out (empty is the default,
 * and only ROW and MAP_BATCHES_FRAME, which this runtime does not declare,
 * compare them through recorded_fields). Test-only.
 */
#ifndef KOMIRA_UDF_PYW_DESCRIPTOR_H
#define KOMIRA_UDF_PYW_DESCRIPTOR_H

#include <stdint.h>
#include <string.h>

#include "komira_udf_runtime.h"

#define PYW_DESCRIPTOR_MAX 2048

static inline size_t pyw_pd_varint(uint8_t* o, uint64_t v) {
  size_t n = 0;
  while (v >= 0x80) {
    o[n++] = (uint8_t)(v | 0x80);
    v >>= 7;
  }
  o[n++] = (uint8_t)v;
  return n;
}

/* A string field, left out when empty (its default). */
static inline size_t pyw_pd_str(uint8_t* o, uint32_t field, const char* s) {
  size_t len = s != NULL ? strlen(s) : 0;
  if (len == 0) return 0;
  size_t n = pyw_pd_varint(o, ((uint64_t)field << 3) | 2);
  n += pyw_pd_varint(o + n, len);
  memcpy(o + n, s, len);
  return n + len;
}

/* A SpikeField of `format` alone, as field `field`. */
static inline size_t pyw_pd_field(uint8_t* o, uint32_t field, const char* format) {
  uint8_t in[64];
  size_t il = pyw_pd_str(in, 2, format);
  size_t n = pyw_pd_varint(o, ((uint64_t)field << 3) | 2);
  n += pyw_pd_varint(o + n, il);
  memcpy(o + n, in, il);
  return n + il;
}

/* The descriptor of a spec over `args` (a struct) to the one column
 * `result`, written into `o` (PYW_DESCRIPTOR_MAX bytes); its length. */
static inline size_t pyw_descriptor_encode(uint8_t* o, const char* entry, uint32_t shapes,
                                           const struct ArrowSchema* args, const struct ArrowSchema* result) {
  size_t n = pyw_pd_str(o, 1, entry);
  if (shapes != 0) {
    n += pyw_pd_varint(o + n, 2 << 3);
    n += pyw_pd_varint(o + n, shapes);
  }
  for (int64_t i = 0; args != NULL && i < args->n_children && i < 128; i++)
    n += pyw_pd_field(o + n, 3, args->children[i]->format);
  if (result != NULL) n += pyw_pd_field(o + n, 4, result->format);
  return n;
}

#endif /* KOMIRA_UDF_PYW_DESCRIPTOR_H */
