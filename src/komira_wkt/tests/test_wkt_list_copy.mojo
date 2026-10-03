# =============================================================================
# test_wkt_list_copy.mojo — a well-known type must survive being copied as a
# LIST ELEMENT.
# =============================================================================
#
# Mojo 1.0.0 can treat a struct's synthesized copy constructor as trivial for
# some layouts of a struct with an explicit `__deinit__`, and then
# `List.copy()` copies the elements with a memcpy: the copy and the original
# share their heap buffers, dropping the copy frees them under the original,
# and a same-size allocation reuses the buffer.
#
# Each case: build a list whose Strings exceed the inline capacity (so each
# owns a heap buffer), copy the list, drop the copy, allocate same-size
# Strings to reuse any freed buffer, then read the originals back. Every case
# runs and each failing one is named.
# =============================================================================

from std.testing import assert_equal

from komira_wkt import (
    Any,
    BytesValue,
    FieldMask,
    ListValue,
    StringValue,
    Struct,
    Value,
    VALUE_KIND_LIST,
    VALUE_KIND_STRING,
    VALUE_KIND_STRUCT,
)

comptime N = 8


def pad(s: String) -> String:
    var out = s
    while out.byte_length() < 48:
        out += "."
    return out


def churn(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(pad(String("CHURN") + String(i)))
    return out^


def copy_and_drop[T: Copyable & Deinitable](items: List[T]):
    var a = items.copy()
    _ = a^


def tag(prefix: String, i: Int) -> String:
    return pad(prefix + String(i))


def make_struct(i: Int) -> Struct:
    var s = Struct.new()
    s.put(tag("k0-", i), Value.string(tag("v0-", i)))
    s.put(tag("k1-", i), Value.string(tag("v1-", i)))
    return s^


def check_struct_fields(s: Struct, i: Int) raises:
    assert_equal(len(s.keys), 2)
    assert_equal(s.keys[0], tag("k0-", i))
    assert_equal(s.keys[1], tag("k1-", i))
    assert_equal(s.values[0].string_value, tag("v0-", i))
    assert_equal(s.values[1].string_value, tag("v1-", i))


def make_list_value(i: Int) -> ListValue:
    var lv = ListValue.new()
    lv.add(Value.string(tag("e0-", i)))
    lv.add(Value.string(tag("e1-", i)))
    return lv^


def check_list_value(lv: ListValue, i: Int) raises:
    assert_equal(len(lv.values), 2)
    assert_equal(lv.values[0].string_value, tag("e0-", i))
    assert_equal(lv.values[1].string_value, tag("e1-", i))


def check_struct() raises:
    var items = List[Struct]()
    for i in range(N):
        items.append(make_struct(i))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        check_struct_fields(items[i], i)
    assert_equal(len(junk), 256)


def check_list_value_list() raises:
    var items = List[ListValue]()
    for i in range(N):
        items.append(make_list_value(i))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        check_list_value(items[i], i)
    assert_equal(len(junk), 256)


def check_value_string() raises:
    var items = List[Value]()
    for i in range(N):
        items.append(Value.string(tag("s", i)))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[i].kind, VALUE_KIND_STRING)
        assert_equal(items[i].string_value, tag("s", i))
    assert_equal(len(junk), 256)


def check_value_nested() raises:
    # The two recursive arms: a Value holding a Struct, and one holding a
    # ListValue, so the copy goes through both boxes.
    var items = List[Value]()
    for i in range(N):
        items.append(Value.struct_(make_struct(i)))
        items.append(Value.list(make_list_value(i)))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[2 * i].kind, VALUE_KIND_STRUCT)
        check_struct_fields(items[2 * i].struct_value[0], i)
        assert_equal(items[2 * i + 1].kind, VALUE_KIND_LIST)
        check_list_value(items[2 * i + 1].list_value[0], i)
    assert_equal(len(junk), 256)


def check_scalar_wrappers() raises:
    # The heap-owning wrappers, FieldMask and Any: no explicit `__deinit__`,
    # kept as a guard.
    var strs = List[StringValue]()
    var bytes = List[BytesValue]()
    var masks = List[FieldMask]()
    var anys = List[Any]()
    for i in range(N):
        strs.append(StringValue(tag("sv", i)))
        var b = List[UInt8]()
        for j in range(48):
            b.append(UInt8((i + j) % 256))
        bytes.append(BytesValue(b.copy()))
        var paths = List[String]()
        paths.append(tag("p0-", i))
        paths.append(tag("p1-", i))
        masks.append(FieldMask(paths^))
        anys.append(Any(tag("type.googleapis.com/x.T", i), b^))
    copy_and_drop(strs)
    copy_and_drop(bytes)
    copy_and_drop(masks)
    copy_and_drop(anys)
    var junk = churn(256)
    for i in range(N):
        assert_equal(strs[i].value, tag("sv", i))
        assert_equal(len(bytes[i].value), 48)
        assert_equal(Int(bytes[i].value[47]), (i + 47) % 256)
        assert_equal(masks[i].paths[0], tag("p0-", i))
        assert_equal(masks[i].paths[1], tag("p1-", i))
        assert_equal(anys[i].type_url, tag("type.googleapis.com/x.T", i))
        assert_equal(len(anys[i].value), 48)
    assert_equal(len(junk), 256)


def main() raises:
    var failed = 0
    try:
        check_struct()
    except e:
        print("FAIL Struct:", e)
        failed += 1
    try:
        check_list_value_list()
    except e:
        print("FAIL ListValue:", e)
        failed += 1
    try:
        check_value_string()
    except e:
        print("FAIL Value (string arm):", e)
        failed += 1
    try:
        check_value_nested()
    except e:
        print("FAIL Value (struct and list arms):", e)
        failed += 1
    try:
        check_scalar_wrappers()
    except e:
        print("FAIL StringValue/BytesValue/FieldMask/Any:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " case(s) corrupted by List.copy()")
    print("test_wkt_list_copy: PASS")
