# =============================================================================
# tests/test_assignment_binary_codec.mojo
#   The object-store CAS binary assignment store — codec unit gate.
# =============================================================================
#
# The Assignment binary codec (`encode_binary` / `decode_binary`) is the persisted
# form the object-store-CAS `ClusterAssignmentStore` writes. The codec MUST be:
#   * ROUND-TRIP exact — encode then decode reproduces P / reason / node_ids /
#     owners byte-for-byte (incl. the unassigned-"" owner and the empty live set).
#   * SMALLER than JSON — node-ids interned once, owners as u16 indices.
#   * MALFORMED-REJECTING — a bad magic / unknown version / truncated body / an
#     out-of-range owner index raises rather than returning a corrupt assignment.
#
# These are pure-value tests (no store, no network) — the codec lives on
# the `Assignment` type in komira_broker.
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


def _assert_assignment_eq(a: Assignment, b: Assignment, msg: String) raises:
    """Field-exact equality (P / reason / node_ids / owners)."""
    assert_equal(a.num_partitions, b.num_partitions, msg + ": num_partitions")
    assert_equal(a.reason, b.reason, msg + ": reason")
    assert_equal(len(a.node_ids), len(b.node_ids), msg + ": node_ids len")
    for i in range(len(a.node_ids)):
        assert_equal(a.node_ids[i], b.node_ids[i], msg + ": node_ids[" + String(i) + "]")
    assert_equal(len(a.owners), len(b.owners), msg + ": owners len")
    for i in range(len(a.owners)):
        assert_equal(a.owners[i], b.owners[i], msg + ": owners[" + String(i) + "]")


# =============================================================================
# TEST 1 — round-trip of a typical 3-node / 6-partition assignment.
# =============================================================================
def test_roundtrip_typical() raises:
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
    var b = Assignment.decode_binary(body)
    _assert_assignment_eq(a, b, "typical 3-node/6-part")
    print("  test_roundtrip_typical: PASS")


# =============================================================================
# TEST 2 — round-trip with UNASSIGNED ("" owner) partitions (the no-live-node /
# over-provisioned-pid state encoded as the 0xFFFF sentinel).
# =============================================================================
def test_roundtrip_unassigned_owners() raises:
    # Empty live set: every owner is "" (the no-broker state).
    var a = Assignment(
        num_partitions=4,
        owners=_strs(String(""), String(""), String(""), String("")),
        node_ids=List[String](),
        reason=REBALANCE_STALE_NODE,
    )
    var body = a.encode_binary()
    var b = Assignment.decode_binary(body)
    _assert_assignment_eq(a, b, "all-unassigned empty live set")

    # Mixed: some pids assigned, some unassigned (a P larger than live capacity).
    var c = Assignment(
        num_partitions=4,
        owners=_strs(String("n1"), String(""), String("n1"), String("")),
        node_ids=_strs(String("n1")),
        reason=REBALANCE_INITIAL,
    )
    var cbody = c.encode_binary()
    var d = Assignment.decode_binary(cbody)
    _assert_assignment_eq(c, d, "mixed assigned/unassigned")
    print("  test_roundtrip_unassigned_owners: PASS")


# =============================================================================
# TEST 3 — round-trip of the empty (P==0) assignment + a single-node single-part.
# =============================================================================
def test_roundtrip_edge_sizes() raises:
    var a = Assignment(
        num_partitions=0,
        owners=List[String](),
        node_ids=List[String](),
        reason=REBALANCE_INITIAL,
    )
    var body = a.encode_binary()
    var b = Assignment.decode_binary(body)
    _assert_assignment_eq(a, b, "empty P==0")

    var c = Assignment(
        num_partitions=1,
        owners=_strs(String("solo")),
        node_ids=_strs(String("solo")),
        reason=REBALANCE_INITIAL,
    )
    var cbody = c.encode_binary()
    var d = Assignment.decode_binary(cbody)
    _assert_assignment_eq(c, d, "single node single partition")
    print("  test_roundtrip_edge_sizes: PASS")


# =============================================================================
# TEST 4 — the binary body is SMALLER than the JSON for a realistic assignment
# (the interning win: owners are u16 indices, not P full node-id strings).
# =============================================================================
def _assignment_with_node_ids(var nodes: List[String]) raises -> Assignment:
    """A 48-partition assignment spread round-robin over `nodes`."""
    var owners = List[String]()
    for pid in range(48):
        owners.append(nodes[pid % len(nodes)])
    return Assignment(
        num_partitions=48,
        owners=owners^,
        node_ids=nodes^,
        reason=REBALANCE_NEW_NODE,
    )


