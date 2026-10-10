# =============================================================================
# FFI-BOUNDARY: plan_door_stub -- a test-only plan door with canned answers.
# =============================================================================
#
# The shared library `:plan_door_stub` (komira_plan_harness/BUCK) exports the
# six symbols of the door ABI that komira_plan_harness/door.mojo speaks (its
# header has the table), plus two counters only a test reads. It decodes
# nothing: it compares the WHOLE plan byte string with the plans below and
# answers each with a fixed result. tests/test_door_stub.mojo drives it
# through PlanDoor and holds the same byte strings.
#
#   PLAN_TABLE         the fixed table (id int64, name string?, score
#                      float64; rows 10/alpha/1.5, 20/NULL/-2.25,
#                      30/gamma/0.125), in two chunks: rows 0-1, row 2.
#                      Door A exports it as a stream of two batches, Door B
#                      as an Arrow IPC stream of two record batches.
#   PLAN_REFUSE        DOOR_ERR_ENGINE, last_error
#                      `PLAN_ENDPOINT_UNSUPPORTED_REMOTE_FS(10): ...`, and
#                      neither `*out` nor `*out_len` written.
#   PLAN_DIRTY_REFUSE  the same refusal, but it first writes `*out` (Door A)
#                      or `*out_len` (Door B): the producer fault the door must
#                      report.
#   PLAN_SHORT_FILL    Door B: the fill call copies and reports one byte fewer
#                      than the probe reported: the producer fault the door
#                      must report.
#   PLAN_OK_UNWRITTEN  Door A: DOOR_OK without writing `*out`.
#   PLAN_OK_RELEASED   Door A: DOOR_OK with `*out` a released (zeroed) struct.
#   PLAN_RELEASE_KEEPS_SLOT
#                      Door A: the table, but the stream's release callback,
#                      after releasing everything, leaves `release` non-NULL.
#   PLAN_OVERRUN       Door B: the fill copies the result and writes one more
#                      byte, at out[cap] (inside the guard bytes door.mojo
#                      allocates past cap), and reports the right length.
#   PLAN_FILL_REFUSE   Door B: the probe answers, the fill refuses
#                      (`PLAN_ENDPOINT_EXECUTION_FAILED(20): ...`) without
#                      writing `*out_len`.
#   PLAN_FILL_DIRTY_REFUSE
#                      the same, but the fill writes `*out_len` first.
#   anything else      DOOR_ERR_ENGINE, `PLAN_ENDPOINT_MALFORMED(5): ...`.
# A plan named for one door gets the table through the other one; each of
# the producer faults above is one the door must name (door.mojo's header).
#
# Every plan holds a NUL byte, so a door that measured the plan with strlen
# would send the wrong bytes and get the MALFORMED refusal.
#
# THE ASYNC RUNTIME. komira_ctx_new starts a komira_async
# PerCoreAsyncRuntime (four epoll workers, pthreads) inside this library and
# komira_ctx_free shuts it down and joins them. The `id` column of the table
# is computed by a fork-join wave on that runtime (fork_join_shared over the
# runtime's LocalDispatcher, one chunk per row), and each chunk records the
# thread it ran on: komira_plan_door_stub_pool_threads returns how many of
# them were not the caller's thread. So a table that matches proves a Mojo
# process dlopened a Mojo library whose own runtime ran work on its own
# threads, and came back.
#
# THE RELEASE COUNT. Door A's stream is komira_arrow_ipc's exported stream
# (build_record_batch_stream) wrapped in one of this file's: the outer
# stream's callbacks forward to the inner stream's, and its release callback
# counts one release on the session, releases the inner stream and frees
# both. komira_plan_door_stub_releases returns the count.
#
# Who owns and frees each pointer:
#   - ctx: a `_Session` allocated by komira_ctx_new; the caller owns it and
#     frees it once with komira_ctx_free (which joins the runtime's threads).
#   - last_error's text: the session's `err` bytes, valid until the next call.
#   - the plan: the caller's bytes, copied before anything else; no pointer
#     to them is kept.
#   - Door A: the caller's ArrowArrayStream is written once, on DOOR_OK; the
#     inner stream box and the `_CountedStream` behind its private_data are
#     this library's, freed by the release callback the caller calls once.
#     The release must come before komira_ctx_free (it counts on the session).
#   - Door B: `*out_len` is the caller's slot; `out` is the caller's buffer
#     of `cap` bytes, written only when `cap` is at least the length. The
#     parked result is the session's, dropped on the fill or the next plan.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc, unsafe_memcpy

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_interface import CArrowArray, CArrowSchema
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
    release_c_stream,
)
from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    encode_record_batch_message,
    encode_schema_message,
)
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_GENERIC_FORK_JOIN
from komira_async_api.fork_join_shared import fork_join_shared
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_async_api.token import CancellationToken
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _BytesPtr = UnsafePointer[UInt8, MutUntrackedOrigin]
comptime _U64Ptr = UnsafePointer[UInt64, MutUntrackedOrigin]
comptime _StreamPtr = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
comptime _SchemaPtr = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _ArrayPtr = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _ReleaseFn = def (_StreamPtr) thin -> None

