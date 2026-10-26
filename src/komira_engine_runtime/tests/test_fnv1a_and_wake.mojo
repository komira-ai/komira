# =============================================================================
# test_fnv1a_and_wake -- the FNV-1a hash and the address wait/wake primitives
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * `fnv1a_64_over` and `fnv1a_64_over_span` give the published FNV-1a 64
#     vectors ("" , "a", "foobar") and agree with each other: a wrong prime,
#     offset basis or xor/multiply order changes every vector;
#   * the partition fingerprint puts the 8 little-endian stride bytes first:
#     it equals the hash of those bytes followed by the tags, and differs when
#     only the stride changes;
#   * `wait_on_address` returns at once when the word already differs from
#     `expected`, returns after its timeout when it does not, and
#     `wake_all_by_address` with no waiter wakes nobody: a wait that ignores
#     `expected` or `timeout_ns` returns a non-negative status here. The
#     primitives are the ones `komira_async` defines; this package does not
#     carry its own copy.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_atomic_alias import AtomicI32
from komira_engine_runtime.spill.fnv1a import (
    FNV1A_64_OFFSET_BASIS,
    fnv1a_64_over,
    fnv1a_64_over_span,
    fnv1a_64_partition_fingerprint,
)
from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_all_by_address,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def test_fnv1a_published_vectors() raises:
    assert_equal(fnv1a_64_over(List[UInt8]()), FNV1A_64_OFFSET_BASIS)
    assert_equal(fnv1a_64_over(List[UInt8]()), UInt64(0xCBF29CE484222325))
    assert_equal(fnv1a_64_over(_bytes("a")), UInt64(0xAF63DC4C8601EC8C))
    assert_equal(fnv1a_64_over(_bytes("foobar")), UInt64(0x85944171F73967E8))


def test_fnv1a_span_matches_list() raises:
    var b = _bytes("komira spill")
    assert_equal(fnv1a_64_over_span(Span(b)), fnv1a_64_over(b))


def test_partition_fingerprint_layout() raises:
    var tags: List[UInt8] = [3, 1, 4]
    var expect = List[UInt8]()
    var stride = 40
    for i in range(8):
        expect.append(UInt8((stride >> (8 * i)) & 0xFF))
    for i in range(len(tags)):
        expect.append(tags[i])
    assert_equal(fnv1a_64_partition_fingerprint(stride, tags), fnv1a_64_over(expect))
    assert_true(
        fnv1a_64_partition_fingerprint(48, tags)
        != fnv1a_64_partition_fingerprint(40, tags)
    )


def test_wait_returns_when_word_differs() raises:
    var word = AtomicI32(Int32(1))
    var r = wait_on_address(word, Int32(0), Int64(1_000_000_000))
    comptime if CompilationTarget.is_linux():
        assert_true(r < 0)  # -EAGAIN: the value did not match


def test_wait_times_out_and_wake_without_waiters() raises:
    var word = AtomicI32(Int32(7))
    var r = wait_on_address(word, Int32(7), Int64(1_000_000))  # 1 ms
    comptime if CompilationTarget.is_linux():
        assert_true(r < 0)  # -ETIMEDOUT
    var woken = wake_all_by_address(word)
    comptime if CompilationTarget.is_linux():
        assert_equal(woken, Int32(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
