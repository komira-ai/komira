"""The two directions of the komira/python runtime's Arrow IPC transport under
bad input. A worker whose reply is corrupt (replaced inside the worker) is
refused by the checked reader with the reader's reason, nothing the call
reserved stays held, and the instance answers the next call; a host that
passes an argument array that breaks the Arrow C data layout is refused by the
argument writer by name before anything is sent to the worker.

    test_udf_ipc.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import decimal
import gc
import os
import struct
import sys

import pyarrow as pa

import udf_host as h

I64, I32 = pa.int64(), pa.int32()

# What a call refuses with when the worker's reply fails the checked reader
# (src/udf_python/ipc_read.c).
FAILED = "the worker's output failed validation: "
COUNTS = "the RecordBatch's columns or buffers differ from the bound schema"
NOT_IPC = "the reply is not an IPC message (no continuation marker)"
LENGTH_DIFFERS = "a column's length differs from the batch's"
NULLS_RANGE = "a column's null count is out of range"
VALIDITY_SHORT = "a validity bitmap is shorter than the column"
VALUES_SHORT = "a values buffer is shorter than the column"
VALUES_ALIGN = "a values buffer is not aligned to its type"
OUTSIDE_BODY = "a buffer lies outside the body"
OFFSETS_SHORT = "an offsets buffer is shorter than the column"
OFFSETS_ALIGN = "an offsets buffer is not aligned to its type"
OFFSETS_BAD = "offsets decrease or are negative"
OFFSET_PAST = "an offset runs past the data"
LIST_CHILD_SHORT = "a list child is shorter than its offsets"
STRUCT_CHILD = "a struct child's length differs from the struct's"
NOT_UTF8 = "a string is not valid UTF-8"
BITMAP_SHORT = "a boolean values bitmap is shorter than the column"

# What a call refuses with when an argument array breaks the Arrow C data
# layout (src/udf_python/ipc.c).
NO_OFFSETS = "an argument column has no offsets buffer"
NO_DATA = "an argument column has no data buffer"
NO_VALUES = "an argument column has no values buffer"
ARG_OFFSETS_BAD = "an argument column has offsets that decrease or are negative"
CHILD_SHORT = "a nested argument column is shorter than its parent's range"
NOT_PRIMITIVE = "an argument column is not a primitive array of the batch's length"
NOT_BOUND_TYPE = "an argument column is not an array of its bound type and the batch's length"

OPS = r"""import decimal
import struct
import sys

import pyarrow as pa


def ident_arrow(x):
    return x


# A worker that sends a corrupt reply. The call's first value is the mode (0:
# send the valid reply); the function returns a valid array and the worker's
# reply sender is replaced for one send by one that sends the corrupt bytes.
def _message(array):
    # One RecordBatch message, each body buffer padded to 8 bytes.
    batch = pa.RecordBatch.from_arrays([array], names=["result"])
    return batch.serialize().to_pybytes()


def _hijack(reply):
    wire = sys.modules["_komira_udf_wire"]
    original = wire.send_ok

    def once(sock, request_id, body=b"", flags=0):
        wire.send_ok = original
        original(sock, request_id, reply, flags)

    wire.send_ok = once


def _q(*values):
    return struct.pack("<%dq" % len(values), *values)


