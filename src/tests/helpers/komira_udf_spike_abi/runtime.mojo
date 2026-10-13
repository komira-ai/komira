# The engine side of the UDF runtime contract, behind a value API: open a
# runtime library, drive its table, and check every result with the host's
# post-conditions (docs/design/udf_runtime_interface.md sections 4.3 to 4.6).
# It knows no runtime by name: everything it learns comes through describe.
#
# The values it takes and returns are spec.mojo's. Every call returns an
# Outcome: the runtime's status, message, trace, row and group, and `fault`, a post-condition the host found broken (a layout
# that fails import validation, a wrong length, a null in a non-nullable
# result, an input not moved whatever the status (then released here,
# once), `out` set on failure, an error row outside the batch, a frame that
# does not end). run_error() maps either to the run's named error through
# one table (contract.run_error).
#
# Handles are opaque: a Handle holds the runtime's pointer as a Word, which
# this file cannot read through, and its kind; it is passed back only to the
# entry of its kind.
#
# Contexts lost (design section 4.5): a status that loses its context
# (contract.loses_context: ERR_INSTANCE_LOST, ERR_WORKER_CRASHED, ERR_KILLED,
# ERR_OUT_OF_MEMORY) marks the context of the instance or groups object it
# came from. Any later call into an instance or groups object of that
# context raises UDF_HARNESS_LOST_CONTEXT_REUSED: nothing is retried after a
# loss. Closing them stays allowed, and is what the host does next.
#
# Bisection (design section 4.5, the ERR_RAISED row): call_batch bisects a
# batch that is not VOLATILE and raised with row -1, on the same instance.

from ._cabi import Word
from ._host import (
    Counts,
    arm_virtual_clock,
    disarm_virtual_clock,
    virtual_clock_on,
    _Arena,
    arm_cancel_on_clock,
    array_released,
    counts,
    device_column,
    device_stream,
    device_struct,
    disarm_cancel_on_clock,
    host_data_of,
    import_column,
    import_struct,
    make_host,
    new_error,
    new_host_data,
    pulls_of,
    release_out,
    release_stream,
    schema_of,
    stream_moved,
    stream_record,
    take_error,
)
from ._table import (
    cancel_flag_of,
    cancel_value,
    init_runtime,
    memory_report_present,
    new_call,
    new_caps,
    new_spec,
    open_library,
    read_caps,
    read_words,
    required_size,
    slot_value,
    t_agg_close,
    t_agg_finish,
    t_agg_merge,
    t_agg_open,
    t_agg_state,
    t_agg_update,
    t_call_batch,
    t_close_context,
    t_close_instance,
    t_describe,
    t_frame_close,
    t_frame_next,
    t_frame_open,
    t_load,
    t_memory_report,
    t_open_context,
    t_open_instance,
    t_shutdown,
    t_unload,
    t_validate,
    table_abi,
    table_size,
    time_calls,
    time_calls_mt,
    word_array,
)
from .contract import (
    ABI_MAJOR,
    ERR_RAISED,
    FEATURE_MEMORY_REPORT,
    NULL_PROPAGATE,
    OK,
    VOLATILE,
    loses_context,
    status_name,
)
from .values import Batch, Column, ColumnType, TYPE_INT32

from .spec import (
    CallOptions,
    CallResult,
    CallTimes,
    Capabilities,
    CodeObject,
    CodeSet,
    FrameResult,
    Handle,
    KIND_CONTEXT,
    KIND_FRAME,
    KIND_GROUPS,
    KIND_INSTANCE,
    KIND_UDF,
    Opened,
    Outcome,
    ThreadTimes,
    UdfSpec,
    _MAX_FRAME_OUTPUTS,
    _rows,
    descriptor_bytes,
    descriptor_for,
)


def _need(h: Handle, kind: Int) raises:
    if h.kind != kind:
        raise Error("UDF_HARNESS_HANDLE_KIND: " + String(h.kind) + ", wanted " + String(kind))


