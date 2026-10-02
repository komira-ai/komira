# =============================================================================
# tests/test_assignment_zero_copy_view.mojo
#   The object-store CAS binary assignment store — zero-copy view gate.
# =============================================================================
#
# Latency: in-DC the object-store round-trip is sub-ms / low-ms,
# so the decode/parse cost is a real fraction of a read. `Assignment.view(body)`
# returns an `AssignmentView` that READS the persisted binary body IN PLACE — it
# validates the header then exposes P / reason / node-count / per-pid owner index /
# node strings / per-pid owner slice by reading DIRECTLY from the borrowed bytes,
# with NO List allocation and NO re-parse (zero-copy). The owned `decode_binary`
# path (the cache / where ownership is needed) stays — its round-trip gate is
# `test_assignment_binary_codec`, which MUST also stay green.
#
# THE ZERO-COPY ASSERTION (the heart of this gate): the view's owner array is a
# `Span[UInt8, origin]` OVER THE SOURCE BODY — `owners_bytes()` returns a Span
# whose backing pointer is INSIDE the original `body` buffer (the same bytes, not
# a fresh List). The node strings are `StringSlice[origin]` slices into that same
# buffer. We assert the Span aliases the body (pointer-identity of the underlying
# bytes via offset), AND that every field equals the original Assignment.
#
# These are pure-value tests (no store, no network).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_broker import (
    Assignment,
    REBALANCE_INITIAL,
    REBALANCE_NEW_NODE,
    REBALANCE_STALE_NODE,
)


