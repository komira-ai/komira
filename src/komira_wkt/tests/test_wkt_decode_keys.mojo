# =============================================================================
# test_wkt_decode_keys.mojo — every WKT `decode` body, keyed both ways.
# =============================================================================
#
# Each well-known type's `decode[D]` is one loop shared by every wire
# backend: a field is matched by its number (`PbDecoder`) OR its JSON name
# (`JsonDecoder`, which yields `field_no == 0`), and anything else goes to
# `dec.skip()`. The codec's JSON arms read a WKT through its canonical form
# (`read_proto3_json`), so the name half of each match and the skip arm are
# only reached by calling `decode[JsonDecoder]` directly, or by a binary
# message carrying a field the type does not declare. This file does both
# for every type:
#
#   - JSON keys: each declared field read by its JSON name lands in the
#     right member (a misspelt name in the match would leave it at its
#     default, or send it to the strict skip, which raises). The repeated
#     and map fields of FieldMask, ListValue and Struct read the whole
#     proto3-JSON array or object under their one key, and a scalar or an
#     array in the wrong place is refused (komira-ai/komira#1018);
#   - a strict `JsonDecoder` refuses an undeclared key (the skip arm runs:
#     dropping `dec.skip()` would accept it silently), a lenient one drops it;
#   - binary: an undeclared length-delimited field ahead of the declared
#     ones is skipped whole (without the skip, its payload bytes would be
#     read as the next tag) and the declared fields still decode.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_proto_codec import JsonDecoder, encode_proto, decode_proto

from komira_wkt import (
    Any,
    Timestamp,
    Duration,
    Empty,
    Int32Value,
    Int64Value,
    UInt32Value,
    UInt64Value,
    FloatValue,
    DoubleValue,
    BoolValue,
    StringValue,
    BytesValue,
    FieldMask,
    Struct,
    Value,
    ListValue,
    VALUE_KIND_NULL,
    VALUE_KIND_NUMBER,
    VALUE_KIND_STRING,
    VALUE_KIND_BOOL,
    VALUE_KIND_STRUCT,
    VALUE_KIND_LIST,
)
from komira_wkt.structpb import _StructEntry


# An undeclared field 15, wire type 2 (length-delimited), two payload bytes
# 0x08 0x01: if the decoder did not skip it, its length byte and payload
# would be read as the next tags.
def _unknown_prefix() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(0x7A)
    b.append(0x02)
    b.append(0x08)
    b.append(0x01)
    return b^


def _with_unknown(var known: List[UInt8]) -> List[UInt8]:
    var b = _unknown_prefix()
    for i in range(len(known)):
        b.append(known[i])
    return b^


def _json(text: String) raises -> JsonDecoder:
    return JsonDecoder.from_text(text)


def _lenient(text: String) raises -> JsonDecoder:
    return JsonDecoder.from_text_lenient(text)


comptime _UNKNOWN = "unknown field"


# =============================================================================
# Timestamp / Duration.
# =============================================================================


