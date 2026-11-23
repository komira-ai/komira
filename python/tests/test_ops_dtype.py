"""The dtype spellings of komira._ops._dtype: `parse` and `canonical` for every
type the komira/python runtime carries, the canonical form of each spelling
(whitespace, the `list<T>` shorthand and the aliases), the struct field-name
rules, the decimal and timestamp parameters, and every refusal (exact class and
full message): unknown names, trailing text, unbalanced brackets, and a list
item or struct field that is not a flat type.

    test_ops_dtype.py
"""

import dataclasses
import sys

from komira._errors import UnsupportedOperation
from komira._ops import _dtype

# The types a refusal lists, written out here so a change of the list is a
# change of this file.
CARRIED = (
    "bool, int8, int16, int32, int64, float32, float64, string, large_string, binary, large_binary, "
    "date32[day], timestamp[s|ms|us|ns] with an optional tz, decimal128(p, s), list<item: T>, "
    "large_list<item: T> and struct<name: T, ...>, where a list item or struct field is not a list, "
    "a struct, a decimal or a zoned timestamp"
)
# What a refusal calls the text when `parse` and `canonical` are called with
# the text alone.
WHAT = "dtype"
# The refusal of a text that is no carried type, and the refusal of a list item
# or struct field that is a carried type a column cannot hold as a child.
UNMAPPABLE = (
    "UDF_RETURN_TYPE_UNMAPPABLE: {what} {value!r} is not a type komira/python carries; "
    "the carried types are {carried}"
)
NESTS = (
    "UDF_RETURN_TYPE_UNMAPPABLE: {what} {value!r} nests {child} in a list or struct, "
    "which a komira column cannot hold; the carried types are {carried}"
)

# (a spelling, its canonical form)
SAME = [
    ("bool", "bool"),
    ("int8", "int8"),
    ("int16", "int16"),
    ("int32", "int32"),
    ("int64", "int64"),
    ("float32", "float32"),
    ("float64", "float64"),
    ("string", "string"),
    ("large_string", "large_string"),
    ("binary", "binary"),
    ("large_binary", "large_binary"),
    ("date32[day]", "date32[day]"),
    ("timestamp[s]", "timestamp[s]"),
    ("timestamp[ms]", "timestamp[ms]"),
    ("timestamp[us]", "timestamp[us]"),
    ("timestamp[ns]", "timestamp[ns]"),
    ("timestamp[s, tz=UTC]", "timestamp[s, tz=UTC]"),
    ("timestamp[ms, tz=UTC]", "timestamp[ms, tz=UTC]"),
    ("timestamp[us, tz=Europe/Paris]", "timestamp[us, tz=Europe/Paris]"),
    ("timestamp[ns, tz=+05:30]", "timestamp[ns, tz=+05:30]"),
    ("decimal128(1, 0)", "decimal128(1, 0)"),
    ("decimal128(10, 2)", "decimal128(10, 2)"),
    ("decimal128(38, 0)", "decimal128(38, 0)"),
    ("decimal128(38, 38)", "decimal128(38, 38)"),
    ("list<item: int64>", "list<item: int64>"),
    ("large_list<item: string>", "large_list<item: string>"),
    ("list<item: timestamp[ns]>", "list<item: timestamp[ns]>"),
    ("list<item: date32[day]>", "list<item: date32[day]>"),
    ("struct<a: int64>", "struct<a: int64>"),
    ("struct<a: int64, b: string>", "struct<a: int64, b: string>"),
    ("struct<a: timestamp[us], b: large_binary>", "struct<a: timestamp[us], b: large_binary>"),
    ("struct<my col: int64>", "struct<my col: int64>"),
    ("struct<int64: string>", "struct<int64: string>"),
    ("struct<é: bool>", "struct<é: bool>"),
    # the aliases
    ("utf8", "string"),
    ("large_utf8", "large_string"),
    ("date32", "date32[day]"),
    ("list<item: utf8>", "list<item: string>"),
    ("struct<a: date32, b: large_utf8>", "struct<a: date32[day], b: large_string>"),
    # the list shorthand
    ("list<int64>", "list<item: int64>"),
    ("large_list<string>", "large_list<item: string>"),
    ("large_list<utf8>", "large_list<item: string>"),
    ("list<date32>", "list<item: date32[day]>"),
    ("list<timestamp[ns]>", "list<item: timestamp[ns]>"),
    # whitespace around punctuation
    ("timestamp[s,tz=UTC]", "timestamp[s, tz=UTC]"),
    ("timestamp[ ms , tz=UTC ]", "timestamp[ms, tz=UTC]"),
    ("timestamp[ us ]", "timestamp[us]"),
    ("decimal128(10,2)", "decimal128(10, 2)"),
    ("decimal128( 10 , 2 )", "decimal128(10, 2)"),
    ("list<item:int64>", "list<item: int64>"),
    ("list< item : int64 >", "list<item: int64>"),
    ("list< int64 >", "list<item: int64>"),
    ("struct<a:int64,b:string>", "struct<a: int64, b: string>"),
    ("struct< a : int64 , b : utf8 >", "struct<a: int64, b: string>"),
    ("struct<a:int64 ,  b:string>", "struct<a: int64, b: string>"),
]


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def unmappable(text):
    return UNMAPPABLE.format(what=WHAT, value=text, carried=CARRIED)


