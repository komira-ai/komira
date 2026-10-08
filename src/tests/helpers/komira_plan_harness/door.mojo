# =============================================================================
# FFI-BOUNDARY: komira_plan_harness/door.mojo -- a plan door, behind a safe API.
# =============================================================================
#
# A plan door is a shared library that executes a serialized plan
# (`komira.plan.v1.WirePlanEnvelope` bytes) and returns the result. This file
# dlopens one, whose path is given on the command line (`--plan-door=<path>`,
# door_path_from_args), and is the only code of the harness that touches its
# C ABI. Everything public here takes and returns values: plan bytes in,
# a komira_arrow Table (or an Arrow IPC byte list) out, a named error on any
# refusal or protocol fault. No pointer type appears in a public signature.
#
# The C ABI this file speaks (PLAN_DOOR_ABI_VERSION):
#
#   int32_t komira_abi_version(void)                    never fails
#   void   *komira_ctx_new(void)                        NULL if no engine
#   void    komira_ctx_free(void *ctx)                  NULL is a no-op
#   const char *komira_last_error(void *ctx)            "" when none
#   int32_t komira_plan_stream(void *ctx, const uint8_t *plan, uint64_t len,
#                              struct ArrowArrayStream *out)          Door A
#   int32_t komira_plan_bytes(void *ctx, const uint8_t *plan, uint64_t len,
#                             uint8_t *out, uint64_t cap, uint64_t *out_len)
#                                                                     Door B
#
# Return codes: DOOR_OK 0, DOOR_ERR_NULL_CTX -1, DOOR_ERR_NULL_ARG -2,
# DOOR_ERR_ENGINE -3 (a refusal: komira_last_error then begins
# `PLAN_ENDPOINT_<NAME>(<code>): `), DOOR_ERR_BUFFER_TOO_SMALL -4 (Door B's
# probe: `*out_len` holds the length needed). The plan's length is an
# argument because protobuf bytes hold NULs; so does Door B's output.
#
# The order of a session: open the library, call komira_abi_version and
# refuse a mismatch (PLAN_DOOR_ABI_MISMATCH) before any other symbol is
# bound, check every symbol resolves, then komira_ctx_new.
#
# Door A. The library fills a caller-owned ArrowArrayStream; the caller owns
# the stream from then on and releases it exactly once (Arrow C Stream
# Interface). This file drains it with komira_arrow_ipc's
# drain_record_batch_stream, which copies every buffer and calls the
# stream's own release callback, then checks that the callback marked the
# struct released (PLAN_DOOR_STREAM_NOT_RELEASED otherwise).
#
# Door B. A probe (`out` NULL, `cap` 0) returns DOOR_ERR_BUFFER_TOO_SMALL
# with the length; the fill call with a buffer of exactly that length must
# return DOOR_OK and report the SAME length (PLAN_DOOR_LENGTH_MISMATCH
# otherwise). Eight guard bytes past `cap` must be left as written
# (PLAN_DOOR_OVERRUN otherwise).
#
# DOOR_OK from Door A must come with every slot of `*out` written and its
# release set: PLAN_DOOR_OUT_NOT_WRITTEN and
# PLAN_DOOR_STREAM_RELEASED_ON_RETURN otherwise, raised before any callback
# is called.
#
# A refusal (DOOR_ERR_ENGINE, from Door A, or from Door B's probe or fill)
# must leave `*out` (Door A) and `*out_len` (Door B) as the caller wrote
# them: both are pre-filled with a sentinel, and a changed byte is
# PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL. An empty plan is PLAN_DOOR_EMPTY_PLAN,
# refused before any call. The refusal itself
# is PLAN_DOOR_REFUSED: <the library's last_error text>; parse_endpoint_refusal
# reads the name and the code back out of it.
#
# Who owns and frees each pointer:
#   - the OwnedDLHandle: allocated here, never freed, so the library is never
#     dlclosed. A Mojo library closed while its runtime's globals or threads
#     are live kills the process at exit (the same reason the dlopen gate
#     drivers of komira_arrow_ipc never close theirs). One leaked handle and
#     one loader reference per PlanDoor.open.
#   - ctx: created by komira_ctx_new, owned by the PlanDoor, freed exactly
#     once by komira_ctx_free in PlanDoor's destructor.
#   - the last_error text: owned by the library's session, valid until the
#     next call on it; copied into a String at once.
#   - the plan bytes: the caller's List, borrowed for one synchronous call.
#   - the ArrowArrayStream box (Door A): allocated and freed here, around one
#     call; the stream's own buffers belong to the library until its release
#     callback runs, and drain_record_batch_stream calls it.
#   - the `*out_len` slot and the output buffer (Door B): two Lists of the
#     call, passed by their own (tracked) pointers; the output List is
#     returned.
# =============================================================================

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.sys import size_of

