# =============================================================================
# FFI-BOUNDARY: the corpus fixtures of the conformance suite, in Mojo, over
# the Arrow C Data arrays the host moves in (docs/design/udf_runtime_interface.md
# section 6.3: every runtime ships the same named fixtures in its language).
# =============================================================================
# Each fixture has the entry name, shape and signature of the reference
# runtime's (src/tests/helpers/komira_udf_spike_abi/refrt/echo_runtime.c),
# so the same cases pass on both. The column fixtures run one row at a time
# in a raising Mojo function, and the loop that calls it catches what it
# raises and returns ERR_RAISED with the row: the export helper of design
# section 5.3 ("native code must not unwind across the ABI"), so no Mojo
# error crosses the C ABI. A ROW fixture reads fields through a row view
# that raises on a name outside the read set and records it, so the batch
# fails with ERR_FIELD_NOT_DECLARED even when user code catches the error.
#
# Who owns and frees each pointer: inputs are moved in by _table.mojo and
# released there; outputs are built with _arrow.mojo's blocks, released by
# the host or, on a failure, here before returning (an error never leaves
# `out` set).
# =============================================================================

from komira_udf_spike_abi._cabi import CUdfCall, CUdfHost, CUdfSpec, Void, is_null, null_void, read_cstr
from komira_udf_spike_abi.contract import (
    ERR_ABI,
    ERR_CANCELLED,
    ERR_DEADLINE,
    ERR_DESCRIPTOR,
    ERR_FIELD_NOT_DECLARED,
    ERR_RAISED,
    ERR_UNSUPPORTED,
    FORM_PACKAGE,
    FORM_VALUE,
    OK,
    SHAPE_AGG_MERGEABLE,
    SHAPE_AGG_PLAIN,
    SHAPE_MAP_BATCHES_COLUMN,
    SHAPE_MAP_BATCHES_FRAME,
    SHAPE_ROW,
    SHAPE_SCALAR,
    SHAPE_STEP,
)
from komira_atomic_alias import AtomicI32
from std.atomic import Ordering
from std.sys import size_of

from ._arrow import (
    arr,
    child,
    f64_at,
    fail,
    i32_at,
    i64_at,
    is_valid,
    length,
    make_col,
    n_children,
    release_array,
    schema_child,
    schema_children,
    schema_format,
    schema_name,
    set_null,
)

comptime F_DOUBLE = 1
comptime F_DOUBLE_STRICT = 2
comptime F_FAHRENHEIT = 3
comptime F_IDENTITY = 4
comptime F_SHORT_BY_ONE = 5
comptime F_BAD_LAYOUT = 6
comptime F_NULL_OUT = 7
comptime F_CONST7 = 8
comptime F_RAISE_ON_ROW_3 = 9
comptime F_SLOW_LOOP = 10
comptime F_SUM = 11
comptime F_RUNNING_SUM = 12
comptime F_GROUP_MAX = 13
comptime F_EMPTY_TABLE = 14
comptime F_PICK = 15
comptime F_PICK_CAUGHT = 16
comptime F_OUT_SET_ON_ERROR = 17
comptime F_OK_WITHOUT_OUTPUT = 18
comptime F_DEVICE_NOT_CPU = 19
comptime F_NULL_COUNT_LIES = 20
comptime F_ARGS_KEPT = 21
comptime F_YIELD_TWO_THEN_RAISE = 22
comptime F_ADD_STRICT = 23
comptime F_LONG_BY_ONE = 24
comptime F_SUM_ARGS_KEPT = 25
comptime F_ENDLESS = 26
comptime F_NULL_ON_ZERO = 27
comptime F_NARROW = 28
comptime F_ADD_MIXED = 29
comptime F_RAISE_NO_ROW = 30
comptime F_SUM_STATE_LONG = 31
comptime F_SUM_FINISH_SHORT = 32
comptime F_TWO_TYPES = 33
comptime F_LEAF_SLICED = 34
comptime F_LEAF_NULL_COUNT_UNKNOWN = 35
comptime F_LEAF_EMPTY_DATA_NULL = 36
comptime F_TABLE_SLICED = 37
comptime F_TABLE_NULL_COUNT_UNKNOWN = 38

