# =============================================================================
# join_probe_levers -- the streaming join probe's process setting for chunk
# buffer reuse, and the witness counters of its probe-key share and buffers.
# =============================================================================
#
# Two levers of the streaming probe (`join_probe_op`, not in this unit) record
# what they did here: the probe-key SHARE (a key column handed over by
# reference instead of copied; a decline is attributed to a validity bitmap or
# to a non-INT64 type) and chunk-BUFFER reuse (served from the worker's slot or
# by a fresh allocation). The counters are unconditional (one relaxed add per
# acquisition), so a zero means the site was never reached; the witness line
# (`join_probe_levers_line`, with the deferral verdicts appended) prints only
# under the scheduler trace, to stderr.
# =============================================================================

from std.atomic import Atomic
from std.ffi import _Global
from std.io import FileDescriptor
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_async.runtime.sched_trace import sched_trace_enabled

from .join_defer_verdict import defer_verdict_fields


def _init_jpl_i64() -> OwnedPointer[Atomic[DType.int64]]:
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


comptime _JPB_CFG = _Global["komira_join_probe_buf_reuse_cfg", _init_jpl_i64]

comptime _JKS_SHARED = _Global["komira_join_key_share_shared", _init_jpl_i64]
comptime _JKS_DECL_VAL = _Global[
    "komira_join_key_share_decl_validity", _init_jpl_i64
]
comptime _JKS_DECL_TYPE = _Global[
    "komira_join_key_share_decl_type", _init_jpl_i64
]

comptime _JPB_REUSE = _Global["komira_join_probe_buf_reuse", _init_jpl_i64]
comptime _JPB_FRESH = _Global["komira_join_probe_buf_fresh", _init_jpl_i64]


# fd 2: a query's stdout is its result stream.
comptime _JPL_STDERR: FileDescriptor = FileDescriptor(2)


def join_probe_buf_reuse_configure(on: Bool) raises:
    """Set the chunk-buffer reuse setting for this process (off by default):
    a probe takes its chunk buffers from a per-worker slot instead of a fresh
    allocation per chunk. Set once, from a flag, before any probe runs."""
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process lifetime); the wildcard origin is the stdlib API's
    # own return type and is confined to this function.
    _JPB_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](1 if on else 0))


def join_probe_buf_reuse_enabled() raises -> Bool:
    """Is chunk-buffer reuse on? Off unless configured."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    return Int(_JPB_CFG.get_or_create_ptr()[][].load()) > 0


def join_probe_buf_reuse_reset_config() raises:
    """TEST-ONLY. The setting back to its default (off)."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    _JPB_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def join_key_share_note_shared() raises:
    """One probe-key acquisition served by the Arc share (no memcpy)."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    var gp = _JKS_SHARED.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_key_share_note_declined(has_validity: Bool) raises:
    """One acquisition the gate wanted to share and `can_share_as_primitive`
    REFUSED — attributed to the condition that refused it.
    """
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    if has_validity:
        var gv = _JKS_DECL_VAL.get_or_create_ptr()
        _ = gv[][].fetch_add(Int64(1))
        return
    var gt = _JKS_DECL_TYPE.get_or_create_ptr()
    _ = gt[][].fetch_add(Int64(1))


def join_probe_buf_note(reused: Bool) raises:
    """One chunk-buffer acquisition, served from the per-worker slot (`reused`)
    or by a fresh `alloc` fallback.
    """
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    if reused:
        var gr = _JPB_REUSE.get_or_create_ptr()
        _ = gr[][].fetch_add(Int64(1))
        return
    var gf = _JPB_FRESH.get_or_create_ptr()
    _ = gf[][].fetch_add(Int64(1))


def join_key_share_shared_count() raises -> Int:
    """Probe-key acquisitions served by the share, process-wide."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    return Int(_JKS_SHARED.get_or_create_ptr()[][].load())


def join_key_share_declined_validity_count() raises -> Int:
    """Acquisitions declined because the key column carries a validity bitmap."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    return Int(_JKS_DECL_VAL.get_or_create_ptr()[][].load())


def join_key_share_declined_type_count() raises -> Int:
    """Acquisitions declined because the arrow_type is not INT64-compatible."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    return Int(_JKS_DECL_TYPE.get_or_create_ptr()[][].load())


def join_probe_buf_reuse_count() raises -> Int:
    """Chunk-buffer acquisitions served from the per-worker slot."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    return Int(_JPB_REUSE.get_or_create_ptr()[][].load())


def join_probe_buf_fresh_count() raises -> Int:
    """Chunk-buffer acquisitions that fell back to a fresh `alloc` while the
    gate was ON — a non-zero value here names a route with no resume slab.
    """
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    return Int(_JPB_FRESH.get_or_create_ptr()[][].load())


def reset_join_probe_lever_counters() raises:
    """TEST-ONLY: zero all five witnesses."""
    # SAFETY: FFI carve-out (see `join_probe_buf_reuse_configure`).
    _JKS_SHARED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JKS_DECL_VAL.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JKS_DECL_TYPE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPB_REUSE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPB_FRESH.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def join_probe_levers_trace_enabled() raises -> Bool:
    """Does the witness line print? Under the scheduler trace."""
    return sched_trace_enabled()


def join_key_share_why(share: Int, decl_validity: Int, decl_type: Int) -> StaticString:
    """Name the clause that decided the probe-key acquisitions, from the three
    counters: `shared_all`, `validity`, `type`, `declined_both`, `mixed`, or
    `unreached` when none was counted.
    """
    if share == 0 and decl_validity == 0 and decl_type == 0:
        return StaticString("unreached")
    if decl_validity == 0 and decl_type == 0:
        return StaticString("shared_all")
    if share > 0:
        return StaticString("mixed")
    if decl_validity > 0 and decl_type > 0:
        return StaticString("declined_both")
    if decl_validity > 0:
        return StaticString("validity")
    return StaticString("type")


def join_probe_levers_line(site: StaticString) raises -> String:
    """The witness line, as a String, so its TEXT is testable."""
    var sh = join_key_share_shared_count()
    var dv = join_key_share_declined_validity_count()
    var dt = join_key_share_declined_type_count()
    return (
        String("[JOIN_PROBE_LEVERS] at=")
        + String(site)
        + " share="
        + String(sh)
        + " decl_validity="
        + String(dv)
        + " decl_type="
        + String(dt)
        + " why="
        + String(join_key_share_why(sh, dv, dt))
        + " buf_reuse="
        + String(Int(join_probe_buf_reuse_enabled()))
        + " reuse="
        + String(join_probe_buf_reuse_count())
        + " fresh="
        + String(join_probe_buf_fresh_count())
        + defer_verdict_fields()
    )


def join_probe_levers_dump(site: StaticString) raises:
    """Print one cumulative witness line to stderr, under the scheduler trace."""
    if not join_probe_levers_trace_enabled():
        return
    print(join_probe_levers_line(site), file=_JPL_STDERR)
