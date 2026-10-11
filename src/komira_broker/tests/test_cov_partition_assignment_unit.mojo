# =============================================================================
# tests/test_cov_partition_assignment_unit.mojo
#   The partition assignment: its constructor invariants, its accessors'
#   range checks, both persisted forms (JSON and binary) with every refusal,
#   the zero-copy view over v1/v2/v3 bodies, and the spread corner cases.
# =============================================================================
#
#   1. Assignment(): generations are cut to P, a short high-water list is
#      padded and raised to the live generation; each accessor refuses an
#      out-of-range pid.
#   2. JSON: escaped node ids round-trip; spaces before integers parse;
#      each missing field is refused. Malformed bodies the decoder accepts
#      are not pinned (komira-ai/komira#1093).
#   3. Binary: the u16 caps on node count, owner count and node-id length,
#      each refused at 65536 and accepted at 65535;
#      a truncated header and node table are refused.
#   4. View: each truncated block is refused; the i64 reader refuses a
#      short span; each accessor refuses an
#      out-of-range index; a v2 body (no high-water) falls back to the live
#      generation, and to_owned materializes P entries.
#   5. Spread: a negative P is refused, a prior "" owner is not sticky,
#      unsorted live nodes are sorted, is_even on empty and uneven sets, and
#      a same-size membership swap is a stale-node rebalance.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_broker.partition_assignment import (
    Assignment,
    LiveNode,
    REBALANCE_INITIAL,
    REBALANCE_NONE,
    REBALANCE_STALE_NODE,
    _abytes_find,
    _vread_i64,
    assign_partitions,
    live_node_ids,
    mint_shard_id,
    rebalance_reason_for,
)


