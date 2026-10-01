# =============================================================================
# test_network_accumulator.mojo — the NEUTRAL network output->input seam.
# =============================================================================
#
# HERMETIC (no cloud, no seams). What this file is FOR is the two REFUSALS,
# because both of them are the difference between this seam and the edge seam it
# sits beside — and a reader who copies `EdgeOutcomeAccumulator`'s
# skip-on-empty / last-writer-wins semantics onto it produces a security defect
# rather than a cosmetic one:
#
#   (1) AN EMPTY NETWORK ID IS A RAISE, NOT A SKIP. On AWS a
#       `CreateSecurityGroup` with no VpcId does not fail — it creates the group
#       in the account's DEFAULT VPC. So a silently-skipped record becomes a
#       fence installed in a network the workload is not in, behind a 200.
#   (2) TWO DIFFERENT IDS UNDER ONE KEY IS A RAISE, NOT AN OVERWRITE. The same
#       node is read in plan and again in apply and must answer the same
#       network; last-writer-wins would fence workloads in whichever one
#       happened to run second.
#
# ⚠ A TEST THAT ONLY EXERCISED THE HAPPY PATH WOULD PASS AGAINST A STRAIGHT COPY
# OF `EdgeOutcomeAccumulator`, which is exactly the regression this file exists
# to catch.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_edge import NetworkOutcomeAccumulator


comptime _VPC: String = "vpc-example01"
comptime _OTHER_VPC: String = "vpc-example02"
comptime _NODE: String = "env-network"


def _subnets() -> List[String]:
    var s = List[String]()
    s.append(String("subnet-aaa1"))
    s.append(String("subnet-bbb2"))
    s.append(String("subnet-ccc3"))
    return s^


def test_records_and_reads_back_by_logical_id() raises:
    """The happy path: a producer records, a consumer reads by the SAME key."""
    var acc = NetworkOutcomeAccumulator()
    assert_equal(acc.count(), 0, "a fresh accumulator holds nothing")
    assert_equal(
        acc.network_for(String(_NODE)),
        String(""),
        "an unrecorded key answers EMPTY, never a default",
    )
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    assert_equal(acc.count(), 1, "one network node recorded")
    assert_equal(
        acc.network_for(String(_NODE)), String(_VPC), "the discovered id"
    )
    assert_equal(len(acc.zones_for(String(_NODE))), 3, "three zones recorded")
    assert_equal(
        acc.zones_for(String(_NODE))[0],
        String("subnet-aaa1"),
        "zone order is the producer's selection order, never re-sorted",
    )
    print("  test_records_and_reads_back_by_logical_id: PASS")


def test_an_unrelated_key_reads_empty_not_the_only_row() raises:
    """⛔ THE ONE-ROW TRAP. With exactly one network in the environment, a
    consumer asking for a DIFFERENT node must still get EMPTY. An implementation
    that answered "the only row" would work for as long as there is one network
    and silently fence the wrong workload the day there are two — which is CQ-4,
    still open."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    assert_equal(
        acc.network_for(String("some-other-network")),
        String(""),
        "a key with no row answers EMPTY even when exactly one row exists",
    )
    assert_equal(
        len(acc.zones_for(String("some-other-network"))),
        0,
        "and its zone list is empty too",
    )
    print("  test_an_unrelated_key_reads_empty_not_the_only_row: PASS")


def test_empty_network_id_is_REFUSED_not_skipped() raises:
    """⛔ REFUSAL (1). `EdgeOutcomeAccumulator.record_url` SKIPS an empty url;
    this seam RAISES, and the message must name the producer."""
    var acc = NetworkOutcomeAccumulator()
    var raised = False
    var msg = String("")
    try:
        acc.record_network(String(_NODE), String(""), _subnets())
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "an EMPTY network id must RAISE, not be skipped")
    assert_true(
        msg.find(String(_NODE)) >= 0,
        "the refusal names the PRODUCING node — the whole reason it is a raise"
        " rather than a skip is that a skip surfaces at a consumer instead",
    )
    assert_equal(acc.count(), 0, "and nothing was recorded")
    print("  test_empty_network_id_is_REFUSED_not_skipped: PASS")


def test_re_recording_the_SAME_id_refreshes_zones_in_place() raises:
    """The re-runnable half: plan reads, apply reads again, same answer. The
    zone list refreshes in place and no second row appears."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    var narrowed = List[String]()
    narrowed.append(String("subnet-aaa1"))
    acc.record_network(String(_NODE), String(_VPC), narrowed)
    assert_equal(acc.count(), 1, "still ONE row — not a second")
    assert_equal(
        len(acc.zones_for(String(_NODE))), 1, "the zone list refreshed in place"
    )
    print("  test_re_recording_the_SAME_id_refreshes_zones_in_place: PASS")


