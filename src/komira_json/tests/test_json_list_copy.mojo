# =============================================================================
# test_json_list_copy.mojo: a JsonValue survives being copied as a LIST
# ELEMENT.
# =============================================================================
#
# Mojo 1.0.0 can treat a struct's synthesized copy constructor as trivial
# for some layouts of a struct with an explicit `__deinit__`, and
# `List.copy()` then copies the elements with a memcpy: the copy and the
# original share their String and List buffers, and dropping the copy frees
# them under the original. JsonValue's current layout does not reproduce
# this; the test guards a layout or compiler change that would.
#
# The primary guard is compile-time: `main` asserts that JsonValue's copy
# constructor and destructor are non-trivial, so `List` must call them per
# element. The runtime cases are secondary coverage of every path that
# copies a JsonValue: `List.copy()` of scalars and of nested trees,
# `List.extend`, `JsonValue(copy=...)`, and `.copy()`. Each case builds,
# copies, drops the copy, allocates same-size Strings to reuse any freed
# String buffer, then reads the originals back. That reuse targets the
# String size class only, so it detects shared `text` and key buffers; a
# shared `children` or `obj_keys` buffer shows up only if the double free
# crashes. Every case runs and each failing one is named.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value

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
    # `List.copy()`, then drop the copy.
    var a = items.copy()
    _ = a^


def tree(i: Int) raises -> JsonValue:
    """`{"k<i>": "s<i>", "arr<i>": ["e0-<i>", {"inner<i>": "deep<i>"}]}`,
    every key and string padded past the inline capacity."""
    var inner = JsonValue.empty_object()
    inner.set_member(
        pad(String("inner") + String(i)),
        JsonValue.from_string(pad(String("deep") + String(i))),
    )
    var arr = JsonValue.empty_array()
    arr.push(JsonValue.from_string(pad(String("e0-") + String(i))))
    arr.push(inner^)
    var obj = JsonValue.empty_object()
    obj.set_member(
        pad(String("k") + String(i)),
        JsonValue.from_string(pad(String("s") + String(i))),
    )
    obj.set_member(pad(String("arr") + String(i)), arr^)
    return obj^


def check_tree(v: JsonValue, i: Int) raises:
    assert_true(v.is_object())
    assert_equal(v.num_members(), 2)
    assert_equal(v.key_at(0), pad(String("k") + String(i)))
    assert_equal(v.key_at(1), pad(String("arr") + String(i)))
    assert_equal(v.children[0].text, pad(String("s") + String(i)))
    ref arr = v.children[1]
    assert_true(arr.is_array())
    assert_equal(arr.array_len(), 2)
    assert_equal(arr.children[0].text, pad(String("e0-") + String(i)))
    ref inner = arr.children[1]
    assert_equal(inner.obj_keys[0], pad(String("inner") + String(i)))
    assert_equal(inner.children[0].text, pad(String("deep") + String(i)))


def check_list_of_strings() raises:
    var items = List[JsonValue]()
    for i in range(N):
        items.append(JsonValue.from_string(pad(String("a") + String(i))))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        assert_equal(items[i].as_string(), pad(String("a") + String(i)))
    assert_equal(len(junk), 256)


def check_list_of_trees() raises:
    var items = List[JsonValue]()
    for i in range(N):
        items.append(tree(i))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        check_tree(items[i], i)
    assert_equal(len(junk), 256)


def check_list_of_parsed() raises:
    var items = List[JsonValue]()
    for i in range(N):
        var text = (
            String('{"')
            + pad(String("pk") + String(i))
            + '":["'
            + pad(String("pv") + String(i))
            + '",{"'
            + pad(String("pq") + String(i))
            + '":"'
            + pad(String("pw") + String(i))
            + '"}]}'
        )
        items.append(parse_json_value(text))
    copy_and_drop(items)
    var junk = churn(256)
    for i in range(N):
        ref v = items[i]
        assert_equal(v.key_at(0), pad(String("pk") + String(i)))
        ref arr = v.children[0]
        assert_equal(arr.children[0].text, pad(String("pv") + String(i)))
        assert_equal(arr.children[1].obj_keys[0], pad(String("pq") + String(i)))
        assert_equal(
            arr.children[1].children[0].text, pad(String("pw") + String(i))
        )
    assert_equal(len(junk), 256)


def check_children_list_copy() raises:
    # The recursion box itself: copy one value's `children`, drop the copy.
    var v = JsonValue.empty_array()
    for i in range(N):
        v.push(tree(i))
    copy_and_drop(v.children)
    var junk = churn(256)
    for i in range(N):
        check_tree(v.children[i], i)
    assert_equal(len(junk), 256)


def check_extend() raises:
    var items = List[JsonValue]()
    for i in range(N):
        items.append(tree(i))
    var other = List[JsonValue]()
    other.extend(Span(items))
    _ = other^
    var junk = churn(256)
    for i in range(N):
        check_tree(items[i], i)
    assert_equal(len(junk), 256)


def check_copy_constructor() raises:
    var v = JsonValue.empty_array()
    for i in range(N):
        v.push(tree(i))
    var c = JsonValue(copy=v)
    _ = c^
    var d = v.copy()
    _ = d^
    var junk = churn(256)
    assert_equal(v.array_len(), N)
    for i in range(N):
        check_tree(v.children[i], i)
    assert_equal(len(junk), 256)


def main() raises:
    comptime assert not JsonValue.__copy_ctor_is_trivial, (
        "JsonValue must have a non-trivial copy constructor: a trivial one"
        " lets List.copy() memcpy elements and share their heap buffers"
    )
    comptime assert not JsonValue.__del__is_trivial, (
        "JsonValue must have a non-trivial destructor: it owns heap buffers"
    )
    var failed = 0
    try:
        check_list_of_strings()
    except e:
        print("FAIL list of strings:", e)
        failed += 1
    try:
        check_list_of_trees()
    except e:
        print("FAIL list of trees:", e)
        failed += 1
    try:
        check_list_of_parsed()
    except e:
        print("FAIL list of parsed values:", e)
        failed += 1
    try:
        check_children_list_copy()
    except e:
        print("FAIL children list copy:", e)
        failed += 1
    try:
        check_extend()
    except e:
        print("FAIL List.extend:", e)
        failed += 1
    try:
        check_copy_constructor()
    except e:
        print("FAIL JsonValue(copy=...):", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " JsonValue copy path(s) corrupted")
    print("test_json_list_copy: PASS")