# The door ABI version this library implements; door.mojo's
# PLAN_DOOR_ABI_VERSION must equal it.
comptime _ABI_VERSION: Int32 = 1

comptime _OK: Int32 = 0
comptime _ERR_NULL_CTX: Int32 = -1
comptime _ERR_NULL_ARG: Int32 = -2
comptime _ERR_ENGINE: Int32 = -3
comptime _ERR_BUFFER_TOO_SMALL: Int32 = -4

comptime _WORKERS = 4

comptime _UNKNOWN = 0
comptime _TABLE = 1
comptime _REFUSE = 2
comptime _DIRTY_REFUSE = 3
comptime _SHORT_FILL = 4
comptime _OK_UNWRITTEN = 5
comptime _OK_RELEASED = 6
comptime _OVERRUN = 7
comptime _RELEASE_KEEPS_SLOT = 8
comptime _FILL_REFUSE = 9
comptime _FILL_DIRTY_REFUSE = 10


def _classify(plan: List[UInt8]) -> Int:
    """Which canned plan `plan` is: 0x08 0x02 0x12 0x00 then one tag byte."""
    if len(plan) != 5:
        return _UNKNOWN
    if plan[0] != 0x08 or plan[1] != 0x02 or plan[2] != 0x12 or plan[3] != 0x00:
        return _UNKNOWN
    var tag = Int(plan[4])
    if tag >= _TABLE and tag <= _FILL_DIRTY_REFUSE:
        return tag
    return _UNKNOWN


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# --- the session -----------------------------------------------------------


struct _Session(Movable):
    var rt: PerCoreAsyncRuntime[NoopSink]
    var err: List[UInt8]
    var parked_key: List[UInt8]
    var parked: List[UInt8]
    var has_parked: Bool
    var releases: Int64
    var pool_threads: Int64

    def __init__(out self):
        self.rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
        self.err = [UInt8(0)]
        self.parked_key = List[UInt8]()
        self.parked = List[UInt8]()
        self.has_parked = False
        self.releases = 0
        self.pool_threads = 0

    def set_error(mut self, msg: String):
        var b = msg.as_bytes()
        self.err = List[UInt8](capacity=len(b) + 1)
        for i in range(len(b)):
            self.err.append(b[i])
        self.err.append(0)

    def clear_error(mut self):
        self.err = [UInt8(0)]

    def drop_park(mut self):
        self.parked = List[UInt8]()
        self.parked_key = List[UInt8]()
        self.has_parked = False


def _noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _session(ctx: _VoidPtr) -> UnsafePointer[_Session, MutUntrackedOrigin]:
    # SAFETY: `ctx` is non-NULL (checked by every caller) and came from
    # komira_ctx_new, so it addresses a live `_Session`.
    return ctx.bitcast[_Session]()


def _copy_plan(plan: _BytesPtr, n: UInt64) -> List[UInt8]:
    var out = List[UInt8](capacity=Int(n))
    for i in range(Int(n)):
        # SAFETY: the caller declared `plan[0, n)` readable.
        out.append(plan[i])
    return out^


# --- the fork-join wave that computes `id` -------------------------------------


