"""The types the komira/python runtime carries beyond numerics: bool, strings,
binary, dates, timestamps (with and without a time zone), decimals, lists and
structs, at any depth the runtime holds, through validate, load and
call_batch. Each type is round-tripped by a VALUES and an ARROW identity
function (nulls, boundaries, an empty batch, sliced and re-based inputs); the
refusal of a result that is not the declared type without loss is exact;
validate refuses what is not carried by name; and a date or timestamp that
Python cannot hold is refused by row and argument. The hostile replies and
host arrays are in test_udf_ipc.py.

    test_udf_types.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import datetime
import decimal
import math
import os
import sys

import pyarrow as pa

import udf_host as h

I64, I32, F64 = pa.int64(), pa.int32(), pa.float64()
I64_MIN, I64_MAX = -(2**63), 2**63 - 1
UTC = datetime.timezone.utc
EPOCH = datetime.datetime(1970, 1, 1, tzinfo=UTC)
D = decimal.Decimal

# The refusal texts of validate (src/udf_python/README.md, "Types").
NOT_BUILT = "type '%s' of %s is not built in komira/python yet"
DICTIONARY = "a dictionary-encoded %s is not built in komira/python yet"
DEEP = "%s nests deeper than komira/python carries (the limit is 16)"
TOO_MANY = "%s has more type nodes than komira/python carries (the limit is 256)"
NAME_TOO_LONG = "a name of %d bytes in %s is not built in komira/python yet (the limit is 63)"
ZONE_TOO_LONG = "a time zone of %d bytes in %s is not built in komira/python yet (the limit is 63)"
NO_CHILDREN = "type '+s' of %s has no children"
NS_VALUES = "a timestamp[ns] in %s is not built for the VALUES batch format: datetime.datetime holds microseconds"

OPS = r"""import dataclasses
import datetime as dt
import decimal

import pyarrow as pa


@dataclasses.dataclass
class Rec:
    a: int
    b: str


@dataclasses.dataclass
class Short:
    a: int


def ident(x):
    return x


def ident_arrow(x):
    return x


def first(a, b):
    return a


def bad_at_two(x):
    return "a" if x == 2 else x


def mixed(i, s, t, d, l, st):
    if i is None:
        return None
    stamp = None if t is None else t.isoformat()
    fields = None if st is None else sorted(st.items())
    return "%d|%s|%s|%s|%s|%s" % (i, s, stamp, d, l, fields)


def mixed_arrow(i, s, t, d, l, st):
    rows = zip(*[c.to_pylist() for c in (i, s, t, d, l, st)])
    return pa.array([mixed(*row) for row in rows], pa.string())


# Each constant is returned for every row by the function of the same name.
UTC = dt.timezone.utc
PLUS = dt.timezone(dt.timedelta(hours=5, minutes=30))
CONSTANTS = {
    "r_str": "a",
    "r_int_for_bool": 1,
    "r_bool_for_int": True,
    "r_wide_int8": 128,
    "r_datetime_for_date": dt.datetime(2027, 1, 1),
    "r_date_for_stamp": dt.date(2027, 1, 1),
    "r_naive_for_zoned": dt.datetime(2027, 1, 1),
    "r_aware_for_naive": dt.datetime(2027, 1, 1, tzinfo=UTC),
    "r_micros_for_ms": dt.datetime(2027, 1, 1, 0, 0, 0, 123456),
    "r_micros_for_s": dt.datetime(2027, 1, 1, 0, 0, 0, 1),
    "r_float_for_decimal": 1.5,
    "r_scale_loss": decimal.Decimal("1.234"),
    "r_eleven_digits": decimal.Decimal("12345678901"),
    "r_nan_decimal": decimal.Decimal("NaN"),
    "r_bool_for_decimal": True,
    "r_str_for_binary": "abc",
    "r_bytes_for_string": b"abc",
    "r_surrogate": "\ud800",
    "r_float32_big": 1e40,
    "r_float32_tenth": 0.1,
    "r_str_for_list": "ab",
    "r_list_bad_item": [1, "a"],
    "r_dict_missing": {"a": 1},
    "r_dict_extra": {"a": 1, "b": "x", "c": 2},
    "r_dict_bad_field": {"a": 2.5, "b": "x"},
    "r_dataclass_short": Short(1),
    "r_dataclass_class": Rec,
    "r_dec38_over": 10**38,
    "r_dec52_over": decimal.Decimal("1000.00"),
    "r_inf_decimal": decimal.Decimal("Infinity"),
    "r_ns_over": dt.datetime(2262, 4, 12),
    "r_f32_odd": 16777217,
    "ok_f32_half": 0.5,
    "ok_f32_int": 3,
    "ok_f64_int": 2 ** 53,
    "ok_bytearray": bytearray(b"ab"),
    "ok_memoryview": memoryview(b"cd"),
    "ok_dec_int": 5,
    "ok_dec_trailing": decimal.Decimal("1.2000"),
    "ok_dec_exponent": decimal.Decimal("1E+1"),
    "ok_dec_max": decimal.Decimal("9" * 38),
    "ok_dec_fraction": decimal.Decimal("-0." + "9" * 38),
    "ok_dec38_int": 10**38 - 1,
    "ok_dec52_max": decimal.Decimal("999.99"),
    "ok_dec52_zero_tail": decimal.Decimal("1.230"),
    "ok_dec52_negative_zero": decimal.Decimal("-0.00"),
    "ok_ns_edge": dt.datetime(2262, 4, 11),
    "ok_f32_even": 16777216,
    "ok_tuple": (1, 2),
    "ok_dataclass": Rec(1, "x"),
    "ok_offset_instant": dt.datetime(2027, 1, 1, 5, 30, tzinfo=PLUS),
    "ok_ms": dt.datetime(2027, 1, 1, 0, 0, 0, 123000),
    "ok_s": dt.datetime(2027, 1, 1),
    "ok_ns": dt.datetime(2027, 1, 1, 0, 0, 0, 5),
    "ok_date": dt.date(1970, 1, 2),
    "ok_str": "héllo \U0001F600",
}


