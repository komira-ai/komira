# =============================================================================
# Direct tests for optimizer_transitive_edges.derive_transitive_edges
# =============================================================================
#
# The pass reads only `chain.edges`, so these fixtures build JoinChains with
# edges and no relations. Each expected edge list below is traced by hand
# through the three phases of the pass (union-find, class grouping in
# first-seen order, pair enumeration); the comment on each test names the
# defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_optimizer.optimizer_reorder import JoinChain, JoinEdge
from komira_optimizer.optimizer_transitive_edges import (
    derive_transitive_edges,
)


def _edge(l: Int, r: Int, lk: String, rk: String) -> JoinEdge:
    var lks: List[String] = [lk]
    var rks: List[String] = [rk]
    return JoinEdge(l, r, lks^, rks^)


def _assert_edge(
    chain: JoinChain, idx: Int, l: Int, r: Int, lk: String, rk: String
) raises:
    ref e = chain.edges[idx]
    assert_equal(e.left_relation, l, "left relation of edge " + String(idx))
    assert_equal(e.right_relation, r, "right relation of edge " + String(idx))
    assert_equal(len(e.left_keys), 1, "a synthetic edge has one left key")
    assert_equal(len(e.right_keys), 1, "a synthetic edge has one right key")
    assert_equal(String(e.left_keys[0]), lk)
    assert_equal(String(e.right_keys[0]), rk)


def test_empty_chain_adds_nothing() raises:
    """No edges: no class, nothing appended."""
    var chain = JoinChain()
    assert_equal(derive_transitive_edges(chain), 0)
    assert_equal(len(chain.edges), 0)


def test_star_class_adds_the_missing_pair_then_is_idempotent() raises:
    """0.a = 1.b and 0.a = 2.c put {0.a, 1.b, 2.c} in one class; the only
    pair with no edge is (1.b, 2.c), appended after the real edges.

    Catches: the per-column existence check always answering False (a
    second run would append again), the synthetic edge built with the
    wrong relation or column, and the pass not returning its count.
    """
    var chain = JoinChain()
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(0, 2, "a", "c"))
    assert_equal(derive_transitive_edges(chain), 1)
    assert_equal(len(chain.edges), 3)
    _assert_edge(chain, 2, 1, 2, "b", "c")
    # A second run finds every pair covered (the synthetic edge included).
    assert_equal(derive_transitive_edges(chain), 0)
    assert_equal(len(chain.edges), 3)


def test_reverse_oriented_edge_counts_as_existing() raises:
    """0.a = 1.b and 2.c = 1.b: the class lists 0.a, 1.b, 2.c. The pair
    (1.b, 2.c) is covered by the edge stored as (2, 1, c, b), so only
    (0.a, 2.c) is new. The second edge's left node joins an existing
    class (the left-side merge branch of the grouping phase).

    Catches: the reverse-direction check removed (2 edges would be added).
    """
    var chain = JoinChain()
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(2, 1, "c", "b"))
    assert_equal(derive_transitive_edges(chain), 1)
    assert_equal(len(chain.edges), 3)
    _assert_edge(chain, 2, 0, 2, "a", "c")


def test_chain_shape_right_node_joins_existing_class() raises:
    """0.a = 1.b and 1.b = 2.c: the second edge's right node joins the
    class (the right-side merge branch of the grouping phase); the one
    new pair is (0.a, 2.c).

    Catches: the right-side merge dropping the node (the class would have
    2 members and nothing would be added).
    """
    var chain = JoinChain()
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(1, 2, "b", "c"))
    assert_equal(derive_transitive_edges(chain), 1)
    _assert_edge(chain, 2, 0, 2, "a", "c")


def test_two_member_classes_add_nothing() raises:
    """Two unrelated classes of size 2 each: no pair lacks an edge."""
    var chain = JoinChain()
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(1, 2, "x", "y"))
    assert_equal(derive_transitive_edges(chain), 0)
    assert_equal(len(chain.edges), 2)


def test_same_relation_pair_in_class_is_skipped() raises:
    """0.x = 1.y and 0.z = 1.y put 0.x and 0.z in one class. The pair
    (0.x, 0.z) is on one relation and must not become an edge.

    Catches: the same-relation skip removed (a self edge 0-0 would be
    appended and the count would be 1).
    """
    var chain = JoinChain()
    chain.edges.append(_edge(0, 1, "x", "y"))
    chain.edges.append(_edge(0, 1, "z", "y"))
    assert_equal(derive_transitive_edges(chain), 0)
    assert_equal(len(chain.edges), 2)


def test_duplicate_edge_union_is_a_no_op() raises:
    """A repeated edge unions two nodes already in one class (the early
    return of the union); the result equals the star case.
    """
    var chain = JoinChain()
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(0, 2, "a", "c"))
    assert_equal(derive_transitive_edges(chain), 1)
    assert_equal(len(chain.edges), 4)
    _assert_edge(chain, 3, 1, 2, "b", "c")


def test_unequal_key_lists_use_the_shorter_length() raises:
    """Edge 1 has left keys [z, p] and right keys [q]: only z = q joins a
    class, and the existence check must not read right_keys[1].

    Edges: (0,2) p=r, (0,1) [z,p]=[q], (2,1) r=q. One class with members
    in first-seen order 0.p, 2.r, 0.z, 1.q. New pairs: (0.p, 1.q), since
    p sits at index 1 of edge 1 with no right key there, and (2.r, 0.z).

    Catches: the min(len(left_keys), len(right_keys)) bound removed in the
    union or grouping phase, or the `j < len(e.right_keys)` guard removed
    from the existence check (both read past right_keys; with bounds
    checks the build traps, without them the counts change).
    """
    var chain = JoinChain()
    chain.edges.append(_edge(0, 2, "p", "r"))
    var lks: List[String] = ["z", "p"]
    var rks: List[String] = ["q"]
    chain.edges.append(JoinEdge(0, 1, lks^, rks^))
    chain.edges.append(_edge(2, 1, "r", "q"))
    assert_equal(derive_transitive_edges(chain), 2)
    assert_equal(len(chain.edges), 5)
    _assert_edge(chain, 3, 0, 1, "p", "q")
    _assert_edge(chain, 4, 2, 0, "r", "z")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