def test_a_DIFFERENT_id_under_one_key_is_REFUSED() raises:
    """⛔ REFUSAL (2). Two networks under one logical id is a raise, and the
    message must name BOTH ids — an operator cannot act on "conflict"."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    var raised = False
    var msg = String("")
    try:
        acc.record_network(String(_NODE), String(_OTHER_VPC), _subnets())
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a SECOND, DIFFERENT id under one key must RAISE")
    assert_true(msg.find(String(_VPC)) >= 0, "the refusal names the FIRST id")
    assert_true(
        msg.find(String(_OTHER_VPC)) >= 0, "and the SECOND id"
    )
    assert_equal(
        acc.network_for(String(_NODE)),
        String(_VPC),
        "the FIRST id survives — the refusal does not half-apply",
    )
    print("  test_a_DIFFERENT_id_under_one_key_is_REFUSED: PASS")


def test_share_is_ONE_state_not_a_copy() raises:
    """The producer holds a `share()`d handle and the consumer holds another;
    a write through one must be visible through the other. A `share()` that
    deep-copied would make every consumer read EMPTY forever — and the failure
    would look exactly like a missing `depends_on` edge."""
    var writer = NetworkOutcomeAccumulator()
    var reader = writer.share()
    writer.record_network(String(_NODE), String(_VPC), _subnets())
    assert_equal(
        reader.network_for(String(_NODE)),
        String(_VPC),
        "a write through one handle is visible through the other",
    )
    assert_equal(reader.count(), 1, "and so is the row count")
    # ...and the refusal is shared state too: the CONFLICT must be seen by a
    # write through the SECOND handle, or two conformers holding two handles
    # could each record a different network and neither would notice.
    var raised = False
    try:
        reader.record_network(String(_NODE), String(_OTHER_VPC), _subnets())
    except e:
        raised = True
    assert_true(
        raised,
        "the conflict refusal fires across handles — otherwise two nodes"
        " holding two shares could each adopt a different network in silence",
    )
    print("  test_share_is_ONE_state_not_a_copy: PASS")


def test_two_networks_two_keys_do_not_collide() raises:
    """The multi-network shape: two nodes, two keys, two
    answers, in first-recorded order."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    acc.record_network(String("second-network"), String(_OTHER_VPC), List[String]())
    assert_equal(acc.count(), 2, "two rows")
    assert_equal(acc.network_for(String(_NODE)), String(_VPC))
    assert_equal(
        acc.network_for(String("second-network")), String(_OTHER_VPC)
    )
    var ids = acc.logical_ids()
    assert_equal(ids[0], String(_NODE), "first-recorded order is preserved")
    assert_equal(ids[1], String("second-network"))
    print("  test_two_networks_two_keys_do_not_collide: PASS")


# =============================================================================
# THE TRI-STATE — `record_absent` / `is_recorded`.
# =============================================================================
#
# ⛔ THE DEFECT THESE PIN. Without the tri-state, `network_for` answers EMPTY for
# two states a consumer must act on DIFFERENTLY, and has no way to tell them
# apart:
#
#   key MISSING          the network node has NOT RUN — a missing `depends_on`,
#                        or a REVERSE (destroy) walk, which cannot discover at
#                        all. A consumer must RAISE and name the producer.
#   key present, ABSENT  the network node RAN and there is no network YET. A
#                        consumer must report ABSENT — the fence does not exist
#                        either — so that `plan_graph` over a FRESH environment
#                        can run at all.
#
# If both answered `""`, the policy conformers would raise on both, and a plan
# of a fresh environment would be impossible — so these nodes could not be
# composed into a real bundle graph.
#
# ⚠ A TEST THAT ONLY CHECKED `network_for` STILL PASSES WITH THE TRI-STATE
# DELETED: `record_absent` leaves `network_for` answering EMPTY on purpose.
# `is_recorded` is the whole discrimination and must be asserted directly.


def test_is_recorded_DISCRIMINATES_missing_from_absent() raises:
    """★ THE POINT OF THE TRI-STATE, in one test. Both states answer EMPTY from
    `network_for`; only `is_recorded` separates them."""
    var acc = NetworkOutcomeAccumulator()
    assert_true(
        not acc.is_recorded(String(_NODE)),
        "a key nothing has written is NOT recorded — the network node has not"
        " run, and a consumer must raise",
    )
    acc.record_absent(String(_NODE))
    assert_true(
        acc.is_recorded(String(_NODE)),
        "after `record_absent` the key IS recorded — the node RAN",
    )
    assert_equal(
        acc.network_for(String(_NODE)),
        String(""),
        "and it still answers NO network id, because there is none — an absent"
        " row must never be mistaken for a resolvable one",
    )
    assert_equal(
        len(acc.zones_for(String(_NODE))),
        0,
        "an absent network has no placement targets either",
    )
    assert_equal(acc.count(), 1, "an absent row is a ROW, and is counted")
    print("  test_is_recorded_DISCRIMINATES_missing_from_absent: PASS")