def _const(value):
    def fn(x):
        return value

    return fn


for _name, _value in CONSTANTS.items():
    globals()[_name] = _const(_value)


# Arrow arrays returned for a declared type that is not their own.
ARRAYS = {
    "ar_int64": lambda: pa.array([1, 2], pa.int64()),
    "ar_int32": lambda: pa.array([1, 2], pa.int32()),
    "ar_string": lambda: pa.array(["a", "b"], pa.string()),
    "ar_bool": lambda: pa.array([True, False], pa.bool_()),
    "ar_list_int32": lambda: pa.array([[1], [2, 3]], pa.list_(pa.int32())),
}


def _array_of(make):
    def fn(x):
        return make()

    return fn


for _name, _make in ARRAYS.items():
    globals()[_name] = _array_of(_make)


def stamp_naive(x):
    return pa.array([0] * len(x), pa.timestamp("us"))


def stamp_utc(x):
    return pa.array([0] * len(x), pa.timestamp("us", tz="UTC"))


def stamp_offset(x):
    return pa.array([0] * len(x), pa.timestamp("us", tz="+05:30"))
"""

_NAMES = {"__name__": "ops"}
exec(OPS, _NAMES)
CONSTANTS = _NAMES["CONSTANTS"]
mixed = _NAMES["mixed"]


def micros(when):
    """The microseconds since the epoch of the instant `when` is (a naive
    datetime counts as UTC)."""
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    return (when - EPOCH) // datetime.timedelta(microseconds=1)


# ---- the types and their values ----------------------------------------------


def has_ns(t):
    """Whether `t`, or a type inside it, is a timestamp[ns]."""
    if pa.types.is_timestamp(t):
        return t.unit == "ns"
    if pa.types.is_list(t) or pa.types.is_large_list(t):
        return has_ns(t.value_type)
    if pa.types.is_struct(t):
        return any(has_ns(t.field(i).type) for i in range(t.num_fields))
    return False


def build(t, values):
    """The array of `values` as `t`; a timestamp's values are integers in its unit."""
    if pa.types.is_timestamp(t):
        return pa.array(values, I64).cast(t)
    return pa.array(values, t)


def stamps(unit, zoned):
    """Integers in `unit` that run from the first to the last instant a
    datetime holds (inside a day or two of them for a zoned type, whose local
    time must stay a datetime too); nanoseconds span int64."""
    per = {"s": 1, "ms": 10**3, "us": 10**6, "ns": 10**9}[unit]
    if unit == "ns":
        return [I64_MIN, 0, None, 1700000000 * per + 123456789, I64_MAX, -1, 1]
    frac = {"s": 0, "ms": 123, "us": 123456}[unit]
    edge = 2 * 86400 if zoned else 0
    return [(-62135596800 + edge) * per, 0, None, 1700000000 * per + frac,
            (253402300799 - edge) * per + per - 1, -per + frac, 1]


def ints(bits):
    return [-(1 << (bits - 1)), (1 << (bits - 1)) - 1, None, 0, -1, 1, 42]


AB = pa.struct([("a", I64), ("b", pa.string())])
NESTED = pa.struct([("a", pa.struct([("x", I32), ("y", pa.string())])), ("b", pa.list_(I64))])
EVERYTHING = pa.struct([("t", pa.timestamp("us", tz="UTC")), ("d", pa.decimal128(10, 2)),
                        ("f", pa.float32()), ("o", pa.bool_())])
TEXT = ["", "abc", None, "héllo wörld", "日本語", "\U0001F600 emoji \U0001F680",
        "x" * 300, "\x00nul"]
BYTES = [b"", b"\x00", None, b"a\x00b", bytes(range(256)), b"\xff\xfe"]
F32_MAX = 3.4028234663852886e38

