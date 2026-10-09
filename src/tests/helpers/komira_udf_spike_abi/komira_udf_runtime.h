/*
 * komira_udf_runtime.h: the UDF runtime C ABI, version 1.0, as
 * docs/design/udf_runtime_interface.md section 4.3 states it. Test-only: this
 * copy serves the conformance harness and the reference runtimes under
 * src/tests/helpers; nothing outside src/tests may include it.
 *
 * Plain C99, no include beyond <stdint.h> and <stddef.h>. The Arrow C Data,
 * C Stream and C Device structs are copied verbatim from the Arrow
 * specification under their standard include guards, so a runtime needs no
 * Arrow header. Every komira struct that crosses the ABI begins with
 * `size_t struct_size`; within a major version entries and fields are only
 * appended.
 *
 * Where the design names a value without a number (capability bits, the
 * threading and hosting values, CodeForm, null mode, stability), the number
 * is fixed here and marked "numbered here".
 */
#ifndef KOMIRA_UDF_RUNTIME_H
#define KOMIRA_UDF_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Arrow C Data Interface ------------------------------------------- */
#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE

#define ARROW_FLAG_DICTIONARY_ORDERED 1
#define ARROW_FLAG_NULLABLE 2
#define ARROW_FLAG_MAP_KEYS_SORTED 4

struct ArrowSchema {
  const char* format;
  const char* name;
  const char* metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema** children;
  struct ArrowSchema* dictionary;
  void (*release)(struct ArrowSchema*);
  void* private_data;
};

struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void** buffers;
  struct ArrowArray** children;
  struct ArrowArray* dictionary;
  void (*release)(struct ArrowArray*);
  void* private_data;
};

#endif /* ARROW_C_DATA_INTERFACE */

/* ---- Arrow C Stream Interface ----------------------------------------- */
#ifndef ARROW_C_STREAM_INTERFACE
#define ARROW_C_STREAM_INTERFACE

struct ArrowArrayStream {
  int (*get_schema)(struct ArrowArrayStream*, struct ArrowSchema* out);
  int (*get_next)(struct ArrowArrayStream*, struct ArrowArray* out);
  const char* (*get_last_error)(struct ArrowArrayStream*);
  void (*release)(struct ArrowArrayStream*);
  void* private_data;
};

#endif /* ARROW_C_STREAM_INTERFACE */

/* ---- Arrow C Device Data Interface ------------------------------------ */
#ifndef ARROW_C_DEVICE_DATA_INTERFACE
#define ARROW_C_DEVICE_DATA_INTERFACE

#define ARROW_DEVICE_CPU 1
#define ARROW_DEVICE_CUDA 2
#define ARROW_DEVICE_CUDA_HOST 3
#define ARROW_DEVICE_OPENCL 4
#define ARROW_DEVICE_VULKAN 7
#define ARROW_DEVICE_METAL 8
#define ARROW_DEVICE_VPI 9
#define ARROW_DEVICE_ROCM 10
#define ARROW_DEVICE_ROCM_HOST 11
#define ARROW_DEVICE_EXT_DEV 12
#define ARROW_DEVICE_CUDA_MANAGED 13
#define ARROW_DEVICE_ONEAPI 14
#define ARROW_DEVICE_WEBGPU 15
#define ARROW_DEVICE_HEXAGON 16

typedef int32_t ArrowDeviceType;

struct ArrowDeviceArray {
  struct ArrowArray array;
  int64_t device_id;
  ArrowDeviceType device_type;
  void* sync_event;
  int64_t reserved[3];
};

#endif /* ARROW_C_DEVICE_DATA_INTERFACE */

/* The Arrow specification puts the device stream under a guard of its own. */
#ifndef ARROW_C_DEVICE_STREAM_INTERFACE
#define ARROW_C_DEVICE_STREAM_INTERFACE