def test_absent_then_a_real_network_UPGRADES_the_same_row() raises:
    """⛔ THE FIRST-APPLY SHAPE, AND IT MUST NOT RAISE. `apply_graph_tracked`
    walks per node: read -> ABSENT (records absent) -> create (records the id).
    An implementation that reused the different-id refusal here would see `''`
    vs `vpc-…` as two networks under one key and refuse the ONE walk that is
    supposed to work."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_absent(String(_NODE))
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    assert_equal(acc.count(), 1, "the SAME row was upgraded, not a second one")
    assert_equal(
        acc.network_for(String(_NODE)),
        String(_VPC),
        "the discovered id replaces the absent marker",
    )
    assert_equal(
        len(acc.zones_for(String(_NODE))), 3, "and the zones land with it"
    )
    assert_true(acc.is_recorded(String(_NODE)), "still recorded, now resolved")
    print("  test_absent_then_a_real_network_UPGRADES_the_same_row: PASS")


def test_a_recorded_network_may_NOT_be_downgraded_to_absent() raises:
    """⛔ THE DOWNGRADE IS A RAISE, for `record_network`'s reason restated.

    A node that answered "this network exists" and then answers "there is none"
    in ONE drive gave two answers under one key. Accepting the second would flip
    every scoped consumer from *resolve and converge* to *report absent* — so a
    fence that EXISTS would be planned as `create` (which fails) or, on a
    teardown, skipped as nothing-to-delete (which LEAKS it, and on GCP then
    blocks the network's own delete)."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_network(String(_NODE), String(_VPC), _subnets())
    var raised = False
    var msg = String("")
    try:
        acc.record_absent(String(_NODE))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "downgrading a resolved row to ABSENT must RAISE")
    assert_true(
        msg.find(String(_VPC)) >= 0,
        "the refusal names the id that was already recorded",
    )
    assert_true(
        msg.find(String(_NODE)) >= 0, "and the node whose key it is"
    )
    assert_equal(
        acc.network_for(String(_NODE)),
        String(_VPC),
        "the recorded id survives — the refusal does not half-apply",
    )
    print("  test_a_recorded_network_may_NOT_be_downgraded_to_absent: PASS")


def test_record_absent_is_IDEMPOTENT_across_repeated_reads() raises:
    """A plan and then an apply both read the same still-absent network. The
    second `record_absent` must be a no-op, not a second row and not a raise —
    the seam is re-runnable for the same reason re-recording the SAME id is."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_absent(String(_NODE))
    acc.record_absent(String(_NODE))
    acc.record_absent(String(_NODE))
    assert_equal(acc.count(), 1, "three absent reads, ONE row")
    assert_true(acc.is_recorded(String(_NODE)))
    print("  test_record_absent_is_IDEMPOTENT_across_repeated_reads: PASS")


def test_absent_is_PER_KEY_and_shared_across_handles() raises:
    """An absent row for one node says NOTHING about another — and, like every
    other row, it is written into the ONE shared state."""
    var writer = NetworkOutcomeAccumulator()
    var reader = writer.share()
    writer.record_absent(String(_NODE))
    assert_true(
        reader.is_recorded(String(_NODE)),
        "the absent marker is visible through a share()d handle — otherwise a"
        " consumer would raise about a node that had reported absent",
    )
    assert_true(
        not reader.is_recorded(String("second-network")),
        "and it is PER KEY: an unrelated node is still NOT recorded",
    )
    print("  test_absent_is_PER_KEY_and_shared_across_handles: PASS")


def test_an_absent_row_does_not_make_record_network_refuse_a_SECOND_key() raises:
    """The upgrade path must not leak across keys: an absent row for node A and
    a real network for node B are two independent rows."""
    var acc = NetworkOutcomeAccumulator()
    acc.record_absent(String(_NODE))
    acc.record_network(String("second-network"), String(_OTHER_VPC), _subnets())
    assert_equal(acc.count(), 2, "two rows")
    assert_equal(acc.network_for(String(_NODE)), String(""))
    assert_equal(
        acc.network_for(String("second-network")), String(_OTHER_VPC)
    )
    assert_true(acc.is_recorded(String(_NODE)))
    assert_true(acc.is_recorded(String("second-network")))
    print(
        "  test_an_absent_row_does_not_make_record_network_refuse_a_SECOND_key:"
        " PASS"
    )


def main() raises:
    test_records_and_reads_back_by_logical_id()
    test_an_unrelated_key_reads_empty_not_the_only_row()
    test_empty_network_id_is_REFUSED_not_skipped()
    test_re_recording_the_SAME_id_refreshes_zones_in_place()
    test_a_DIFFERENT_id_under_one_key_is_REFUSED()
    test_share_is_ONE_state_not_a_copy()
    test_two_networks_two_keys_do_not_collide()
    test_is_recorded_DISCRIMINATES_missing_from_absent()
    test_absent_then_a_real_network_UPGRADES_the_same_row()
    test_a_recorded_network_may_NOT_be_downgraded_to_absent()
    test_record_absent_is_IDEMPOTENT_across_repeated_reads()
    test_absent_is_PER_KEY_and_shared_across_handles()
    test_an_absent_row_does_not_make_record_network_refuse_a_SECOND_key()
    print(
        "OK: test_network_accumulator (the neutral network output->input seam —"
        " both refusals, the one-row trap, shared-state semantics, and the"
        " TRI-STATE: missing vs recorded-absent vs resolved)"
        " — all assertions passed"
    )