def test_timestamp_keys() raises:
    var d = _json('{"seconds":5,"nanos":7}')
    var t = Timestamp.decode[JsonDecoder](d)
    assert_equal(t.seconds, Int64(5))
    assert_equal(t.nanos, Int32(7))
    var s = _json('{"seconds":5,"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Timestamp.decode[JsonDecoder](s)
    var l = _lenient('{"zz":1,"nanos":9}')
    var lt = Timestamp.decode[JsonDecoder](l)
    assert_equal(lt.seconds, Int64(0))
    assert_equal(lt.nanos, Int32(9))
    var b = decode_proto[Timestamp](
        _with_unknown(encode_proto[Timestamp](Timestamp(Int64(11), Int32(12))))
    )
    assert_equal(b.seconds, Int64(11))
    assert_equal(b.nanos, Int32(12))


def test_duration_keys() raises:
    var d = _json('{"seconds":-5,"nanos":-7}')
    var v = Duration.decode[JsonDecoder](d)
    assert_equal(v.seconds, Int64(-5))
    assert_equal(v.nanos, Int32(-7))
    var s = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Duration.decode[JsonDecoder](s)
    var l = _lenient('{"seconds":3,"zz":1}')
    assert_equal(Duration.decode[JsonDecoder](l).seconds, Int64(3))
    var b = decode_proto[Duration](
        _with_unknown(encode_proto[Duration](Duration(Int64(21), Int32(22))))
    )
    assert_equal(b.seconds, Int64(21))
    assert_equal(b.nanos, Int32(22))
    assert_equal(Duration.new().seconds, Int64(0))
    assert_equal(Duration.new().nanos, Int32(0))


# =============================================================================
# Any, Empty, FieldMask.
# =============================================================================


def test_any_keys() raises:
    var d = _json('{"typeUrl":"t/x.Y","value":"AQI="}')
    var a = Any.decode[JsonDecoder](d)
    assert_equal(a.type_url, String("t/x.Y"))
    assert_equal(len(a.value), 2)
    assert_equal(a.value[0], UInt8(1))
    assert_equal(a.value[1], UInt8(2))
    var s = _json('{"typeUrl":"t/x.Y","zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Any.decode[JsonDecoder](s)
    var l = _lenient('{"zz":1,"value":"Aw=="}')
    var la = Any.decode[JsonDecoder](l)
    assert_equal(la.type_url, String(""))
    assert_equal(len(la.value), 1)
    var bytes = List[UInt8]()
    bytes.append(9)
    var b = decode_proto[Any](
        _with_unknown(encode_proto[Any](Any(String("t/a.B"), bytes^)))
    )
    assert_equal(b.type_url, String("t/a.B"))
    assert_equal(len(b.value), 1)
    assert_equal(b.value[0], UInt8(9))


def test_empty_skips_every_field() raises:
    # Empty declares no field: a binary field is skipped whole (its payload
    # is not read as a tag) and a strict JSON key is refused.
    _ = decode_proto[Empty](_unknown_prefix())
    var two = _unknown_prefix()
    var more = _unknown_prefix()
    for i in range(len(more)):
        two.append(more[i])
    _ = decode_proto[Empty](two^)
    var s = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Empty.decode[JsonDecoder](s)
    var l = _lenient('{"zz":1,"yy":2}')
    _ = Empty.decode[JsonDecoder](l)


def test_field_mask_keys() raises:
    var s = _json('{"zz":"x"}')
    with assert_raises(contains=_UNKNOWN):
        _ = FieldMask.decode[JsonDecoder](s)
    var l = _lenient('{"zz":"x","yy":"w"}')
    assert_equal(len(FieldMask.decode[JsonDecoder](l).paths), 0)
    var paths = List[String]()
    paths.append(String("p1"))
    var b = decode_proto[FieldMask](
        _with_unknown(encode_proto[FieldMask](FieldMask(paths^)))
    )
    assert_equal(len(b.paths), 1)
    assert_equal(b.paths[0], String("p1"))


# =============================================================================
# Value / Struct / ListValue / the map entry.
# =============================================================================


def test_value_keys_every_arm() raises:
    var n0 = _json('{"nullValue":0}')
    assert_equal(Value.decode[JsonDecoder](n0).kind, VALUE_KIND_NULL)
    var n1 = _json('{"numberValue":2.5}')
    var vn = Value.decode[JsonDecoder](n1)
    assert_equal(vn.kind, VALUE_KIND_NUMBER)
    assert_equal(vn.number_value, Float64(2.5))
    var n2 = _json('{"stringValue":"hi"}')
    var vs = Value.decode[JsonDecoder](n2)
    assert_equal(vs.kind, VALUE_KIND_STRING)
    assert_equal(vs.string_value, String("hi"))
    var n3 = _json('{"boolValue":true}')
    var vb = Value.decode[JsonDecoder](n3)
    assert_equal(vb.kind, VALUE_KIND_BOOL)
    assert_true(vb.bool_value)
    var n4 = _json('{"structValue":{"k":1}}')
    var vst = Value.decode[JsonDecoder](n4)
    assert_equal(vst.kind, VALUE_KIND_STRUCT)
    assert_equal(vst.struct_value[0].keys[0], String("k"))
    var n5 = _json('{"listValue":[1,2]}')
    var vl = Value.decode[JsonDecoder](n5)
    assert_equal(vl.kind, VALUE_KIND_LIST)
    assert_equal(len(vl.list_value[0].values), 2)
    var s = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Value.decode[JsonDecoder](s)
    var l = _lenient('{"zz":1,"boolValue":false}')
    assert_equal(Value.decode[JsonDecoder](l).kind, VALUE_KIND_BOOL)
    var b = decode_proto[Value](
        _with_unknown(encode_proto[Value](Value.string(String("w"))))
    )
    assert_equal(b.kind, VALUE_KIND_STRING)
    assert_equal(b.string_value, String("w"))


def test_struct_and_entry_keys() raises:
    var s = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Struct.decode[JsonDecoder](s)
    var l = _lenient('{"zz":1,"yy":{"k":2}}')
    assert_equal(len(Struct.decode[JsonDecoder](l).keys), 0)
    # The entry message itself: both names, a strict refusal, a lenient
    # drop, and a skipped binary field.
    var e = _json('{"key":"k","value":true}')
    var ent = _StructEntry.decode[JsonDecoder](e)
    assert_equal(ent.key, String("k"))
    assert_equal(ent.value.kind, VALUE_KIND_BOOL)
    var es = _json('{"key":"k","zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = _StructEntry.decode[JsonDecoder](es)
    var el = _lenient('{"zz":1,"key":"j"}')
    var lent = _StructEntry.decode[JsonDecoder](el)
    assert_equal(lent.key, String("j"))
    assert_equal(lent.value.kind, VALUE_KIND_NULL)
    var eb = decode_proto[_StructEntry](
        _with_unknown(
            encode_proto[_StructEntry](
                _StructEntry(String("m"), Value.number(Float64(4.0)))
            )
        )
    )
    assert_equal(eb.key, String("m"))
    assert_equal(eb.value.number_value, Float64(4.0))
    var one = Struct.new()
    one.put(String("z"), Value.boolean(True))
    var sb = decode_proto[Struct](_with_unknown(encode_proto[Struct](one)))
    assert_equal(len(sb.keys), 1)
    assert_equal(sb.keys[0], String("z"))
    assert_true(sb.values[0].bool_value)


def test_list_value_keys() raises:
    var s = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = ListValue.decode[JsonDecoder](s)
    var l = _lenient('{"zz":1,"yy":[3]}')
    assert_equal(len(ListValue.decode[JsonDecoder](l).values), 0)
    var one = ListValue.new()
    one.add(Value.number(Float64(6.0)))
    var b = decode_proto[ListValue](_with_unknown(encode_proto[ListValue](one)))
    assert_equal(len(b.values), 1)
    assert_equal(b.values[0].number_value, Float64(6.0))


# =============================================================================
# The repeated and map fields in their proto3-JSON message form
# (komira-ai/komira#1018). A repeated field is one key whose value is a JSON
# array, a map field one key whose value is a JSON object; the body must read
# the whole of it, and give the value the binary form of the same message
# gives. Reading one element per key raised on the FieldMask array, kept one
# of the ListValue elements, and read the Struct map's keys as fields of a
# map entry message.
# =============================================================================


def test_field_mask_paths_array() raises:
    var d = _json('{"paths":["a_b","c"]}')
    var m = FieldMask.decode[JsonDecoder](d)
    assert_equal(len(m.paths), 2)
    assert_equal(m.paths[0], String("a_b"))
    assert_equal(m.paths[1], String("c"))
    var e = _json('{"paths":[]}')
    assert_equal(len(FieldMask.decode[JsonDecoder](e).paths), 0)
    # A bare string is not the repeated field's JSON form.
    var bad = _json('{"paths":"a_b"}')
    with assert_raises(contains="expected a JSON array"):
        _ = FieldMask.decode[JsonDecoder](bad)


def test_list_value_values_array() raises:
    var d = _json('{"values":[1,"x",null,true,[2,3],{"k":4}]}')
    var lv = ListValue.decode[JsonDecoder](d)
    assert_equal(len(lv.values), 6)
    assert_equal(lv.values[0].kind, VALUE_KIND_NUMBER)
    assert_equal(lv.values[0].number_value, Float64(1.0))
    assert_equal(lv.values[1].kind, VALUE_KIND_STRING)
    assert_equal(lv.values[1].string_value, String("x"))
    assert_equal(lv.values[2].kind, VALUE_KIND_NULL)
    assert_equal(lv.values[3].kind, VALUE_KIND_BOOL)
    assert_equal(lv.values[4].kind, VALUE_KIND_LIST)
    assert_equal(len(lv.values[4].list_value[0].values), 2)
    assert_equal(lv.values[5].kind, VALUE_KIND_STRUCT)
    assert_equal(lv.values[5].struct_value[0].keys[0], String("k"))
    # The binary form of the same message decodes to the same JSON.
    var b = decode_proto[ListValue](encode_proto[ListValue](lv))
    assert_equal(b.to_proto3_json(), lv.to_proto3_json())
    assert_equal(lv.to_proto3_json(), String('[1,"x",null,true,[2,3],{"k":4}]'))
    var bad = _json('{"values":"x"}')
    with assert_raises(contains="expected a JSON array"):
        _ = ListValue.decode[JsonDecoder](bad)


def test_struct_fields_object() raises:
    var d = _json('{"fields":{"a":1,"b":"s","n":null,"o":{"p":[true]}}}')
    var st = Struct.decode[JsonDecoder](d)
    assert_equal(len(st.keys), 4)
    assert_equal(st.keys[0], String("a"))
    assert_equal(st.values[0].number_value, Float64(1.0))
    assert_equal(st.keys[1], String("b"))
    assert_equal(st.values[1].string_value, String("s"))
    assert_equal(st.keys[2], String("n"))
    assert_equal(st.values[2].kind, VALUE_KIND_NULL)
    assert_equal(st.keys[3], String("o"))
    assert_equal(st.values[3].kind, VALUE_KIND_STRUCT)
    assert_equal(
        st.to_proto3_json(), String('{"a":1,"b":"s","n":null,"o":{"p":[true]}}')
    )
    var b = decode_proto[Struct](encode_proto[Struct](st))
    assert_equal(b.to_proto3_json(), st.to_proto3_json())
    # An object whose keys happen to be the entry message's field names is
    # still a map of two members, not one entry.
    var kv = _json('{"fields":{"key":"a","value":1}}')
    var skv = Struct.decode[JsonDecoder](kv)
    assert_equal(len(skv.keys), 2)
    assert_equal(skv.keys[0], String("key"))
    assert_equal(skv.values[0].string_value, String("a"))
    assert_equal(skv.keys[1], String("value"))
    assert_equal(skv.values[1].number_value, Float64(1.0))
    var bad = _json('{"fields":[1]}')
    with assert_raises(contains="expected a JSON object"):
        _ = Struct.decode[JsonDecoder](bad)


# =============================================================================
# The scalar wrappers.
# =============================================================================


def test_float_wrapper_keys() raises:
    var d = _json('{"value":0.5}')
    assert_equal(DoubleValue.decode[JsonDecoder](d).value, Float64(0.5))
    var ds = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = DoubleValue.decode[JsonDecoder](ds)
    var dl = _lenient('{"zz":1,"value":1.5}')
    assert_equal(DoubleValue.decode[JsonDecoder](dl).value, Float64(1.5))
    var db = decode_proto[DoubleValue](
        _with_unknown(encode_proto[DoubleValue](DoubleValue(Float64(2.25))))
    )
    assert_equal(db.value, Float64(2.25))

    var f = _json('{"value":0.25}')
    assert_equal(FloatValue.decode[JsonDecoder](f).value, Float32(0.25))
    var fs = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = FloatValue.decode[JsonDecoder](fs)
    var fl = _lenient('{"zz":1,"value":-1.5}')
    assert_equal(FloatValue.decode[JsonDecoder](fl).value, Float32(-1.5))
    var fb = decode_proto[FloatValue](
        _with_unknown(encode_proto[FloatValue](FloatValue(Float32(3.5))))
    )
    assert_equal(fb.value, Float32(3.5))


def test_int_wrapper_keys() raises:
    var a = _json('{"value":"-9"}')
    assert_equal(Int64Value.decode[JsonDecoder](a).value, Int64(-9))
    var as_ = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Int64Value.decode[JsonDecoder](as_)
    var al = _lenient('{"zz":1,"value":8}')
    assert_equal(Int64Value.decode[JsonDecoder](al).value, Int64(8))
    var ab = decode_proto[Int64Value](
        _with_unknown(encode_proto[Int64Value](Int64Value(Int64(-77))))
    )
    assert_equal(ab.value, Int64(-77))

    var u = _json('{"value":"18446744073709551615"}')
    assert_equal(
        UInt64Value.decode[JsonDecoder](u).value, UInt64(18446744073709551615)
    )
    var us = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = UInt64Value.decode[JsonDecoder](us)
    var ul = _lenient('{"zz":1,"value":4}')
    assert_equal(UInt64Value.decode[JsonDecoder](ul).value, UInt64(4))
    var ub = decode_proto[UInt64Value](
        _with_unknown(encode_proto[UInt64Value](UInt64Value(UInt64(78))))
    )
    assert_equal(ub.value, UInt64(78))

    var i = _json('{"value":-3}')
    assert_equal(Int32Value.decode[JsonDecoder](i).value, Int32(-3))
    var is_ = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = Int32Value.decode[JsonDecoder](is_)
    var il = _lenient('{"zz":1,"value":5}')
    assert_equal(Int32Value.decode[JsonDecoder](il).value, Int32(5))
    var ib = decode_proto[Int32Value](
        _with_unknown(encode_proto[Int32Value](Int32Value(Int32(-79))))
    )
    assert_equal(ib.value, Int32(-79))

    var w = _json('{"value":4294967295}')
    assert_equal(UInt32Value.decode[JsonDecoder](w).value, UInt32(4294967295))
    var ws = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = UInt32Value.decode[JsonDecoder](ws)
    var wl = _lenient('{"zz":1,"value":6}')
    assert_equal(UInt32Value.decode[JsonDecoder](wl).value, UInt32(6))
    var wb = decode_proto[UInt32Value](
        _with_unknown(encode_proto[UInt32Value](UInt32Value(UInt32(80))))
    )
    assert_equal(wb.value, UInt32(80))


def test_bool_string_bytes_wrapper_keys() raises:
    var b = _json('{"value":true}')
    assert_true(BoolValue.decode[JsonDecoder](b).value)
    var bs = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = BoolValue.decode[JsonDecoder](bs)
    var bl = _lenient('{"zz":1,"value":true}')
    assert_true(BoolValue.decode[JsonDecoder](bl).value)
    var bb = decode_proto[BoolValue](
        _with_unknown(encode_proto[BoolValue](BoolValue(True)))
    )
    assert_true(bb.value)

    var s = _json('{"value":"hey"}')
    assert_equal(StringValue.decode[JsonDecoder](s).value, String("hey"))
    var ss = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = StringValue.decode[JsonDecoder](ss)
    var sl = _lenient('{"zz":1,"value":"yo"}')
    assert_equal(StringValue.decode[JsonDecoder](sl).value, String("yo"))
    var sb = decode_proto[StringValue](
        _with_unknown(encode_proto[StringValue](StringValue(String("ab"))))
    )
    assert_equal(sb.value, String("ab"))

    var y = _json('{"value":"AQI="}')
    var yv = BytesValue.decode[JsonDecoder](y)
    assert_equal(len(yv.value), 2)
    assert_equal(yv.value[1], UInt8(2))
    var ys = _json('{"zz":1}')
    with assert_raises(contains=_UNKNOWN):
        _ = BytesValue.decode[JsonDecoder](ys)
    var yl = _lenient('{"zz":1,"value":"Aw=="}')
    assert_equal(BytesValue.decode[JsonDecoder](yl).value[0], UInt8(3))
    var raw = List[UInt8]()
    raw.append(0xFE)
    var yb = decode_proto[BytesValue](
        _with_unknown(encode_proto[BytesValue](BytesValue(raw^)))
    )
    assert_equal(len(yb.value), 1)
    assert_equal(yb.value[0], UInt8(0xFE))


def main() raises:
    test_timestamp_keys()
    test_duration_keys()
    test_any_keys()
    test_empty_skips_every_field()
    test_field_mask_keys()
    test_value_keys_every_arm()
    test_struct_and_entry_keys()
    test_list_value_keys()
    test_field_mask_paths_array()
    test_list_value_values_array()
    test_struct_fields_object()
    test_float_wrapper_keys()
    test_int_wrapper_keys()
    test_bool_string_bytes_wrapper_keys()
    print("test_wkt_decode_keys: all tests passed")