def nests(text, child):
    return NESTS.format(what=WHAT, value=text, child=child, carried=CARRIED)


def refused_both_ways(text, message):
    refuses(lambda: _dtype.parse(text), UnsupportedOperation, message)
    refuses(lambda: _dtype.canonical(text), UnsupportedOperation, message)


def test_the_carried_text_is_the_one_the_refusals_list():
    assert _dtype.CARRIED == CARRIED


def test_every_spelling_has_its_canonical_form():
    for given, want in SAME:
        assert _dtype.canonical(given) == want, given
        assert isinstance(_dtype.canonical(given), str), given


def test_canonical_is_a_fixed_point_of_canonical_and_parse():
    for given, want in SAME:
        assert _dtype.canonical(want) == want, want
        assert _dtype.canonical(_dtype.canonical(given)) == _dtype.canonical(given), given
        assert _dtype.parse(given) == _dtype.parse(want), given
        assert _dtype.parse(_dtype.canonical(given)) == _dtype.parse(given), given


def test_a_parsed_type_is_a_frozen_value():
    t = _dtype.parse("decimal128(10, 2)")
    assert isinstance(t, _dtype.DType)
    assert t == _dtype.parse("decimal128(10,2)")
    assert t != _dtype.parse("decimal128(10, 3)")
    assert hash(t) == hash(_dtype.parse("decimal128( 10 , 2 )"))
    e = raised(lambda: setattr(t, "precision", 5))
    assert isinstance(e, dataclasses.FrozenInstanceError), repr(e)
    assert t.precision == 10


def test_the_aliases_are_the_types_they_name():
    assert _dtype.parse("utf8") == _dtype.parse("string")
    assert _dtype.parse("large_utf8") == _dtype.parse("large_string")
    assert _dtype.parse("date32") == _dtype.parse("date32[day]")
    assert _dtype.parse("string") != _dtype.parse("large_string")
    assert _dtype.parse("binary") != _dtype.parse("large_binary")
    assert _dtype.parse("list<int64>") != _dtype.parse("large_list<int64>")


def test_the_scalar_types_are_all_different():
    names = [
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "float32",
        "float64",
        "string",
        "large_string",
        "binary",
        "large_binary",
        "date32[day]",
        "timestamp[s]",
        "timestamp[ms]",
        "timestamp[us]",
        "timestamp[ns]",
        "timestamp[us, tz=UTC]",
        "decimal128(10, 2)",
    ]
    parsed = {_dtype.parse(n) for n in names}
    assert len(parsed) == len(names)