def _vec(*flat):
    # A flatbuffers vector of (a, b) int64 structs: its count, then the pairs.
    return struct.pack("<I", len(flat) // 2) + _q(*flat)


def _edit(msg, *alternatives):
    hits = [(old, new) for old, new in alternatives if msg.count(old) == 1]
    assert len(hits) == 1, "the edit does not apply to this message"
    old, new = hits[0]
    assert len(old) == len(new)
    return msg.replace(old, new)


def _armed(mode, valid, edits):
    # `edits(msg)` maps each mode to a function that gives the corrupt bytes.
    if mode:
        _hijack(edits(_message(valid))[mode]())
    return valid


def _text(rtype, fmt):
    width = struct.calcsize(fmt)
    size = 3 * width

    def hostile(x):
        offs = struct.pack("<3" + fmt, 0, 7, 11)
        data = b"abcdefghijk"
        sizes = sorted({size, (size + 7) // 8 * 8})

        def edits(msg):
            return {
                1: lambda: _edit(msg, (offs, struct.pack("<3" + fmt, 0, 7, 1000))),
                2: lambda: _edit(msg, (offs, struct.pack("<3" + fmt, 0, 11, 7))),
                3: lambda: _edit(msg, (offs, struct.pack("<3" + fmt, -1, 7, 11))),
                4: lambda: _edit(msg, (data, b"abc\xffefghijk")),
                5: lambda: _edit(msg, (data, b"ab\xc0\x80efghijk")),
                6: lambda: _edit(msg, (data, b"a\xed\xa0\x80efghijk")),
                7: lambda: _edit(msg, (data, b"abc\xf4\x90\x80\x80hijk")),
                8: lambda: _edit(msg, (data, b"abcde\xe2\x82\xachij")),
                9: lambda: _edit(msg, *[(_q(0, 0, 0, m), _q(0, 0, width // 2, m)) for m in sizes]),
            }

        return _armed(x[0].as_py(), pa.array(["abcdefg", "hijk"], rtype), edits)

    return hostile


def _lists(rtype, fmt):
    width = struct.calcsize(fmt)
    size = 3 * width

    def hostile(x):
        offs = struct.pack("<3" + fmt, 0, 3, 4)
        sizes = sorted({size, (size + 7) // 8 * 8})

        def edits(msg):
            return {
                1: lambda: _edit(msg, (_vec(2, 0, 4, 0), _vec(2, 0, 3, 0))),
                2: lambda: _edit(msg, (offs, struct.pack("<3" + fmt, 0, 4, 3))),
                3: lambda: _edit(msg, (offs, struct.pack("<3" + fmt, 0, 3, 100))),
                4: lambda: _edit(msg, *[(_q(0, 0, 0, m), _q(0, 0, width // 2, m)) for m in sizes]),
            }

        return _armed(x[0].as_py(), pa.array([[1, 2, 3], [4]], rtype), edits)

    return hostile


hostile_string = _text(pa.string(), "i")
hostile_large_string = _text(pa.large_string(), "q")
hostile_list = _lists(pa.list_(pa.int64()), "i")
hostile_large_list = _lists(pa.large_list(pa.int64()), "q")


def hostile_text_list(x):
    valid = pa.array([["abcdefg", "hijk"]], pa.list_(pa.string()))
    child_longer = lambda msg: {1: lambda: _edit(msg, (_vec(1, 0, 2, 0), _vec(1, 0, 5, 0)))}
    return _armed(x[0].as_py(), valid, child_longer)


def hostile_struct(x):
    one = pa.struct([("a", pa.int64())])
    two = pa.struct([("a", pa.int64()), ("b", pa.int64())])
    valid = pa.array([{"a": 111}, {"a": 222}], one)

    def edits(msg):
        return {
            1: lambda: _edit(msg, (_vec(2, 0, 2, 0), _vec(2, 0, 1, 0))),
            2: lambda: _edit(msg, (_vec(2, 0, 2, 0), _vec(2, 0, 2, 1))),
            3: lambda: _edit(msg, (_vec(2, 0, 2, 0), _vec(2, 0, 2, 3))),
            4: lambda: _message(pa.array([{"a": 1, "b": 2}, {"a": 3, "b": 4}], two)),
            5: lambda: _message(pa.array([1, 2], pa.int64())),
        }

    return _armed(x[0].as_py(), valid, edits)


def hostile_bool(x):
    valid = pa.array([True] * len(x), pa.bool_())
    short = [(_q(0, 0, 0, m), _q(0, 0, 0, 1)) for m in (2, 8)]
    return _armed(x[0].as_py(), valid, lambda msg: {1: lambda: _edit(msg, *short)})


def hostile_int64(x):
    valid = pa.array([1, 2], pa.int64())
    two_columns = pa.RecordBatch.from_arrays([valid, valid], names=["result", "other"])

    def edits(msg):
        return {
            1: lambda: _message(pa.array(["a", "b"], pa.string())),
            2: lambda: two_columns.serialize().to_pybytes(),
            3: lambda: bytes(16),
            4: lambda: _edit(msg, (_vec(2, 0), _vec(3, 0))),
            5: lambda: _edit(msg, (_vec(2, 0), _vec(2, 3))),
            6: lambda: _edit(msg, (_vec(2, 0), _vec(2, 1))),
            7: lambda: _edit(msg, (_q(0, 0, 0, 16), _q(0, 0, 0, 8))),
            8: lambda: _edit(msg, (_q(0, 0, 0, 16), _q(0, 0, 4096, 16))),
        }

    return _armed(x[0].as_py(), valid, edits)


# The values buffer moves by one byte and still lies inside the body, so only
# its alignment is wrong. Three int32 values are 12 bytes, padded to 16: the
# buffer moves one byte on. Decimal values have no padding after them: the
# reply holds a null, so its validity bitmap (1 byte, padded to 8) comes
# first, and the values buffer moves one byte back, into that padding.
def hostile_int32(x):
    valid = pa.array([1, 2, 3], pa.int32())
    shifted = lambda msg: {1: lambda: _edit(msg, (_q(0, 0, 0, 12), _q(0, 0, 1, 12)))}
    return _armed(x[0].as_py(), valid, shifted)


def hostile_decimal(x):
    valid = pa.array([decimal.Decimal("1.50"), None], pa.decimal128(10, 2))
    shifted = lambda msg: {1: lambda: _edit(msg, (_q(0, 1, 8, 32), _q(0, 1, 7, 32)))}
    return _armed(x[0].as_py(), valid, shifted)


# A string array of no rows, whose offsets buffer is empty or holds the one
# offset; the reply is the bytes pyarrow writes for it.
def _empty_text(rtype, with_offset):
    offsets = pa.py_buffer(bytes(4 if rtype == pa.string() else 8)) if with_offset else None
    return pa.Array.from_buffers(rtype, 0, [None, offsets, pa.py_buffer(b"")])


def _empty_reply(rtype, with_offset):
    def fn(x):
        return _empty_text(rtype, with_offset)

    return fn


empty_string_no_offsets = _empty_reply(pa.string(), False)
empty_string_one_offset = _empty_reply(pa.string(), True)
empty_large_string_no_offsets = _empty_reply(pa.large_string(), False)
empty_large_string_one_offset = _empty_reply(pa.large_string(), True)


def empty_replies_differ(x):
    same = [
        _message(_empty_text(t, False)) == _message(_empty_text(t, True)) for t in (pa.string(), pa.large_string())
    ]
    return pa.array([not any(same)] * len(x), pa.bool_())
"""


def refused(r, status, message, row=None):
    assert r.status == status and r.err.message == message, (r.status, r.err)
    if row is not None:
        assert r.err.row == row, r.err
    assert r.array is None


# ---- a worker whose reply is corrupt --------------------------------------------


def hostile_session(env, entry, rtype):
    rt = env.runtime()
    spec = env.bundle_spec({"ops.py": OPS}, "ops:" + entry, args=[("x", I64)], result=rtype,
                           batch_format=h.ARROW)
    udf = rt.load_ok(spec)
    return rt, rt.open_context_ok().open_instance_ok(udf)


def corrupt(rt, inst, rtype, rows, mode, why):
    """A call whose worker sends the corrupt reply `mode`: refused as an
    internal error with the reader's reason, nothing the call reserved is
    still held, and the same instance answers the next call."""
    gc.collect()
    held = rt.state.reserved - rt.state.released
    column = pa.array([mode] + [0] * (rows - 1), I64)
    r = inst.call([column])
    refused(r, h.ERR_INTERNAL, FAILED + why, -1)
    gc.collect()
    assert rt.state.reserved - rt.state.released == held, "the refused reply's bytes were not released"
    out = inst.call_ok([pa.array([0] * rows, I64)])
    assert out.type == rtype and len(out) == rows, out


def a_corrupt_string_reply_is_refused_by_the_offsets_and_the_bytes(env):
    for entry, t in (("hostile_string", pa.string()), ("hostile_large_string", pa.large_string())):
        rt, inst = hostile_session(env, entry, t)
        corrupt(rt, inst, t, 2, 1, OFFSET_PAST)
        corrupt(rt, inst, t, 2, 2, OFFSETS_BAD)
        corrupt(rt, inst, t, 2, 3, OFFSETS_BAD)
        for mode in (4, 5, 6, 7, 8):
            corrupt(rt, inst, t, 2, mode, NOT_UTF8)
        corrupt(rt, inst, t, 2, 9, OFFSETS_ALIGN)
        assert inst.call_ok([pa.array([0, 0], I64)]).to_pylist() == ["abcdefg", "hijk"]


def a_corrupt_list_reply_is_refused_by_the_offsets_and_the_child_length(env):
    for entry, t in (("hostile_list", pa.list_(I64)), ("hostile_large_list", pa.large_list(I64))):
        rt, inst = hostile_session(env, entry, t)
        corrupt(rt, inst, t, 2, 1, LIST_CHILD_SHORT)
        corrupt(rt, inst, t, 2, 2, OFFSETS_BAD)
        corrupt(rt, inst, t, 2, 3, LIST_CHILD_SHORT)
        corrupt(rt, inst, t, 2, 4, OFFSETS_ALIGN)
        assert inst.call_ok([pa.array([0, 0], I64)]).to_pylist() == [[1, 2, 3], [4]]
    t = pa.list_(pa.string())
    rt, inst = hostile_session(env, "hostile_text_list", t)
    corrupt(rt, inst, t, 1, 1, OFFSETS_SHORT)
    assert inst.call_ok([pa.array([0], I64)]).to_pylist() == [["abcdefg", "hijk"]]


def a_corrupt_struct_reply_is_refused_by_the_child_length(env):
    t = pa.struct([("a", I64)])
    rt, inst = hostile_session(env, "hostile_struct", t)
    corrupt(rt, inst, t, 2, 1, STRUCT_CHILD)
    assert inst.call_ok([pa.array([0, 0], I64)]).to_pylist() == [{"a": 111}, {"a": 222}]


def a_corrupt_struct_reply_is_refused_by_a_nested_null_count_and_by_the_node_counts(env):
    t = pa.struct([("a", I64)])
    rt, inst = hostile_session(env, "hostile_struct", t)
    # A child that claims a null while its validity buffer is empty; a child
    # that claims one null more than it has rows.
    corrupt(rt, inst, t, 2, 2, VALIDITY_SHORT)
    corrupt(rt, inst, t, 2, 3, NULLS_RANGE)
    # One node too many (a struct of two fields), one too few (a bare int64).
    corrupt(rt, inst, t, 2, 4, COUNTS)
    corrupt(rt, inst, t, 2, 5, COUNTS)
    assert inst.call_ok([pa.array([0, 0], I64)]).to_pylist() == [{"a": 111}, {"a": 222}]


def a_corrupt_boolean_reply_is_refused_by_the_bitmap_length(env):
    rt, inst = hostile_session(env, "hostile_bool", pa.bool_())
    corrupt(rt, inst, pa.bool_(), 16, 1, BITMAP_SHORT)
    assert inst.call_ok([pa.array([0] * 16, I64)]).to_pylist() == [True] * 16


def a_corrupt_int_reply_is_refused_by_the_layout_checks(env):
    rt, inst = hostile_session(env, "hostile_int64", I64)
    for mode, why in ((1, COUNTS), (2, COUNTS), (3, NOT_IPC), (4, LENGTH_DIFFERS), (5, NULLS_RANGE),
                      (6, VALIDITY_SHORT), (7, VALUES_SHORT), (8, OUTSIDE_BODY)):
        corrupt(rt, inst, I64, 2, mode, why)
    assert inst.call_ok([pa.array([0, 0], I64)]).to_pylist() == [1, 2]


def a_values_buffer_that_is_not_aligned_to_its_type_is_refused(env):
    t = pa.int32()
    rt, inst = hostile_session(env, "hostile_int32", t)
    corrupt(rt, inst, t, 3, 1, VALUES_ALIGN)
    assert inst.call_ok([pa.array([0, 0, 0], I64)]).to_pylist() == [1, 2, 3]
    t = pa.decimal128(10, 2)
    rt, inst = hostile_session(env, "hostile_decimal", t)
    corrupt(rt, inst, t, 2, 1, VALUES_ALIGN)
    assert inst.call_ok([pa.array([0, 0], I64)]).to_pylist() == [decimal.Decimal("1.50"), None]


def a_string_reply_of_no_rows_is_accepted_with_an_empty_or_one_entry_offsets_buffer(env):
    # The two replies of each width are different bytes on the wire.
    rt, inst = hostile_session(env, "empty_replies_differ", pa.bool_())
    assert inst.call_ok([pa.array([0], I64)]).to_pylist() == [True]
    for t, entries in ((pa.string(), ("empty_string_no_offsets", "empty_string_one_offset")),
                       (pa.large_string(), ("empty_large_string_no_offsets", "empty_large_string_one_offset"))):
        for entry in entries:
            rt, inst = hostile_session(env, entry, t)
            out = inst.call_ok([pa.array([], I64)])
            assert out.type == t and len(out) == 0 and out.to_pylist() == [], (entry, out)
            assert inst.call_ok([pa.array([], I64)]).type == t, entry


# ---- a host whose argument array breaks the Arrow C data layout ------------------


def hand_instances(env, types):
    """One identity instance per argument type: {type: Instance}."""
    rt = env.runtime()
    loaded = {t: rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:ident_arrow", args=[("x", t)], result=t,
                                            batch_format=h.ARROW))
              for t in types}
    ctx = rt.open_context_ok()
    return {t: ctx.open_instance_ok(u) for t, u in loaded.items()}


def ints(fmt, *values):
    return struct.pack("<%d%s" % (len(values), fmt), *values)


def column_of(*children, length=2):
    """The argument struct of a call, built by hand, with these columns."""
    return h.HandArray(length, [None], children).device_array()


def ints_child(length=2, **kw):
    return h.HandArray(length, [None, ints("q", *range(1, length + 1))], **kw)


def text_child(offsets, data=b"abcde", length=2):
    return h.HandArray(length, [None, offsets, data])


def a_host_array_that_breaks_the_layout_is_refused_by_name_before_the_worker_sees_it(env):
    pair = pa.struct([("a", I64), ("b", I64)])
    items = pa.list_(I64)
    cases = [
        (pa.string(), text_child(None), NO_OFFSETS),
        (pa.string(), text_child(ints("i", 0, 5, 3)), ARG_OFFSETS_BAD),
        (pa.string(), text_child(ints("i", -1, 2, 5)), ARG_OFFSETS_BAD),
        (pa.string(), text_child(ints("i", 0, 2, 5), data=None), NO_DATA),
        (I64, h.HandArray(2, [None, None]), NO_VALUES),
        (I64, ints_child(released=True), NOT_PRIMITIVE),
        (pa.string(), h.HandArray(2, [None, ints("i", 0, 2, 5)]), NOT_BOUND_TYPE),
        (items, h.HandArray(2, [None, ints("i", 0, 2, 4)], [ints_child(3)]), CHILD_SHORT),
        (pair, h.HandArray(2, [None], [ints_child(2)]), NOT_BOUND_TYPE),
    ]
    good = {pa.string(): pa.array(["a", "b"]), I64: pa.array([1, 2], I64), items: pa.array([[1], [2, 3]], items),
            pair: pa.array([{"a": 1, "b": 2}, {"a": 3, "b": 4}], pair)}
    insts = hand_instances(env, good)
    for t, child, message in cases:
        inst = insts[t]
        refused(inst.call_raw(column_of(child)), h.ERR_INTERNAL, message, -1)
        assert inst.call_ok([good[t]]).equals(good[t]), "the instance answers the next call"


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    me = sys.modules["__main__"]
    cases = [f for f in (getattr(me, n) for n in dir(me))
             if getattr(f, "__module__", None) == "__main__" and callable(f)
             and getattr(f, "__code__", None) is not None
             and f.__code__.co_argcount == 1 and f.__code__.co_varnames[0] == "env"]
    for case in cases:
        with h.Env(lib_dir) as env:
            case(env)
        print("ok", case.__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