struct ArrowDeviceArrayStream {
  ArrowDeviceType device_type;
  int (*get_schema)(struct ArrowDeviceArrayStream* self, struct ArrowSchema* out);
  int (*get_next)(struct ArrowDeviceArrayStream* self, struct ArrowDeviceArray* out);
  const char* (*get_last_error)(struct ArrowDeviceArrayStream* self);
  void (*release)(struct ArrowDeviceArrayStream* self);
  void* private_data;
};

#endif /* ARROW_C_DEVICE_STREAM_INTERFACE */

/* ---- komira UDF runtime ABI ------------------------------------------- */

#define KOMIRA_UDF_ABI_MAJOR 1
#define KOMIRA_UDF_ABI_MINOR 0

typedef enum { /* 0 is success; values are never reused */
  KOMIRA_UDF_OK = 0,
  KOMIRA_UDF_ERR_ABI = 1,            /* major mismatch or missing minimum minor */
  KOMIRA_UDF_ERR_DESCRIPTOR = 2,     /* unknown descriptor_version, non-canonical bytes, bad entry */
  KOMIRA_UDF_ERR_UNSUPPORTED = 3,    /* shape, type or feature this runtime does not support */
  KOMIRA_UDF_ERR_CODE_DIGEST = 4,    /* a code object's bytes do not match its sha256 */
  KOMIRA_UDF_ERR_LOAD = 5,           /* import, compile or deserialize failed */
  KOMIRA_UDF_ERR_RAISED = 6,         /* user code raised; message and trace set */
  KOMIRA_UDF_ERR_RETURN_TYPE = 7,    /* user output not castable to the declared type */
  KOMIRA_UDF_ERR_LENGTH = 8,         /* column-form output length differs from input */
  KOMIRA_UDF_ERR_STATE_TOO_LARGE = 9,
  KOMIRA_UDF_ERR_GROUP_TOO_LARGE = 10,
  KOMIRA_UDF_ERR_CANCELLED = 11,
  KOMIRA_UDF_ERR_DEADLINE = 12,
  KOMIRA_UDF_ERR_OUT_OF_MEMORY = 13, /* refused by the host's memory hook, or the runtime's own */
  KOMIRA_UDF_ERR_INSTANCE_LOST = 14, /* the context cannot be used again; the host reopens it */
  KOMIRA_UDF_ERR_INTERNAL = 15,      /* a runtime bug; never user code */
  KOMIRA_UDF_ERR_FIELD_NOT_DECLARED = 16 /* ROW: user code read a field outside the read set; message names it */
} komira_udf_status;

/* capabilities.shapes and spec.shape: one bit per call shape, in the order
 * the design's capability table lists them (numbered here). */
#define KOMIRA_UDF_SHAPE_SCALAR (1u << 0)
#define KOMIRA_UDF_SHAPE_ROW (1u << 1)
#define KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN (1u << 2)
#define KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME (1u << 3)
#define KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED (1u << 4)
#define KOMIRA_UDF_SHAPE_AGG_PLAIN (1u << 5)
#define KOMIRA_UDF_SHAPE_AGG_MERGEABLE (1u << 6)
#define KOMIRA_UDF_SHAPE_STEP (1u << 7)

/* capabilities.threading: one value (numbered here). */
#define KOMIRA_UDF_THREAD_SAFE 1u
#define KOMIRA_UDF_CONTEXT_PER_THREAD 2u
#define KOMIRA_UDF_SINGLE_THREAD 3u

/* capabilities.transports: a mask (numbered here). */
#define KOMIRA_UDF_TRANSPORT_IN_PROCESS (1u << 0)
#define KOMIRA_UDF_TRANSPORT_WORKER (1u << 1)

/* capabilities.hosting: the mode a managed runtime is in (numbered here). A
 * native runtime reports 0, which the design names only as a number. */
#define KOMIRA_UDF_HOSTING_NONE 0u
#define KOMIRA_UDF_HOSTING_EMBEDDED 1u
#define KOMIRA_UDF_HOSTING_HOST_INTERPRETER 2u