GROUPS = {
    "scalars": [
        ("bool", pa.bool_(), [True, None, False, True, True, False, None, False, True]),
        ("int8", pa.int8(), ints(8)), ("int16", pa.int16(), ints(16)),
        ("int32", I32, ints(32)), ("int64", I64, ints(64)),
        ("float32", pa.float32(), [0.0, -0.0, 0.5, None, F32_MAX, -F32_MAX, 1.1754943508222875e-38,
                                   1.401298464324817e-45, math.inf, -math.inf, 16777216.0]),
        ("float64", F64, [0.0, 1.5, None, sys.float_info.max, -sys.float_info.max, 5e-324,
                          math.inf, -math.inf, sys.float_info.min]),
    ],
    "text": [
        ("string", pa.string(), TEXT), ("large_string", pa.large_string(), TEXT),
        ("binary", pa.binary(), BYTES), ("large_binary", pa.large_binary(), BYTES),
    ],
    "temporal": [
        ("date32", pa.date32(), [datetime.date.min, datetime.date(1970, 1, 1), None, datetime.date.max,
                                 datetime.date(2028, 2, 29), datetime.date(1969, 12, 31)]),
    ] + [
        ("timestamp[%s%s]" % (unit, ", " + tz if tz else ""), pa.timestamp(unit, tz=tz), stamps(unit, bool(tz)))
        for unit in ("s", "ms", "us", "ns") for tz in (None, "UTC", "+05:30")
    ],
    "decimals": [
        ("decimal128(38, 0)", pa.decimal128(38, 0), [D(10**38 - 1), D(-(10**38 - 1)), None, D(0), D(1), D(-1)]),
        ("decimal128(38, 38)", pa.decimal128(38, 38), [D("0." + "9" * 38), D("-0." + "9" * 38),
                                                      D("0." + "0" * 37 + "1"), None, D("0." + "0" * 38)]),
        ("decimal128(10, 2)", pa.decimal128(10, 2), [D("0.00"), D("-99999999.99"), D("99999999.99"), None,
                                                    D("0.01"), D("123.45")]),
        ("decimal128(1, 0)", pa.decimal128(1, 0), [D(9), D(-9), None, D(0)]),
    ],
    "nested": [
        ("list<int64>", pa.list_(I64), [[1, 2, 3], [], None, [None, 5], [I64_MIN, I64_MAX]]),
        ("large_list<string>", pa.large_list(pa.string()), [["a", "bb", None, ""], [], None, ["é"]]),
        ("list<list<int64>>", pa.list_(pa.list_(I64)), [[[1], []], None, [None, [2, 3]], []]),
        ("list<struct>", pa.list_(AB), [[{"a": 1, "b": "x"}, None, {"a": None, "b": None}], [], None,
                                        [{"a": 2, "b": "yy"}]]),
        ("struct<a, b>", AB, [{"a": 1, "b": "x"}, None, {"a": None, "b": "y"}, {"a": 3, "b": None},
                              {"a": None, "b": None}]),
        ("struct<a: int8>", pa.struct([("a", pa.int8())]), [{"a": 1}, None, {"a": None}, {"a": -128}]),
        ("struct<struct, list>", NESTED, [{"a": {"x": 1, "y": "p"}, "b": [1, 2]}, {"a": None, "b": None}, None,
                                          {"a": {"x": None, "y": None}, "b": []}]),
        ("struct<list, string>", pa.struct([("l", pa.list_(I64)), ("s", pa.string())]),
         [{"l": [1, 2], "s": "a"}, {"l": None, "s": None}, None, {"l": [], "s": ""}]),
        ("struct<all kinds>", EVERYTHING, [
            {"t": datetime.datetime(2027, 1, 1, tzinfo=UTC), "d": D("1.50"), "f": 0.5, "o": True}, None,
            {"t": None, "d": None, "f": None, "o": None}]),
    ],
}
ALL = [case for group in GROUPS.values() for case in group]


def inputs_of(t, values):
    """The columns a type is called with: the values, none, only nulls, and
    slices of three copies that start inside a validity byte and inside the
    offsets."""
    arr = build(t, values * 3)
    yield build(t, values)
    yield build(t, [])
    yield pa.nulls(4, t)
    for lo, n in ((1, None), (3, 11), (8, 2)):
        yield arr.slice(lo, n)


def run_identity(env, group):
    """Every type of `group` through a VALUES and an ARROW identity function (a
    timestamp[ns] argument is the ARROW one only): the output is the declared
    type and equals the input, whatever the input's offset."""
    rt = env.runtime()
    loaded = []
    for label, t, values in group:
        for fmt, entry in ((h.VALUES, "ops:ident"), (h.ARROW, "ops:ident_arrow")):
            if fmt == h.VALUES and has_ns(t):
                continue
            spec = env.bundle_spec({"ops.py": OPS}, entry, args=[("x", t)], result=t, batch_format=fmt)
            loaded.append((label, fmt, t, values, rt.load_ok(spec)))
    ctx = rt.open_context_ok()
    for label, fmt, t, values, udf in loaded:
        inst = ctx.open_instance_ok(udf)
        for arr in inputs_of(t, values):
            out = inst.call_ok([arr])
            assert out.type == t, (label, fmt, out.type)
            assert out.equals(arr), (label, fmt, out.to_pylist(), arr.to_pylist())


def numbers_bool_and_floats_round_trip_through_values_and_arrow_functions(env):
    run_identity(env, GROUPS["scalars"])


def strings_and_binary_round_trip_through_values_and_arrow_functions(env):
    run_identity(env, GROUPS["text"])


def dates_and_timestamps_of_every_unit_and_zone_round_trip(env):
    run_identity(env, GROUPS["temporal"])


def decimals_round_trip_through_values_and_arrow_functions(env):
    run_identity(env, GROUPS["decimals"])


def lists_and_structs_round_trip_through_values_and_arrow_functions(env):
    run_identity(env, GROUPS["nested"])


def nan_and_infinities_survive_a_float_round_trip(env):
    rt = env.runtime()
    for t in (pa.float32(), F64):
        arr = pa.array([math.nan, 1.0, None, math.inf, -math.inf], t)
        for fmt, entry in ((h.VALUES, "ops:ident"), (h.ARROW, "ops:ident_arrow")):
            spec = env.bundle_spec({"ops.py": OPS}, entry, args=[("x", t)], result=t, batch_format=fmt)
            udf = rt.load_ok(spec)
            inst = rt.open_context_ok().open_instance_ok(udf)
            got = inst.call_ok([arr]).to_pylist()
            assert math.isnan(got[0]) and got[1:] == [1.0, None, math.inf, -math.inf], (t, fmt, got)


