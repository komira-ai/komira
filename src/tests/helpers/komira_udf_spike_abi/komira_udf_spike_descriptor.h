/*
 * komira_udf_spike_descriptor.h: the descriptor of the spike runtimes,
 * version 1. Test-only. docs/design/udf_runtime_interface.md section 3.1
 * makes the descriptor runtime-owned: each runtime defines its own message.
 * The spike runtimes under src/tests/helpers share this one, so one decoder
 * (native/spike_descriptor.c) serves every runtime written in C, the
 * harness encodes it as a producer would (descriptor.mojo), and a runtime
 * in another language reads it with a decoder of its own.
 *
 * The message, in protobuf wire format:
 *
 *   message SpikeDescriptor {                 // descriptor_version 1
 *     string entry = 1;                       // the entry captured; equals code.entry
 *     uint32 shapes = 2;                      // the shape bits the entry supports
 *     repeated SpikeField args = 3;           // argument types in call order; not
 *                                             // used for ROW and MAP_BATCHES_FRAME
 *     repeated SpikeField result = 4;         // the result's field, or a table's columns
 *     bool result_is_table = 5;
 *     SpikeField state = 6;                   // a mergeable aggregate's state type
 *     RecordedFields recorded_fields = 7;     // ROW and MAP_BATCHES_FRAME, when known
 *   }
 *   message SpikeField { string name = 1; string format = 2; }   // stands for WireField:
 *                                             // a name and an Arrow C Data format string
 *   message RecordedFields {                  // as section 3.1 defines it
 *     repeated SpikeField fields = 1;
 *     repeated SpikeField key_fields = 2;
 *   }
 *
 * Canonical form (validate refuses anything else, ERR_DESCRIPTOR): fields in
 * ascending field number, each non-repeated field at most once and each
 * repeated field's entries together; no unknown field; no field holding its
 * default (an empty string, shapes 0, result_is_table false); varints in
 * their shortest form. recorded_fields has presence: emitted whenever it is
 * set, even when both lists are empty. In RecordedFields both lists ascend
 * by the UTF-8 bytes of the name, and a name appears once across both.
 */
#ifndef KOMIRA_UDF_SPIKE_DESCRIPTOR_H
#define KOMIRA_UDF_SPIKE_DESCRIPTOR_H

#include <stddef.h>
#include <stdint.h>

#include "komira_udf_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

#define KOMIRA_UDF_SPIKE_DESCRIPTOR_VERSION 1u
#define KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS 128

/* One SpikeField; both strings point into the decoded bytes (not
 * NUL-terminated). */
typedef struct {
  const uint8_t* name;
  size_t name_len;
  const uint8_t* format;
  size_t format_len;
} komira_udf_spike_field;

typedef struct {
  const uint8_t* entry;
  size_t entry_len;
  uint32_t shapes;
  size_t n_args;
  komira_udf_spike_field args[KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
  size_t n_result;
  komira_udf_spike_field result[KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
  int result_is_table;
  int has_state;
  komira_udf_spike_field state;
  int has_recorded;
  size_t n_fields;
  komira_udf_spike_field fields[KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
  size_t n_keys;
  komira_udf_spike_field keys[KOMIRA_UDF_SPIKE_DESCRIPTOR_MAX_FIELDS];
} komira_udf_spike_descriptor;

/* Decode `n` bytes as a canonical version-1 descriptor into *d: 0, or -1
 * with `why` saying what is not canonical. */
int komira_udf_spike_descriptor_decode(const uint8_t* bytes, size_t n, komira_udf_spike_descriptor* d, char* why,
                                       size_t why_len);

/* validate's comparison (section 3.1, "Every descriptor records the
 * signature"): the spec's descriptor_version and bytes, then the spec
 * against what the descriptor records. KOMIRA_UDF_OK with *d decoded, or
 * ERR_DESCRIPTOR or ERR_READ_SET_MISMATCH with `why` naming the field and
 * both values. `absent_fields_refused`: a ROW or MAP_BATCHES_FRAME
 * descriptor without recorded_fields is refused (the native runtime's rule,
 * section 3.1) rather than left unchecked. Opens no code. */
int32_t komira_udf_spike_descriptor_check(const komira_udf_spec* s, int absent_fields_refused,
                                          komira_udf_spike_descriptor* d, char* why, size_t why_len);

/* The design's name of an Arrow format ("int64" for "l"), or the format. */
const char* komira_udf_spike_type_name(const char* format, size_t len, char* buf, size_t buf_len);

#ifdef __cplusplus
}
#endif

#endif /* KOMIRA_UDF_SPIKE_DESCRIPTOR_H */