/* capabilities.udf_class (numbered here, 0 refused). */
#define KOMIRA_UDF_CLASS_NATIVE 1u
#define KOMIRA_UDF_CLASS_MANAGED 2u

/* capabilities.devices: a mask (numbered here). */
#define KOMIRA_UDF_DEVICE_CPU (1u << 0)

/* capabilities.features: a mask (numbered here). */
#define KOMIRA_UDF_FEATURE_MEMORY_REPORT (1u << 0)

/* spec.form: CodeForm (numbered here, 0 refused). */
#define KOMIRA_UDF_FORM_PACKAGE 1
#define KOMIRA_UDF_FORM_BUNDLE 2
#define KOMIRA_UDF_FORM_VALUE 3

/* spec.null_mode and spec.stability (numbered here, 0 refused). */
#define KOMIRA_UDF_NULL_MANUAL 1
#define KOMIRA_UDF_NULL_PROPAGATE 2
#define KOMIRA_UDF_IMMUTABLE 1
#define KOMIRA_UDF_STABLE 2
#define KOMIRA_UDF_VOLATILE 3

typedef struct komira_udf_error { /* allocated by the host per call; filled by the runtime on failure */
  size_t struct_size;
  int32_t code;           /* a komira_udf_status */
  const char* message;    /* UTF-8, one line */
  const char* user_trace; /* mapped to the user's file and line where the runtime can; may be NULL */
  int64_t row;            /* row in the batch when known; -1 otherwise */
  int64_t group;          /* group ordinal when known; -1 otherwise */
  void (*release)(struct komira_udf_error*); /* frees the strings; NULL: nothing to free */
  void* private_data;
} komira_udf_error;

typedef struct komira_udf_host { /* provided by the engine; valid until shutdown returns */
  size_t struct_size;
  uint32_t abi_major, abi_minor;
  void* host_data; /* every callback below is thread-safe; none from a signal handler */
  int32_t (*mem_reserve)(void* host_data, int64_t bytes); /* OK or ERR_OUT_OF_MEMORY */
  void (*mem_release)(void* host_data, int64_t bytes);
  int64_t (*now_ns)(void* host_data); /* monotonic clock deadlines are read against */
  void (*log)(void* host_data, int32_t level, const char* utf8);
} komira_udf_host;

typedef struct komira_udf_capabilities {
  size_t struct_size;
  const char* runtime_id;  /* "<namespace>/<name>"; static for the runtime's life */
  const char* runtime_abi; /* may be empty */
  uint32_t max_descriptor_version;
  uint32_t shapes, threading, thread_affine, transports, hosting, devices, features;
  uint32_t udf_class;   /* NATIVE or MANAGED */
  uint32_t global_lock; /* 1 if user code is serialized across contexts; THREAD_SAFE requires 0 */
} komira_udf_capabilities;

typedef struct komira_udf_spec { /* the UdfRef, decoded by the host; borrowed for the call */
  size_t struct_size;
  int32_t shape; /* one bit of capabilities.shapes, fully resolved */
  int32_t form;  /* CodeForm */
  const char* entry;
  uint32_t descriptor_version;
  const uint8_t* descriptor;
  size_t descriptor_len;
  const struct ArrowSchema* args;   /* a struct schema, one child per arg_types entry; for ROW, the read set by name */
  const struct ArrowSchema* result; /* return_type; a struct for a table */
  const struct ArrowSchema* state;  /* state_type, or NULL */
  int32_t null_mode, stability;
  const char* code_root; /* directory holding code objects named by hex sha256 */
  size_t n_code;
  const char* const* code_roles;
  const uint8_t (*code_sha256)[32];
} komira_udf_spec;

typedef struct komira_udf_call {
  size_t struct_size;
  int64_t deadline_ns;           /* against host->now_ns; 0 = none */
  int64_t call_id;               /* stable across a retry of the same batch */
  const volatile int32_t* cancel; /* host-owned, alive until the call returns; nonzero = cancel */
} komira_udf_call;

