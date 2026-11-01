# parked_morsel_share:
#   - the admission table, one clause at a time (and the ragged-tail form);
#   - publish moves every parked morsel out of the owner's slab;
#   - each published morsel is taken exactly once, in any order, and the
#     foreign witness counts the ones taken by a worker that did not publish;
#   - wait_take returns the pool's morsels while a claim is in flight and None
#     once none is in flight and the pool is empty;
#   - a disabled pool.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_parquet_scan.parked_morsel_share import ParkedMorselShare, parked_share_admitted


def test_admission() raises:
    # opt-in, morsel_rows, claims, workers, alt route, arena, fused agg
    assert_true(parked_share_admitted(True, 1024, 3, 8, False, False, False))
    assert_false(parked_share_admitted(False, 1024, 3, 8, False, False, False))
    assert_false(parked_share_admitted(True, 0, 3, 8, False, False, False))
    assert_false(parked_share_admitted(True, 1024, 0, 8, False, False, False))
    assert_false(parked_share_admitted(True, 1024, 8, 8, False, False, False))
    assert_false(parked_share_admitted(True, 1024, 3, 1, False, False, False))
    assert_false(parked_share_admitted(True, 1024, 3, 8, True, False, False))
    assert_false(parked_share_admitted(True, 1024, 3, 8, False, True, False))
    assert_false(parked_share_admitted(True, 1024, 3, 8, False, False, True))
    # The ragged tail admits a claim space as large as the pool, never an
    # empty one, and keeps every other clause.
    assert_true(parked_share_admitted(True, 1024, 20, 8, False, False, False, True))
    assert_false(parked_share_admitted(True, 1024, 0, 8, False, False, False, True))
    assert_false(parked_share_admitted(True, 1024, 20, 8, False, True, False, True))


def _morsel(id: Int) raises -> Morsel:
    return Morsel(RecordBatch.count_only(id + 1), id, 0)


def test_publish_and_take_exactly_once() raises:
    var pool = ParkedMorselShare(True)
    assert_true(pool.enabled())
    var parked = Slab[Morsel]()
    for i in range(3):
        parked.append(_morsel(i))
    pool.publish(parked, 0)
    assert_equal(len(parked), 0)
    var parked1 = Slab[Morsel]()
    parked1.append(_morsel(3))
    pool.publish(parked1, 1)
    pool.publish(parked1, 1)  # an empty slab publishes nothing
    assert_equal(pool.published_count(), 4)
    var seen = List[Bool]()
    for _ in range(4):
        seen.append(False)
    # Worker 0 takes two, worker 1 the other two.
    for t in range(4):
        var got = pool.try_take(0 if t < 2 else 1)
        assert_true(got.__bool__())
        var id = got.value().morsel_id
        assert_false(seen[id])
        seen[id] = True
        assert_equal(got.value().batch.num_rows(), id + 1)
    assert_false(pool.try_take(0).__bool__())
    # The pool is a stack: worker 0 took worker 1's morsel and one of its
    # own, worker 1 took two of worker 0's: three foreign takes.
    assert_equal(pool.foreign_count(), 3)


def test_wait_take_ends_only_when_nothing_is_in_flight() raises:
    var pool = ParkedMorselShare(True)
    pool.enter()
    var parked = Slab[Morsel]()
    parked.append(_morsel(0))
    pool.publish(parked, 2)
    var got = pool.wait_take(2)
    assert_equal(got.value().morsel_id, 0)
    pool.leave()
    assert_false(pool.wait_take(2).__bool__())
    assert_equal(pool.foreign_count(), 0)


def test_a_disabled_pool() raises:
    var pool = ParkedMorselShare(False)
    assert_false(pool.enabled())
    assert_false(pool.try_take(0).__bool__())
    assert_equal(pool.published_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