def children_with_their_own_offsets_are_rebased(env):
    # A struct built from sliced children and a list over sliced values: the
    # array's children are not at offset 0, so the writer moves them.
    a = pa.array([10, 11, 12, 13, 14], I64).slice(2)
    b = pa.array(["u", "v", "w", "x", "y"]).slice(2)
    struct = pa.StructArray.from_arrays([a, b], names=["a", "b"])
    values = pa.array([9, 8, 1, 2, 3, 4], I64).slice(2)
    lst = pa.ListArray.from_arrays(pa.array([0, 3, 4], pa.int32()), values)
    rows = pa.array([["a", None], [], ["bb", "ccc", "dddd"], ["e"]], pa.list_(pa.string())).slice(1, 3)
    rt = env.runtime()
    cases = [(struct.type, struct), (lst.type, lst), (rows.type, rows)]
    loaded = [rt.load_ok(env.bundle_spec({"ops.py": OPS}, entry, args=[("x", t)], result=t, batch_format=fmt))
              for t, _ in cases for fmt, entry in ((h.VALUES, "ops:ident"), (h.ARROW, "ops:ident_arrow"))]
    ctx = rt.open_context_ok()
    insts = iter([ctx.open_instance_ok(u) for u in loaded])
    for t, arr in cases:
        for _ in range(2):
            out = next(insts).call_ok([arr])
            assert out.type == t and out.equals(arr), (t, out.to_pylist(), arr.to_pylist())
    assert struct.to_pylist() == [{"a": 12, "b": "w"}, {"a": 13, "b": "x"}, {"a": 14, "b": "y"}]
    assert lst.to_pylist() == [[1, 2, 3], [4]]


def a_function_of_six_types_gets_every_argument_and_returns_the_text_it_builds(env):
    t_type, d_type = pa.timestamp("us", tz="UTC"), pa.decimal128(10, 2)
    l_type = pa.list_(I64)
    columns = [
        pa.array([1, None, 3, I64_MAX], I64),
        pa.array(["a", "b", None, "日本"], pa.string()),
        pa.array([0, 1700000000123456, None, -1], I64).cast(t_type),
        pa.array([D("1.50"), None, D("-0.01"), D("99999999.99")], d_type),
        pa.array([[1, 2], [], None, [None]], l_type),
        pa.array([{"a": 1, "b": "x"}, None, {"a": None, "b": "y"}, {"a": 4, "b": None}], AB),
    ]
    args = [("i", I64), ("s", pa.string()), ("t", t_type), ("d", d_type), ("l", l_type), ("st", AB)]
    rt = env.runtime()
    loaded = [rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:" + entry, args=args, result=pa.string(),
                                         batch_format=fmt))
              for entry, fmt in (("mixed", h.VALUES), ("mixed_arrow", h.ARROW))]
    ctx = rt.open_context_ok()
    for udf in loaded:
        inst = ctx.open_instance_ok(udf)
        for cols in (columns, [c.slice(1) for c in columns], [c.slice(0, 0) for c in columns]):
            want = [mixed(*row) for row in zip(*[c.to_pylist() for c in cols])]
            out = inst.call_ok(cols)
            assert out.type == pa.string() and out.to_pylist() == want, (out.to_pylist(), want)


# ---- results that are not the declared type, refused by value ---------------

# (function, declared result type, the text after "without loss"): each
# function returns its constant (OPS) for every row.
REFUSED = [
    ("r_str", I64, ""),
    ("r_int_for_bool", pa.bool_(), ""),
    ("r_bool_for_int", I64, ""),
    ("r_wide_int8", pa.int8(), ""),
    ("r_datetime_for_date", pa.date32(), ""),
    ("r_date_for_stamp", pa.timestamp("us"), ""),
    ("r_naive_for_zoned", pa.timestamp("us", tz="UTC"), ""),
    ("r_aware_for_naive", pa.timestamp("us"), ""),
    ("r_micros_for_ms", pa.timestamp("ms"), ""),
    ("r_micros_for_s", pa.timestamp("s"), ""),
    ("r_float_for_decimal", pa.decimal128(10, 2), ""),
    ("r_scale_loss", pa.decimal128(10, 2), ""),
    ("r_eleven_digits", pa.decimal128(10, 0), ""),
    ("r_nan_decimal", pa.decimal128(10, 2), ""),
    ("r_bool_for_decimal", pa.decimal128(10, 2), ""),
    ("r_str_for_binary", pa.binary(), ""),
    ("r_bytes_for_string", pa.string(), ""),
    ("r_surrogate", pa.string(), ""),
    ("r_surrogate", pa.large_string(), ""),
    ("r_float32_big", pa.float32(), ""),
    ("r_float32_tenth", pa.float32(), ""),
    ("r_str_for_list", pa.list_(I64), ""),
    ("r_list_bad_item", pa.list_(I64), ": [1] is str 'a'"),
    ("r_dict_missing", AB, ": the field 'b' is missing"),
    ("r_dict_extra", AB, ": the key 'c' is not a field"),
    ("r_dict_bad_field", AB, ": ['a'] is float 2.5"),
    ("r_dataclass_short", AB, ": the field 'b' is missing"),
    ("r_dataclass_class", AB, ""),
    ("r_dec38_over", pa.decimal128(38, 0), ""),
    ("r_dec52_over", pa.decimal128(5, 2), ""),
    ("r_nan_decimal", pa.decimal128(5, 2), ""),
    ("r_inf_decimal", pa.decimal128(5, 2), ""),
    ("r_ns_over", pa.timestamp("ns"), ""),
    ("r_f32_odd", pa.float32(), ""),
]