def test_a_decimal_keeps_its_precision_and_scale():
    t = _dtype.parse("decimal128(38, 7)")
    assert (t.precision, t.scale) == (38, 7)
    t = _dtype.parse("decimal128(1,0)")
    assert (t.precision, t.scale) == (1, 0)
    t = _dtype.parse("decimal128(12, 12)")
    assert (t.precision, t.scale) == (12, 12)


def test_decimal_bounds_are_refused():
    for text in (
        "decimal128(0, 0)",
        "decimal128(39, 0)",
        "decimal128(100, 0)",
        "decimal128(5, 6)",
        "decimal128(1, 2)",
        "decimal128(5, -1)",
        "decimal128(-1, 0)",
        "decimal128(a, 0)",
        "decimal128(5, b)",
        "decimal128(5.5, 0)",
        "decimal128(, 2)",
        "decimal128(5, )",
        "decimal128()",
        "decimal128",
        "decimal128(5, 2, 128)",
    ):
        refused_both_ways(text, unmappable(text))


def test_timestamp_units_and_zones():
    zoned = _dtype.parse("timestamp[ms, tz=America/New_York]")
    assert zoned.tz == "America/New_York"
    assert _dtype.parse("timestamp[us, tz=UTC]").tz == "UTC"
    units = {_dtype.parse(f"timestamp[{u}]").unit for u in ("s", "ms", "us", "ns")}
    assert len(units) == 4
    assert _dtype.parse("timestamp[us]") != _dtype.parse("timestamp[us, tz=UTC]")
    assert _dtype.parse("timestamp[us, tz=UTC]") != _dtype.parse("timestamp[us, tz=Europe/Paris]")
    assert _dtype.parse("timestamp[us, tz=UTC]").unit == _dtype.parse("timestamp[us]").unit
    for text in (
        "timestamp",
        "timestamp[]",
        "timestamp[min]",
        "timestamp[h]",
        "timestamp[day]",
        "timestamp[us, UTC]",
        "timestamp[us, zone=UTC]",
        "timestamp[us, tz=UTC, tz=UTC]",
        "timestamp[us, tz=UTC, x]",
        "timestamp(us)",
        "timestamp[us]]",
        "date32[ms]",
        "date32[]",
        "date32[day, tz=UTC]",
    ):
        refused_both_ways(text, unmappable(text))


def test_a_list_and_a_struct_hold_their_children_by_name():
    t = _dtype.parse("list<int64>")
    assert t.children == (("item", _dtype.parse("int64")),)
    t = _dtype.parse("large_list<item: utf8>")
    assert t.children == (("item", _dtype.parse("string")),)
    t = _dtype.parse("struct<b: int64, a: string, c: timestamp[ns]>")
    assert [name for name, _ in t.children] == ["b", "a", "c"]
    assert [child for _, child in t.children] == [
        _dtype.parse("int64"),
        _dtype.parse("string"),
        _dtype.parse("timestamp[ns]"),
    ]
    assert _dtype.parse("int64").children == ()
    assert _dtype.parse("struct<a: int64, b: string>") != _dtype.parse("struct<b: string, a: int64>")
    assert _dtype.parse("struct<a: int64>") != _dtype.parse("struct<b: int64>")


def test_struct_field_names_are_non_empty_unique_and_have_no_punctuation():
    for text in (
        "struct<: int64>",
        "struct< : int64>",
        "struct<a: int64, : string>",
        "struct<a: int64, a: string>",
        "struct<a: int64, b: string, a: int64>",
        "struct<a:b: int64>",
        "struct<a,b: int64>",
        "struct<a<b: int64>",
        "struct<a>b: int64>",
    ):
        refused_both_ways(text, unmappable(text))


def test_a_struct_needs_at_least_one_well_formed_field():
    for text in (
        "struct",
        "struct<>",
        "struct< >",
        "struct<a>",
        "struct<a: >",
        "struct<a: int64,>",
        "struct<,>",
        "struct<, a: int64>",
        "struct<a: int64 b: string>",
    ):
        refused_both_ways(text, unmappable(text))


