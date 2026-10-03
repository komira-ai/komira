# =============================================================================
# test_wkt_list_copy.mojo — copying a heap-owning well-known type is a DEEP
# copy, directly and as a LIST ELEMENT.
# =============================================================================
#
# A synthesized copy constructor has been reported to be treated as trivial
# for some layouts of a struct with an explicit `__deinit__`, letting
# `List.copy()` memcpy elements that own heap buffers: the copy and the
# original would share those buffers, and dropping the copy would free them
# under the original. That was not reproduced for these types: the
# list-survival checks below pass with or without the explicit copy
# constructors (see the `structpb.mojo` header), so they are a guard, not a
# reproduction.
#
# What the cases pin:
#   * `T(copy=x)` and `List[T].copy()` produce a copy EQUAL to the original,
#     field by field, for every `Value` arm (null, number, string, bool,
#     struct, list) and for `Struct`, `ListValue`, `StringValue`,
#     `BytesValue`, `FieldMask` and `Any`;
#   * mutating the copy (overwriting a String, `put` on an existing and a new
#     key, `add` an element) leaves the original unchanged;
#   * after the copy is dropped and same-size Strings (48 bytes, above the
#     inline capacity, so each owns a heap buffer) are allocated to reuse any
#     freed buffer, the original still reads back intact.
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
    VALUE_KIND_BOOL,
    VALUE_KIND_LIST,
    VALUE_KIND_NULL,
    VALUE_KIND_NUMBER,
    VALUE_KIND_STRING,
    VALUE_KIND_STRUCT,
)

comptime N = 8


# -- helpers ------------------------------------------------------------------


def _pad(s: String) -> String:
    var out = s
    while out.byte_length() < 48:
        out += "."
    return out