from komira_arrow.schema import RecordBatch, Schema
from komira_arrow.table import Table
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    c_abi_stream_schema,
    consumer_release_c_stream,
    drain_record_batch_stream,
)
from komira_collections.slab import Slab

from .door_ipc import decode_ipc_stream

comptime PLAN_DOOR_ABI_VERSION: Int32 = 1
"""The version of the door ABI this harness speaks (the table above)."""

comptime PLAN_DOOR_FLAG = "--plan-door"
"""The flag naming the plan-door library: `--plan-door=<path>`."""

comptime DOOR_OK: Int32 = 0
comptime DOOR_ERR_NULL_CTX: Int32 = -1
comptime DOOR_ERR_NULL_ARG: Int32 = -2
comptime DOOR_ERR_ENGINE: Int32 = -3
comptime DOOR_ERR_BUFFER_TOO_SMALL: Int32 = -4

comptime _Void = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _Bytes = UnsafePointer[UInt8, MutUntrackedOrigin]

comptime _SENTINEL: UInt64 = 0xA5A5A5A5A5A5A5A5
comptime _STREAM_WORDS = 5
comptime _GUARD = 8
comptime _GUARD_BYTE: UInt8 = 0xCD
comptime _MAX_RESULT = 1 << 34
comptime _MAX_ERROR = 1 << 20


def door_path_from_args(args: List[String]) raises -> String:
    """The path given as `--plan-door=<path>` or `--plan-door <path>`.
    Raises PLAN_DOOR_FLAG_MISSING when neither is there or the value is
    empty, and PLAN_DOOR_FLAG_BAD_VALUE when the value starts with `--` (the
    next flag taken for the path)."""
    var prefix = String(PLAN_DOOR_FLAG) + "="
    for i in range(len(args)):
        var v = String("")
        if args[i].startswith(prefix):
            v = String(args[i][byte = prefix.byte_length() :])
        elif args[i] == PLAN_DOOR_FLAG and i + 1 < len(args):
            v = args[i + 1].copy()
        else:
            continue
        if v.startswith("--"):
            raise Error(
                String("PLAN_DOOR_FLAG_BAD_VALUE: ") + PLAN_DOOR_FLAG
                + " takes a path, not the flag `" + v + "`"
            )
        if v.byte_length() > 0:
            return v^
    raise Error(
        String("PLAN_DOOR_FLAG_MISSING: no ") + PLAN_DOOR_FLAG + "=<path> argument"
    )


@fieldwise_init
struct EndpointRefusal(Copyable, Movable, Writable):
    """A refusal's `PLAN_ENDPOINT_<NAME>(<code>): <detail>` text, read back."""

    var name: String
    var code: Int
    var detail: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.name, "(", self.code, "): ", self.detail)


def _digits_value(s: String) raises -> Int:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error("not a code")
    var v = 0
    for i in range(len(b)):
        if b[i] < 48 or b[i] > 57:
            raise Error("not a code")
        v = v * 10 + Int(b[i] - 48)
    return v