comptime ROW_FIELDS_MAX = 8
comptime SLOW_ROW_NS: Int64 = 100_000_000
"""slow_loop: at most 100 ms of the host's clock per row."""


@fieldwise_init
struct Fixture(Copyable, Movable):
    """A fixture's id, shape and signature: `args` one format per argument
    ("*" for ROW: one to ROW_FIELDS_MAX named int64 fields); `result` one
    format, or "t" then one per column for a table; `state` "" for none."""

    var id: Int
    var shape: UInt32
    var args: String
    var result: String
    var state: String


def find_fixture(entry: String) -> Optional[Fixture]:
    if entry == "double":
        return Fixture(F_DOUBLE, SHAPE_SCALAR, "l", "l", "")
    if entry == "double_strict":
        return Fixture(F_DOUBLE_STRICT, SHAPE_SCALAR, "l", "l", "")
    if entry == "fahrenheit":
        return Fixture(F_FAHRENHEIT, SHAPE_MAP_BATCHES_COLUMN, "g", "g", "")
    if entry == "identity":
        return Fixture(F_IDENTITY, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    if entry == "short_by_one":
        return Fixture(F_SHORT_BY_ONE, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    if entry == "bad_layout":
        return Fixture(F_BAD_LAYOUT, SHAPE_SCALAR, "l", "l", "")
    if entry == "null_out":
        return Fixture(F_NULL_OUT, SHAPE_SCALAR, "l", "l", "")
    if entry == "const7":
        return Fixture(F_CONST7, SHAPE_SCALAR, "", "l", "")
    if entry == "raise_on_row_3":
        return Fixture(F_RAISE_ON_ROW_3, SHAPE_SCALAR, "l", "l", "")
    if entry == "slow_loop":
        return Fixture(F_SLOW_LOOP, SHAPE_SCALAR, "l", "l", "")
    if entry == "sum":
        return Fixture(F_SUM, SHAPE_AGG_MERGEABLE, "l", "l", "l")
    if entry == "running_sum":
        return Fixture(F_RUNNING_SUM, SHAPE_MAP_BATCHES_FRAME, "l", "tl", "")
    if entry == "group_max":
        return Fixture(F_GROUP_MAX, SHAPE_AGG_PLAIN, "l", "l", "")
    if entry == "empty_table":
        return Fixture(F_EMPTY_TABLE, SHAPE_STEP, "l", "t", "")
    if entry == "pick":
        return Fixture(F_PICK, SHAPE_ROW, "*", "l", "")
    if entry == "pick_caught":
        return Fixture(F_PICK_CAUGHT, SHAPE_ROW, "*", "l", "")
    if entry == "out_set_on_error":
        return Fixture(F_OUT_SET_ON_ERROR, SHAPE_SCALAR, "l", "l", "")
    if entry == "ok_without_output":
        return Fixture(F_OK_WITHOUT_OUTPUT, SHAPE_SCALAR, "l", "l", "")
    if entry == "device_not_cpu":
        return Fixture(F_DEVICE_NOT_CPU, SHAPE_SCALAR, "l", "l", "")
    if entry == "null_count_lies":
        return Fixture(F_NULL_COUNT_LIES, SHAPE_SCALAR, "l", "l", "")
    if entry == "args_kept":
        return Fixture(F_ARGS_KEPT, SHAPE_SCALAR, "l", "l", "")
    if entry == "yield_two_then_raise":
        return Fixture(F_YIELD_TWO_THEN_RAISE, SHAPE_MAP_BATCHES_FRAME, "l", "tl", "")
    if entry == "add_strict":
        return Fixture(F_ADD_STRICT, SHAPE_SCALAR, "ll", "l", "")
    if entry == "long_by_one":
        return Fixture(F_LONG_BY_ONE, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    if entry == "sum_args_kept":
        return Fixture(F_SUM_ARGS_KEPT, SHAPE_AGG_MERGEABLE, "l", "l", "l")
    if entry == "endless":
        return Fixture(F_ENDLESS, SHAPE_MAP_BATCHES_FRAME, "l", "tl", "")
    # 2x, and a null for 0: a null the function returns for valid inputs.
    if entry == "null_on_zero":
        return Fixture(F_NULL_ON_ZERO, SHAPE_SCALAR, "l", "l", "")
    # int64 in, the same values as int32 out.
    if entry == "narrow":
        return Fixture(F_NARROW, SHAPE_MAP_BATCHES_COLUMN, "l", "i", "")
    # a (int64) + b (int32), null where either is null.
    if entry == "add_mixed":
        return Fixture(F_ADD_MIXED, SHAPE_SCALAR, "li", "l", "")
    # A batch function that raises naming no row (row -1, legal).
    if entry == "raise_no_row":
        return Fixture(F_RAISE_NO_ROW, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    # sum with a state one row too long; with a result one row short.
    if entry == "sum_state_long":
        return Fixture(F_SUM_STATE_LONG, SHAPE_AGG_MERGEABLE, "l", "l", "l")
    if entry == "sum_finish_short":
        return Fixture(F_SUM_FINISH_SHORT, SHAPE_AGG_MERGEABLE, "l", "l", "l")
    # Each input batch's column x as a table (x int64, 10 * x int32).
    if entry == "table_two_types":
        return Fixture(F_TWO_TYPES, SHAPE_MAP_BATCHES_FRAME, "l", "tli", "")
    # Legal Arrow the host must read: identity's column at offset 11 over
    # padding with null bits; with null_count -1; with no data buffer when
    # empty. A frame of identity tables at struct offset 2 over a child at
    # offset 3; with a validity bitmap and null_count -1.
    if entry == "leaf_sliced":
        return Fixture(F_LEAF_SLICED, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    if entry == "leaf_null_count_unknown":
        return Fixture(F_LEAF_NULL_COUNT_UNKNOWN, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    if entry == "leaf_empty_data_null":
        return Fixture(F_LEAF_EMPTY_DATA_NULL, SHAPE_MAP_BATCHES_COLUMN, "l", "l", "")
    if entry == "table_sliced":
        return Fixture(F_TABLE_SLICED, SHAPE_MAP_BATCHES_FRAME, "l", "tl", "")
    if entry == "table_null_count_unknown":
        return Fixture(F_TABLE_NULL_COUNT_UNKNOWN, SHAPE_MAP_BATCHES_FRAME, "l", "tl", "")
    return None


# --- validate ------------------------------------------------------------------------


def _leaf_is(s: Void, fmt: String) -> Bool:
    return not is_null(s) and schema_format(s) == fmt and schema_children(s) == 0


def _struct_is(s: Void, fmts: String) -> Bool:
    if is_null(s) or schema_format(s) != "+s" or schema_children(s) != len(fmts.as_bytes()):
        return False
    for i in range(schema_children(s)):
        if not _leaf_is(schema_child(s, i), String(fmts[byte = i : i + 1])):
            return False
    return True


def _row_args_ok(s: Void) -> Bool:
    """A ROW read set: one to ROW_FIELDS_MAX int64 fields, each named, no
    name twice."""
    if is_null(s) or schema_format(s) != "+s":
        return False
    var n = schema_children(s)
    if n < 1 or n > ROW_FIELDS_MAX:
        return False
    for i in range(n):
        var c = schema_child(s, i)
        if not _leaf_is(c, "l") or schema_name(c) == "":
            return False
        for j in range(i):
            if schema_name(schema_child(s, j)) == schema_name(c):
                return False
    return True


def check_spec(s: Void, e: Void, mut fx: Fixture) -> Int32:
    """The spec names a fixture with its shape and signature, in a form and
    descriptor this library reads; OK with `fx` set, or the refusal."""
    # SAFETY: `s` is the host's komira_udf_spec, lent for the call; its
    # struct_size is checked before any later field is read.
    var sp = s.bitcast[CUdfSpec]()
    if is_null(s) or sp[].struct_size < size_of[CUdfSpec]():
        return fail(e, ERR_ABI, "spec struct_size is below this library's")
    var found = find_fixture(read_cstr(sp[].entry))
    if not found:
        return fail(e, ERR_DESCRIPTOR, "no fixture has this entry")
    if sp[].form < FORM_PACKAGE or sp[].form > FORM_VALUE:
        return fail(e, ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE")
    if sp[].descriptor_version > 0:
        return fail(e, ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here")
    if sp[].descriptor_len != 0:
        return fail(e, ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical")
    var f = found.value().copy()
    if UInt32(sp[].shape) != f.shape:
        return fail(e, ERR_UNSUPPORTED, "the fixture does not have this shape")
    var result_ok = _struct_is(sp[].result, String(f.result[byte=1:])) if f.result.startswith("t") else _leaf_is(
        sp[].result, f.result
    )
    var state_ok = is_null(sp[].state) if f.state == "" else _leaf_is(sp[].state, f.state)
    var args_ok = _row_args_ok(sp[].args) if f.args == "*" else _struct_is(sp[].args, f.args)
    if not args_ok or not result_ok or not state_ok:
        return fail(e, ERR_UNSUPPORTED, "the declared types are not the fixture's signature")
    fx = f^
    return OK


def read_set(s: Void) -> List[String]:
    """The ROW read set's field names, copied from the spec's args."""
    var sp = s.bitcast[CUdfSpec]()
    var out = List[String]()
    for i in range(schema_children(sp[].args)):
        out.append(schema_name(schema_child(sp[].args, i)))
    return out^


# --- the call ---------------------------------------------------------------------------


def cancelled(call: Void) -> Bool:
    if is_null(call):
        return False
    # SAFETY: the host's komira_udf_call, alive for the call; `cancel` is
    # NULL or an int32 flag the host stores with release order.
    var flag = call.bitcast[CUdfCall]()[].cancel
    if is_null(flag):
        return False
    return flag.bitcast[AtomicI32]()[].load[ordering=Ordering.ACQUIRE]() != 0


def now_ns(host: Void) -> Int64:
    # SAFETY: the host struct init received, valid until shutdown returns.
    var h = host.bitcast[CUdfHost]()
    return h[].now_ns(h[].host_data)


def past_deadline(host: Void, call: Void) -> Bool:
    if is_null(call):
        return False
    var d = call.bitcast[CUdfCall]()[].deadline_ns
    return d != 0 and now_ns(host) > d


def start_call(host: Void, call: Void, e: Void) -> Int32:
    if is_null(call) or call.bitcast[CUdfCall]()[].struct_size < size_of[CUdfCall]():
        return fail(e, ERR_ABI, "call struct_size is below this library's")
    if cancelled(call):
        return fail(e, ERR_CANCELLED, "cancelled before the batch")
    if past_deadline(host, call):
        return fail(e, ERR_DEADLINE, "the deadline passed before the batch")
    return OK


def _value(fx: Int, x: Void, y: Void, r: Int, o: Void, d: Void) raises:
    """Row r of a column fixture into row r of `o` (values at `d`): the
    user function, which may raise."""
    if fx == F_RAISE_ON_ROW_3 and r == 3:
        raise Error("raise_on_row_3: row 3")
    var strict = fx == F_DOUBLE_STRICT or fx == F_ADD_STRICT
    if strict and (not is_valid(x, r) or (fx == F_ADD_STRICT and not is_valid(y, r))):
        raise Error("a strict fixture got a null argument")
    if (
        fx == F_NULL_OUT
        or not is_valid(x, r)
        or (fx == F_NULL_ON_ZERO and i64_at(x, r) == 0)
        or (fx == F_ADD_MIXED and not is_valid(y, r))
    ):
        set_null(o, r)
        return
    # SAFETY: `d` is make_col's values block of at least r + 1 rows.
    if fx == F_FAHRENHEIT:
        d.bitcast[Float64]()[r] = f64_at(x, r) * 1.8 + 32.0
    elif fx == F_DOUBLE or fx == F_DOUBLE_STRICT or fx == F_NULL_ON_ZERO:
        d.bitcast[Int64]()[r] = 2 * i64_at(x, r)
    elif fx == F_ADD_MIXED:
        d.bitcast[Int64]()[r] = i64_at(x, r) + Int64(i32_at(y, r))
    elif fx == F_NARROW:
        d.bitcast[Int32]()[r] = Int32(i64_at(x, r))
    elif fx == F_ADD_STRICT:
        d.bitcast[Int64]()[r] = i64_at(x, r) + i64_at(y, r)
    else:
        d.bitcast[Int64]()[r] = i64_at(x, r)


def scalar(fx: Int, host: Void, call: Void, a: Void, o: Void, e: Void) -> Int32:
    """A column fixture over the argument struct `a`, into `o`."""
    var n = length(a)
    var x = child(a, 0) if n_children(a) > 0 else null_void()
    var y = child(a, 1) if n_children(a) > 1 else null_void()
    var rows = n
    if fx == F_SHORT_BY_ONE and n > 0:
        rows = n - 1
    elif fx == F_LONG_BY_ONE:
        rows = n + 1
    var d = make_col(o, rows)
    var at = 0
    try:
        for r in range(rows):
            at = r
            if fx == F_SLOW_LOOP:
                if cancelled(call):
                    release_array(o)
                    return fail(e, ERR_CANCELLED, "slow_loop: cancelled", r)
                if past_deadline(host, call):
                    release_array(o)
                    return fail(e, ERR_DEADLINE, "slow_loop: deadline passed", r)
                # Each row waits SLOW_ROW_NS of the host's clock, or until the
                # flag is set; a cancel set during the call is seen next row.
                var until = now_ns(host) + SLOW_ROW_NS
                while now_ns(host) < until and not cancelled(call):
                    pass
            if fx == F_NARROW:
                d.bitcast[Int32]()[r] = 0
            else:
                d.bitcast[Int64]()[r] = 0
            if r >= n:
                continue
            if fx == F_CONST7:
                d.bitcast[Int64]()[r] = 7
                continue
            _value(fx, x, y, r, o, d)
    except err:
        release_array(o)
        return fail(e, ERR_RAISED, String(err), at)
    if fx == F_BAD_LAYOUT:
        arr(o)[].n_buffers = 1
    return OK


# --- ROW ---------------------------------------------------------------------------------


struct RowView(Movable):
    """One row of the argument struct, read by field name. A name outside
    the read set raises, as the language's own error would, and is recorded
    (the first one), so the batch fails whether or not user code catches."""

    var fields: List[String]
    var a: Void
    var row: Int
    var violation: String
    var violation_row: Int

    def __init__(out self, var fields: List[String], a: Void):
        self.fields = fields^
        self.a = a
        self.row = 0
        self.violation = ""
        self.violation_row = -1

    def get(mut self, name: String) raises -> Int64:
        for i in range(len(self.fields)):
            if self.fields[i] == name:
                return i64_at(child(self.a, i), self.row)
        if self.violation == "":
            self.violation = name
            self.violation_row = self.row
        raise Error("field '" + name + "' is not in the read set")

    def refusal(self, e: Void) -> Int32:
        var msg = "field '" + self.violation + "' is not in the read set {"
        for i in range(len(self.fields)):
            msg += (", " if i > 0 else "") + self.fields[i]
        msg += "}; add it to columns=[...]"
        return fail(e, ERR_FIELD_NOT_DECLARED, msg, self.violation_row)


def _pick(mut v: RowView) raises -> Int64:
    """f(r) = r.a if r.flag else r.b."""
    return v.get("a") if v.get("flag") != 0 else v.get("b")


def row_call(fx: Int, fields: List[String], a: Void, o: Void, e: Void) -> Int32:
    """pick (the read error propagates) and pick_caught (user code catches
    it and returns 0 for the row) over every row of `a`."""
    var n = length(a)
    var d = make_col(o, n)
    var v = RowView(fields.copy(), a)
    for r in range(n):
        v.row = r
        var y: Int64 = 0
        if fx == F_PICK:
            try:
                y = _pick(v)
            except:
                release_array(o)
                return v.refusal(e)
        else:
            try:
                y = _pick(v)
            except:
                y = 0
        # SAFETY: make_col's values block of n rows.
        d.bitcast[Int64]()[r] = y
    if v.violation != "":
        release_array(o)
        return v.refusal(e)
    return OK