@fieldwise_init
struct _IdWork(SharedChunkWork):
    """Chunk c writes payload[c] = input[c] * 10 and payload[n + c] = the
    thread it ran on.

    DISPATCH-BOUNDARY SAFETY: chunk c writes only slots c and n + c of the
    payload, which the driver pre-sized to 2n; the input is read-only."""

    var n: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P) raises:
        _ = n_chunks
        # SAFETY: the one dispatch site (_ids_on_pool) instantiates In and P
        # as List[Int64] and List[UInt64].
        var ip = UnsafePointer(to=input).bitcast[List[Int64]]()
        var pp = UnsafePointer(to=payload).bitcast[List[UInt64]]()
        pp[][chunk_id] = UInt64(ip[][chunk_id] * 10)
        pp[][self.n + chunk_id] = external_call["pthread_self", UInt64]()


@fieldwise_init
struct _Wave(Movable):
    var ids: List[Int64]
    var pool_threads: Int64


def _ids_on_pool[
    disp_o: Origin[mut=True]
](dispatcher: Pointer[LocalDispatcher[NoopSink], disp_o], base: List[Int64]) raises -> _Wave:
    """`base[c] * 10` for each c, each computed by one chunk of a fork-join
    wave on the session's runtime, and how many threads other than the
    caller's ran a chunk. `base` is a read-only borrow, so its origin is the
    immutable one fork_join_shared takes."""
    var n = len(base)
    var payload = List[UInt64](length=2 * n, fill=0)
    var out = fork_join_shared[
        _IdWork,
        List[Int64],
        List[UInt64],
        origin_of(base),
        LocalDispatcher[NoopSink],
        has_pool=True,
        disp_o=disp_o,
    ](
        _IdWork(n),
        base,
        payload^,
        n,
        2,
        0,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher),
        CancellationToken.never(),
        SITE_GENERIC_FORK_JOIN,
    )
    var me = external_call["pthread_self", UInt64]()
    var others = List[UInt64]()
    for c in range(n):
        var t = out[n + c]
        if t == me:
            continue
        var seen = False
        for k in range(len(others)):
            if others[k] == t:
                seen = True
        if not seen:
            others.append(t)
    var ids = List[Int64]()
    for c in range(n):
        ids.append(Int64(out[c]))
    return _Wave(ids^, Int64(len(others)))


# --- the fixed table -------------------------------------------------------------


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    sb.add_field(Field("name", ArrowType.STRING, nullable=True))
    sb.add_field(Field("score", ArrowType.FLOAT64, nullable=False))
    return sb.build()


def _batch(
    ids: List[Int64], names: List[String], valid: List[Bool], scores: List[Float64]
) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids.copy())))
    rbb.add_column(Column.from_string(StringArray.from_strings_with_validity(names.copy(), valid.copy())))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(scores.copy())))
    return rbb.build(_schema())


def _table_batches(mut sess: _Session) raises -> Slab[RecordBatch]:
    var base: List[Int64] = [1, 2, 3]
    var wave = _ids_on_pool(Pointer(to=sess.rt.dispatcher()), base)
    sess.pool_threads = wave.pool_threads
    ref ids = wave.ids
    var out = Slab[RecordBatch].with_capacity(2)
    out.append(
        _batch(
            [ids[0], ids[1]],
            [String("alpha"), String("")],
            [True, False],
            [Float64(1.5), Float64(-2.25)],
        )
    )
    out.append(_batch([ids[2]], [String("gamma")], [True], [Float64(0.125)]))
    return out^


def _append_frame(mut out: List[UInt8], frame: SharedAlignedBuffer[HeapRegion]):
    for i in range(frame.len()):
        out.append(frame.read_u8_at(i))


def _table_ipc(mut sess: _Session) raises -> List[UInt8]:
    """`[Schema][RecordBatch][RecordBatch][EOS]` of the fixed table."""
    var batches = _table_batches(sess)
    var out = List[UInt8]()
    _append_frame(out, encode_schema_message(_schema()))
    for i in range(len(batches)):
        var rb = batches.take_slot_unchecked(i)
        _append_frame(out, encode_record_batch_message(rb.take_columns()))
    batches.set_len_unchecked(0)
    _append_frame(out, arrow_ipc_eos_bytes())
    return out^