def _churn(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(_pad(String("CHURN") + String(i)))
    return out^


def _tag(prefix: String, i: Int) -> String:
    return _pad(prefix + String(i))


def _make_struct(i: Int) -> Struct:
    var s = Struct.new()
    s.put(_tag("k0-", i), Value.string(_tag("v0-", i)))
    s.put(_tag("k1-", i), Value.string(_tag("v1-", i)))
    return s^


def _check_struct(s: Struct, i: Int) raises:
    assert_equal(len(s.keys), 2)
    assert_equal(len(s.values), 2)
    assert_equal(s.keys[0], _tag("k0-", i))
    assert_equal(s.keys[1], _tag("k1-", i))
    assert_equal(s.values[0].kind, VALUE_KIND_STRING)
    assert_equal(s.values[0].string_value, _tag("v0-", i))
    assert_equal(s.values[1].kind, VALUE_KIND_STRING)
    assert_equal(s.values[1].string_value, _tag("v1-", i))


def _mutate_struct(mut s: Struct):
    """Overwrite a value in place, replace one by key, add a new key."""
    s.values[0].string_value = _pad("MUTATED-v0")
    var k1 = s.keys[1].copy()
    s.put(k1, Value.string(_pad("MUTATED-v1")))
    s.put(_pad("MUTATED-k2"), Value.number(Float64(7.0)))


def _make_list_value(i: Int) -> ListValue:
    var lv = ListValue.new()
    lv.add(Value.string(_tag("e0-", i)))
    lv.add(Value.string(_tag("e1-", i)))
    return lv^


def _check_list_value(lv: ListValue, i: Int) raises:
    assert_equal(len(lv.values), 2)
    assert_equal(lv.values[0].kind, VALUE_KIND_STRING)
    assert_equal(lv.values[0].string_value, _tag("e0-", i))
    assert_equal(lv.values[1].kind, VALUE_KIND_STRING)
    assert_equal(lv.values[1].string_value, _tag("e1-", i))


def _mutate_list_value(mut lv: ListValue):
    lv.values[0].string_value = _pad("MUTATED-e0")
    lv.add(Value.string(_pad("MUTATED-e2")))


# One `Value` per arm; `_make_value(i, arm)` and `_check_value(v, i, arm)`
# agree on the payload of each.
comptime ARMS = 6


def _make_value(i: Int, arm: Int) raises -> Value:
    if arm == 0:
        return Value.null()
    if arm == 1:
        return Value.number(Float64(i) + 0.5)
    if arm == 2:
        return Value.string(_tag("s", i))
    if arm == 3:
        return Value.boolean(i % 2 == 0)
    if arm == 4:
        return Value.struct_(_make_struct(i))
    if arm == 5:
        return Value.list(_make_list_value(i))
    raise Error("no arm " + String(arm))


def _check_value(v: Value, i: Int, arm: Int) raises:
    if arm == 0:
        assert_equal(v.kind, VALUE_KIND_NULL)
    elif arm == 1:
        assert_equal(v.kind, VALUE_KIND_NUMBER)
        assert_equal(v.number_value, Float64(i) + 0.5)
    elif arm == 2:
        assert_equal(v.kind, VALUE_KIND_STRING)
        assert_equal(v.string_value, _tag("s", i))
    elif arm == 3:
        assert_equal(v.kind, VALUE_KIND_BOOL)
        assert_equal(v.bool_value, i % 2 == 0)
    elif arm == 4:
        assert_equal(v.kind, VALUE_KIND_STRUCT)
        assert_equal(len(v.struct_value), 1)
        assert_equal(len(v.list_value), 0)
        _check_struct(v.struct_value[0], i)
    elif arm == 5:
        assert_equal(v.kind, VALUE_KIND_LIST)
        assert_equal(len(v.list_value), 1)
        assert_equal(len(v.struct_value), 0)
        _check_list_value(v.list_value[0], i)
    else:
        raise Error("no arm " + String(arm))


def _mutate_value(mut v: Value):
    """Change every field, and reach through the boxes into the nested
    `Struct` / `ListValue`."""
    if len(v.struct_value) > 0:
        _mutate_struct(v.struct_value[0])
    if len(v.list_value) > 0:
        _mutate_list_value(v.list_value[0])
    v.kind = VALUE_KIND_STRING
    v.number_value = Float64(-1.0)
    v.bool_value = not v.bool_value
    v.string_value = _pad("MUTATED-s")


# -- direct copy constructors -------------------------------------------------


def test_struct_copy_ctor_is_deep() raises:
    var s = _make_struct(3)
    var c = Struct(copy=s)
    _check_struct(c, 3)
    _mutate_struct(c)
    assert_equal(len(c.keys), 3)
    _check_struct(s, 3)


def test_list_value_copy_ctor_is_deep() raises:
    var lv = _make_list_value(4)
    var c = ListValue(copy=lv)
    _check_list_value(c, 4)
    _mutate_list_value(c)
    assert_equal(len(c.values), 3)
    _check_list_value(lv, 4)


def test_value_copy_ctor_is_deep_every_arm() raises:
    for arm in range(ARMS):
        var v = _make_value(5, arm)
        var c = Value(copy=v)
        _check_value(c, 5, arm)
        _mutate_value(c)
        _check_value(v, 5, arm)


def test_wrapper_copy_ctors_are_deep() raises:
    var sv = StringValue(_tag("sv", 1))
    var sc = StringValue(copy=sv)
    assert_equal(sc.value, _tag("sv", 1))
    sc.value = _pad("MUTATED-sv")
    assert_equal(sv.value, _tag("sv", 1))

    var b = List[UInt8]()
    for j in range(48):
        b.append(UInt8(j))
    var bv = BytesValue(b.copy())
    var bc = BytesValue(copy=bv)
    assert_equal(len(bc.value), 48)
    bc.value[0] = UInt8(99)
    bc.value.append(UInt8(1))
    assert_equal(len(bv.value), 48)
    assert_equal(Int(bv.value[0]), 0)

    var paths = List[String]()
    paths.append(_tag("p0-", 1))
    var fm = FieldMask(paths^)
    var fc = FieldMask(copy=fm)
    assert_equal(fc.paths[0], _tag("p0-", 1))
    fc.paths[0] = _pad("MUTATED-p0")
    fc.paths.append(_pad("MUTATED-p1"))
    assert_equal(len(fm.paths), 1)
    assert_equal(fm.paths[0], _tag("p0-", 1))

    var a = Any(_tag("type.googleapis.com/x.T", 1), b^)
    var ac = Any(copy=a)
    assert_equal(ac.type_url, _tag("type.googleapis.com/x.T", 1))
    assert_equal(len(ac.value), 48)
    ac.type_url = _pad("MUTATED-url")
    ac.value[0] = UInt8(99)
    assert_equal(a.type_url, _tag("type.googleapis.com/x.T", 1))
    assert_equal(Int(a.value[0]), 0)


# -- `List.copy()` ------------------------------------------------------------
# Each: copy the list, check the copy equals the expected content, mutate the
# copy, check the original, drop the copy, churn, check the original again.


def test_list_of_struct_copy() raises:
    var items = List[Struct]()
    for i in range(N):
        items.append(_make_struct(i))
    var copies = items.copy()
    for i in range(N):
        _check_struct(copies[i], i)
        _mutate_struct(copies[i])
    for i in range(N):
        _check_struct(items[i], i)
    _ = copies^
    var junk = _churn(256)
    for i in range(N):
        _check_struct(items[i], i)
    assert_equal(len(junk), 256)


def test_list_of_list_value_copy() raises:
    var items = List[ListValue]()
    for i in range(N):
        items.append(_make_list_value(i))
    var copies = items.copy()
    for i in range(N):
        _check_list_value(copies[i], i)
        _mutate_list_value(copies[i])
    for i in range(N):
        _check_list_value(items[i], i)
    _ = copies^
    var junk = _churn(256)
    for i in range(N):
        _check_list_value(items[i], i)
    assert_equal(len(junk), 256)


def test_list_of_value_copy_every_arm() raises:
    # Element `k` holds arm `k % ARMS`, so every arm (scalar and both boxes)
    # is copied N times.
    var items = List[Value]()
    for k in range(N * ARMS):
        items.append(_make_value(k // ARMS, k % ARMS))
    var copies = items.copy()
    for k in range(N * ARMS):
        _check_value(copies[k], k // ARMS, k % ARMS)
        _mutate_value(copies[k])
    for k in range(N * ARMS):
        _check_value(items[k], k // ARMS, k % ARMS)
    _ = copies^
    var junk = _churn(256)
    for k in range(N * ARMS):
        _check_value(items[k], k // ARMS, k % ARMS)
    assert_equal(len(junk), 256)


def test_list_of_wrappers_copy() raises:
    var strs = List[StringValue]()
    var bytes = List[BytesValue]()
    var masks = List[FieldMask]()
    var anys = List[Any]()
    for i in range(N):
        strs.append(StringValue(_tag("sv", i)))
        var b = List[UInt8]()
        for j in range(48):
            b.append(UInt8((i + j) % 256))
        bytes.append(BytesValue(b.copy()))
        var paths = List[String]()
        paths.append(_tag("p0-", i))
        paths.append(_tag("p1-", i))
        masks.append(FieldMask(paths^))
        anys.append(Any(_tag("type.googleapis.com/x.T", i), b^))
    var strs_c = strs.copy()
    var bytes_c = bytes.copy()
    var masks_c = masks.copy()
    var anys_c = anys.copy()
    for i in range(N):
        assert_equal(strs_c[i].value, _tag("sv", i))
        assert_equal(len(bytes_c[i].value), 48)
        assert_equal(Int(bytes_c[i].value[47]), (i + 47) % 256)
        assert_equal(masks_c[i].paths[1], _tag("p1-", i))
        assert_equal(anys_c[i].type_url, _tag("type.googleapis.com/x.T", i))
        strs_c[i].value = _pad("MUTATED-sv")
        bytes_c[i].value[47] = UInt8(0)
        masks_c[i].paths[1] = _pad("MUTATED-p1")
        anys_c[i].type_url = _pad("MUTATED-url")
    _ = strs_c^
    _ = bytes_c^
    _ = masks_c^
    _ = anys_c^
    var junk = _churn(256)
    for i in range(N):
        assert_equal(strs[i].value, _tag("sv", i))
        assert_equal(len(bytes[i].value), 48)
        assert_equal(Int(bytes[i].value[47]), (i + 47) % 256)
        assert_equal(masks[i].paths[0], _tag("p0-", i))
        assert_equal(masks[i].paths[1], _tag("p1-", i))
        assert_equal(anys[i].type_url, _tag("type.googleapis.com/x.T", i))
        assert_equal(len(anys[i].value), 48)
    assert_equal(len(junk), 256)


def main() raises:
    # Every case runs and each failing one is named, rather than stopping at
    # the first: a copy defect is layout-dependent, so the full set of
    # failing types is the useful report.
    var failed = 0
    try:
        test_struct_copy_ctor_is_deep()
    except e:
        print("FAIL test_struct_copy_ctor_is_deep:", e)
        failed += 1
    try:
        test_list_value_copy_ctor_is_deep()
    except e:
        print("FAIL test_list_value_copy_ctor_is_deep:", e)
        failed += 1
    try:
        test_value_copy_ctor_is_deep_every_arm()
    except e:
        print("FAIL test_value_copy_ctor_is_deep_every_arm:", e)
        failed += 1
    try:
        test_wrapper_copy_ctors_are_deep()
    except e:
        print("FAIL test_wrapper_copy_ctors_are_deep:", e)
        failed += 1
    try:
        test_list_of_struct_copy()
    except e:
        print("FAIL test_list_of_struct_copy:", e)
        failed += 1
    try:
        test_list_of_list_value_copy()
    except e:
        print("FAIL test_list_of_list_value_copy:", e)
        failed += 1
    try:
        test_list_of_value_copy_every_arm()
    except e:
        print("FAIL test_list_of_value_copy_every_arm:", e)
        failed += 1
    try:
        test_list_of_wrappers_copy()
    except e:
        print("FAIL test_list_of_wrappers_copy:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " copy case(s) failed")
    print("test_wkt_list_copy: all tests passed")