# (function, declared result type, the value as the type holds it)
ACCEPTED = [
    ("ok_f32_half", pa.float32(), 0.5),
    ("ok_f32_int", pa.float32(), 3.0),
    ("ok_f64_int", F64, 2.0**53),
    ("ok_bytearray", pa.binary(), b"ab"),
    ("ok_memoryview", pa.large_binary(), b"cd"),
    ("ok_dec_int", pa.decimal128(10, 2), D("5.00")),
    ("ok_dec_trailing", pa.decimal128(10, 2), D("1.20")),
    ("ok_dec_exponent", pa.decimal128(10, 2), D("10.00")),
    ("ok_dec_max", pa.decimal128(38, 0), D("9" * 38)),
    ("ok_dec_fraction", pa.decimal128(38, 38), D("-0." + "9" * 38)),
    ("ok_dec38_int", pa.decimal128(38, 0), D("9" * 38)),
    ("ok_dec52_max", pa.decimal128(5, 2), D("999.99")),
    ("ok_dec52_zero_tail", pa.decimal128(5, 2), D("1.23")),
    ("ok_dec52_negative_zero", pa.decimal128(5, 2), D("0.00")),
    ("ok_ns_edge", pa.timestamp("ns"), datetime.datetime(2262, 4, 11)),
    ("ok_f32_even", pa.float32(), 16777216.0),
    ("ok_tuple", pa.list_(I64), [1, 2]),
    ("ok_dataclass", AB, {"a": 1, "b": "x"}),
    ("ok_offset_instant", pa.timestamp("us", tz="UTC"), datetime.datetime(2027, 1, 1, tzinfo=UTC)),
    ("ok_ms", pa.timestamp("ms"), datetime.datetime(2027, 1, 1, 0, 0, 0, 123000)),
    ("ok_s", pa.timestamp("s"), datetime.datetime(2027, 1, 1)),
    ("ok_ns", pa.timestamp("ns"), datetime.datetime(2027, 1, 1, 0, 0, 0, 5)),
    ("ok_date", pa.date32(), datetime.date(1970, 1, 2)),
    ("ok_str", pa.string(), "héllo \U0001F600"),
    ("ok_str", pa.large_string(), "héllo \U0001F600"),
]


def refused(r, status, message, row=None):
    assert r.status == status and r.err.message == message, (r.status, r.err)
    if row is not None:
        assert r.err.row == row, r.err
    assert r.array is None


def session(env, entries, args=(("x", I64),), batch_format=h.VALUES):
    """One instance per (function, result type) of `entries`, in order."""
    rt = env.runtime()
    loaded = [rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:" + name, args=list(args), result=t,
                                         batch_format=batch_format))
              for name, t in entries]
    ctx = rt.open_context_ok()
    return rt, [ctx.open_instance_ok(u) for u in loaded]


def a_value_that_is_not_the_declared_type_without_loss_is_refused_by_row_and_value(env):
    rt, insts = session(env, [(name, t) for name, t, _ in REFUSED])
    for inst, (name, t, detail) in zip(insts, REFUSED):
        value = CONSTANTS[name]
        want = "row 0 returned %s %r, which is not %s without loss%s" % (type(value).__name__, value, t, detail)
        refused(inst.call([pa.array([1], I64)]), h.ERR_RETURN_TYPE, want, 0)
    assert insts[0].call([pa.array([1, 2], I64)]).status == h.ERR_RETURN_TYPE, "an instance stays usable"


def exact_messages_name_the_row_the_type_and_the_path_inside_a_list_or_struct(env):
    rt, insts = session(env, [("r_float32_big", pa.float32()), ("r_list_bad_item", pa.list_(I64)),
                              ("r_dict_missing", AB)])
    refused(insts[0].call([pa.array([1], I64)]), h.ERR_RETURN_TYPE,
            "row 0 returned float 1e+40, which is not float without loss", 0)
    refused(insts[1].call([pa.array([1], I64)]), h.ERR_RETURN_TYPE,
            "row 0 returned list [1, 'a'], which is not list<item: int64> without loss: [1] is str 'a'", 0)
    refused(insts[2].call([pa.array([1], I64)]), h.ERR_RETURN_TYPE,
            "row 0 returned dict {'a': 1}, which is not struct<a: int64, b: string> without loss: "
            "the field 'b' is missing", 0)


def the_loose_python_forms_of_each_type_are_accepted_and_stored_exactly(env):
    rt, insts = session(env, [(name, t) for name, t, _ in ACCEPTED])
    for inst, (name, t, value) in zip(insts, ACCEPTED):
        out = inst.call_ok([pa.array([1, 2], I64)])
        want = pa.array([value, value], t)
        assert out.type == t and out.equals(want), (name, out.to_pylist(), want.to_pylist())


