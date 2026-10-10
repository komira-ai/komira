# =============================================================================
# test_inference_byte_name_and_seed.mojo -- the unrecognized-scalar message
# and a seeded `_infer_partial_into`
# =============================================================================
#
# Refs #1117.
#   * test_unrecognized_scalar_names_the_byte -- `_classify_scalar` names
#     the first byte of a value it cannot classify as the line check does:
#     the character for printable ASCII (`x`), two hex digits otherwise
#     (0x80, 0x01). Before the fix it printed the decimal value after `0x`
#     (`byte 0x120` for `x`). `infer_jsonl_schema` on `{"a":x}` carries the
#     same message.
#   * test_seeded_partial_appends_only_new_names -- `_infer_partial_into`
#     with `column_names = ["a"]` and its inferred tag on entry: a document
#     with keys `b` and `a` leaves `["a", "b"]` with one tag per name (`a`
#     promoted by its value, `b` inferred). Before the fix every name of
#     the registry, the seeded `a` included, was appended again
#     (`["a", "a", "b"]`) while the tags grew only for `b`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json_index.structural_index import build_structural_index
from komira_jsonl.schema_inference import (
    INF_FLOAT64,
    INF_INT64,
    INF_STRING,
    _classify_scalar,
    _infer_partial_into,
    infer_jsonl_schema,
)


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _classify_err(var b: List[UInt8]) -> String:
    try:
        _ = _classify_scalar(Span(b), 1, len(b))
    except e:
        return String(e)
    return String("not refused")


def _one(prefix: UInt8, first: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    b.append(prefix)
    b.append(first)
    b.append(0x79)
    return b^


def test_unrecognized_scalar_names_the_byte() raises:
    var pre = "_classify_scalar: unrecognized scalar starting with "
    assert_equal(_classify_err(_one(0x3A, 0x78)), pre + "'x' at byte 1")
    assert_equal(_classify_err(_one(0x3A, 0x80)), pre + "byte 0x80 at byte 1")
    assert_equal(_classify_err(_one(0x3A, 0x01)), pre + "byte 0x01 at byte 1")
    var b = _bytes_of(String('{"a":x}'))
    var msg = String("not refused")
    try:
        _ = infer_jsonl_schema(Span(b))
    except e:
        msg = String(e)
    assert_true(msg.endswith(pre + "'x' at byte 5"), msg)


def test_seeded_partial_appends_only_new_names() raises:
    var b = _bytes_of(String('{"b":"s","a":1.5}\n{"b":"t"}\n'))
    var idx = build_structural_index(Span(b))
    var names = List[String]()
    names.append("a")
    var inferred = List[UInt8]()
    inferred.append(INF_INT64)
    _infer_partial_into(Span(b), idx, names, inferred)
    assert_equal(len(names), 2)
    assert_equal(names[0], "a")
    assert_equal(names[1], "b")
    assert_equal(len(inferred), 2)
    assert_equal(Int(inferred[0]), Int(INF_FLOAT64))
    assert_equal(Int(inferred[1]), Int(INF_STRING))


def main() raises:
    test_unrecognized_scalar_names_the_byte()
    test_seeded_partial_appends_only_new_names()
    print("test_inference_byte_name_and_seed: all passed")
