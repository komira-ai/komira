# =============================================================================
# tests/test_cluster_assignment_store.mojo
#   The object-store CAS binary assignment store — store CAS gate.
# =============================================================================
#
# The `ClusterAssignmentStore[Storage]` is the DB-free partition-assignment
# persistence over a CloneableConditionalWriteStore. This gate pins the CAS
# semantics over the in-memory twin (no network), mirroring the consumer-group
# coordinator's
# "CAS resolves the concurrent-driver race" gate:
#
#   * CREATE then READ — a first write (empty etag -> If-None-Match) creates the
#     object; a read returns the body + the post-write etag; an absent topic reads
#     None (404 -> the coordinator's 'no prior' / initial pass).
#   * UPDATE via If-Match — a second write carrying the read etag succeeds and
#     mints a NEW etag.
#   * THE FAILING TEST (the whole point): TWO coordinators sharing ONE store both
#     read the same etag (or absence) and both try to write. EXACTLY ONE wins;
#     the LOSER gets a 412 / precondition Error, RE-READS the winner's body, and
#     RE-WRITES on the fresh etag — converging to a SINGLE consistent assignment.
#     This is the cross-coordinator disjoint-assignment guarantee (a partial /
#     lost-update assignment is never persisted).
#
# The bodies are the binary Assignment form (encode_binary / decode_binary), so
# this also exercises the codec end-to-end through the store.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker import (
    Assignment,
    ClusterAssignmentStore,
    StoredAssignment,
    REBALANCE_INITIAL,
    REBALANCE_NEW_NODE,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


