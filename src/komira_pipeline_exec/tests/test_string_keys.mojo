# =============================================================================
# The intern table of the string-keyed sink, and the content hash
# =============================================================================
#
# What these tests prove, on the table by itself:
#
#   * A string interned twice has one id, whatever the hash it is given
#     alongside is (the caller supplies the carried hash).
#   * Two different strings given the SAME hash get different ids: the probe
#     compares bytes, it does not trust the hash. That holds for a string and
#     its own prefix, and for the empty string, which is an entry like another.
#   * Five thousand strings across many doublings of the slot directory and of
#     the byte arena keep their ids and their bytes.
#   * A step the pool denies allocates nothing and changes nothing: the call
#     returns -1, says how many bytes it asked for, and the table still
#     answers for what it held. A table at its entry limit says so.
#   * The content hash is a function of the bytes alone (the same bytes from
#     two places hash alike) and tells apart strings that differ in order,
#     length or a trailing zero byte.

from std.testing import TestSuite, assert_equal, assert_true

from komira_pipeline_exec.segment_pool import SegmentPool, WorkerReservation
from komira_pipeline_exec.string_keys import InternTable, hash_string


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _text(span: Span[UInt8, _]) -> String:
    var out = String("")
    for i in range(len(span)):
        out += chr(Int(span[i]))
    return out^


def test_a_string_interned_twice_has_one_id() raises:
    var table = InternTable()
    var res = WorkerReservation(SegmentPool())
    var a = _bytes("apple")
    var first = table.intern(Span(a), hash_string(Span(a)), res)
    var other = _bytes("pear")
    var second = table.intern(Span(other), hash_string(Span(other)), res)
    var again = _bytes("apple")
    var third = table.intern(Span(again), hash_string(Span(again)), res)
    assert_equal(first, 0)
    assert_equal(second, 1)
    assert_equal(third, first)
    assert_equal(table.n, 2)


def test_different_strings_with_one_hash_are_different_entries() raises:
    var table = InternTable()
    var res = WorkerReservation(SegmentPool())
    var h = UInt64(12345)
    var abc = _bytes("abc")
    var ab = _bytes("ab")
    var abd = _bytes("abd")
    var empty = List[UInt8]()
    var i0 = table.intern(Span(abc), h, res)
    var i1 = table.intern(Span(ab), h, res)
    var i2 = table.intern(Span(abd), h, res)
    var i3 = table.intern(Span(empty), h, res)
    assert_equal(table.n, 4)
    assert_true(i0 != i1 and i0 != i2 and i1 != i2 and i3 != i0 and i3 != i1)
    assert_equal(table.intern(Span(ab), h, res), i1)
    assert_equal(table.intern(Span(empty), h, res), i3)
    assert_equal(table.intern(Span(abd), h, res), i2)
    assert_equal(len(table.value(i3)), 0)
    assert_equal(_text(table.value(i1)), "ab")
    assert_equal(_text(table.value(i2)), "abd")


def test_thousands_of_strings_keep_their_ids_and_bytes() raises:
    var table = InternTable()
    var res = WorkerReservation(SegmentPool())
    for i in range(5000):
        var b = _bytes("string number " + String(i))
        assert_equal(table.intern(Span(b), hash_string(Span(b)), res), i)
    assert_equal(table.n, 5000)
    for i in range(5000):
        var b = _bytes("string number " + String(i))
        assert_equal(table.intern(Span(b), hash_string(Span(b)), res), i)
        assert_equal(_text(table.value(i)), "string number " + String(i))
        assert_equal(table.hashes[i], hash_string(Span(b)))
    assert_equal(table.n, 5000)


def test_a_denied_step_allocates_nothing_and_changes_nothing() raises:
    var pool = SegmentPool(6000)
    var table = InternTable()
    var res = WorkerReservation(pool.share())
    var held = 0
    var denied = False
    for i in range(1000):
        var b = _bytes("denied " + String(i))
        var before = table.n
        var id = table.intern(Span(b), hash_string(Span(b)), res)
        if id < 0:
            denied = True
            assert_true(table.denied_bytes > 0)
            assert_true(not table.too_many)
            assert_equal(table.n, before)
            break
        held = table.n
    assert_true(denied, "a 6,000-byte budget did not deny 1,000 strings")
    assert_true(held > 0)
    assert_true(pool.granted() <= 6000)
    # What it held still answers.
    for i in range(held):
        var b = _bytes("denied " + String(i))
        assert_equal(table.intern(Span(b), hash_string(Span(b)), res), i)
    res.give_back_all()
    assert_equal(pool.granted(), 0)


def test_a_table_at_its_entry_limit_says_so() raises:
    var table = InternTable(128)
    var res = WorkerReservation(SegmentPool())
    for i in range(128):
        var b = _bytes("entry " + String(i))
        assert_true(table.intern(Span(b), hash_string(Span(b)), res) >= 0)
    var extra = _bytes("one too many")
    assert_equal(table.intern(Span(extra), hash_string(Span(extra)), res), -1)
    assert_true(table.too_many)
    # A string already held is still found.
    var held = _bytes("entry 7")
    assert_equal(table.intern(Span(held), hash_string(Span(held)), res), 7)


def test_the_content_hash_is_a_function_of_the_bytes() raises:
    var a1 = _bytes("hello")
    var a2 = _bytes("hello")
    assert_equal(hash_string(Span(a1)), hash_string(Span(a2)))
    var ab = _bytes("ab")
    var ba = _bytes("ba")
    assert_true(hash_string(Span(ab)) != hash_string(Span(ba)))
    var empty = List[UInt8]()
    var zero = List[UInt8]()
    zero.append(0)
    assert_true(hash_string(Span(empty)) != hash_string(Span(zero)))
    var one = _bytes("a")
    var padded = List[UInt8]()
    padded.append(97)
    padded.append(0)
    assert_true(hash_string(Span(one)) != hash_string(Span(padded)))


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_string_interned_twice_has_one_id]()
    suite.test[test_different_strings_with_one_hash_are_different_entries]()
    suite.test[test_thousands_of_strings_keep_their_ids_and_bytes]()
    suite.test[test_a_denied_step_allocates_nothing_and_changes_nothing]()
    suite.test[test_a_table_at_its_entry_limit_says_so]()
    suite.test[test_the_content_hash_is_a_function_of_the_bytes]()
    suite^.run()
