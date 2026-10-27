# =============================================================================
# test_enrichment_sender.mojo -- FakeEnrichmentSender, the in-memory sender.
# =============================================================================
#
#   record       a delivered item's id, source key and body are recorded in call
#                order, and every call counts as an attempt.
#   failure      fail_all, fail_next(n) (exactly n calls, then success) and
#                fail_source (every item of that source key, others unaffected)
#                return False and record no delivery, but do count as attempts;
#                clear_failures restores delivery.
#   trait        the fake is usable through the EnrichmentSender trait.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg_enrich import EnrichmentItem, EnrichmentSender, FakeEnrichmentSender


def _item(id: String, source: String, body: String) -> EnrichmentItem:
    return EnrichmentItem.new(id.copy(), "p", source.copy(), body.copy(), Int64(1))


def test_deliveries_are_recorded_in_order() raises:
    var s = FakeEnrichmentSender()
    assert_true(s.deliver(_item("a", "s1", "body a")))
    assert_true(s.deliver(_item("b", "s2", "body b")))
    assert_equal(s.delivered_count(), 2)
    assert_equal(s.attempt_count(), 2)
    assert_equal(s.delivered_item_ids[0], "a")
    assert_equal(s.delivered_item_ids[1], "b")
    assert_equal(s.delivered_sources[1], "s2")
    assert_equal(s.delivered_bodies[0], "body a")


def test_fail_all() raises:
    var s = FakeEnrichmentSender()
    s.fail_all = True
    assert_false(s.deliver(_item("a", "s", "b")))
    assert_equal(s.delivered_count(), 0)
    assert_equal(s.attempt_count(), 1)
    s.clear_failures()
    assert_true(s.deliver(_item("a", "s", "b")))
    assert_equal(s.delivered_count(), 1)
    assert_equal(s.attempt_count(), 2)


def test_fail_next_fails_exactly_that_many_calls() raises:
    var s = FakeEnrichmentSender()
    s.fail_next(2)
    assert_false(s.deliver(_item("a", "s", "b")))
    assert_false(s.deliver(_item("a", "s", "b")))
    assert_true(s.deliver(_item("a", "s", "b")))
    assert_equal(s.attempt_count(), 3)
    assert_equal(s.delivered_count(), 1)


def test_fail_source_spares_other_sources() raises:
    var s = FakeEnrichmentSender()
    s.fail_source("bad")
    assert_false(s.deliver(_item("a", "bad", "b")))
    assert_true(s.deliver(_item("b", "good", "b")))
    assert_equal(s.delivered_item_ids[0], "b")
    s.clear_failures()
    assert_true(s.deliver(_item("a", "bad", "b")))


def _through_trait[T: EnrichmentSender](mut sender: T) raises -> Bool:
    return sender.deliver(_item("t", "s", "b"))


def test_usable_through_the_trait() raises:
    var s = FakeEnrichmentSender()
    assert_true(_through_trait(s))
    assert_equal(s.delivered_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
