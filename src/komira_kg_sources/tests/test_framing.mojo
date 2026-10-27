# =============================================================================
# test_framing.mojo -- the byte and name helpers every stored object uses.
# =============================================================================
#
#   writers   integers are little-endian; a string is a u32 length and its bytes;
#             a string over the limit and a length a u32 cannot hold are refused.
#   readers   each reader returns what the writer wrote and moves the offset past
#             it; a read past the end, at a negative offset or past the end of
#             the body is refused; a length that would wrap an `offset + length`
#             sum (4294967295 at a non-zero offset) is refused by subtraction; a
#             string over the limit, or not UTF-8, is refused; trailing bytes are
#             refused.
#   names     text, prefix and hash-name rules; two prefixes nest when equal or
#             one lies under the other at a '/'; a listing location is cut to its
#             name only when it has the directory and the suffix.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg_sources.framing import (
    FIELD_MAX_BYTES,
    check_prefix,
    check_text,
    expect_end,
    get_bytes,
    get_i64,
    get_text,
    get_u32,
    get_u8,
    is_hash_name,
    name_without_suffix,
    need,
    prefixes_nest,
    put_bytes,
    put_i64,
    put_length,
    put_text,
    put_u32,
    put_u8,
    sort_strings,
)


def _long(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "x"
    return s^


def _bytes(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def test_integers_are_little_endian() raises:
    var out = List[UInt8]()
    put_u8(out, 7)
    put_u32(out, 0x01020304)
    put_i64(out, Int64(-2))
    assert_equal(len(out), 13)
    assert_equal(Int(out[0]), 7)
    assert_equal(Int(out[1]), 4)
    assert_equal(Int(out[2]), 3)
    assert_equal(Int(out[3]), 2)
    assert_equal(Int(out[4]), 1)
    assert_equal(Int(out[5]), 254)
    for i in range(6, 13):
        assert_equal(Int(out[i]), 255)
    var off = 0
    assert_equal(get_u8(out, off, "t", "a"), 7)
    assert_equal(get_u32(out, off, "t", "b"), 0x01020304)
    assert_equal(get_i64(out, off, "t", "c"), Int64(-2))
    assert_equal(off, 13)
    expect_end(out, off, "t")


def test_a_string_and_a_byte_run_round_trip() raises:
    var out = List[UInt8]()
    put_text(out, "café", "name")
    put_bytes(out, _bytes([0, 255, 0, 10]), "run")
    var off = 0
    assert_equal(get_text(out, off, "t", "name"), "café")
    var run = get_bytes(out, off, "t", "run")
    assert_equal(len(run), 4)
    assert_equal(Int(run[1]), 255)
    assert_equal(Int(run[3]), 10)
    expect_end(out, off, "t")


def test_a_length_a_u32_cannot_hold_is_not_written() raises:
    var out = List[UInt8]()
    put_length(out, 4294967295, "run")
    assert_equal(len(out), 4)
    for i in range(4):
        assert_equal(Int(out[i]), 255)
    with assert_raises(contains="run length 4294967296 does not fit in a u32"):
        put_length(out, 4294967296, "run")
    with assert_raises(contains="run length -1 does not fit in a u32"):
        put_length(out, -1, "run")
    assert_equal(len(out), 4)


def test_a_string_over_the_limit_is_not_written() raises:
    var out = List[UInt8]()
    put_text(out, _long(FIELD_MAX_BYTES), "name")
    assert_equal(len(out), 4 + FIELD_MAX_BYTES)
    with assert_raises(contains="name is 65537 bytes, over the limit of 65536"):
        put_text(out, _long(FIELD_MAX_BYTES + 1), "name")


def test_reads_past_the_end_are_refused() raises:
    var body = _bytes([1, 2, 3])
    var off = 0
    with assert_raises(contains="t: truncated word at offset 0 (3 bytes remain)"):
        _ = get_u32(body, off, "t", "word")
    off = 3
    with assert_raises(contains="truncated byte at offset 3 (0 bytes remain)"):
        _ = get_u8(body, off, "t", "byte")
    off = 1
    with assert_raises(contains="truncated big at offset 1 (2 bytes remain)"):
        _ = get_i64(body, off, "t", "big")
    off = 9
    with assert_raises(contains="truncated byte at offset 9 (0 bytes remain)"):
        need(body, off, 1, "t", "byte")
    off = -1
    with assert_raises(contains="truncated byte at offset -1 (0 bytes remain)"):
        need(body, off, 1, "t", "byte")
    with assert_raises(contains="truncated byte"):
        need(body, 0, -1, "t", "byte")
    need(body, 0, 3, "t", "whole body")
    need(body, 3, 0, "t", "nothing at the end")


def test_a_length_that_would_wrap_an_offset_sum_is_refused() raises:
    # u32 length 4294967295 at offset 1: `offset + length` is 4294967296.
    var body = _bytes([9, 255, 255, 255, 255, 1, 2, 3])
    var off = 1
    with assert_raises(contains="truncated run at offset 5"):
        _ = get_bytes(body, off, "t", "run")
    off = 1
    with assert_raises(contains="the name claims 4294967295 bytes"):
        _ = get_text(body, off, "t", "name")


def test_a_length_past_the_end_is_refused_before_anything_is_allocated() raises:
    var body = _bytes([5, 0, 0, 0, 65, 66])
    var off = 0
    with assert_raises(contains="truncated run at offset 4 (2 bytes remain)"):
        _ = get_bytes(body, off, "t", "run")
    off = 0
    with assert_raises(contains="truncated name at offset 4 (2 bytes remain)"):
        _ = get_text(body, off, "t", "name")


def test_a_string_over_the_limit_is_refused_on_read() raises:
    var body = List[UInt8]()
    put_u32(body, FIELD_MAX_BYTES + 1)
    for _ in range(FIELD_MAX_BYTES + 1):
        body.append(UInt8(120))
    var off = 0
    with assert_raises(contains="claims 65537 bytes, over the limit of 65536"):
        _ = get_text(body, off, "t", "name")


def test_a_string_that_is_not_utf8_is_refused() raises:
    var body = _bytes([2, 0, 0, 0, 0xC3, 0x28])
    var off = 0
    with assert_raises(contains="t: the name is not valid UTF-8"):
        _ = get_text(body, off, "t", "name")


def test_trailing_bytes_are_refused() raises:
    var body = _bytes([1, 2])
    expect_end(body, 2, "t")
    with assert_raises(contains="t: 1 trailing bytes after the last field"):
        expect_end(body, 1, "t")


def test_text_rules() raises:
    check_text("f", "ok", False)
    check_text("f", "", True)
    check_text("f", _long(FIELD_MAX_BYTES), False)
    with assert_raises(contains="f must not be empty"):
        check_text("f", "", False)
    with assert_raises(contains="f is 65537 bytes"):
        check_text("f", _long(FIELD_MAX_BYTES + 1), True)
    with assert_raises(contains="f must not hold a control byte"):
        check_text("f", "a\nb", False)
    with assert_raises(contains="f must not hold a control byte"):
        check_text("f", "a" + chr(127) + "b", False)
    with assert_raises(contains="f must not hold a control byte"):
        check_text("f", "a" + chr(31) + "b", False)
    check_text("f", "a bé", False)


def test_prefix_rules() raises:
    check_prefix("p", "a")
    check_prefix("p", "area/store")
    with assert_raises(contains="p must not be empty"):
        check_prefix("p", "")
    with assert_raises(contains="p must not start or end with '/'"):
        check_prefix("p", "/a")
    with assert_raises(contains="p must not start or end with '/'"):
        check_prefix("p", "a/")
    with assert_raises(contains="p must not hold '//'"):
        check_prefix("p", "a//b")
    with assert_raises(contains="p must not hold a control byte"):
        check_prefix("p", "a\tb")


def test_prefixes_nest_when_equal_or_one_lies_under_the_other() raises:
    assert_true(prefixes_nest("a", "a"))
    assert_true(prefixes_nest("a", "a/b"))
    assert_true(prefixes_nest("a/b", "a"))
    assert_true(prefixes_nest("a/b/c", "a/b"))
    assert_false(prefixes_nest("a", "ab"))
    assert_false(prefixes_nest("ab", "a"))
    assert_false(prefixes_nest("a/b", "a/c"))
    assert_false(prefixes_nest("raw", "lineage"))


def test_hash_names() raises:
    assert_true(is_hash_name("0123456789abcdef"))
    assert_false(is_hash_name("0123456789abcde"))
    assert_false(is_hash_name("0123456789abcdef0"))
    assert_false(is_hash_name("0123456789ABCDEF"))
    assert_false(is_hash_name("0123456789abcdeg"))
    assert_false(is_hash_name("0123456789abcde/"))
    assert_false(is_hash_name(""))


def test_a_location_is_cut_to_its_name() raises:
    assert_equal(name_without_suffix("p/raw/ab12.rawrec", "p/raw/", ".rawrec"), "ab12")
    assert_equal(name_without_suffix("p/raw/.rawrec", "p/raw/", ".rawrec"), "")
    assert_equal(name_without_suffix("q/raw/ab12.rawrec", "p/raw/", ".rawrec"), "")
    assert_equal(name_without_suffix("p/raw/ab12.other", "p/raw/", ".rawrec"), "")
    assert_equal(name_without_suffix("p/raw", "p/raw/", ".rawrec"), "")
    assert_equal(name_without_suffix("p/raw/a/b.rawrec", "p/raw/", ".rawrec"), "a/b")


def test_strings_sort_ascending() raises:
    var keys = List[String]()
    keys.append("b")
    keys.append("c")
    keys.append("a")
    keys.append("a")
    sort_strings(keys)
    assert_equal(keys[0], "a")
    assert_equal(keys[1], "a")
    assert_equal(keys[2], "b")
    assert_equal(keys[3], "c")
    var empty = List[String]()
    sort_strings(empty)
    assert_equal(len(empty), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