def parse_endpoint_refusal(text: String) raises -> EndpointRefusal:
    """Read `[PLAN_DOOR_REFUSED: ]PLAN_ENDPOINT_<NAME>(<code>): <detail>`.
    Raises PLAN_DOOR_REFUSAL_UNREADABLE when the text has another shape."""
    var lead = String("PLAN_DOOR_REFUSED: ")
    var s = String(text[byte = lead.byte_length() :]) if text.startswith(lead) else text.copy()
    var unreadable = Error(
        String("PLAN_DOOR_REFUSAL_UNREADABLE: not PLAN_ENDPOINT_<NAME>(<code>): ") + text
    )
    if not s.startswith("PLAN_ENDPOINT_"):
        raise unreadable
    var open = s.find("(")
    var close = s.find("): ")
    if open < 0 or close < open:
        raise unreadable
    var name = String(s[byte=:open])
    var code: Int
    try:
        code = _digits_value(String(s[byte = open + 1 : close]))
    except:
        raise unreadable
    var nb = name.as_bytes()
    for i in range(len(nb)):
        var c = nb[i]
        if not ((c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95):
            raise unreadable
    return EndpointRefusal(name^, code, String(s[byte = close + 3 :]))


def _code_name(rc: Int32) -> String:
    if rc == DOOR_OK:
        return String("DOOR_OK")
    if rc == DOOR_ERR_NULL_CTX:
        return String("DOOR_ERR_NULL_CTX")
    if rc == DOOR_ERR_NULL_ARG:
        return String("DOOR_ERR_NULL_ARG")
    if rc == DOOR_ERR_ENGINE:
        return String("DOOR_ERR_ENGINE")
    if rc == DOOR_ERR_BUFFER_TOO_SMALL:
        return String("DOOR_ERR_BUFFER_TOO_SMALL")
    return String("unknown code ") + String(Int(rc))


def _bad_return(symbol: String, rc: Int32, step: String) -> Error:
    return Error(
        String("PLAN_DOOR_BAD_RETURN: ") + symbol + " returned " + _code_name(rc)
        + " " + step
    )


def _require_plan(plan: List[UInt8]) raises:
    if len(plan) == 0:
        raise Error("PLAN_DOOR_EMPTY_PLAN: a plan is at least one byte (an empty List has no buffer to pass)")


def _null_bytes() -> _Bytes:
    # SAFETY: Optional of a pointer has the layout of the bare pointer, and
    # None is the all-zero (NULL) pattern; the result is only passed as a C
    # NULL argument, never dereferenced.
    var none: Optional[_Bytes] = None
    return UnsafePointer(to=none).bitcast[_Bytes]()[]


struct _DoorSession(Movable):
    """The two raw handles of a session; private to this file.

    # SAFETY: `lib` is a heap slot holding the library's OwnedDLHandle,
    # written once by `PlanDoor.open` and never freed (the file header says
    # why); `ctx` is the library's session, from komira_ctx_new, freed once
    # in `__deinit__`. Neither leaves this file.
    """

    var lib: UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]
    var ctx: _Void

    def __init__(out self, lib: UnsafePointer[OwnedDLHandle, MutUntrackedOrigin], ctx: _Void):
        self.lib = lib
        self.ctx = ctx

    def __deinit__(deinit self):
        # SAFETY: `ctx` came from komira_ctx_new and is freed only here; the
        # handle stays open (never dlclosed), so the symbol is still mapped.
        self.lib[].call["komira_ctx_free", NoneType](self.ctx)


def _door_symbols() -> List[String]:
    return [
        "komira_abi_version",
        "komira_ctx_new",
        "komira_ctx_free",
        "komira_last_error",
        "komira_plan_stream",
        "komira_plan_bytes",
    ]