# --- the counted stream (Door A) ------------------------------------------------


struct _CountedStream(Movable):
    """Behind the exported stream's private_data: the inner stream komira_arrow_ipc
    built, and the session whose release count it bumps.

    # SAFETY: `inner` is this library's heap box, freed by `_counted_release`;
    # `session` is the caller's ctx, which the caller keeps alive until it has
    # released the stream (the file header's ownership list)."""

    var inner: _StreamPtr
    var session: UnsafePointer[_Session, MutUntrackedOrigin]
    var keep_slot: Bool

    def __init__(
        out self,
        inner: _StreamPtr,
        session: UnsafePointer[_Session, MutUntrackedOrigin],
        keep_slot: Bool,
    ):
        self.inner = inner
        self.session = session
        self.keep_slot = keep_slot


def _counted(stream: _VoidPtr) -> UnsafePointer[_CountedStream, MutUntrackedOrigin]:
    # SAFETY: `stream` is a live exported stream of this library, whose
    # private_data is the `_CountedStream` `_export_counted` stored.
    return stream.bitcast[CArrowArrayStream]()[].private_data.bitcast[_CountedStream]()


# SAFETY (the three forwarding callbacks below): the consumer calls them only
# on a live stream of this library, so `_counted(stream)` is the live
# `_CountedStream` and its `inner` the live stream komira_arrow_ipc built; the
# inner callbacks get the inner stream as their self, and the consumer's out
# struct passes through unread.
def _counted_get_schema(stream: _VoidPtr, out_schema: _SchemaPtr) abi("C") -> Int32:
    var inner = _counted(stream)[].inner
    return inner[].get_schema(inner.bitcast[NoneType](), out_schema)


def _counted_get_next(stream: _VoidPtr, out_array: _ArrayPtr) abi("C") -> Int32:
    var inner = _counted(stream)[].inner
    return inner[].get_next(inner.bitcast[NoneType](), out_array)


def _counted_get_last_error(stream: _VoidPtr) abi("C") -> UnsafePointer[Int8, MutUntrackedOrigin]:
    var inner = _counted(stream)[].inner
    return inner[].get_last_error(inner.bitcast[NoneType]())


def _release_inner(cs: UnsafePointer[_CountedStream, MutUntrackedOrigin]):
    """One release of the stream's state: counted, then the inner stream's
    batches freed (release_c_stream is the producer half, and komira_arrow_ipc
    produced the inner stream)."""
    # SAFETY: `cs` is the live `_CountedStream` of a stream being released;
    # its session outlives the stream (the caller releases before
    # komira_ctx_free), and `inner` is still allocated (freed after this).
    cs[].session[].releases += 1
    release_c_stream(cs[].inner)


def _counted_release(stream_ptr: _StreamPtr) -> None:
    """The exported stream's release callback: release the state once, free
    the two boxes, mark the caller's struct released (release = NULL)."""
    # SAFETY: `stream_ptr` is the consumer's struct, which this library
    # filled; a released one (release NULL) or a spent one (private_data NULL,
    # PLAN_RELEASE_KEEPS_SLOT's leftover) is left alone.
    if Int(stream_ptr) == 0 or stream_ptr[].is_released():
        return
    if Int(stream_ptr[].private_data) == 0:
        return
    var cs = _counted(stream_ptr.bitcast[NoneType]())
    var keep_slot = cs[].keep_slot
    _release_inner(cs)
    cs[].inner.free()
    # SAFETY: `cs` was allocated and initialised by `_export_counted`; this is
    # its one destruction, guarded by the two slots checked above.
    cs.destroy_pointee()
    cs.free()
    # SAFETY: the consumer's struct, rewritten as released (all callbacks the
    # no-op stubs, release and private_data NULL)...
    stream_ptr.unsafe_write(CArrowArrayStream())
    if keep_slot:
        # ...except for PLAN_RELEASE_KEEPS_SLOT, whose release stays set (to
        # this function, which the private_data check above makes a no-op):
        # the fault door.mojo must report.
        var f: _ReleaseFn = _counted_release
        stream_ptr[].release = UnsafePointer(to=f).bitcast[_VoidPtr]()[]