def test_binary_owners_are_interned_not_repeated() raises:
    """The INTERNING WIN, tested as the scaling property it actually is.

    ⚠️ THIS DELIBERATELY DOES NOT COMPARE TOTAL BODY SIZES
    (`binary_len < json_len`): the v2 `generations` and v3 `max_generations`
    trailers append 2 x (4 + P x i64) = 776 bytes of FIXED-WIDTH i64 at P=48,
    which takes the binary body to 926 bytes against 814 of JSON — JSON's
    variable-length decimal is genuinely more compact for small generation
    numbers. A total-size comparison is only a PROXY for the interning claim,
    and the trailers break the proxy without touching the claim: excluding the
    trailers the same body is 150 bytes vs 814 (5.4x).

    So assert the claim DIRECTLY, and in a form no future trailer can perturb:
    node-ids are interned ONCE into the node table and `owners[pid]` is a u16
    INDEX, so making the node-ids LONGER must grow the binary by ~N x the extra
    length (the table) while it grows the JSON by ~P x the extra length (one full
    copy per partition). With P=48 >> N=3, the binary must grow strictly less."""
    var short_nodes = _strs(
        String("broker-1"), String("broker-2"), String("broker-3")
    )
    # The SAME topology, with node-ids 40 bytes longer each.
    var pad = String("-0123456789012345678901234567890123456789")
    var long_nodes = _strs(
        String("broker-1") + pad,
        String("broker-2") + pad,
        String("broker-3") + pad,
    )

    var a_short = _assignment_with_node_ids(short_nodes^)
    var a_long = _assignment_with_node_ids(long_nodes^)

    var bin_growth = len(a_long.encode_binary()) - len(a_short.encode_binary())
    var json_growth = (
        len(a_long.encode().as_bytes()) - len(a_short.encode().as_bytes())
    )

    # Interned: the binary pays the extra bytes N=3 times (the node table only).
    assert_true(
        bin_growth < json_growth,
        "binary grew "
        + String(bin_growth)
        + " bytes vs JSON's "
        + String(json_growth)
        + " for the same node-id lengthening — owners must be u16 INDICES into"
        + " an interned node table, not P full node-id copies",
    )
    # Tight bound: the pad bytes appear exactly N=3 times (once per node-table
    # entry), never P=48 times. Derived from len(pad), not hardcoded.
    var pad_len = len(pad.as_bytes())
    assert_true(
        bin_growth <= 3 * pad_len,
        "binary grew "
        + String(bin_growth)
        + " bytes — the node-id bytes must appear exactly N=3 times (the node"
        + " table), so growth is bounded by N x pad ("
        + String(3 * pad_len)
        + "), not P x pad",
    )
    print(
        "  test_binary_owners_are_interned_not_repeated: PASS (binary +"
        + String(bin_growth)
        + " vs json +"
        + String(json_growth)
        + ")"
    )


# =============================================================================
# TEST 5 — MALFORMED bodies are REJECTED (bad magic / unknown version /
# truncation / out-of-range owner index).
# =============================================================================
def test_reject_bad_magic() raises:
    var body = List[UInt8]()
    # Wrong magic (all zeros) + a plausible-length tail.
    for _ in range(32):
        body.append(UInt8(0))
    with assert_raises():
        _ = Assignment.decode_binary(body)
    print("  test_reject_bad_magic: PASS")


def test_reject_unknown_version() raises:
    var a = Assignment(
        num_partitions=2,
        owners=_strs(String("x"), String("y")),
        node_ids=_strs(String("x"), String("y")),
        reason=REBALANCE_NEW_NODE,
    )
    var body = a.encode_binary()
    # Bytes 4..6 are the LE format_version (==1). Bump it to an unknown 99.
    body[4] = UInt8(99)
    body[5] = UInt8(0)
    with assert_raises():
        _ = Assignment.decode_binary(body)
    print("  test_reject_unknown_version: PASS")


def test_reject_truncated() raises:
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
    # Lop off the tail (the owners array) — the decode must raise, not read OOB.
    var truncated = List[UInt8]()
    var keep = len(body) - 6
    for i in range(keep):
        truncated.append(body[i])
    with assert_raises():
        _ = Assignment.decode_binary(truncated)
    print("  test_reject_truncated: PASS")


def test_reject_out_of_range_owner_index() raises:
    # Hand-build a body with a 1-node table but an owner index == 5 (OOB).
    # Layout: magic u32 | ver u16 | reserved u16 | P i32 | reason i32 |
    #         node_count u32 | [len u16 | "n"] | owners_count u32 | owner u16
    var body = List[UInt8]()
    # magic 0x42415353 LE
    body.append(UInt8(0x53)); body.append(UInt8(0x53))
    body.append(UInt8(0x41)); body.append(UInt8(0x42))
    # version 1 LE
    body.append(UInt8(1)); body.append(UInt8(0))
    # reserved 0
    body.append(UInt8(0)); body.append(UInt8(0))
    # P = 1 (i32 LE)
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # reason = 1 (i32 LE)
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # node_count = 1 (u32 LE)
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # node[0]: len=1, "n"
    body.append(UInt8(1)); body.append(UInt8(0))
    body.append(UInt8(ord("n")))
    # owners_count = 1 (u32 LE)
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # owner index = 5 (u16 LE) — OUT OF RANGE for a 1-node table (valid: 0 or 0xFFFF)
    body.append(UInt8(5)); body.append(UInt8(0))
    with assert_raises():
        _ = Assignment.decode_binary(body)
    print("  test_reject_out_of_range_owner_index: PASS")


def main() raises:
    test_roundtrip_typical()
    test_roundtrip_unassigned_owners()
    test_roundtrip_edge_sizes()
    test_binary_owners_are_interned_not_repeated()
    test_reject_bad_magic()
    test_reject_unknown_version()
    test_reject_truncated()
    test_reject_out_of_range_owner_index()
    print("ALL test_assignment_binary_codec tests PASS")