struct PlanDoor(Movable):
    """One session on a plan-door library: the handshake done, a context
    open. Not Copyable: it owns the context, which its destructor frees."""

    var _s: _DoorSession
    var path: String
    var abi_version: Int32

    def __init__(out self, var session: _DoorSession, var path: String, abi_version: Int32):
        self._s = session^
        self.path = path^
        self.abi_version = abi_version

    @staticmethod
    def open(path: String, expected_abi: Int32 = PLAN_DOOR_ABI_VERSION) raises -> PlanDoor:
        """dlopen `path`, check its ABI version against `expected_abi`, check
        the six door symbols, open a context. Raises PLAN_DOOR_OPEN_FAILED,
        PLAN_DOOR_ABI_MISMATCH, PLAN_DOOR_MISSING_SYMBOL or
        PLAN_DOOR_CTX_NEW_FAILED. komira_abi_version is the first and, on a
        mismatch, the only symbol called."""
        # SAFETY: one heap slot for the OwnedDLHandle, re-originated to the
        # untracked origin because it outlives every Mojo scope: it is never
        # freed once written (the file header says why). Every `lib[]` below
        # reads that slot, which `unsafe_write` initialised before the first
        # one; on a raise the slot (and the library) leak by design.
        var lib = alloc[OwnedDLHandle](1).unsafe_origin_cast[MutUntrackedOrigin]()
        try:
            # SAFETY: `lib` is a fresh one-element allocation; written once.
            lib.unsafe_write(OwnedDLHandle(path))
        except e:
            lib.free()
            raise Error(String("PLAN_DOOR_OPEN_FAILED: ") + path + ": " + String(e))
        if not lib[].check_symbol("komira_abi_version"):
            raise Error(
                String("PLAN_DOOR_MISSING_SYMBOL: ") + path + " has no komira_abi_version"
            )
        var version = lib[].call["komira_abi_version", Int32]()
        if version != expected_abi:
            raise Error(
                String("PLAN_DOOR_ABI_MISMATCH: ") + path + " reports door ABI "
                + String(Int(version)) + ", the harness speaks "
                + String(Int(expected_abi))
            )
        var symbols = _door_symbols()
        for i in range(len(symbols)):
            if not lib[].check_symbol(symbols[i]):
                raise Error(
                    String("PLAN_DOOR_MISSING_SYMBOL: ") + path + " has no " + symbols[i]
                )
        # SAFETY: komira_ctx_new takes nothing and returns the session handle
        # this PlanDoor then owns (freed once by _DoorSession.__deinit__).
        var ctx = lib[].call["komira_ctx_new", _Void]()
        if Int(ctx) == 0:
            raise Error(String("PLAN_DOOR_CTX_NEW_FAILED: ") + path + ": komira_ctx_new returned NULL")
        return PlanDoor(_DoorSession(lib, ctx), path.copy(), version)

    def last_error(self) -> String:
        """The library's last error text for this session ("" when none)."""
        # SAFETY: `lib[]` is the handle slot `open` wrote (never freed);
        # `ctx` is this session's live handle. The result is borrowed text.
        var p = self._s.lib[].call["komira_last_error", _Bytes](self._s.ctx)
        if Int(p) == 0:
            return String("")
        # SAFETY: a NUL-terminated string owned by the session, valid until
        # the next call on it; read up to its NUL (or _MAX_ERROR bytes) and
        # copied before anything else is called.
        var out = List[UInt8]()
        var i = 0
        while i < _MAX_ERROR and p[i] != 0:
            out.append(p[i])
            i += 1
        return String(from_utf8_lossy=Span(out))

    def instrument[symbol: StaticString](self) raises -> Int64:
        """Call `int64_t <symbol>(void *ctx)`: a counter a test library
        exports beside the door symbols (a stub's release count, say). A
        library without the symbol is PLAN_DOOR_MISSING_SYMBOL, not a crash."""
        # SAFETY: `lib[]` is the handle slot `open` wrote (never freed); the
        # symbol is checked before the call, which passes this session's ctx.
        if not self._s.lib[].check_symbol(String(symbol)):
            raise Error(String("PLAN_DOOR_MISSING_SYMBOL: ") + self.path + " has no " + String(symbol))
        return self._s.lib[].call[symbol, Int64](self._s.ctx)

    def has_symbol(self, name: String) -> Bool:
        # SAFETY: `lib[]` is the handle slot `open` wrote (never freed).
        return self._s.lib[].check_symbol(name)

    def _refused(self) -> Error:
        return Error(String("PLAN_DOOR_REFUSED: ") + self.last_error())

    def plan_stream(mut self, plan: List[UInt8]) raises -> Table:
        """Door A: execute `plan`, drain the Arrow C stream it returns into a
        Table (every buffer copied), the stream released exactly once.
        Raises PLAN_DOOR_EMPTY_PLAN for an empty plan, before any call."""
        _require_plan(plan)
        # SAFETY: one heap slot for the ArrowArrayStream, untracked because
        # komira_arrow_ipc's C-stream functions take that origin; freed on
        # every path below. `words` views the same five pointer-sized slots as
        # UInt64s (size asserted next); every `words[i]` and `box[]` below
        # stays inside that one slot.
        var box = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
        var words = box.bitcast[UInt64]()
        comptime assert size_of[CArrowArrayStream]() == _STREAM_WORDS * 8, "ArrowArrayStream is five pointer slots"
        for i in range(_STREAM_WORDS):
            # SAFETY: the box holds _STREAM_WORDS words (asserted above).
            words[i] = _SENTINEL
        # SAFETY: `plan`'s buffer is borrowed for this synchronous call; the
        # library copies `len(plan)` bytes and keeps no pointer to them. The
        # box is ours, written by the library only on DOOR_OK.
        var rc = self._s.lib[].call["komira_plan_stream", Int32](
            self._s.ctx, plan.unsafe_ptr(), UInt64(len(plan)), box
        )
        if rc != DOOR_OK:
            var touched = False
            for i in range(_STREAM_WORDS):
                if words[i] != _SENTINEL:
                    touched = True
            box.free()
            if touched:
                raise Error(
                    "PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL: komira_plan_stream returned "
                    + _code_name(rc) + " and wrote its out_stream"
                )
            if rc == DOOR_ERR_ENGINE:
                raise self._refused()
            raise _bad_return("komira_plan_stream", rc, "for a non-NULL plan and out_stream")
        # DOOR_OK must mean a live stream: every slot written, release set.
        # Calling get_schema through an unwritten slot would jump to the
        # sentinel address.
        var unwritten = False
        for i in range(_STREAM_WORDS):
            if words[i] == _SENTINEL:
                unwritten = True
        if unwritten:
            box.free()
            raise Error(
                "PLAN_DOOR_OUT_NOT_WRITTEN: komira_plan_stream returned DOOR_OK and"
                " left out_stream (or a slot of it) as the caller wrote it"
            )
        if box[].is_released():
            box.free()
            raise Error(
                "PLAN_DOOR_STREAM_RELEASED_ON_RETURN: komira_plan_stream returned"
                " DOOR_OK with a released out_stream (release is NULL)"
            )
        # SAFETY (both calls): on DOOR_OK the library filled the box with a
        # live stream that this call now owns. c_abi_stream_schema calls
        # get_schema and does not release; drain_record_batch_stream calls
        # get_schema and get_next, copies every buffer, and calls the stream's
        # own release callback on every path, the raising ones included.
        var schema: Schema
        try:
            schema = c_abi_stream_schema(
                box.bitcast[NoneType](), box[].get_schema, box[].get_last_error
            )
        except e:
            consumer_release_c_stream(box)
            box.free()
            raise e^
        var batches: Slab[RecordBatch]
        try:
            batches = drain_record_batch_stream(box)
        except e:
            # SAFETY: the box is still allocated; after the drain it holds the
            # struct the release callback left (only `release` is read).
            var live = not box[].is_released()
            box.free()
            if live:
                raise Error(
                    String("PLAN_DOOR_STREAM_NOT_RELEASED: the drain failed and left the stream live: ")
                    + String(e)
                )
            raise e^
        # SAFETY: as above; the box is freed right after this read.
        var released = box[].is_released()
        box.free()
        if not released:
            raise Error(
                "PLAN_DOOR_STREAM_NOT_RELEASED: the stream's release callback ran"
                " and left its release slot set"
            )
        return Table.from_chunks(batches^, schema^)

    def plan_ipc_bytes(mut self, plan: List[UInt8]) raises -> List[UInt8]:
        """Door B: execute `plan` through the probe-then-fill protocol and
        return the Arrow IPC stream bytes it fills. Raises
        PLAN_DOOR_EMPTY_PLAN for an empty plan, before any call."""
        _require_plan(plan)
        # The `*out_len` slot and the output buffer are Lists of this call:
        # their pointers carry the Lists' own origins, and the Lists outlive
        # both calls (each is read after them).
        var len_slot: List[UInt64] = [_SENTINEL]
        # SAFETY: `plan` borrowed for the call (the library copies `len(plan)`
        # bytes and keeps no pointer); the probe's `out` is NULL with `cap`
        # 0, so the library may write only `len_slot[0]`.
        var rc = self._s.lib[].call["komira_plan_bytes", Int32](
            self._s.ctx, plan.unsafe_ptr(), UInt64(len(plan)), _null_bytes(), UInt64(0),
            len_slot.unsafe_ptr(),
        )
        var reported = len_slot[0]
        if rc == DOOR_ERR_ENGINE:
            if reported != _SENTINEL:
                raise Error(
                    "PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL: komira_plan_bytes refused the probe"
                    " and wrote out_len = " + String(reported)
                )
            raise self._refused()
        if rc != DOOR_ERR_BUFFER_TOO_SMALL:
            raise _bad_return("komira_plan_bytes", rc, "to the probe (out NULL, cap 0)")
        if reported == _SENTINEL or reported > UInt64(_MAX_RESULT):
            raise Error(
                "PLAN_DOOR_LENGTH_MISMATCH: the probe reported out_len = " + String(reported)
            )
        var need = Int(reported)
        # `need` bytes for the library, then _GUARD bytes it must not touch.
        var buf = List[UInt8](length=need + _GUARD, fill=_GUARD_BYTE)
        len_slot[0] = _SENTINEL
        # SAFETY: `buf` holds `need + _GUARD` bytes and `cap` says `need`, so
        # a conforming library writes `buf[0, need)` and `len_slot[0]` only.
        var rc2 = self._s.lib[].call["komira_plan_bytes", Int32](
            self._s.ctx, plan.unsafe_ptr(), UInt64(len(plan)), buf.unsafe_ptr(), UInt64(need),
            len_slot.unsafe_ptr(),
        )
        var filled = len_slot[0]
        for i in range(_GUARD):
            if buf[need + i] != _GUARD_BYTE:
                raise Error(
                    String("PLAN_DOOR_OVERRUN: komira_plan_bytes wrote past cap = ") + String(need)
                )
        if rc2 == DOOR_ERR_ENGINE:
            if filled != _SENTINEL:
                raise Error(
                    "PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL: komira_plan_bytes refused the fill"
                    " and wrote out_len = " + String(filled)
                )
            raise self._refused()
        if rc2 != DOOR_OK:
            raise _bad_return("komira_plan_bytes", rc2, "to the fill (cap = the probe's length)")
        if filled != UInt64(need):
            raise Error(
                String("PLAN_DOOR_LENGTH_MISMATCH: the probe reported ") + String(need)
                + " bytes, the fill reported " + String(filled)
            )
        buf.resize(need, 0)
        return buf^

    def plan_bytes(mut self, plan: List[UInt8]) raises -> Table:
        """Door B, decoded: the Table its Arrow IPC stream holds."""
        return decode_ipc_stream(self.plan_ipc_bytes(plan))