def only_the_failing_row_is_named_when_the_rows_before_it_are_fine(env):
    rt, insts = session(env, [("bad_at_two", I64)])
    refused(insts[0].call([pa.array([0, 1, 2], I64)]), h.ERR_RETURN_TYPE,
            "row 2 returned str 'a', which is not int64 without loss", 2)
    assert insts[0].call_ok([pa.array([0, 1, 3], I64)]).to_pylist() == [0, 1, 3]


# (function, declared type of the Arrow result, the type the function returns)
ARROW_REFUSED = [
    ("ar_int64", pa.string(), "int64"),
    ("ar_string", I64, "string"),
    ("ar_bool", pa.int8(), "bool"),
]

# (function, declared type of the Arrow result, the values as the type holds them)
ARROW_ACCEPTED = [
    ("ar_int32", I64, [1, 2]),
    ("ar_int64", F64, [1.0, 2.0]),
    ("ar_string", pa.large_string(), ["a", "b"]),
    ("ar_list_int32", pa.large_list(I64), [[1], [2, 3]]),
]


def an_arrow_result_is_cast_only_within_one_kind_of_type(env):
    rt, insts = session(env, [(name, t) for name, t, _ in ARROW_REFUSED], batch_format=h.ARROW)
    for inst, (name, t, given) in zip(insts, ARROW_REFUSED):
        refused(inst.call([pa.array([1, 2], I64)]), h.ERR_RETURN_TYPE,
                "returned %s, which is not %s without loss" % (given, t))
    rt, insts = session(env, [(name, t) for name, t, _ in ARROW_ACCEPTED], batch_format=h.ARROW)
    for inst, (name, t, values) in zip(insts, ARROW_ACCEPTED):
        out = inst.call_ok([pa.array([1, 2], I64)])
        assert out.type == t and out.to_pylist() == values, (name, out.type, out.to_pylist())


def days(*values):
    return pa.array(values, I32).cast(pa.date32())


YEAR_10000_DAYS, BEFORE_YEAR_1_DAYS = 2932897, -719163
YEAR_10000_US, BEFORE_YEAR_1_US = 253402300800 * 10**6, -62135596800 * 10**6 - 1


HELD = "row %d of argument '%s' holds a %s outside the years 1 to 9999, which %s cannot hold"


