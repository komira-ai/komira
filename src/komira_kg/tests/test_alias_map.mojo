# =============================================================================
# test_alias_map.mojo -- the directed union-find over node ids.
# =============================================================================
#
#   identity    an id never named resolves to itself and is not an alias.
#   direction   union(alias, canonical) makes the second argument the answer;
#               chains collapse to the last canonical; a self-union and a repeat
#               change nothing.
#   order       a consistent set of unions gives the same answer for every id
#               under every order of the calls, and resolving in any order (which
#               compresses paths differently) gives the same answers.
#   conflict    an id claimed for two canonical ids merges both sets; the later
#               call's canonical represents them (documented, order-dependent).
#   bookkeeping num_registered counts distinct ids named in a union.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg import AliasMap


def test_an_unnamed_id_resolves_to_itself() raises:
    var m = AliasMap()
    assert_equal(m.resolve(5), Int64(5))
    assert_false(m.is_alias(5))
    assert_equal(m.num_registered(), 0)


def test_union_makes_the_second_argument_canonical() raises:
    var m = AliasMap()
    m.union(1, 2)
    assert_equal(m.resolve(1), Int64(2))
    assert_equal(m.resolve(2), Int64(2))
    assert_true(m.is_alias(1))
    assert_false(m.is_alias(2))


def test_a_chain_collapses_to_the_last_canonical() raises:
    var m = AliasMap()
    m.union(1, 2)
    m.union(2, 3)
    assert_equal(m.resolve(1), Int64(3))
    assert_equal(m.resolve(2), Int64(3))
    assert_equal(m.resolve(3), Int64(3))
    assert_true(m.is_alias(1))
    assert_true(m.is_alias(2))
    assert_false(m.is_alias(3))
    # A later alias of an alias lands on the same canonical.
    m.union(4, 1)
    assert_equal(m.resolve(4), Int64(3))
    # An unrelated id is untouched.
    assert_equal(m.resolve(999), Int64(999))


def test_a_self_union_and_a_repeat_change_nothing() raises:
    var m = AliasMap()
    m.union(1, 2)
    m.union(3, 3)
    assert_equal(m.num_registered(), 2)
    m.union(1, 2)
    m.union(1, 2)
    assert_equal(m.num_registered(), 2)
    assert_equal(m.resolve(1), Int64(2))
    assert_equal(m.resolve(3), Int64(3))


def _apply(pairs: List[Int64], order: List[Int]) -> AliasMap:
    """Apply the unions pairs[2k] -> pairs[2k+1] in the given order."""
    var m = AliasMap()
    for i in range(len(order)):
        var k = order[i]
        m.union(pairs[2 * k], pairs[2 * k + 1])
    return m^


def _extend(
    n: Int, mut cur: List[Int], mut used: List[Bool], mut out: List[List[Int]]
):
    if len(cur) == n:
        out.append(cur.copy())
        return
    for i in range(n):
        if used[i]:
            continue
        used[i] = True
        cur.append(i)
        _extend(n, cur, used, out)
        _ = cur.pop()
        used[i] = False


def _permutations(n: Int) -> List[List[Int]]:
    """Every ordering of 0..n-1."""
    var out = List[List[Int]]()
    var cur = List[Int]()
    var used = List[Bool]()
    for _ in range(n):
        used.append(False)
    _extend(n, cur, used, out)
    return out^


def test_consistent_unions_give_the_same_answers_in_every_order() raises:
    # Two trees: 1,2 -> 3 -> 4 and 5 -> 6, and 7 -> 6. Each id has one canonical.
    var pairs: List[Int64] = [1, 3, 2, 3, 3, 4, 5, 6, 7, 6]
    var ids: List[Int64] = [1, 2, 3, 4, 5, 6, 7, 8]
    var want: List[Int64] = [4, 4, 4, 4, 6, 6, 6, 8]
    var orders = _permutations(5)
    assert_equal(len(orders), 120)
    for o in range(len(orders)):
        var m = _apply(pairs, orders[o])
        for i in range(len(ids)):
            assert_equal(m.resolve(ids[i]), want[i])


def test_resolving_in_any_order_gives_the_same_answers() raises:
    var pairs: List[Int64] = [1, 2, 2, 3, 3, 4, 4, 5]
    var order: List[Int] = [0, 1, 2, 3]
    var orders = _permutations(5)
    for o in range(len(orders)):
        var m = _apply(pairs, order)
        # Resolve the ids 1..5 in this permutation of order.
        for i in range(len(orders[o])):
            assert_equal(m.resolve(Int64(orders[o][i] + 1)), Int64(5))
        for nid in range(1, 6):
            assert_equal(m.resolve(Int64(nid)), Int64(5))


def test_a_copy_is_independent() raises:
    var m = AliasMap()
    m.union(1, 2)
    var c = m.copy()
    c.union(2, 9)
    assert_equal(c.resolve(1), Int64(9))
    assert_equal(m.resolve(1), Int64(2))


def test_conflicting_claims_merge_and_the_later_canonical_represents() raises:
    var first = AliasMap()
    first.union(1, 2)
    first.union(1, 3)
    assert_equal(first.resolve(1), Int64(3))
    assert_equal(first.resolve(2), Int64(3))

    var reversed = AliasMap()
    reversed.union(1, 3)
    reversed.union(1, 2)
    assert_equal(reversed.resolve(1), Int64(2))
    assert_equal(reversed.resolve(3), Int64(2))


def test_num_registered_counts_distinct_ids() raises:
    var m = AliasMap()
    m.union(1, 2)
    m.union(2, 3)
    m.union(4, 3)
    assert_equal(m.num_registered(), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
