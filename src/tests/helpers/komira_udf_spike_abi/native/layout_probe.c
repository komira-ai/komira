/*
 * The C compiler's view of komira_udf_runtime.h and komira_udf_wire.h, for
 * tests/test_layout.mojo, which compares every row with the Mojo mirror
 * (_cabi.mojo, contract.mojo, wire.mojo) and fails on any difference, on a
 * row only one side has, or on a table entry the probe does not list.
 *
 * Rows are `sizeof <type>`, `offsetof <type>.<field>`, `slot <entry>` (the
 * offset of a komira_udf_runtime entry, in table order), `const <NAME>`, and
 * `table_slots`: the entry count derived from sizeof(komira_udf_runtime), so
 * an entry appended to the header without a `slot` row here turns the test
 * red.
 */
#include <stddef.h>
#include <stdint.h>

#include "komira_udf_runtime.h"
#include "komira_udf_wire.h"

typedef struct ArrowSchema ArrowSchema;
typedef struct ArrowArray ArrowArray;
typedef struct ArrowArrayStream ArrowArrayStream;
typedef struct ArrowDeviceArray ArrowDeviceArray;
typedef struct ArrowDeviceArrayStream ArrowDeviceArrayStream;

typedef struct {
  const char* name;
  int64_t value;
} row;

#define S(T) {"sizeof " #T, (int64_t)sizeof(T)}
#define O(T, f) {"offsetof " #T "." #f, (int64_t)offsetof(T, f)}
#define E(f) {"slot " #f, (int64_t)offsetof(komira_udf_runtime, f)}
#define K(C) {"const " #C, (int64_t)(C)}

