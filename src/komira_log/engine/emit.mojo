# =============================================================================
# komira_log.engine.emit — the comptime hot-path emitter (P2a).
# =============================================================================
#
# The engine emit path: a parametric `emit_record[fmt, level,
# module, *ArgTs]` that
#   1. computes `comptime site_id = fnv1a_32(fmt)` and
#      `comptime module_id = fnv1a_32(module)` — literals at the call site,
#      ZERO runtime hash (the NanoLog property),
#   2. binary-encodes the args via a monomorphized `@parameter for` over the
#      `*ArgTs: LogArg` pack — NO runtime type dispatch, NO formatting, NO
#      per-record alloc beyond the inline blob / arena spill,
#   3. writes a fixed-stride `LogEventRecord` into the caller's per-core ring.
#
# The arg-blob wire format (symmetric with the drain decoder):
#   [ tag_0, tag_1, ..., tag_{n-1} | arg_bytes_0, arg_bytes_1, ... ]
# i.e. an n-byte tag table (n = n_args, carried in the record header) followed
# by each arg's raw encoded bytes (the `LogArg.encode_into` output). The blob
# fits inline in `arg_blob` when ≤ ARG_INLINE_BYTES; otherwise it spills to the
# ring arena and the record carries the (arg_off, arg_len) handle.
#
# Encapsulation: the `*ArgTs: LogArg` variadic passes TYPED values, never
# pointers (the typed-variadic pattern). No `UnsafePointer` crosses this
# API. The scratch blob is a function-local owned `List[UInt8]`. The record
# pushed onto the ring is POD.
# =============================================================================

from komira_log.log_arg import LogArg
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    FLAG_HAS_ARG_OVERFLOW,
    ARG_INLINE_BYTES,
)
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import fnv1a_32
from komira_log.engine.calibration import read_raw_ticks


# -----------------------------------------------------------------------------
# emit_record — the hot path. Computes the comptime ids, encodes the args, and
# pushes a fixed-stride record into `ring`. Returns False iff the ring dropped
# the record (full + DROP policy).
#
# `level` is a runtime UInt8 here (the facade's comptime level floor + the
# per-module gate live ABOVE this call, in the facade — P2b wires them). P2a's
# round-trip drives `emit_record` directly to exercise the engine core.
# -----------------------------------------------------------------------------


def emit_record[
    fmt: StringLiteral,
    module: StringLiteral,
    *ArgTs: LogArg,
](
    mut ring: LogRecordRing,
    level: UInt8,
    corr_id: UInt64,
    *args: *ArgTs,
) -> Bool:
    comptime site_id = fnv1a_32(fmt)
    comptime module_id = fnv1a_32(module)

    var ts = read_raw_ticks()

    # Monomorphized arg encode: tag table first (one byte per arg), then each
    # arg's raw bytes — straight-line, NO runtime type dispatch.
    comptime n = args.__len__()
    var blob = List[UInt8]()

    comptime for i in range(n):
        blob.append(args[i].arg_tag())

    comptime for i in range(n):
        args[i].encode_into(blob)

    var rec = LogEventRecord()
    rec.kind = REC_LOG
    rec.level = level
    rec.site_id = site_id
    rec.module_id = module_id
    rec.n_args = UInt8(n)
    rec.timestamp = ts
    rec.corr_id = corr_id

    var blob_len = len(blob)
    if blob_len <= ARG_INLINE_BYTES:
        # Inline path — copy into the record's fixed blob.
        for i in range(blob_len):
            rec.arg_blob[i] = blob[i]
        rec.arg_inline_len = UInt16(blob_len)
    else:
        # Spill path — stash the blob in the ring arena, carry the handle.
        var handle = ring.arena_append(blob)
        rec.flags = rec.flags | FLAG_HAS_ARG_OVERFLOW
        rec.arg_off = handle[0]
        rec.arg_len = handle[1]

    return ring.try_push(rec)
