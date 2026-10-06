# =============================================================================
# TopNBoundary — the two invariants a wrong answer would ride in on
# =============================================================================
#
# `komira_morsel/topn_boundary.mojo` is consumed at a Parquet claim site to
# SKIP a whole row group. Two properties are therefore correctness properties,
# not tuning ones, and each is asserted here in the direction that FAILS on the
# obvious wrong edit:
#
#   1. THE PRUNE IS STRICT. A unit whose key range TOUCHES the boundary is
#      KEPT. Flip `>` to `>=` in `prunes_range` and `test_asc_tie_at_boundary_
#      is_not_pruned` fails — which is exactly right, because that edit drops
#      rows a tie-break key could still promote into the answer.
#   2. THE BOUNDARY ONLY TIGHTENS. `publish` of a looser value is a no-op, so
#      a worker that has just started cannot undo a worker that has finished.
#      Delete the `candidate >= old` guard and `test_publish_only_tightens`
#      fails.
#
# Plus the thing the whole design rests on: a `clone()` names the SAME cell.
# If it did not, every worker would publish into its own private word and the
# scan would read an UNSET boundary forever — a silent no-op that no value
# check anywhere could see, because the answer would still be right.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_morsel.topn_boundary import TopNBoundary


def test_unset_prunes_nothing() raises:
    var b = TopNBoundary.new(descending=False)
    assert_false(b.is_set())
    # Any range at all, including one entirely above every plausible key.
    assert_false(b.prunes_range(Int64(1_000_000), Int64(2_000_000)))
    assert_false(b.prunes_range(Int64(-5), Int64(-1)))
    _ = b^


def test_unset_prunes_nothing_descending() raises:
    var b = TopNBoundary.new(descending=True)
    assert_false(b.is_set())
    assert_false(b.prunes_range(Int64(-2_000_000), Int64(-1_000_000)))
    _ = b^


def test_asc_prunes_strictly_worse_range() raises:
    var b = TopNBoundary.new(descending=False)
    b.publish(Int64(100))
    assert_true(b.is_set())
    assert_equal(Int(b.load()), 100)
    # Every key in the unit is strictly worse than the cut -> prunable.
    assert_true(b.prunes_range(Int64(101), Int64(500)))
    # The unit straddles the cut -> NOT prunable.
    assert_false(b.prunes_range(Int64(50), Int64(500)))
    # The unit is entirely better -> NOT prunable.
    assert_false(b.prunes_range(Int64(1), Int64(99)))
    _ = b^


def test_asc_tie_at_boundary_is_not_pruned() raises:
    """⛔ THE STRICTNESS TEST. A unit whose MINIMUM equals the boundary holds
    rows that can still win on a tie-break key. `>=` here is a wrong answer."""
    var b = TopNBoundary.new(descending=False)
    b.publish(Int64(100))
    assert_false(b.prunes_range(Int64(100), Int64(100)))
    assert_false(b.prunes_range(Int64(100), Int64(999)))
    _ = b^


def test_desc_prunes_strictly_worse_range() raises:
    var b = TopNBoundary.new(descending=True)
    b.publish(Int64(100))
    assert_true(b.is_set())
    # Descending: worse = smaller.
    assert_true(b.prunes_range(Int64(1), Int64(99)))
    assert_false(b.prunes_range(Int64(1), Int64(100)))
    assert_false(b.prunes_range(Int64(101), Int64(500)))
    _ = b^


def test_publish_only_tightens() raises:
    var b = TopNBoundary.new(descending=False)
    b.publish(Int64(100))
    b.publish(Int64(500))          # looser — must be ignored
    assert_equal(Int(b.load()), 100)
    b.publish(Int64(20))           # tighter — must win
    assert_equal(Int(b.load()), 20)
    b.publish(Int64(20))           # equal — idempotent
    assert_equal(Int(b.load()), 20)
    _ = b^


def test_publish_only_tightens_descending() raises:
    var b = TopNBoundary.new(descending=True)
    b.publish(Int64(100))
    b.publish(Int64(20))           # looser for DESC
    assert_equal(Int(b.load()), 100)
    b.publish(Int64(500))
    assert_equal(Int(b.load()), 500)
    _ = b^


def test_clone_shares_one_cell() raises:
    """⛔ THE DESIGN TEST. Producer and consumer hold two HANDLES to ONE word.
    A clone that copied the value would make the whole mechanism an inert
    no-op that still answers correctly — invisible to every value gate."""
    var producer = TopNBoundary.new(descending=False)
    var consumer = producer.clone()
    assert_false(consumer.is_set())
    producer.publish(Int64(42))
    assert_true(consumer.is_set())
    assert_equal(Int(consumer.load()), 42)
    assert_true(consumer.prunes_range(Int64(43), Int64(44)))
    # And the other direction: a clone of a clone is still the same cell.
    var third = consumer.clone()
    third.publish(Int64(7))
    assert_equal(Int(producer.load()), 7)
    _ = third^
    _ = consumer^
    _ = producer^


def test_sentinel_key_fails_safe() raises:
    """A real key EQUAL to the unset sentinel reads as 'nobody published'. That
    is the ONE direction this file may fail in: the scan prunes nothing."""
    var b = TopNBoundary.new(descending=False)
    b.publish(Int64.MAX)
    assert_false(b.is_set())
    assert_false(b.prunes_range(Int64.MAX, Int64.MAX))
    _ = b^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
