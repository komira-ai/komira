/*
 * udfpy_wire.h: the constants of the wire between this runtime library and
 * its zygote and workers (docs/design/udf_python_worker.md section 4). The
 * framing is private to this runtime: one 40-byte header, then a payload.
 * All integers are little-endian.
 *
 * Header: u32 magic, u32 op, u64 request_id, u32 flags, u32 slot (0),
 * u64 payload_offset (0), u64 payload_len.
 *
 * Every request payload is a 64-byte head, then the op's body:
 *   head = u64 handle, i64 deadline_ns_left (0: none), i64 call_id,
 *          u32 0, u32 0, 32 zero bytes
 * A reply (OK or ERROR) carries its request's id; its payload is the body.
 * An ERROR body is i32 code, i64 row, i64 group, str message, str trace,
 * where str is a u32 length and that many UTF-8 bytes. The OK reply of
 * UNLOAD is a u32, the UDFs the zygote still holds; that of CLOSE_INSTANCE is
 * a u32, the instances the worker still holds. EXIT is the one message
 * nobody asked for (request id 0).
 */
#ifndef UDFPY_WIRE_H
#define UDFPY_WIRE_H

#include <stdint.h>

#define UDFPY_MAGIC 0x4644554Bu
#define UDFPY_WIRE_VERSION 3u
#define UDFPY_HEADER_BYTES 40u
#define UDFPY_HEAD_BYTES 64u
#define UDFPY_MAX_PAYLOAD ((uint64_t)1 << 31)

#define UDFPY_FLAG_INLINE 1u
#define UDFPY_FLAG_RETIRE 4u
#define UDFPY_FLAG_RETRY 8u

#define UDFPY_OP_HELLO 1u
#define UDFPY_OP_LOAD 4u
#define UDFPY_OP_UNLOAD 5u
#define UDFPY_OP_OPEN_INSTANCE 8u
#define UDFPY_OP_CLOSE_INSTANCE 9u
#define UDFPY_OP_CALL_BATCH 10u
#define UDFPY_OP_SHUTDOWN 22u
#define UDFPY_OP_FORK 30u
#define UDFPY_OP_OK 128u
#define UDFPY_OP_ERROR 129u
#define UDFPY_OP_EXIT 130u

typedef struct udfpy_header {
  uint32_t magic;
  uint32_t op;
  uint64_t request_id;
  uint32_t flags;
  uint32_t slot;
  uint64_t payload_offset;
  uint64_t payload_len;
} udfpy_header;

#endif /* UDFPY_WIRE_H */