def _strs(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(x)
    return out^


def _assignment(p: Int, *owners: String) -> Assignment:
    """Build an Assignment over `p` partitions with the given owners; the node
    table is the distinct non-empty owners in first-seen order."""
    var ow = List[String]()
    var nodes = List[String]()
    for o in owners:
        ow.append(o)
        if o.byte_length() > 0:
            var seen = False
            for i in range(len(nodes)):
                if nodes[i] == o:
                    seen = True
                    break
            if not seen:
                nodes.append(o)
    return Assignment(
        num_partitions=p,
        owners=ow^,
        node_ids=nodes^,
        reason=REBALANCE_NEW_NODE,
    )


# =============================================================================
# TEST 1 — create then read; absent topic reads None.
# =============================================================================
def test_create_read_absent() raises:
    var s = ClusterAssignmentStore[SharedInMemoryConditionalStore](
        SharedInMemoryConditionalStore(), String("cl-1")
    )

    # Absent -> None (404 -> the coordinator's initial pass).
    var none = s.read_assignment(String("example-data"))
    assert_false(Bool(none), "absent topic must read None (404)")

    # CREATE (empty etag -> If-None-Match).
    var a = _assignment(
        2, String("n1"), String("n2")
    )
    var etag1 = s.store_assignment(
        String("example-data"), a.encode_binary(), String("")
    )
    assert_true(etag1.byte_length() > 0, "create must mint a non-empty etag")

    # READ back -> body decodes to the same assignment + the create etag.
    var got = s.read_assignment(String("example-data"))
    assert_true(Bool(got), "after create the topic must read present")
    ref stored = got.value()
    assert_equal(stored.etag, etag1, "read etag == the create etag")
    var decoded = Assignment.decode_binary(stored.body)
    assert_equal(decoded.num_partitions, 2, "decoded P")
    assert_equal(decoded.owners[0], String("n1"), "decoded owner 0")
    assert_equal(decoded.owners[1], String("n2"), "decoded owner 1")

    # ZERO-COPY read path: the SAME stored body, viewed in place
    # via `stored.view()` — no List allocation / re-parse. The view's fields must
    # match the owned decode. The view borrows `stored.body`; its origin ties its
    # lifetime to `stored`, so it cannot outlive the StoredAssignment.
    var view = stored.view()
    assert_equal(view.num_partitions(), 2, "view P")
    assert_equal(String(view.owner(0)), String("n1"), "view owner 0")
    assert_equal(String(view.owner(1)), String("n2"), "view owner 1")
    assert_equal(view.node_count(), 2, "view node_count")
    print("  test_create_read_absent: PASS")


# =============================================================================
# TEST 2 — update via If-Match mints a new etag; a stale etag loses (412).
# =============================================================================
def test_update_ifmatch_and_stale_loses() raises:
    var s = ClusterAssignmentStore[SharedInMemoryConditionalStore](
        SharedInMemoryConditionalStore(), String("cl-2")
    )
    var topic = String("t")

    var a = _assignment(2, String("n1"), String("n2"))
    var etag1 = s.store_assignment(topic, a.encode_binary(), String(""))

    # UPDATE on the current etag -> succeeds, mints a fresh etag.
    var b = _assignment(2, String("n2"), String("n1"))
    var etag2 = s.store_assignment(topic, b.encode_binary(), etag1)
    assert_true(etag2 != etag1, "an update must mint a NEW etag")

    # A write on the STALE etag1 must LOSE (412 / precondition).
    var raised = False
    try:
        _ = s.store_assignment(topic, a.encode_binary(), etag1)
    except e:
        raised = True
        assert_true(
            ClusterAssignmentStore[
                SharedInMemoryConditionalStore
            ].is_precondition_failure(String(e)),
            "a stale-etag write must fail with a precondition (412)",
        )
    assert_true(raised, "a stale-etag write must raise")
    print("  test_update_ifmatch_and_stale_loses: PASS")


# =============================================================================
# TEST 3 — THE FAILING TEST: two coordinators sharing ONE store; exactly one
# wins the create, the loser re-reads + re-writes, converging to a single
# consistent assignment (the cross-coordinator disjoint guarantee).
# =============================================================================
def test_two_coordinators_cas_converges() raises:
    # ONE shared underlying store, TWO coordinator handles over CLONES of it
    # (the in-mem twin's clone shares the same map — modelling two processes
    # hitting the same S3 bucket).
    var base = SharedInMemoryConditionalStore()
    var coord_a = ClusterAssignmentStore[SharedInMemoryConditionalStore](
        base.clone(), String("cl-shared")
    )
    var coord_b = ClusterAssignmentStore[SharedInMemoryConditionalStore](
        base.clone(), String("cl-shared")
    )
    var topic = String("example-data")

    # Both read ABSENT (None) — both will try the create (If-None-Match).
    var a_seen = coord_a.read_assignment(topic)
    var b_seen = coord_b.read_assignment(topic)
    assert_false(Bool(a_seen), "A sees absent")
    assert_false(Bool(b_seen), "B sees absent")

    # A's assignment: 2 partitions to n1 / n2. B's: 2 partitions to n3 / n4.
    var asg_a = _assignment(2, String("n1"), String("n2"))
    var asg_b = _assignment(2, String("n3"), String("n4"))

    # A creates first (wins the If-None-Match).
    var etag_a = coord_a.store_assignment(topic, asg_a.encode_binary(), String(""))
    assert_true(etag_a.byte_length() > 0, "A's create wins")

    # B tries to create on the empty etag -> If-None-Match LOSES (the object
    # already exists). B must re-read + re-evaluate (the loser-retries path).
    var b_lost = False
    try:
        _ = coord_b.store_assignment(topic, asg_b.encode_binary(), String(""))
    except e:
        b_lost = True
        assert_true(
            ClusterAssignmentStore[
                SharedInMemoryConditionalStore
            ].is_precondition_failure(String(e)),
            "B's create must lose with a precondition (the object exists)",
        )
    assert_true(b_lost, "B's blind create must lose to A's")

    # B re-reads the winner's body (A's assignment) + its etag, then re-writes
    # ITS recomputed assignment on the FRESH etag (the converge step).
    var b_reread = coord_b.read_assignment(topic)
    assert_true(Bool(b_reread), "B re-reads the present assignment")
    ref b_stored = b_reread.value()
    # B sees A's assignment (n1/n2), recomputes (here it just persists its own
    # B-view onto the fresh etag — the point is the CAS chains, not the policy).
    var etag_b = coord_b.store_assignment(
        topic, asg_b.encode_binary(), b_stored.etag
    )
    assert_true(etag_b != etag_a, "B's converge-write mints a new etag")

    # FINAL STATE is SINGLE + CONSISTENT: a fresh read sees exactly B's body
    # (the last successful CAS) — never a torn / merged / lost-update body.
    var final = coord_a.read_assignment(topic)
    assert_true(Bool(final), "final assignment present")
    var final_decoded = Assignment.decode_binary(final.value().body)
    assert_equal(final_decoded.owners[0], String("n3"), "final owner 0 == B's n3")
    assert_equal(final_decoded.owners[1], String("n4"), "final owner 1 == B's n4")
    assert_equal(final.value().etag, etag_b, "final etag == B's converge etag")
    print("  test_two_coordinators_cas_converges: PASS")


def main() raises:
    test_create_read_absent()
    test_update_ifmatch_and_stale_loses()
    test_two_coordinators_cas_converges()
    print("ALL test_cluster_assignment_store tests PASS")