typedef struct komira_udf_rt komira_udf_rt;             /* the runtime, once per process */
typedef struct komira_udf_udf komira_udf_udf;           /* a validated, loaded UDF */
typedef struct komira_udf_context komira_udf_context;   /* one interpreter or isolate */
typedef struct komira_udf_instance komira_udf_instance; /* one UDF inside one context */
typedef struct komira_udf_frame komira_udf_frame;       /* one frame, plain-aggregate or step call */
typedef struct komira_udf_groups komira_udf_groups;     /* the accumulators of many groups */

typedef struct komira_udf_runtime { /* static in the runtime; the host reads entries below struct_size */
  size_t struct_size;
  uint32_t abi_major, abi_minor;
  int32_t (*describe)(komira_udf_rt*, komira_udf_capabilities* out);
  int32_t (*validate)(komira_udf_rt*, const komira_udf_spec*, komira_udf_error*); /* pure; no user code */
  int32_t (*load)(komira_udf_rt*, const komira_udf_spec*, komira_udf_udf** out, komira_udf_error*);
  void (*unload)(komira_udf_udf*);
  int32_t (*open_context)(komira_udf_rt*, uint32_t slot, komira_udf_context** out, komira_udf_error*);
  void (*close_context)(komira_udf_context*);
  int32_t (*open_instance)(komira_udf_context*, komira_udf_udf*, komira_udf_instance** out,
                           komira_udf_error*);
  void (*close_instance)(komira_udf_instance*);
  /* SCALAR, ROW, MAP_BATCHES_COLUMN. args moved in; out moved out (release == NULL on failure). */
  int32_t (*call_batch)(komira_udf_instance*, const komira_udf_call*, struct ArrowDeviceArray* args,
                        struct ArrowDeviceArray* out, komira_udf_error*);
  /* MAP_BATCHES_FRAME (grouped or not), AGG_PLAIN, STEP. `in` is moved in. */
  int32_t (*frame_open)(komira_udf_instance*, const komira_udf_call*, struct ArrowDeviceArrayStream* in,
                        komira_udf_frame** out, komira_udf_error*);
  int32_t (*frame_next)(komira_udf_frame*, const komira_udf_call*, struct ArrowDeviceArray* out,
                        komira_udf_error*); /* end: OK with out->array.release == NULL */
  void (*frame_close)(komira_udf_frame*);
  /* AGG_MERGEABLE, vectorized over groups. group_ids: an int32 array, one per row; ids < n_groups. */
  int32_t (*agg_open)(komira_udf_instance*, komira_udf_groups** out, komira_udf_error*);
  int32_t (*agg_update)(komira_udf_groups*, const komira_udf_call*, struct ArrowDeviceArray* args,
                        struct ArrowDeviceArray* group_ids, uint32_t n_groups, komira_udf_error*);
  int32_t (*agg_merge)(komira_udf_groups*, const komira_udf_call*, struct ArrowDeviceArray* states,
                       struct ArrowDeviceArray* group_ids, uint32_t n_groups, komira_udf_error*);
  int32_t (*agg_state)(komira_udf_groups*, uint32_t emit_first_n, struct ArrowDeviceArray* out,
                       komira_udf_error*);
  int32_t (*agg_finish)(komira_udf_groups*, uint32_t emit_first_n, struct ArrowDeviceArray* out,
                        komira_udf_error*);
  void (*agg_close)(komira_udf_groups*);
  void (*shutdown)(komira_udf_rt*); /* after it returns: no release, no host callback */
  /* Optional (NULL when the feature bit is clear): */
  int64_t (*memory_report)(komira_udf_context*); /* bytes held outside Arrow buffers, or -1 */
} komira_udf_runtime;

/* The one exported symbol. Returns the runtime's static table, or NULL with *err filled. */
const komira_udf_runtime* komira_udf_runtime_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                     komira_udf_error* err);

#ifdef __cplusplus
}
#endif

#endif /* KOMIRA_UDF_RUNTIME_H */