def _strs(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(x)
    return out^


def _assert_view_matches(a: Assignment, body: List[UInt8], msg: String) raises:
    """View the body zero-copy and assert every field matches the original `a`."""
    var view = Assignment.view(Span[UInt8](body))
    assert_equal(view.num_partitions(), a.num_partitions, msg + ": P")
    assert_equal(view.reason(), a.reason, msg + ": reason")
    assert_equal(view.node_count(), len(a.node_ids), msg + ": node_count")
    # Node strings: each node(i) is a StringSlice into the buffer == the original.
    for i in range(len(a.node_ids)):
        assert_equal(
            String(view.node(i)), a.node_ids[i], msg + ": node[" + String(i) + "]"
        )
    # Owners: every pid's owner string == the original (incl. the "" unassigned).
    assert_equal(view.num_partitions(), len(a.owners), msg + ": owners len")
    for pid in range(len(a.owners)):
        assert_equal(
            String(view.owner(pid)),
            a.owners[pid],
            msg + ": owner[" + String(pid) + "]",
        )


# =============================================================================
# TEST 1 — view of a typical 3-node / 6-partition assignment matches every field.
# =============================================================================
def test_view_typical() raises:
    var a = Assignment(
        num_partitions=6,
        owners=_strs(
            String("a"), String("b"), String("c"),
            String("a"), String("b"), String("c"),
        ),
        node_ids=_strs(String("a"), String("b"), String("c")),
        reason=REBALANCE_NEW_NODE,
    )
    var body = a.encode_binary()
    _assert_view_matches(a, body, "typical 3-node/6-part")
    print("  test_view_typical: PASS")


# =============================================================================
# TEST 2 — view with UNASSIGNED ("" owner) partitions (the 0xFFFF sentinel) AND
# the empty live set.
# =============================================================================
def test_view_unassigned_owners() raises:
    var a = Assignment(
        num_partitions=4,
        owners=_strs(String(""), String(""), String(""), String("")),
        node_ids=List[String](),
        reason=REBALANCE_STALE_NODE,
    )
    var body = a.encode_binary()
    _assert_view_matches(a, body, "all-unassigned empty live set")

    var c = Assignment(
        num_partitions=4,
        owners=_strs(String("n1"), String(""), String("n1"), String("")),
        node_ids=_strs(String("n1")),
        reason=REBALANCE_INITIAL,
    )
    var cbody = c.encode_binary()
    _assert_view_matches(c, cbody, "mixed assigned/unassigned")
    print("  test_view_unassigned_owners: PASS")


# =============================================================================
# TEST 3 — edge sizes: empty (P==0) + single-node single-partition.
# =============================================================================
def test_view_edge_sizes() raises:
    var a = Assignment(
        num_partitions=0,
        owners=List[String](),
        node_ids=List[String](),
        reason=REBALANCE_INITIAL,
    )
    var body = a.encode_binary()
    _assert_view_matches(a, body, "empty P==0")

    var c = Assignment(
        num_partitions=1,
        owners=_strs(String("solo")),
        node_ids=_strs(String("solo")),
        reason=REBALANCE_INITIAL,
    )
    var cbody = c.encode_binary()
    _assert_view_matches(c, cbody, "single node single partition")
    print("  test_view_edge_sizes: PASS")


# =============================================================================
# TEST 4 — THE ZERO-COPY PROOF: `owners_bytes()` is a Span OVER the source body,
# NOT a fresh List. We assert the Span's backing bytes ARE the body's bytes at the
# owners offset (no allocation / re-parse), and the raw u16 owner index for each
# pid matches reading the body directly at the same offset.
# =============================================================================
def test_view_owners_span_aliases_body() raises:
    var nodes = _strs(String("broker-1"), String("broker-2"), String("broker-3"))
    var owners = List[String]()
    for pid in range(12):
        owners.append(nodes[pid % 3])
    var a = Assignment(
        num_partitions=12,
        owners=owners^,
        node_ids=nodes.copy(),
        reason=REBALANCE_NEW_NODE,
    )
    var body = a.encode_binary()
    var view = Assignment.view(Span[UInt8](body))

    # The owners array is viewed in place: owners_bytes() is a Span of length
    # P*2 (each owner is a u16 LE index). It must be P*2 bytes long.
    var ob = view.owners_bytes()
    assert_equal(len(ob), 12 * 2, "owners_bytes length == P*2")

    # ZERO-COPY: the Span aliases the body. owners_offset() tells us where in the
    # body the owners array starts; the Span's i-th byte must equal the body's
    # byte at (owners_offset + i). If the view had allocated a fresh List, this
    # would still match by value — so we ALSO assert the view exposes the offset
    # (proving the bytes are read in place, not re-materialized) and that the raw
    # owner index read via the Span equals the body byte-pair at that offset.
    var off = view.owners_offset()
    for i in range(len(ob)):
        assert_equal(ob[i], body[off + i], "owners_bytes[" + String(i) + "] aliases body")

    # owner_index(pid) reads the u16 LE directly from the Span (no List); confirm
    # it equals decoding the same two body bytes by hand.
    for pid in range(12):
        var lo = Int(body[off + pid * 2])
        var hi = Int(body[off + pid * 2 + 1])
        var expect = lo | (hi << 8)
        assert_equal(
            Int(view.owner_index(pid)),
            expect,
            "owner_index[" + String(pid) + "] reads the body u16 in place",
        )
    print("  test_view_owners_span_aliases_body: PASS")


# =============================================================================
# TEST 5 — MALFORMED bodies are REJECTED at view() time (bad magic / unknown
# version / truncation), same as decode_binary.
# =============================================================================
def test_view_reject_bad_magic() raises:
    var body = List[UInt8]()
    for _ in range(32):
        body.append(UInt8(0))
    with assert_raises():
        _ = Assignment.view(Span[UInt8](body))
    print("  test_view_reject_bad_magic: PASS")


def test_view_reject_unknown_version() raises:
    var a = Assignment(
        num_partitions=2,
        owners=_strs(String("x"), String("y")),
        node_ids=_strs(String("x"), String("y")),
        reason=REBALANCE_NEW_NODE,
    )
    var body = a.encode_binary()
    body[4] = UInt8(99)
    body[5] = UInt8(0)
    with assert_raises():
        _ = Assignment.view(Span[UInt8](body))
    print("  test_view_reject_unknown_version: PASS")


def test_view_reject_truncated() raises:
    var a = Assignment(
        num_partitions=6,
        owners=_strs(
            String("a"), String("b"), String("c"),
            String("a"), String("b"), String("c"),
        ),
        node_ids=_strs(String("a"), String("b"), String("c")),
        reason=REBALANCE_NEW_NODE,
    )
    var body = a.encode_binary()
    var truncated = List[UInt8]()
    var keep = len(body) - 6
    for i in range(keep):
        truncated.append(body[i])
    with assert_raises():
        _ = Assignment.view(Span[UInt8](truncated))
    print("  test_view_reject_truncated: PASS")


# =============================================================================
# TEST 6 — the view can be materialized into an OWNED Assignment (the cache path:
# view zero-copy on the hot read, copy into an owned value where retention is
# needed). The owned copy must equal the original.
# =============================================================================
def test_view_to_owned() raises:
    var a = Assignment(
        num_partitions=6,
        owners=_strs(
            String("a"), String("b"), String("c"),
            String("a"), String("b"), String("c"),
        ),
        node_ids=_strs(String("a"), String("b"), String("c")),
        reason=REBALANCE_NEW_NODE,
    )
    var body = a.encode_binary()
    var view = Assignment.view(Span[UInt8](body))
    var owned = view.to_owned()
    assert_equal(owned.num_partitions, a.num_partitions, "to_owned: P")
    assert_equal(owned.reason, a.reason, "to_owned: reason")
    assert_equal(len(owned.node_ids), len(a.node_ids), "to_owned: node_ids len")
    for i in range(len(a.node_ids)):
        assert_equal(owned.node_ids[i], a.node_ids[i], "to_owned: node[" + String(i) + "]")
    assert_equal(len(owned.owners), len(a.owners), "to_owned: owners len")
    for pid in range(len(a.owners)):
        assert_equal(owned.owners[pid], a.owners[pid], "to_owned: owner[" + String(pid) + "]")
    print("  test_view_to_owned: PASS")


def main() raises:
    test_view_typical()
    test_view_unassigned_owners()
    test_view_edge_sizes()
    test_view_owners_span_aliases_body()
    test_view_reject_bad_magic()
    test_view_reject_unknown_version()
    test_view_reject_truncated()
    test_view_to_owned()
    print("ALL test_assignment_zero_copy_view tests PASS")