def a_date_or_timestamp_python_cannot_hold_is_refused_by_row_and_argument(env):
    us, ms_utc, date = pa.timestamp("us"), pa.timestamp("ms", tz="UTC"), pa.date32()
    # (type, the column that holds one value Python cannot, a column that it can, the failing row, the message)
    cases = [
        (us, build(us, [0, YEAR_10000_US, 0]), build(us, [0, 1, 2]), 1,
         HELD % (1, "x", "timestamp[us]", "datetime.datetime")),
        (us, build(us, [BEFORE_YEAR_1_US, 0]), build(us, [0, 1]), 0,
         HELD % (0, "x", "timestamp[us]", "datetime.datetime")),
        (date, days(0, 0, YEAR_10000_DAYS), days(0, 1, 2), 2, HELD % (2, "x", "date32[day]", "datetime.date")),
        (date, days(BEFORE_YEAR_1_DAYS, 0), days(0, 1), 0, HELD % (0, "x", "date32[day]", "datetime.date")),
        (ms_utc, build(ms_utc, [0, YEAR_10000_US // 1000]), build(ms_utc, [0, 1]), 1,
         HELD % (1, "x", "timestamp[ms, tz=UTC]", "datetime.datetime")),
    ]
    rt = env.runtime()
    loaded = [rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:ident", args=[("x", t)], result=t))
              for t, _, _, _, _ in cases]
    ctx = rt.open_context_ok()
    for udf, (t, column, fine, row, message) in zip(loaded, cases):
        inst = ctx.open_instance_ok(udf)
        refused(inst.call([column]), h.ERR_UNSUPPORTED, message, row)
        assert inst.call_ok([fine]).equals(fine), "the instance answers the next call"


def a_date_python_cannot_hold_names_the_argument_and_the_leaf_type_inside_a_list_or_struct(env):
    us = pa.timestamp("us")
    rt = env.runtime()
    two = [("a", I64), ("when", us)]
    nested = pa.list_(us)
    record = pa.struct([("n", I64), ("day", pa.date32())])
    loaded = [
        rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:first", args=two, result=I64)),
        rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:ident", args=[("x", nested)], result=nested)),
        rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:ident", args=[("x", record)], result=record)),
    ]
    ctx = rt.open_context_ok()
    pair, listed, structured = [ctx.open_instance_ok(u) for u in loaded]
    refused(pair.call([pa.array([1, 2], I64), build(us, [0, YEAR_10000_US])]), h.ERR_UNSUPPORTED,
            HELD % (1, "when", "timestamp[us]", "datetime.datetime"), 1)
    assert pair.call_ok([pa.array([1, 2], I64), build(us, [0, 1])]).to_pylist() == [1, 2]
    lists = pa.ListArray.from_arrays(pa.array([0, 1, 2, 3], I32), build(us, [0, BEFORE_YEAR_1_US, 0]))
    refused(listed.call([lists]), h.ERR_UNSUPPORTED, HELD % (1, "x", "timestamp[us]", "datetime.datetime"), 1)
    ok_lists = pa.ListArray.from_arrays(pa.array([0, 1, 2], I32), build(us, [0, 0]))
    assert listed.call_ok([ok_lists]).equals(ok_lists)
    records = pa.StructArray.from_arrays([pa.array([1, 2], I64), days(0, YEAR_10000_DAYS)], names=["n", "day"])
    refused(structured.call([records]), h.ERR_UNSUPPORTED, HELD % (1, "x", "date32[day]", "datetime.date"), 1)
    ok_records = pa.StructArray.from_arrays([pa.array([1, 2], I64), days(0, 1)], names=["n", "day"])
    assert structured.call_ok([ok_records]).equals(ok_records)
    # Row 0 fails in its timestamp field and row 2 in its date field (which
    # comes first): the message names row 0 and the type that fails there.
    both = pa.struct([("day", pa.date32()), ("when", us)])
    udf = rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:ident", args=[("x", both)], result=both))
    inst = rt.open_context_ok().open_instance_ok(udf)
    mixed = pa.StructArray.from_arrays([days(0, 0, YEAR_10000_DAYS), build(us, [YEAR_10000_US, 0, 0])],
                                       names=["day", "when"])
    refused(inst.call([mixed]), h.ERR_UNSUPPORTED, HELD % (0, "x", "timestamp[us]", "datetime.datetime"), 0)


def an_arrow_result_of_another_time_zone_is_refused_and_the_same_zone_is_accepted(env):
    utc, plain, plus = pa.timestamp("us", tz="UTC"), pa.timestamp("us"), pa.timestamp("us", tz="+05:30")
    rt, insts = session(env, [("stamp_naive", utc), ("stamp_offset", utc), ("stamp_utc", plain),
                              ("stamp_utc", utc), ("stamp_offset", plus)], batch_format=h.ARROW)
    refused(insts[0].call([pa.array([1], I64)]), h.ERR_RETURN_TYPE,
            "returned timestamp[us], which is not timestamp[us, tz=UTC] without loss")
    refused(insts[1].call([pa.array([1], I64)]), h.ERR_RETURN_TYPE,
            "returned timestamp[us, tz=+05:30], which is not timestamp[us, tz=UTC] without loss")
    refused(insts[2].call([pa.array([1], I64)]), h.ERR_RETURN_TYPE,
            "returned timestamp[us, tz=UTC], which is not timestamp[us] without loss")
    for inst, t in zip(insts[3:], (utc, plus)):
        out = inst.call_ok([pa.array([1, 2], I64)])
        assert out.type == t and out.cast(I64).to_pylist() == [0, 0], out


# ---- validate ------------------------------------------------------------------

CODE = [(h.ROLE_BUNDLE, bytes(32))]


def verdict(rt, args=None, result=I64, batch_format=h.VALUES):
    """(status, message) of validate for the argument types `args` ([(name, type)]) and the result."""
    spec = h.Spec("m:f", args=[("x", I64)] if args is None else args, result=result, code=CODE,
                  batch_format=batch_format)
    status, err = rt.validate(spec)
    return status, err.message if err else None


def deep(levels):
    t = I64
    for _ in range(levels):
        t = pa.list_(t)
    return t


def wide(n):
    return pa.struct([("c%d" % i, I64) for i in range(n)])


def validate_accepts_each_carried_type_as_an_argument_and_as_the_result(env):
    rt = env.runtime()
    for label, t, _ in ALL:
        assert verdict(rt, result=t) == (h.OK, None), (label, "result", "VALUES")
        for fmt in (h.VALUES, h.ARROW):
            if fmt == h.VALUES and has_ns(t):
                continue
            assert verdict(rt, args=[("x", t)], result=t, batch_format=fmt) == (h.OK, None), (label, fmt)
    mixed_args = [("a", pa.bool_()), ("b", pa.string()), ("c", pa.decimal128(38, 2)), ("d", pa.list_(AB)),
                  ("e", pa.timestamp("ns", tz="UTC")), ("f", pa.large_binary()), ("g", pa.date32())]
    assert verdict(rt, args=mixed_args, batch_format=h.ARROW) == (h.OK, None)
    assert verdict(rt, args=[("x", deep(15))], result=deep(15)) == (h.OK, None), "16 levels deep"
    assert verdict(rt, result=wide(255)) == (h.OK, None), "256 type nodes"
    assert verdict(rt, args=[("x", pa.struct([("n" * 63, I64)]))], result=pa.struct([("n" * 63, I64)])) == (
        h.OK, None), "a name of 63 bytes"
    assert verdict(rt, args=[("x", pa.timestamp("us", tz="z" * 63))]) == (h.OK, None), "a zone of 63 bytes"


def validate_refuses_a_type_that_is_not_carried_by_name_and_path(env):
    rt = env.runtime()
    refusals = [
        (pa.uint8(), NOT_BUILT % ("C", "%s")), (pa.float16(), NOT_BUILT % ("e", "%s")),
        (pa.date64(), NOT_BUILT % ("tdm", "%s")), (pa.null(), NOT_BUILT % ("n", "%s")),
        (pa.time32("s"), NOT_BUILT % ("tts", "%s")), (pa.duration("s"), NOT_BUILT % ("tDs", "%s")),
        (pa.binary(4), NOT_BUILT % ("w:4", "%s")), (pa.list_(I64, 3), NOT_BUILT % ("+w:3", "%s")),
        (pa.map_(pa.string(), I64), NOT_BUILT % ("+m", "%s")),
        (pa.decimal256(10, 2), NOT_BUILT % ("d:10,2,256", "%s")),
        (pa.dictionary(I32, pa.string()), DICTIONARY % "%s"),
    ]
    for t, text in refusals:
        for fmt in (h.VALUES, h.ARROW):
            assert verdict(rt, args=[("x", t)], batch_format=fmt) == (h.ERR_UNSUPPORTED, text % "x"), (t, fmt)
        assert verdict(rt, result=t) == (h.ERR_UNSUPPORTED, text % "the result"), t
    inside = [
        (pa.list_(pa.uint8()), NOT_BUILT % ("C", "%s.item")),
        (pa.large_list(pa.float16()), NOT_BUILT % ("e", "%s.item")),
        (pa.struct([("a", I64), ("z", pa.date64())]), NOT_BUILT % ("tdm", "%s.z")),
        (pa.list_(pa.struct([("k", pa.map_(pa.string(), I64))])), NOT_BUILT % ("+m", "%s.item.k")),
        (pa.list_(pa.dictionary(I32, pa.string())), DICTIONARY % "%s.item"),
    ]
    for t, text in inside:
        assert verdict(rt, args=[("x", t)]) == (h.ERR_UNSUPPORTED, text % "x"), t
        assert verdict(rt, result=t) == (h.ERR_UNSUPPORTED, text % "the result"), t
    assert verdict(rt, args=[("a", I64), ("second", pa.uint16())]) == (
        h.ERR_UNSUPPORTED, NOT_BUILT % ("S", "second"))


def validate_refuses_a_type_beyond_the_depth_node_name_and_zone_limits(env):
    rt = env.runtime()
    # The refusal names the node one level past the limit: its column, then
    # one `.item` per list above it.
    assert verdict(rt, args=[("x", deep(16))]) == (h.ERR_UNSUPPORTED, DEEP % ("x" + ".item" * 16))
    assert verdict(rt, result=deep(16)) == (h.ERR_UNSUPPORTED, DEEP % ("the result" + ".item" * 16))
    assert verdict(rt, args=[("x", deep(15))]) == (h.OK, None)
    # A struct of 256 fields is 257 nodes: the refusal names the 257th.
    assert verdict(rt, result=wide(256)) == (h.ERR_UNSUPPORTED, TOO_MANY % "the result.c255")
    assert verdict(rt, args=[("x", wide(256))]) == (h.ERR_UNSUPPORTED, TOO_MANY % "x.c255")
    assert verdict(rt, result=wide(255)) == (h.OK, None)
    name = "n" * 64
    assert verdict(rt, result=pa.struct([(name, I64)])) == (
        h.ERR_UNSUPPORTED, NAME_TOO_LONG % (64, "the result"))
    assert verdict(rt, args=[("x", pa.struct([(name, I64)]))]) == (
        h.ERR_UNSUPPORTED, NAME_TOO_LONG % (64, "x"))
    assert verdict(rt, args=[("x", pa.list_(pa.struct([(name, I64)])))]) == (
        h.ERR_UNSUPPORTED, NAME_TOO_LONG % (64, "x.item"))
    assert verdict(rt, result=pa.struct([("n" * 63, I64)])) == (h.OK, None)
    assert verdict(rt, args=[("x", pa.timestamp("us", tz="z" * 64))]) == (
        h.ERR_UNSUPPORTED, ZONE_TOO_LONG % (64, "x"))
    assert verdict(rt, result=pa.timestamp("us", tz="z" * 64)) == (
        h.ERR_UNSUPPORTED, ZONE_TOO_LONG % (64, "the result"))
    assert verdict(rt, result=pa.struct([])) == (h.ERR_UNSUPPORTED, NO_CHILDREN % "the result")
    assert verdict(rt, args=[("x", pa.struct([]))]) == (h.ERR_UNSUPPORTED, NO_CHILDREN % "x")


def a_values_function_cannot_take_a_nanosecond_timestamp_but_an_arrow_one_can(env):
    rt = env.runtime()
    ns, ns_utc = pa.timestamp("ns"), pa.timestamp("ns", tz="UTC")
    for t, path in ((ns, "x"), (ns_utc, "x"), (pa.list_(ns), "x.item"), (pa.struct([("a", I64), ("w", ns)]), "x.w"),
                    (pa.large_list(pa.struct([("w", ns_utc)])), "x.item.w")):
        assert verdict(rt, args=[("x", t)]) == (h.ERR_UNSUPPORTED, NS_VALUES % path), t
        assert verdict(rt, args=[("x", t)], batch_format=h.ARROW) == (h.OK, None), t
        assert verdict(rt, result=t) == (h.OK, None), t
    assert verdict(rt, args=[("a", I64), ("b", ns)]) == (h.ERR_UNSUPPORTED, NS_VALUES % "b")
    spec = env.bundle_spec({"ops.py": OPS}, "ops:ident", args=[("x", ns)], result=ns)
    status, udf, err = rt.load(spec)
    assert (status, udf, err.message) == (h.ERR_UNSUPPORTED, None, NS_VALUES % "x"), err
    spec = env.bundle_spec({"ops.py": OPS}, "ops:ok_ns", result=ns)
    udf = rt.load_ok(spec)
    inst = rt.open_context_ok().open_instance_ok(udf)
    out = inst.call_ok([pa.array([1], I64)])
    assert out.type == ns and out.cast(I64).to_pylist() == [micros(CONSTANTS["ok_ns"]) * 1000]


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