def _s(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _i(*xs: Int) -> List[Int64]:
    var out = List[Int64]()
    for x in xs:
        out.append(Int64(x))
    return out^


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return out^


def _two() -> Assignment:
    # P=2, one node "abc", generations [3, 4], high-water [5, 4, 9].
    return Assignment(
        num_partitions=2,
        owners=_s("abc", "abc"),
        node_ids=_s("abc"),
        reason=REBALANCE_INITIAL,
        generations=_i(3, 4),
        max_generations=_i(5, 4, 9),
    )


# ---- 1. constructor and accessors -----------------------------------------------


def test_constructor_invariants() raises:
    # Generations longer than P are cut; a short high-water is padded with 0
    # and raised to the live generation.
    var a = Assignment(
        num_partitions=3,
        owners=_s("a", "b", "a"),
        node_ids=_s("a", "b"),
        reason=REBALANCE_NONE,
        generations=_i(1, 7, 2, 9),
        max_generations=_i(4),
    )
    assert_equal(len(a.generations), 3)
    assert_equal(a.generation_of(2), Int64(2))
    assert_equal(len(a.max_generations), 3)
    assert_equal(a.max_generation_of(0), Int64(4))
    assert_equal(a.max_generation_of(1), Int64(7))
    assert_equal(a.max_generation_of(2), Int64(2))
    with assert_raises(contains="Assignment.owner_of: pid 3 out of range [0, 3)"):
        _ = a.owner_of(3)
    with assert_raises(contains="Assignment.owner_of: pid -1"):
        _ = a.owner_of(-1)
    with assert_raises(contains="Assignment.generation_of: pid 3 out of range"):
        _ = a.generation_of(3)
    with assert_raises(contains="Assignment.max_generation_of: pid -1 out of range"):
        _ = a.max_generation_of(-1)
    # An owners list longer than P: the extra pid has no generation (0).
    var b = Assignment(
        num_partitions=1,
        owners=_s("a", "a"),
        node_ids=_s("a"),
        reason=REBALANCE_NONE,
        generations=_i(6),
    )
    var g = b.generations_for("a")
    assert_equal(len(g), 2)
    assert_equal(g[0], Int64(6))
    assert_equal(g[1], Int64(0))


# ---- 2. JSON form ---------------------------------------------------------------


def test_json_escapes_and_spaces() raises:
    var a = Assignment(
        num_partitions=2,
        owners=_s('q"t', "b\\s"),
        node_ids=_s('q"t', "b\\s"),
        reason=REBALANCE_INITIAL,
    )
    var back = Assignment.decode(a.encode())
    assert_equal(back.owner_of(0), 'q"t')
    assert_equal(back.owner_of(1), "b\\s")
    assert_equal(back.node_ids[1], "b\\s")
    # Spaces before integers (valid JSON). Malformed bodies (a trailing
    # comma, a non-number inside an int array, a lone backslash, an
    # unterminated array) are deliberately not pinned here: the decoder
    # accepts them although its docstring says it raises (komira-ai/komira#1093).
    var d = Assignment.decode(
        '{"p": 2,"reason": 5,"nodes":["a"],"owners":["a","a"],'
        + '"gens":[ 1, -2],"maxgens":[ 3, 9]}'
    )
    assert_equal(d.num_partitions, 2)
    assert_equal(d.reason, 5)
    assert_equal(len(d.node_ids), 1)
    assert_equal(d.generation_of(0), Int64(1))
    assert_equal(d.generation_of(1), Int64(-2))
    assert_equal(d.max_generation_of(0), Int64(3))
    assert_equal(d.max_generation_of(1), Int64(9))
    with assert_raises(contains="Assignment.decode: missing 'p' field"):
        _ = Assignment.decode('{"nodes":[],"owners":[]}')
    with assert_raises(contains="Assignment.decode: missing 'nodes' field"):
        _ = Assignment.decode('{"p":0,"owners":[]}')
    with assert_raises(contains="Assignment.decode: missing 'owners' field"):
        _ = Assignment.decode('{"p":0,"nodes":[]}')
    with assert_raises(contains="Assignment.decode: expected integer at 5"):
        _ = Assignment.decode('{"p":x,"nodes":[],"owners":[]}')
    var hay = List[UInt8]()
    hay.append(1)
    assert_equal(_abytes_find(hay, "", 3), 3)


# ---- 3. binary form -------------------------------------------------------------


def test_binary_caps_and_truncation() raises:
    var many = List[String]()
    for _ in range(65536):
        many.append(String("n"))
    var too_many_nodes = Assignment(
        num_partitions=0, owners=List[String](), node_ids=many.copy(), reason=0
    )
    with assert_raises(contains="node_count 65536 exceeds the u16 cap (65535)"):
        _ = too_many_nodes.encode_binary()
    var too_many_owners = Assignment(
        num_partitions=65536, owners=many^, node_ids=_s("n"), reason=0
    )
    with assert_raises(contains="owners_count 65536 exceeds the u16 cap (65535)"):
        _ = too_many_owners.encode_binary()
    var long_id = String("")
    for _ in range(65536):
        long_id += "x"
    var long_node = Assignment(
        num_partitions=0, owners=List[String](), node_ids=_s(long_id), reason=0
    )
    with assert_raises(contains="node_id length 65536 exceeds the u16 cap"):
        _ = long_node.encode_binary()
    # Exactly at the cap is fine.
    var at_cap = String("")
    for _ in range(65535):
        at_cap += "y"
    var ok = Assignment(
        num_partitions=1, owners=_s(at_cap), node_ids=_s(at_cap), reason=0
    )
    assert_equal(Assignment.decode_binary(ok.encode_binary()).owner_of(0), at_cap)
    # The node and owner counts at exactly 65535 encode (the caps are > 65535,
    # not >= 65535).
    var at_cap_list = List[String]()
    for _ in range(65535):
        at_cap_list.append(String("n"))
    var nodes_at_cap = Assignment(
        num_partitions=0,
        owners=List[String](),
        node_ids=at_cap_list.copy(),
        reason=0,
    )
    assert_true(len(nodes_at_cap.encode_binary()) > 0)
    var owners_at_cap = Assignment(
        num_partitions=65535, owners=at_cap_list^, node_ids=_s("n"), reason=0
    )
    var oac = Assignment.decode_binary(owners_at_cap.encode_binary())
    assert_equal(oac.num_partitions, 65535)
    assert_equal(oac.owner_of(65534), "n")

    var body = _two().encode_binary()
    with assert_raises(contains="assignment binary decode: truncated u32 at offset 0"):
        _ = Assignment.decode_binary(_prefix(body, 2))
    with assert_raises(contains="assignment binary decode: truncated u16 at offset 4"):
        _ = Assignment.decode_binary(_prefix(body, 4))
    # Node "abc": its length u16 at 20, bytes at 22..25.
    with assert_raises(contains="truncated node table (need 3 bytes at 22)"):
        _ = Assignment.decode_binary(_prefix(body, 23))


# ---- 4. the zero-copy view --------------------------------------------------------


def test_view_truncations() raises:
    var body = _two().encode_binary()
    # Layout: header 20, node 20..25, owners_count 25..29, owners 29..33,
    # gens_count 33..37, gens 37..53, maxgens_count 53..57, maxgens 57..81.
    assert_equal(len(body), 81)
    var b3 = _prefix(body, 3)
    with assert_raises(contains="assignment binary view: truncated u32 at offset 0"):
        _ = Assignment.view(Span[UInt8](b3))
    var b21 = _prefix(body, 21)
    with assert_raises(contains="assignment binary view: truncated u16 at offset 20"):
        _ = Assignment.view(Span[UInt8](b21))
    var b23 = _prefix(body, 23)
    with assert_raises(contains="AssignmentView: truncated node table (need 3 bytes at 22)"):
        _ = Assignment.view(Span[UInt8](b23))
    var b30 = _prefix(body, 30)
    with assert_raises(contains="truncated owners array (need 4 bytes at 29)"):
        _ = Assignment.view(Span[UInt8](b30))
    var b38 = _prefix(body, 38)
    with assert_raises(contains="truncated generations array (need 16 bytes at 37)"):
        _ = Assignment.view(Span[UInt8](b38))
    var b60 = _prefix(body, 60)
    with assert_raises(contains="truncated max-generations array (need 24 bytes at 57)"):
        _ = Assignment.view(Span[UInt8](b60))



def test_vread_i64_bounds() raises:
    # The generations accessors read only inside arrays the view constructor
    # bounds-checked, so the i64 reader's own check is driven directly.
    var raw = List[UInt8]()
    for k in range(8):
        raw.append(UInt8(k + 1))
    assert_equal(_vread_i64(Span[UInt8](raw), 0), Int64(0x0807060504030201))
    with assert_raises(contains="assignment binary view: truncated i64 at offset 1"):
        _ = _vread_i64(Span[UInt8](raw), 1)
    with assert_raises(contains="assignment binary view: truncated i64 at offset -1"):
        _ = _vread_i64(Span[UInt8](raw), -1)


def test_view_accessor_ranges_and_legacy_bodies() raises:
    var body = _two().encode_binary()
    var v = Assignment.view(Span[UInt8](body))
    assert_equal(v.max_generations_count(), 3)
    assert_equal(v.max_generation(2), Int64(9))
    with assert_raises(contains="AssignmentView.owner_index: pid 2 out of range [0, 2)"):
        _ = v.owner_index(2)
    with assert_raises(contains="AssignmentView.node: index 1 out of range [0, 1)"):
        _ = v.node(1)
    with assert_raises(contains="AssignmentView.generation: pid -1 out of range"):
        _ = v.generation(-1)
    with assert_raises(contains="AssignmentView.max_generation: pid -1 out of range"):
        _ = v.max_generation(-1)
    # An owner index past the node table (patched to 5) is refused.
    var bad = body.copy()
    bad[31] = UInt8(5)
    var vb = Assignment.view(Span[UInt8](bad))
    with assert_raises(contains="owner index 5 out of node-table range [0, 1) for pid 1"):
        _ = vb.owner(1)
    # A v2 body: no high-water trailer. max_generation falls back to the live
    # generation below P and to 0 above it; to_owned materializes P entries.
    var v2 = _prefix(body, 53)
    var vv2 = Assignment.view(Span[UInt8](v2))
    assert_equal(vv2.max_generations_count(), 0)
    assert_equal(vv2.max_generation(1), Int64(4))
    assert_equal(vv2.max_generation(7), Int64(0))
    var owned = vv2.to_owned()
    assert_equal(len(owned.max_generations), 2)
    assert_equal(owned.max_generations[0], Int64(3))
    assert_equal(owned.generation_of(1), Int64(4))
    # A v1 body: no generations either, every generation reads 0.
    var v1 = _prefix(body, 33)
    var vv1 = Assignment.view(Span[UInt8](v1))
    assert_equal(vv1.generation(1), Int64(0))
    assert_equal(vv1.max_generation(0), Int64(0))


# ---- 5. spread corner cases ---------------------------------------------------------


def test_spread_corners() raises:
    with assert_raises(contains="num_partitions must be >= 0 (got -1)"):
        _ = assign_partitions(_s("a"), -1, None, REBALANCE_INITIAL)
    # A prior laid down with no live node: every owner "", none sticky.
    var empty = assign_partitions(List[String](), 2, None, REBALANCE_INITIAL)
    assert_equal(empty.owner_of(0), "")
    assert_true(empty.is_even())
    var next = assign_partitions(
        _s("a", "b"), 2, Optional(empty.copy()), REBALANCE_INITIAL
    )
    assert_equal(next.owner_of(0), "a")
    assert_equal(next.owner_of(1), "b")
    # Live ids come back sorted whatever order the nodes report in.
    var nodes = List[LiveNode]()
    nodes.append(LiveNode.at("c", Int64(100)))
    nodes.append(LiveNode.at("a", Int64(100)))
    nodes.append(LiveNode.at("z", Int64(1)))
    nodes.append(LiveNode.at("b", Int64(100)))
    var ids = live_node_ids(nodes, Int64(100), Int64(10))
    assert_equal(len(ids), 3)
    assert_equal(ids[0], "a")
    assert_equal(ids[1], "b")
    assert_equal(ids[2], "c")
    # Uneven: one node holds both partitions while another holds none.
    var uneven = Assignment(
        num_partitions=2, owners=_s("a", "a"), node_ids=_s("a", "b"), reason=0
    )
    assert_false(uneven.is_even())
    # Same size, one member swapped: a stale-node rebalance.
    assert_equal(
        rebalance_reason_for(Optional(next.copy()), _s("a", "c"), 2, False),
        REBALANCE_STALE_NODE,
    )
    assert_equal(
        rebalance_reason_for(Optional(next.copy()), _s("a", "b"), 2, False),
        REBALANCE_NONE,
    )
    # A minted shard id with no nonce supplied draws one (never "-1").
    var sid = mint_shard_id("inst", 2)
    assert_true(sid.startswith("inst-"))
    assert_true(sid.find("-w2-") > 0)
    assert_false(sid.endswith("--1"))


def main() raises:
    test_constructor_invariants()
    test_json_escapes_and_spaces()
    test_binary_caps_and_truncation()
    test_view_truncations()
    test_vread_i64_bounds()
    test_view_accessor_ranges_and_legacy_bodies()
    test_spread_corners()
    print("[OK] test_cov_partition_assignment_unit")