def _export_counted(
    var batches: Slab[RecordBatch],
    session: UnsafePointer[_Session, MutUntrackedOrigin],
    out_stream: _StreamPtr,
    keep_slot: Bool,
) raises:
    # SAFETY (the two allocations below): `inner` and `cs` are heap slots of
    # this library, untracked because they outlive this call (the consumer
    # holds the stream). Each is initialised by `unsafe_write` before any
    # read, and `_counted_release` frees both, once; `inner` is freed here
    # if build_record_batch_stream raises.
    var inner = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    inner.unsafe_write(CArrowArrayStream())
    try:
        build_record_batch_stream(batches^, _schema(), inner)
    except e:
        inner.free()
        raise e^
    var cs = alloc[_CountedStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    cs.unsafe_write(_CountedStream(inner, session, keep_slot))
    var outer = CArrowArrayStream()
    outer.get_schema = _counted_get_schema
    outer.get_next = _counted_get_next
    outer.get_last_error = _counted_get_last_error
    var f: _ReleaseFn = _counted_release
    # SAFETY: a thin fn-ptr and the struct's `void*` release slot are both one
    # machine word; the consumer reads the slot back as this function type
    # (komira_arrow_ipc's _set_stream_release does the same).
    outer.release = UnsafePointer(to=f).bitcast[_VoidPtr]()[]
    outer.private_data = cs.bitcast[NoneType]()
    # SAFETY: the caller's struct, written once, on success only.
    out_stream.unsafe_write(outer^)


# --- the C ABI ------------------------------------------------------------------


def _null_void() -> _VoidPtr:
    # SAFETY: Optional of a pointer has the bare pointer's layout and None is
    # NULL; returned to the caller as a C NULL, never dereferenced here.
    var none: Optional[_VoidPtr] = None
    return UnsafePointer(to=none).bitcast[_VoidPtr]()[]


@export
def komira_abi_version() abi("C") -> Int32:
    return _ABI_VERSION


@export
def komira_ctx_new() abi("C") -> _VoidPtr:
    """A session with a started runtime, or NULL."""
    # SAFETY: one heap slot for the session, untracked because the caller
    # holds it as a `void*` between calls. `unsafe_write` initialises it
    # before `p[]` is read; on a failed start the session is destroyed and
    # freed here, otherwise komira_ctx_free does both, once.
    var p = alloc[_Session](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(_Session())
    try:
        # Started in place: the runtime is not moved after its threads run.
        p[].rt.attach_workers(_WORKERS, _noop_sink, BACKEND_EPOLL)
        p[].rt.start()
    except e:
        print("plan_door_stub: komira_ctx_new: " + String(e))
        p.destroy_pointee()
        p.free()
        return _null_void()
    return p.bitcast[NoneType]()


@export
def komira_ctx_free(ctx: _VoidPtr) abi("C"):
    if Int(ctx) == 0:
        return
    var s = _session(ctx)
    try:
        s[].rt.shutdown()
    except e:
        print("plan_door_stub: komira_ctx_free: " + String(e))
    # SAFETY: the one destruction of the session komira_ctx_new made.
    s.destroy_pointee()
    s.free()


@export
def komira_last_error(ctx: _VoidPtr) abi("C") -> _BytesPtr:
    if Int(ctx) == 0:
        return _null_void().bitcast[UInt8]()
    # SAFETY: the session's NUL-terminated `err`, valid until the next call.
    return _session(ctx)[].err.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


@export
def komira_plan_door_stub_releases(ctx: _VoidPtr) abi("C") -> Int64:
    if Int(ctx) == 0:
        return -1
    return _session(ctx)[].releases


@export
def komira_plan_door_stub_pool_threads(ctx: _VoidPtr) abi("C") -> Int64:
    if Int(ctx) == 0:
        return -1
    return _session(ctx)[].pool_threads


comptime _REFUSAL = "PLAN_ENDPOINT_UNSUPPORTED_REMOTE_FS(10): the stub refuses this plan"
comptime _MALFORMED = "PLAN_ENDPOINT_MALFORMED(5): the stub knows no such plan"


@export
def komira_plan_stream(
    ctx: _VoidPtr, plan: _BytesPtr, plan_len: UInt64, out_stream: _StreamPtr
) abi("C") -> Int32:
    if Int(ctx) == 0:
        return _ERR_NULL_CTX
    if Int(plan) == 0 or Int(out_stream) == 0:
        return _ERR_NULL_ARG
    var s = _session(ctx)
    s[].clear_error()
    var which = _classify(_copy_plan(plan, plan_len))
    if which == _REFUSE or which == _DIRTY_REFUSE:
        if which == _DIRTY_REFUSE:
            # SAFETY: the caller's struct is writable (that is the contract);
            # writing it on a refusal is the fault this plan exists to show.
            out_stream.bitcast[UInt64]()[0] = 0
        s[].set_error(_REFUSAL)
        return _ERR_ENGINE
    if which == _UNKNOWN:
        s[].set_error(_MALFORMED)
        return _ERR_ENGINE
    if which == _OK_UNWRITTEN:
        return _OK
    if which == _OK_RELEASED:
        # SAFETY: the caller's struct, written as a released one.
        out_stream.unsafe_write(CArrowArrayStream())
        return _OK
    try:
        _export_counted(_table_batches(s[]), s, out_stream, which == _RELEASE_KEEPS_SLOT)
    except e:
        s[].set_error(String("PLAN_ENDPOINT_EXECUTION_FAILED(20): ") + String(e))
        return _ERR_ENGINE
    return _OK


@export
def komira_plan_bytes(
    ctx: _VoidPtr,
    plan: _BytesPtr,
    plan_len: UInt64,
    out_buf: _BytesPtr,
    out_cap: UInt64,
    out_len: _U64Ptr,
) abi("C") -> Int32:
    if Int(ctx) == 0:
        return _ERR_NULL_CTX
    if Int(plan) == 0 or Int(out_len) == 0:
        return _ERR_NULL_ARG
    var s = _session(ctx)
    s[].clear_error()
    var key = _copy_plan(plan, plan_len)
    var which = _classify(key)
    if which == _REFUSE or which == _DIRTY_REFUSE or which == _UNKNOWN:
        s[].drop_park()
        if which == _DIRTY_REFUSE:
            # SAFETY: the caller's slot; the fault this plan exists to show.
            out_len[] = 77
        s[].set_error(_MALFORMED if which == _UNKNOWN else _REFUSAL)
        return _ERR_ENGINE
    try:
        if not (s[].has_parked and _same_bytes(s[].parked_key, key)):
            s[].parked = _table_ipc(s[])
            s[].parked_key = key.copy()
            s[].has_parked = True
    except e:
        s[].drop_park()
        s[].set_error(String("PLAN_ENDPOINT_EXECUTION_FAILED(20): ") + String(e))
        return _ERR_ENGINE
    var need = len(s[].parked)
    var fill = out_cap >= UInt64(need) and Int(out_buf) != 0
    if fill and (which == _FILL_REFUSE or which == _FILL_DIRTY_REFUSE):
        s[].drop_park()
        if which == _FILL_DIRTY_REFUSE:
            # SAFETY: the caller's slot; the fault this plan exists to show.
            out_len[] = 77
        s[].set_error("PLAN_ENDPOINT_EXECUTION_FAILED(20): the stub refuses the fill")
        return _ERR_ENGINE
    # SAFETY: the caller's slot, written before the capacity test so the probe
    # gets its answer.
    out_len[] = UInt64(need)
    if out_cap < UInt64(need):
        return _ERR_BUFFER_TOO_SMALL
    if Int(out_buf) == 0:
        return _ERR_NULL_ARG
    var n = need
    if which == _SHORT_FILL:
        n = need - 1
        out_len[] = UInt64(n)
    # SAFETY: `out_buf` holds at least `out_cap >= need >= n` bytes.
    unsafe_memcpy(dest=out_buf, src=s[].parked.unsafe_ptr(), count=n)
    if which == _OVERRUN:
        # SAFETY: deliberately one byte past `cap`: inside the guard bytes
        # door.mojo allocates after `cap` (the fault this plan exists to show;
        # it is not safe against a caller without them).
        out_buf[need] = 0
    s[].drop_park()
    return _OK