static const row ROWS[] = {
    S(ArrowSchema), O(ArrowSchema, format), O(ArrowSchema, name), O(ArrowSchema, metadata),
    O(ArrowSchema, flags), O(ArrowSchema, n_children), O(ArrowSchema, children),
    O(ArrowSchema, dictionary), O(ArrowSchema, release), O(ArrowSchema, private_data),

    S(ArrowArray), O(ArrowArray, length), O(ArrowArray, null_count), O(ArrowArray, offset),
    O(ArrowArray, n_buffers), O(ArrowArray, n_children), O(ArrowArray, buffers),
    O(ArrowArray, children), O(ArrowArray, dictionary), O(ArrowArray, release),
    O(ArrowArray, private_data),

    S(ArrowArrayStream), O(ArrowArrayStream, get_schema), O(ArrowArrayStream, get_next),
    O(ArrowArrayStream, get_last_error), O(ArrowArrayStream, release),
    O(ArrowArrayStream, private_data),

    S(ArrowDeviceArray), O(ArrowDeviceArray, array), O(ArrowDeviceArray, device_id),
    O(ArrowDeviceArray, device_type), O(ArrowDeviceArray, sync_event), O(ArrowDeviceArray, reserved),

    S(ArrowDeviceArrayStream), O(ArrowDeviceArrayStream, device_type),
    O(ArrowDeviceArrayStream, get_schema), O(ArrowDeviceArrayStream, get_next),
    O(ArrowDeviceArrayStream, get_last_error), O(ArrowDeviceArrayStream, release),
    O(ArrowDeviceArrayStream, private_data),

    S(komira_udf_error), O(komira_udf_error, struct_size), O(komira_udf_error, code),
    O(komira_udf_error, message), O(komira_udf_error, user_trace), O(komira_udf_error, row),
    O(komira_udf_error, group), O(komira_udf_error, release), O(komira_udf_error, private_data),

    S(komira_udf_host), O(komira_udf_host, struct_size), O(komira_udf_host, abi_major),
    O(komira_udf_host, abi_minor), O(komira_udf_host, host_data), O(komira_udf_host, mem_reserve),
    O(komira_udf_host, mem_release), O(komira_udf_host, now_ns), O(komira_udf_host, log),

    S(komira_udf_capabilities), O(komira_udf_capabilities, struct_size),
    O(komira_udf_capabilities, runtime_id), O(komira_udf_capabilities, runtime_abi),
    O(komira_udf_capabilities, max_descriptor_version), O(komira_udf_capabilities, shapes),
    O(komira_udf_capabilities, threading), O(komira_udf_capabilities, thread_affine),
    O(komira_udf_capabilities, transports), O(komira_udf_capabilities, hosting),
    O(komira_udf_capabilities, devices), O(komira_udf_capabilities, features),
    O(komira_udf_capabilities, udf_class), O(komira_udf_capabilities, global_lock),

    S(komira_udf_spec), O(komira_udf_spec, struct_size), O(komira_udf_spec, shape),
    O(komira_udf_spec, form), O(komira_udf_spec, entry), O(komira_udf_spec, descriptor_version),
    O(komira_udf_spec, descriptor), O(komira_udf_spec, descriptor_len), O(komira_udf_spec, args),
    O(komira_udf_spec, result), O(komira_udf_spec, state), O(komira_udf_spec, null_mode),
    O(komira_udf_spec, stability), O(komira_udf_spec, code_root), O(komira_udf_spec, n_code),
    O(komira_udf_spec, code_roles), O(komira_udf_spec, code_sha256),

    S(komira_udf_call), O(komira_udf_call, struct_size), O(komira_udf_call, deadline_ns),
    O(komira_udf_call, call_id), O(komira_udf_call, cancel),

    S(komira_udf_runtime), O(komira_udf_runtime, struct_size), O(komira_udf_runtime, abi_major),
    O(komira_udf_runtime, abi_minor),
    E(describe), E(validate), E(load), E(unload), E(open_context), E(close_context),
    E(open_instance), E(close_instance), E(call_batch), E(frame_open), E(frame_next),
    E(frame_close), E(agg_open), E(agg_update), E(agg_merge), E(agg_state), E(agg_finish),
    E(agg_close), E(shutdown), E(memory_report),
    {"table_slots",
     (int64_t)((sizeof(komira_udf_runtime) - offsetof(komira_udf_runtime, describe)) / sizeof(void*))},

    S(komira_udf_wire_header), O(komira_udf_wire_header, magic), O(komira_udf_wire_header, op),
    O(komira_udf_wire_header, request_id), O(komira_udf_wire_header, flags),
    O(komira_udf_wire_header, slot), O(komira_udf_wire_header, payload_offset),
    O(komira_udf_wire_header, payload_len),

    K(ARROW_FLAG_NULLABLE), K(ARROW_DEVICE_CPU),
    K(KOMIRA_UDF_ABI_MAJOR), K(KOMIRA_UDF_ABI_MINOR),
    K(KOMIRA_UDF_OK), K(KOMIRA_UDF_ERR_ABI), K(KOMIRA_UDF_ERR_DESCRIPTOR),
    K(KOMIRA_UDF_ERR_UNSUPPORTED), K(KOMIRA_UDF_ERR_CODE_DIGEST), K(KOMIRA_UDF_ERR_LOAD),
    K(KOMIRA_UDF_ERR_RAISED), K(KOMIRA_UDF_ERR_RETURN_TYPE), K(KOMIRA_UDF_ERR_LENGTH),
    K(KOMIRA_UDF_ERR_STATE_TOO_LARGE), K(KOMIRA_UDF_ERR_GROUP_TOO_LARGE),
    K(KOMIRA_UDF_ERR_CANCELLED), K(KOMIRA_UDF_ERR_DEADLINE), K(KOMIRA_UDF_ERR_OUT_OF_MEMORY),
    K(KOMIRA_UDF_ERR_INSTANCE_LOST), K(KOMIRA_UDF_ERR_INTERNAL), K(KOMIRA_UDF_ERR_FIELD_NOT_DECLARED),
    K(KOMIRA_UDF_SHAPE_SCALAR), K(KOMIRA_UDF_SHAPE_ROW), K(KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN),
    K(KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME), K(KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED),
    K(KOMIRA_UDF_SHAPE_AGG_PLAIN), K(KOMIRA_UDF_SHAPE_AGG_MERGEABLE), K(KOMIRA_UDF_SHAPE_STEP),
    K(KOMIRA_UDF_THREAD_SAFE), K(KOMIRA_UDF_CONTEXT_PER_THREAD), K(KOMIRA_UDF_SINGLE_THREAD),
    K(KOMIRA_UDF_TRANSPORT_IN_PROCESS), K(KOMIRA_UDF_TRANSPORT_WORKER),
    K(KOMIRA_UDF_HOSTING_NONE), K(KOMIRA_UDF_HOSTING_EMBEDDED),
    K(KOMIRA_UDF_HOSTING_HOST_INTERPRETER), K(KOMIRA_UDF_CLASS_NATIVE), K(KOMIRA_UDF_CLASS_MANAGED),
    K(KOMIRA_UDF_DEVICE_CPU),
    K(KOMIRA_UDF_FEATURE_MEMORY_REPORT),
    K(KOMIRA_UDF_FORM_PACKAGE), K(KOMIRA_UDF_FORM_BUNDLE), K(KOMIRA_UDF_FORM_VALUE),
    K(KOMIRA_UDF_NULL_MANUAL), K(KOMIRA_UDF_NULL_PROPAGATE),
    K(KOMIRA_UDF_IMMUTABLE), K(KOMIRA_UDF_STABLE), K(KOMIRA_UDF_VOLATILE),
    K(KOMIRA_UDF_WIRE_MAGIC), K(KOMIRA_UDF_WIRE_VERSION), K(KOMIRA_UDF_WIRE_HEADER_BYTES),
    K(KOMIRA_UDF_WIRE_INLINE), K(KOMIRA_UDF_WIRE_END),
    K(KOMIRA_UDF_OP_HELLO), K(KOMIRA_UDF_OP_DESCRIBE), K(KOMIRA_UDF_OP_VALIDATE),
    K(KOMIRA_UDF_OP_LOAD), K(KOMIRA_UDF_OP_UNLOAD), K(KOMIRA_UDF_OP_OPEN_CONTEXT),
    K(KOMIRA_UDF_OP_CLOSE_CONTEXT), K(KOMIRA_UDF_OP_OPEN_INSTANCE), K(KOMIRA_UDF_OP_CLOSE_INSTANCE),
    K(KOMIRA_UDF_OP_CALL_BATCH), K(KOMIRA_UDF_OP_FRAME_OPEN), K(KOMIRA_UDF_OP_FRAME_IN),
    K(KOMIRA_UDF_OP_FRAME_OUT), K(KOMIRA_UDF_OP_FRAME_CLOSE), K(KOMIRA_UDF_OP_AGG_OPEN),
    K(KOMIRA_UDF_OP_AGG_UPDATE), K(KOMIRA_UDF_OP_AGG_MERGE), K(KOMIRA_UDF_OP_AGG_STATE),
    K(KOMIRA_UDF_OP_AGG_FINISH), K(KOMIRA_UDF_OP_AGG_CLOSE), K(KOMIRA_UDF_OP_CANCEL),
    K(KOMIRA_UDF_OP_SHUTDOWN), K(KOMIRA_UDF_OP_OK), K(KOMIRA_UDF_OP_ERROR),
};

int64_t komira_udf_spike_layout_count(void) { return (int64_t)(sizeof(ROWS) / sizeof(ROWS[0])); }

/* The row's name, or NULL past the end. */
const char* komira_udf_spike_layout_name(int64_t i) {
  if (i < 0 || i >= komira_udf_spike_layout_count()) return NULL;
  return ROWS[i].name;
}

/* The row's value, or -1 past the end. */
int64_t komira_udf_spike_layout_value(int64_t i) {
  if (i < 0 || i >= komira_udf_spike_layout_count()) return -1;
  return ROWS[i].value;
}