def test_a_list_has_exactly_one_item():
    for text in (
        "list",
        "large_list",
        "list<>",
        "list<item: >",
        "list<item: int64, item: int64>",
        "list<int64, int64>",
        "list<int64, string>",
    ):
        refused_both_ways(text, unmappable(text))


def test_names_the_runtime_does_not_carry_are_refused():
    for text in (
        "",
        " ",
        "int",
        "integer",
        "double",
        "float",
        "float16",
        "halffloat",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "date64",
        "date64[ms]",
        "time32[s]",
        "time32[ms]",
        "time64[us]",
        "time64[ns]",
        "duration[s]",
        "duration[ns]",
        "month_day_nano_interval",
        "null",
        "decimal256(10, 2)",
        "map<string, int64>",
        "fixed_size_binary[4]",
        "fixed_size_list<item: int64>[3]",
        "dictionary<values=string, indices=int32, ordered=0>",
        "list_view<item: int64>",
        "large_list_view<item: int64>",
        "string_view",
        "binary_view",
        "dense_union<a: int64=0>",
        "sparse_union<a: int64=0>",
        "run_end_encoded<run_ends: int32, values: int64>",
        "mystery",
        "list<item: float16>",
        "list<list<float16>>",
        "struct<a: uint8>",
        "struct<a: int64, b: map<string, int64>>",
    ):
        refused_both_ways(text, unmappable(text))


def test_trailing_text_is_refused():
    for text in (
        "int64 x",
        "int64>",
        "int64)",
        "int64]",
        "int64,",
        "string string",
        "date32[day]x",
        "timestamp[us] x",
        "timestamp[us, tz=UTC] x",
        "decimal128(10, 2) x",
        "decimal128(10, 2))",
        "list<int64> x",
        "list<int64>>",
        "struct<a: int64> x",
        "struct<a: int64>>",
        "struct<a: int64>, b: string",
    ):
        refused_both_ways(text, unmappable(text))


def test_unbalanced_brackets_are_refused():
    for text in (
        "list<int64",
        "list<",
        "list>",
        "large_list<item: int64",
        "struct<a: int64",
        "struct<a: int64, b: string",
        "struct<",
        "decimal128(10, 2",
        "decimal128(",
        "timestamp[us",
        "timestamp[us, tz=UTC",
        "timestamp[",
        "date32[day",
        "list<struct<a: int64>",
        "list<item: int64]",
        "struct<a: timestamp[us>",
    ):
        refused_both_ways(text, unmappable(text))


def test_a_list_item_or_struct_field_must_be_a_flat_type():
    for text, child in (
        ("list<item: decimal128(5, 2)>", "decimal128(5, 2)"),
        ("list<decimal128(38, 0)>", "decimal128(38, 0)"),
        ("large_list<item: decimal128(10, 3)>", "decimal128(10, 3)"),
        ("list<item: list<item: int64>>", "list<item: int64>"),
        ("list<list<int64>>", "list<item: int64>"),
        ("list<list<utf8>>", "list<item: string>"),
        ("list<item: large_list<item: int64>>", "large_list<item: int64>"),
        ("large_list<item: list<item: int64>>", "list<item: int64>"),
        ("list<item: struct<a: int64>>", "struct<a: int64>"),
        ("large_list<struct<a: int64, b: string>>", "struct<a: int64, b: string>"),
        ("list<item: timestamp[us, tz=UTC]>", "timestamp[us, tz=UTC]"),
        ("large_list<timestamp[ns, tz=Europe/Paris]>", "timestamp[ns, tz=Europe/Paris]"),
        ("struct<a: timestamp[us, tz=UTC]>", "timestamp[us, tz=UTC]"),
        ("struct<a: int64, b: decimal128(5, 2)>", "decimal128(5, 2)"),
        ("struct<a: list<item: int64>>", "list<item: int64>"),
        ("struct<a: large_list<item: string>, b: int64>", "large_list<item: string>"),
        ("struct<a: struct<b: int64>>", "struct<b: int64>"),
    ):
        refused_both_ways(text, nests(text, child))


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("ops_dtype: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
