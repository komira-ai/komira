/*
 * komira_udf_wire.h: the fixed header of every message of the UDF worker
 * protocol (docs/design/udf_runtime_interface.md section 5.2). Test-only, like
 * komira_udf_runtime.h beside it.
 *
 * A message is this 40-byte little-endian header on the control channel and
 * an optional payload of `payload_len` bytes, in shared-memory slot `slot` at
 * `payload_offset`, or (flag KOMIRA_UDF_WIRE_INLINE) following the header on
 * the control channel itself. A payload is Arrow IPC encapsulated messages: a
 * record batch, or for LOAD and OPEN the schemas. The protocol is private to
 * one build: HELLO refuses any difference of KOMIRA_UDF_WIRE_VERSION.
 *
 * Each table entry of komira_udf_runtime.h has exactly one request op; every
 * request is answered by OK or ERROR (ERROR carries a komira_udf_error with
 * its strings). Three requests have no table entry: HELLO (the init
 * negotiation), FRAME_IN (an input batch of a frame: the worker side of the
 * `in` stream's get_next) and CANCEL (the per-call cancel flag, sent out of
 * band). The optional memory_report entry has no op: in a worker the process's
 * resident memory is the authoritative number.
 */
#ifndef KOMIRA_UDF_WIRE_H
#define KOMIRA_UDF_WIRE_H

#include <stdint.h>

#define KOMIRA_UDF_WIRE_MAGIC 0x4644554Bu /* "KUDF" read as a little-endian u32 */
#define KOMIRA_UDF_WIRE_VERSION 1u
#define KOMIRA_UDF_WIRE_HEADER_BYTES 40u

typedef struct komira_udf_wire_header {
  uint32_t magic;
  uint32_t op;
  uint64_t request_id; /* a reply carries its request's id; CANCEL names the call it cancels */
  uint32_t flags;
  uint32_t slot;       /* shared-memory slot of the payload; unused with KOMIRA_UDF_WIRE_INLINE */
  uint64_t payload_offset;
  uint64_t payload_len; /* 0: no payload */
} komira_udf_wire_header;

/* flags */
#define KOMIRA_UDF_WIRE_INLINE (1u << 0) /* the payload follows the header on the control channel */
#define KOMIRA_UDF_WIRE_END (1u << 1)    /* FRAME_IN: end of input; OK to FRAME_OUT: end of output */

/* Requests, engine to worker. */
#define KOMIRA_UDF_OP_HELLO 1u
#define KOMIRA_UDF_OP_DESCRIBE 2u
#define KOMIRA_UDF_OP_VALIDATE 3u
#define KOMIRA_UDF_OP_LOAD 4u
#define KOMIRA_UDF_OP_UNLOAD 5u
#define KOMIRA_UDF_OP_OPEN_CONTEXT 6u
#define KOMIRA_UDF_OP_CLOSE_CONTEXT 7u
#define KOMIRA_UDF_OP_OPEN_INSTANCE 8u
#define KOMIRA_UDF_OP_CLOSE_INSTANCE 9u
#define KOMIRA_UDF_OP_CALL_BATCH 10u
#define KOMIRA_UDF_OP_FRAME_OPEN 11u
#define KOMIRA_UDF_OP_FRAME_IN 12u
#define KOMIRA_UDF_OP_FRAME_OUT 13u /* frame_next: pull one output batch */
#define KOMIRA_UDF_OP_FRAME_CLOSE 14u
#define KOMIRA_UDF_OP_AGG_OPEN 15u
#define KOMIRA_UDF_OP_AGG_UPDATE 16u
#define KOMIRA_UDF_OP_AGG_MERGE 17u
#define KOMIRA_UDF_OP_AGG_STATE 18u
#define KOMIRA_UDF_OP_AGG_FINISH 19u
#define KOMIRA_UDF_OP_AGG_CLOSE 20u
#define KOMIRA_UDF_OP_CANCEL 21u
#define KOMIRA_UDF_OP_SHUTDOWN 22u

/* Replies, worker to engine. */
#define KOMIRA_UDF_OP_OK 128u
#define KOMIRA_UDF_OP_ERROR 129u

#endif /* KOMIRA_UDF_WIRE_H */