struct _Call(Copyable, Movable):
    """One komira_udf_call, and whether its cancel flag is armed on the
    host's clock."""

    var call: Word
    var armed: Bool
    var virtual: Bool

    def __init__(out self, call: Word, armed: Bool, virtual: Bool):
        self.call = call
        self.armed = armed
        self.virtual = virtual


struct UdfRuntime(Movable):
    """One loaded runtime library and its table."""

    var path: String
    var _arena: _Arena
    var _lib: Word
    var _table: Word
    var _rt: Word
    var _host: Word
    var _calls: Int64
    var _shut: Bool
    var _owner: List[Int]
    """Instances and groups objects by address, each beside its context's
    address in `_owner_ctx`."""
    var _owner_ctx: List[Int]
    var _lost: List[Int]
    """Contexts a status lost, by address, until they are closed."""
    var _lost_calls_allowed: Bool
    """Test-only (allow_calls_on_lost_contexts): a runtime's own test that
    checks what a lost context answers may call it."""

    def __init__(out self, path: String, var arena: _Arena, lib: Word, table: Word, rt: Word, host: Word):
        self.path = path
        self._arena = arena^
        self._lib = lib
        self._table = table
        self._rt = rt
        self._host = host
        self._calls = 0
        self._shut = False
        self._owner = List[Int]()
        self._owner_ctx = List[Int]()
        self._lost = List[Int]()
        self._lost_calls_allowed = False

    @staticmethod
    def open(path: String, abi_major: UInt32 = ABI_MAJOR) raises -> UdfRuntime:
        """dlopen `path`, init with a host claiming `abi_major` (this ABI's
        unless a test asks for another), and check the table covers every
        required entry. Raises UDF_RUNTIME_OPEN_FAILED,
        UDF_RUNTIME_MISSING_SYMBOL, UDF_RUNTIME_INIT or UDF_RUNTIME_ABI; and
        UDF_RUNTIME_FAULT when describe fails, after shutting it down. How a
        runtime executes is not a capability (design section 4.2), so
        nothing about it is refused here."""
        var arena = _Arena()
        var lib = open_library(path)
        var host = make_host(arena, abi_major, new_host_data(arena))
        var slot = arena.word(8)
        var err = new_error(arena)
        var t = init_runtime(lib, host, slot, err)
        var e = take_error(err)  # released whatever init returned (design 4.4)
        if t.is_null():
            arena.free_all()
            raise Error("UDF_RUNTIME_INIT: " + path + ": " + status_name(e.code) + " " + e.message)
        if table_abi(t) != ABI_MAJOR or table_size(t) < required_size():
            arena.free_all()
            raise Error(
                "UDF_RUNTIME_ABI: " + path + ": table major " + String(table_abi(t)) + ", "
                + String(table_size(t)) + " bytes; this host needs major " + String(ABI_MAJOR)
                + " and " + String(required_size()) + " bytes"
            )
        var rt = UdfRuntime(path, arena^, lib, t, slot_value(slot), host)
        _ = rt.describe()
        return rt^

    def init_refusal(mut self, abi_major: UInt32) -> Outcome:
        """Call init again with a host claiming `abi_major`: a runtime of
        another major must return NULL with ERR_ABI and create nothing. The
        second host counts into this runtime's ledger, so what that init
        reserves (an error's strings) shows in ledger()."""
        var host = make_host(self._arena, abi_major, host_data_of(self._host))
        var slot = self._arena.word(8)
        var err = new_error(self._arena)
        var t = init_runtime(self._lib, host, slot, err)
        var e = take_error(err)  # released whatever init returned (design 4.4)
        if not t.is_null():
            t_shutdown(t, slot_value(slot))
            return Outcome(OK, "", "", -1, -1, "UDF_RUNTIME_FAULT: init accepted ABI major " + String(abi_major))
        return Outcome(e.code, e.message, e.trace, e.row, e.group, "")

    def describe(mut self, fill: UInt8 = 0) raises -> Capabilities:
        """describe's answer. A non-zero `fill` is written over every byte of
        the struct first, so a field the runtime never writes reads back as
        that pattern instead of 0."""
        var c = new_caps(self._arena, fill)
        var rc = t_describe(self._table, self._rt, c)
        if rc != OK:
            raise Error("UDF_RUNTIME_FAULT: describe returned " + status_name(rc))
        var t = read_caps(c)
        return Capabilities(
            t.runtime_id, t.runtime_abi, t.words[0], t.words[1], t.words[2], t.words[3], t.words[4],
            memory_report_present(self._table),
        )

    def feature_slots_agree(mut self) raises -> Bool:
        """The MEMORY_REPORT feature bit is set exactly when the entry is."""
        var caps = self.describe()
        return ((caps.features & FEATURE_MEMORY_REPORT) != 0) == caps.has_memory_report

    def _spec(mut self, spec: UdfSpec) -> Word:
        var hd = host_data_of(self._host)
        var args = schema_of(self._arena, spec.args, spec.arg_names, True, hd)
        var result = schema_of(self._arena, spec.result, List[String](), spec.result_is_table, hd)
        var state = Word.null()
        if spec.state:
            state = schema_of(self._arena, [spec.state.value().copy()], List[String](), False, hd)
        var roles = List[String]()
        var digests = List[List[UInt8]]()
        for i in range(len(spec.code)):
            roles.append(spec.code[i].role)
            digests.append(spec.code[i].sha256.copy())
        return new_spec(
            self._arena, spec.shape, spec.form, spec.entry, spec.descriptor_version, descriptor_bytes(spec),
            args, result, state, spec.null_mode, spec.stability, spec.code_root, roles, digests,
        )

    def _outcome(mut self, rc: Int32, err: Word) -> Outcome:
        """The call's outcome. The error is released whatever the status
        (design section 4.4, the error row: the host calls `release` once
        when it is non-NULL), so an error a runtime filled and then returned
        OK on is released too; its text is dropped."""
        var e = take_error(err)
        if rc == OK:
            return Outcome.of(OK)
        return Outcome(rc, e.message, e.trace, e.row, e.group, "")

    def _opened(mut self, rc: Int32, err: Word, slot: Word, kind: Int) -> Opened:
        return Opened(self._outcome(rc, err), Handle(slot_value(slot) if rc == OK else Word.null(), kind))

    def validate(mut self, spec: UdfSpec) -> Outcome:
        var err = new_error(self._arena)
        return self._outcome(t_validate(self._table, self._rt, self._spec(spec), err), err)

    def load(mut self, spec: UdfSpec) -> Opened:
        var err = new_error(self._arena)
        var slot = self._arena.word(8)
        var rc = t_load(self._table, self._rt, self._spec(spec), slot, err)
        return self._opened(rc, err, slot, KIND_UDF)

    def unload(mut self, udf: Handle) raises:
        _need(udf, KIND_UDF)
        t_unload(self._table, udf._w)

    def open_context(mut self, slot_index: UInt32) -> Opened:
        var err = new_error(self._arena)
        var slot = self._arena.word(8)
        var rc = t_open_context(self._table, self._rt, slot_index, slot, err)
        return self._opened(rc, err, slot, KIND_CONTEXT)

    def close_context(mut self, ctx: Handle) raises:
        _need(ctx, KIND_CONTEXT)
        t_close_context(self._table, ctx._w)
        var a = ctx._w.addr()
        var kept = List[Int]()
        for i in range(len(self._lost)):
            if self._lost[i] != a:
                kept.append(self._lost[i])
        self._lost = kept^

    def _own(mut self, obj: Word, ctx: Int):
        self._owner.append(obj.addr())
        self._owner_ctx.append(ctx)

    def _disown(mut self, obj: Word):
        var a = obj.addr()
        for i in range(len(self._owner)):
            if self._owner[i] == a:
                _ = self._owner.pop(i)
                _ = self._owner_ctx.pop(i)
                return

    def _ctx_of(self, obj: Word) -> Int:
        """The context address of an instance or groups object, or 0."""
        var a = obj.addr()
        for i in range(len(self._owner)):
            if self._owner[i] == a:
                return self._owner_ctx[i]
        return 0

    def context_lost(self, ctx: Handle) -> Bool:
        """Whether a status lost `ctx` (design section 4.5)."""
        var a = ctx._w.addr()
        for i in range(len(self._lost)):
            if self._lost[i] == a:
                return True
        return False

    def lost_context_of(self, obj: Handle) -> Bool:
        """Whether the context of instance or groups object `obj` is lost."""
        var c = self._ctx_of(obj._w)
        for i in range(len(self._lost)):
            if self._lost[i] == c:
                return True
        return False

    def allow_calls_on_lost_contexts(mut self):
        """Test-only: stop refusing calls into a lost context, so a
        runtime's own test can check that such a call returns
        ERR_INSTANCE_LOST (design section 4.5) without running user code.
        The host never does this."""
        self._lost_calls_allowed = True

    def _live(self, obj: Handle, entry: String) raises:
        """Refuse a call into a lost context: nothing is retried after a
        loss (design section 4.5)."""
        if self.lost_context_of(obj) and not self._lost_calls_allowed:
            raise Error(
                "UDF_HARNESS_LOST_CONTEXT_REUSED: " + entry + " on an object of a context a status lost;"
                + " the host only closes it now"
            )

    def _note(mut self, obj: Handle, got: Outcome):
        """Mark the context of `obj` lost when `got` loses it."""
        if loses_context(got.status):
            var c = self._ctx_of(obj._w)
            if c != 0 and not self.lost_context_of(obj):
                self._lost.append(c)

    def open_instance(mut self, ctx: Handle, udf: Handle) raises -> Opened:
        _need(ctx, KIND_CONTEXT)
        _need(udf, KIND_UDF)
        var err = new_error(self._arena)
        var slot = self._arena.word(8)
        var rc = t_open_instance(self._table, ctx._w, udf._w, slot, err)
        var o = self._opened(rc, err, slot, KIND_INSTANCE)
        if rc == OK:
            self._own(o.handle._w, ctx._w.addr())
        return o^

    def close_instance(mut self, inst: Handle) raises:
        _need(inst, KIND_INSTANCE)
        t_close_instance(self._table, inst._w)
        self._disown(inst._w)

    def memory_report(mut self, ctx: Handle) raises -> Int64:
        """The entry's answer, or -2 when the runtime has no such entry."""
        _need(ctx, KIND_CONTEXT)
        if not memory_report_present(self._table):
            return -2
        return t_memory_report(self._table, ctx._w)

    def _begin(mut self, opts: CallOptions) -> _Call:
        self._calls += 1
        var deadline = Int64(0)
        if opts.deadline_passed:
            deadline = 1
        elif opts.deadline_after_ns > 0:
            deadline = arm_virtual_clock(host_data_of(self._host)) + opts.deadline_after_ns
        var call = new_call(self._arena, deadline, self._calls, opts.cancel)
        if opts.cancel_during_call:
            arm_cancel_on_clock(host_data_of(self._host), cancel_flag_of(call))
        return _Call(call, opts.cancel_during_call, opts.deadline_after_ns > 0 and not opts.deadline_passed)

    def _end(mut self, c: _Call):
        if c.armed:
            disarm_cancel_on_clock(host_data_of(self._host))
        if c.virtual:
            disarm_virtual_clock(host_data_of(self._host))

    def calls(self) -> Int64:
        """The calls started so far (call_batch, frames, agg_update and
        agg_merge, each one): the crossings a case can bound."""
        return self._calls

    def call_batch(mut self, inst: Handle, spec: UdfSpec, args: Batch, opts: CallOptions) raises -> CallResult:
        """One call_batch. Under PROPAGATE the host drops every row with a null
        argument before the call and scatters nulls back after it (design
        section 3.4 rule 2); an error's row, a row of the compacted batch the
        runtime saw, is mapped back to the caller's row. A row outside that
        batch is a fault (_call_batch) and is not mapped."""
        _need(inst, KIND_INSTANCE)
        self._live(inst, "call_batch")
        if spec.null_mode != NULL_PROPAGATE:
            return self._call_bisected(inst, spec, args, opts)
        var keep = List[Int]()
        for r in range(args.length):
            var all_valid = True
            for c in range(len(args.columns)):
                if not args.columns[c].valid[r]:
                    all_valid = False
            if all_valid:
                keep.append(r)
        var compact = Batch(len(keep))
        for c in range(len(args.columns)):
            var col = Column(args.columns[c].type_id)
            for k in range(len(keep)):
                col.bits.append(args.columns[c].bits[keep[k]])
                col.valid.append(True)
            compact.columns.append(col^)
        var res = self._call_bisected(inst, spec, compact, opts)
        if not res.outcome.is_ok():
            if res.outcome.row >= 0 and Int(res.outcome.row) < len(keep):
                res.outcome.row = Int64(keep[Int(res.outcome.row)])
            return res^
        var out = Column(res.column.type_id)
        var k = 0
        for r in range(args.length):
            if k < len(keep) and keep[k] == r:
                out.bits.append(res.column.bits[k])
                out.valid.append(res.column.valid[k])
                k += 1
            else:
                out.append_null()
        return CallResult(res.outcome.copy(), out^)

    def _call_bisected(mut self, inst: Handle, spec: UdfSpec, args: Batch, opts: CallOptions) -> CallResult:
        """_call_batch, then the bisection of design section 4.5: a batch
        that is not VOLATILE and raised with row -1 is split in two on the
        same instance, first half first, each half in turn, until a half
        reports a row (mapped to the batch's row) or a one-row half raises
        (that row). Any status other than OK or ERR_RAISED ends it with that
        status, carrying the original message; when no half raises, the
        original outcome stands."""
        var res = self._call_batch(inst, spec, args, opts)
        var o = res.outcome.copy()
        if o.status != ERR_RAISED or o.fault != "" or o.row != -1 or spec.stability == VOLATILE or args.length < 2:
            return res^
        var found = self._bisect(inst, spec, args, 0, args.length, opts, o)
        if found:
            return CallResult(found.value().copy(), res.column.copy())
        return res^

    def _bisect(
        mut self, inst: Handle, spec: UdfSpec, args: Batch, lo: Int, hi: Int, opts: CallOptions, first: Outcome
    ) -> Optional[Outcome]:
        """The outcome that ends bisection of rows [lo, hi), or None when no
        half of it raises."""
        var mid = (lo + hi) // 2
        var bounds: List[Int] = [lo, mid, mid, hi]
        for h in range(2):
            var a = bounds[2 * h]
            var b = bounds[2 * h + 1]
            if b <= a:
                continue
            if self.lost_context_of(inst):
                return None
            var half = self._call_batch(inst, spec, _rows(args, a, b), opts)
            var o = half.outcome.copy()
            if o.is_ok():
                continue
            if o.status != ERR_RAISED or o.fault != "":
                o.message = first.message
                return o^
            if o.row >= 0:
                o.row += Int64(a)
                return o^
            if b - a == 1:
                o.row = Int64(a)
                return o^
            var deeper = self._bisect(inst, spec, args, a, b, opts, first)
            if deeper:
                return deeper^
        return None

    def _call_batch(mut self, inst: Handle, spec: UdfSpec, args: Batch, opts: CallOptions) -> CallResult:
        var hd = host_data_of(self._host)
        var d_args = device_struct(self._arena, args, hd, opts.plant_extra_child, opts.plant_struct_offset)
        var d_out = self._arena.word(128)
        var err = new_error(self._arena)
        var c = self._begin(opts)
        var rc = t_call_batch(self._table, inst._w, c.call, d_args, d_out, err)
        self._end(c)
        var res = self._finish_column(rc, err, d_out, spec.result[0], args.length)
        self._stamp(res.outcome, spec, c)
        self._note(inst, res.outcome)
        var row = res.outcome.row
        if row < -1 or row >= Int64(args.length):
            # The error's row is "row in the batch when known; -1 otherwise"
            # (design 4.3, komira_udf_error): any other value is a runtime
            # bug, never a row of user code to report (4.5, ERR_INTERNAL).
            res.outcome.fault = (
                "UDF_RUNTIME_FAULT: error row " + String(row) + " is outside the batch of "
                + String(args.length) + " rows"
            )
        if not array_released(d_args):
            # Not moved, so still the host's: released here, once, and a
            # fault whatever the status (design section 4.4: moved on entry,
            # whatever status the runtime returns).
            _ = release_out(d_args)
            if res.outcome.fault == "":
                res.outcome.fault = "UDF_RUNTIME_FAULT: args not moved by call_batch"
        return res^

    def _stamp(self, mut o: Outcome, spec: UdfSpec, c: _Call):
        """The call's shape and cancel state, for the error table."""
        o.shape = spec.shape
        o.cancel_was_set = cancel_value(c.call)

    def _finish_column(mut self, rc: Int32, err: Word, d_out: Word, want: ColumnType, rows: Int) -> CallResult:
        """Import a column a runtime returned, with the post-conditions: the
        layout (an OK with no output is a released array, which import
        refuses), `rows` rows, no null in a non-nullable type."""
        var out = self._outcome(rc, err)
        if rc != OK:
            if not array_released(d_out):
                _ = release_out(d_out)
                out.fault = "UDF_RUNTIME_FAULT: out set on failure"
            return CallResult(out^, Column(want.type_id))
        var col = Column(want.type_id)
        try:
            col = import_column(d_out, want)
        except e:
            out.fault = String(e)
        if not release_out(d_out) and out.fault == "":
            out.fault = "UDF_RUNTIME_FAULT: release left its slot set"
        if out.fault == "" and len(col) != rows:
            out.fault = "UDF_BATCH_LENGTH_MISMATCH: " + String(len(col)) + " rows for " + String(rows)
        if out.fault == "" and not want.nullable and col.null_count() > 0:
            out.fault = "UDF_RETURN_TYPE_MISMATCH: a null in a non-nullable result"
        return CallResult(out^, col^)

    def run_frame(mut self, inst: Handle, spec: UdfSpec, inputs: List[Batch], opts: CallOptions) raises -> FrameResult:
        """frame_open over a stream of `inputs`, frame_next until the end,
        frame_close. Records how many input batches the runtime had pulled
        when it produced its first output (-1 when it produced none)."""
        _need(inst, KIND_INSTANCE)
        self._live(inst, "frame_open")
        var hd = host_data_of(self._host)
        var s = device_stream(self._arena, inputs, hd)
        var rec = stream_record(s)
        var err = new_error(self._arena)
        var slot = self._arena.word(8)
        var c = self._begin(opts)
        var rc = t_frame_open(self._table, inst._w, c.call, s, slot, err)
        var out = self._outcome(rc, err)
        # A stream frame_open did not move is still the host's. The runtime
        # may read it in place until frame_close, so it is released after
        # that, once, and the call is a fault, whatever frame_open returned.
        var kept = not stream_moved(s)
        var outputs = List[Batch]()
        var first = -1
        if rc == OK:
            var frame = slot_value(slot)
            var ended = False
            for _ in range(_MAX_FRAME_OUTPUTS + 1):
                var d_out = self._arena.word(128)
                var e2 = new_error(self._arena)
                var rc2 = t_frame_next(self._table, frame, c.call, d_out, e2)
                var got = self._outcome(rc2, e2)
                if rc2 != OK:
                    ended = True
                    out = got^
                    if not array_released(d_out):
                        _ = release_out(d_out)
                        out.fault = "UDF_RUNTIME_FAULT: out set on failure"
                    break
                if array_released(d_out):
                    ended = True
                    break
                if first < 0:
                    first = pulls_of(rec)
                try:
                    if spec.result_is_table:
                        outputs.append(import_struct(d_out, spec.result))
                    else:
                        var col = import_column(d_out, spec.result[0])
                        var b = Batch(len(col))
                        b.columns.append(col^)
                        outputs.append(b^)
                except e:
                    out.fault = String(e)
                if not release_out(d_out) and out.fault == "":
                    out.fault = "UDF_RUNTIME_FAULT: release left its slot set"
                if out.fault != "":
                    ended = True
                    break
            if not ended:
                out.fault = (
                    "UDF_RUNTIME_FAULT: frame_next did not end after " + String(len(outputs)) + " outputs"
                )
            t_frame_close(self._table, frame)
        if kept:
            release_stream(s)
            if out.fault == "":
                out.fault = "UDF_RUNTIME_FAULT: the input stream was not moved by frame_open"
        self._end(c)
        self._stamp(out, spec, c)
        self._note(inst, out)
        return FrameResult(out^, outputs^, first, pulls_of(rec))

    def agg_open(mut self, inst: Handle) raises -> Opened:
        _need(inst, KIND_INSTANCE)
        self._live(inst, "agg_open")
        var err = new_error(self._arena)
        var slot = self._arena.word(8)
        var rc = t_agg_open(self._table, inst._w, slot, err)
        var o = self._opened(rc, err, slot, KIND_GROUPS)
        self._note(inst, o.outcome)
        if rc == OK:
            self._own(o.handle._w, self._ctx_of(inst._w))
        return o^

    def _gids(mut self, gids: List[Int32]) -> Word:
        var col = Column(TYPE_INT32)
        for i in range(len(gids)):
            col.append_int(Int64(gids[i]))
        return device_column(self._arena, col, host_data_of(self._host))

    def _moved_check(self, mut got: Outcome, a: Word, b: Word, entry: String):
        """An input the runtime did not move is still the host's: released
        here, once, and a fault, whatever status the entry returned."""
        var kept = False
        if not array_released(a):
            _ = release_out(a)
            kept = True
        if not array_released(b):
            _ = release_out(b)
            kept = True
        if kept and got.fault == "":
            got.fault = "UDF_RUNTIME_FAULT: an input not moved by " + entry

    def agg_update(mut self, g: Handle, args: Batch, gids: List[Int32], n_groups: UInt32, opts: CallOptions) raises -> Outcome:
        _need(g, KIND_GROUPS)
        self._live(g, "agg_update")
        var d_args = device_struct(
            self._arena, args, host_data_of(self._host), opts.plant_extra_child, opts.plant_struct_offset
        )
        var d_gids = self._gids(gids)
        var err = new_error(self._arena)
        var c = self._begin(opts)
        var rc = t_agg_update(self._table, g._w, c.call, d_args, d_gids, n_groups, err)
        self._end(c)
        var out = self._outcome(rc, err)
        out.cancel_was_set = cancel_value(c.call)
        self._moved_check(out, d_args, d_gids, "agg_update")
        self._note(g, out)
        return out^

    def agg_merge(mut self, g: Handle, states: Column, gids: List[Int32], n_groups: UInt32, opts: CallOptions) raises -> Outcome:
        _need(g, KIND_GROUPS)
        self._live(g, "agg_merge")
        var d_states = device_column(self._arena, states, host_data_of(self._host))
        var d_gids = self._gids(gids)
        var err = new_error(self._arena)
        var c = self._begin(opts)
        var rc = t_agg_merge(self._table, g._w, c.call, d_states, d_gids, n_groups, err)
        self._end(c)
        var out = self._outcome(rc, err)
        out.cancel_was_set = cancel_value(c.call)
        self._moved_check(out, d_states, d_gids, "agg_merge")
        self._note(g, out)
        return out^

    def agg_state(mut self, g: Handle, emit_first_n: UInt32, state_type: ColumnType) raises -> CallResult:
        """A PARTIAL step's states: `emit_first_n` rows of state_type."""
        _need(g, KIND_GROUPS)
        self._live(g, "agg_state")
        var d_out = self._arena.word(128)
        var err = new_error(self._arena)
        var rc = t_agg_state(self._table, g._w, emit_first_n, d_out, err)
        var res = self._finish_column(rc, err, d_out, state_type, Int(emit_first_n))
        self._note(g, res.outcome)
        return res^

    def agg_finish(mut self, g: Handle, emit_first_n: UInt32, result: ColumnType) raises -> CallResult:
        _need(g, KIND_GROUPS)
        self._live(g, "agg_finish")
        var d_out = self._arena.word(128)
        var err = new_error(self._arena)
        var rc = t_agg_finish(self._table, g._w, emit_first_n, d_out, err)
        var res = self._finish_column(rc, err, d_out, result, Int(emit_first_n))
        self._note(g, res.outcome)
        return res^

    def agg_close(mut self, g: Handle) raises:
        _need(g, KIND_GROUPS)
        t_agg_close(self._table, g._w)
        self._disown(g._w)

    def time_call_batch(mut self, inst: Handle, rows: Int, is_float: Bool, a: Float64, b: Float64, iters: Int) raises -> CallTimes:
        """`iters` calls of call_batch on `inst`, each over a fresh struct
        batch of `rows` rows with one column (int64 i, or float64 i / 2 when
        `is_float`), timed around the call alone (native/bench_loop.c). Every
        output must be a * x_i + b, or the call is a mismatch."""
        _need(inst, KIND_INSTANCE)
        var samples = self._arena.word(8 * (iters if iters > 0 else 1))
        var stats = self._arena.word(24)
        if time_calls(self._table, inst._w, rows, is_float, a, b, True, iters, samples, stats) != 0:
            raise Error("UDF_HARNESS_ALLOC: the timed loop could not allocate its input")
        var st = read_words(stats, 3)
        return CallTimes(read_words(samples, iters), Int(st[0]), Int(st[1]), Int(st[2]))

    def time_call_batch_threads(
        mut self, insts: List[Handle], rows: Int, is_float: Bool, a: Float64, b: Float64, iters: Int
    ) raises -> ThreadTimes:
        """The same loop on one thread per instance, all at once; each
        instance must be in a context of its own."""
        var words = List[Word]()
        for i in range(len(insts)):
            _need(insts[i], KIND_INSTANCE)
            words.append(insts[i]._w)
        var arr = word_array(self._arena, words)
        var out = self._arena.word(72)
        if time_calls_mt(self._table, arr, len(insts), rows, is_float, a, b, True, iters, out) != 0:
            raise Error("UDF_HARNESS_ALLOC: the timed loop could not start its threads")
        var w = read_words(out, 9)
        return ThreadTimes(w[0], w[1], w[2], Int(w[3]), Int(w[4]), Int(w[5]), w[6], w[7], w[8])

    def clock_is_virtual(self) -> Bool:
        """Whether the host's clock answers the virtual clock now (only
        while a call with a future deadline runs)."""
        return virtual_clock_on(host_data_of(self._host))

    def ledger(self) -> Counts:
        """Arrays and streams the host exported and their release counts."""
        return counts(host_data_of(self._host))

    def reserved_bytes(self) -> Int:
        """The bytes the runtime has reserved from the host and not released
        (the ledger's reserved_bytes)."""
        return self.ledger().reserved_bytes

    def shutdown(mut self):
        """Shut the runtime down (once); no callback may run after this."""
        if not self._shut:
            t_shutdown(self._table, self._rt)
            self._shut = True

    def __del__(deinit self):
        if not self._shut:
            t_shutdown(self._table, self._rt)
        self._arena.free_all()
