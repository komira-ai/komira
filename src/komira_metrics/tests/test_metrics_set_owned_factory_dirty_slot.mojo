# =============================================================================
# test_metrics_set_owned_factory_dirty_slot -- new_owned_metrics_set on a
# reused, non-zero heap block
# =============================================================================
#
# `new_owned_metrics_set` allocates one uninitialized MetricsSet slot and must
# initialize every field in place. Plain field assignment (`raw[].counters =
# ...`) first destroys the field's "old value", which in a fresh slot is
# whatever bytes the allocator handed back: `Slab.__deinit__` then loops over a
# garbage `_len_t` and frees a garbage buffer pointer (komira-ai/komira#1072).
#
# Every test frees a block of exactly `size_of[MetricsSet]()` bytes just before
# the factory call, so the allocator's same-size free list hands that block to
# the factory as its slot.
#
# - test_factory_frees_nothing_planted_in_the_slot: the freed block carries a
#   well-formed `times` Slab header whose buffer pointer names a live block we
#   own (`victim`). Destroying that "old value" frees `victim`; the test then
#   allocates same-size blocks and fails if the allocator ever hands `victim`
#   back (it never returns a live block, so the check cannot misfire on
#   correct code). This is the catch in the -O0 coverage build. In the
#   optimized test build the assigning factory passed this test too: the
#   destructor calls on the uninitialized slot had no observable effect there.
# - test_factory_on_dirty_reused_block / ..._destroy_recreate_cycles: the
#   issue's repro, an all-0x41 block, then a check that every field reads its
#   initial value (a field the factory leaves unwritten reads 0x41 here, in
#   any build). At -O0 the assigning factory never returns from this repro;
#   the planted-pointer test runs first so that build fails fast instead.
# =============================================================================

from std.memory import alloc, UnsafePointer
from std.sys import size_of
from std.testing import assert_equal, assert_true

from komira_collections.slab import Slab
from komira_metrics.metrics_set import (
    MetricsSet,
    NamedTime,
    new_owned_metrics_set,
)


def _free_dirty_block(n: Int):
    """Allocate an n-byte block, fill it with 0x41, and free it."""
    var junk = List[UInt8](capacity=n)
    for _ in range(n):
        junk.append(UInt8(0x41))
    _ = junk^


def test_factory_frees_nothing_planted_in_the_slot() raises:
    """The factory must not destroy whatever its fresh slot happens to hold."""
    comptime PROBE_BYTES = 256
    comptime MAX_PROBES = 4096
    var n = size_of[MetricsSet]()
    var header_words = size_of[Slab[NamedTime]]() // size_of[Int]()
    # Learn the `times` field offset and which word of its Slab header holds
    # the buffer pointer from a live set, so the test does not hard-code the
    # Slab / List layout.
    var times_off = 0
    var buf_word = -1
    var header = List[Int](capacity=header_words)
    _read_live_times_header(header_words, times_off, buf_word, header)
    assert_true(buf_word >= 0, "found the times buffer pointer in its header")

    # SAFETY: `victim` and `dirty` are owned raw blocks local to this test.
    # `dirty` is written within its n bytes and freed once; `victim` is
    # freed below only when the factory did not free it.
    var victim = alloc[UInt8](PROBE_BYTES)
    var dirty = alloc[UInt8](n)
    for i in range(n):
        dirty[i] = UInt8(0)
    var words = (dirty + times_off).bitcast[Int]()
    for w in range(len(header)):
        words[w] = header[w]
    words[buf_word] = Int(victim)
    dirty.free()

    var m = new_owned_metrics_set()

    var probes = List[List[UInt8]]()
    var victim_freed = False
    for _ in range(MAX_PROBES):
        var p = List[UInt8](capacity=PROBE_BYTES)
        var addr = Int(p.unsafe_ptr())
        probes.append(p^)
        if addr == Int(victim):
            victim_freed = True
            break
    _ = probes^
    if not victim_freed:
        victim.free()
    assert_true(
        not victim_freed,
        "new_owned_metrics_set freed a buffer named by its fresh slot's bytes",
    )
    assert_equal(m[].num_times(), 0, "planted slot: 0 times")
    assert_true(m[].register_time["t"](), "planted slot: register t")


def _read_live_times_header(
    header_words: Int,
    mut times_off: Int,
    mut buf_word: Int,
    mut header: List[Int],
):
    """Record the `times` offset and Slab header words of a live MetricsSet."""
    var live = MetricsSet()
    var base = Int(UnsafePointer(to=live))
    times_off = Int(UnsafePointer(to=live.times)) - base
    var buf = Int(UnsafePointer(to=live.times[0]))
    var hdr = UnsafePointer(to=live.times).bitcast[Int]()
    for w in range(header_words):
        header.append(hdr[w])
        if hdr[w] == buf:
            buf_word = w


def test_factory_on_dirty_reused_block() raises:
    """One factory call on a freshly freed all-0x41 block of the slot size."""
    _free_dirty_block(size_of[MetricsSet]())
    var m = new_owned_metrics_set()
    assert_equal(m[].num_counters(), 0, "dirty block: 0 counters")
    assert_equal(m[].num_times(), 0, "dirty block: 0 times")
    assert_equal(m[].num_gauges(), 0, "dirty block: 0 gauges")
    assert_equal(
        m[].num_dropped_registrations(), 0, "dirty block: 0 dropped"
    )
    assert_true(m[].register_counter["x"](), "dirty block: register x")
    m[].counter["x"]().inc_in_pipeline(Int64(7), worker_id=0)
    assert_equal(
        Int(m[].counter["x"]().reduce()), 7, "dirty block: counter reads 7"
    )


def test_factory_dirty_block_destroy_recreate_cycles() raises:
    """Destroy-and-recreate with a dirty block planted before every call."""
    for i in range(64):
        _free_dirty_block(size_of[MetricsSet]())
        var m = new_owned_metrics_set()
        assert_equal(m[].num_counters(), 0, "cycle: fresh set has 0 counters")
        _ = m[].register_counter["rows"]()
        m[].counter["rows"]().inc_in_pipeline(Int64(i), worker_id=0)
        assert_equal(
            Int(m[].counter["rows"]().reduce()), i, "cycle: counter reads i"
        )
        _ = m^


def main() raises:
    test_factory_frees_nothing_planted_in_the_slot()
    test_factory_on_dirty_reused_block()
    test_factory_dirty_block_destroy_recreate_cycles()
    print("PASS")
