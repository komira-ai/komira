# =============================================================================
# CD-GDIR — the grouped COUNT(DISTINCT)
# finalize's worker -> global group directory, built ONCE as a per-worker gid
# map.
#
# WHAT IS PINNED, against a linear-scan ORACLE computed from the raw key lists
# (never from the struct under test):
#   1. `keys` in FIRST-SEEN order across workers (worker order, then gid order)
#      — the order the finalize's output rows come out in, so a change here is
#      a change of row order, not just of an internal index.
#   2. every worker's `wgid[g]`.
#   3. the NULL group: one global group for every worker's NULL cell, placed at
#      its first appearance, never aliased with a real key equal to its
#      placeholder word.
#   4. `runs[gg]` = the exact number of worker cells mapping onto `gg` (the
#      drain sizes each group's run list from it).
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal

from komira_op_agg_distinct.cd_global_dir import CdGlobalDir


struct _W(Copyable, Movable):
    var keys: List[Int]
    var nulls: List[Bool]

    def __init__(out self, var keys: List[Int], var nulls: List[Bool]):
        self.keys = keys^
        self.nulls = nulls^


def _plain(var keys: List[Int]) -> _W:
    var ns = List[Bool]()
    for _ in range(len(keys)):
        ns.append(False)
    return _W(keys^, ns^)


def _check(imm ws: List[_W], what: String) raises:
    var d = CdGlobalDir()
    var maps = List[List[Int]]()
    for w in range(len(ws)):
        maps.append(d.map_worker(ws[w].keys, ws[w].nulls))
    # The oracle: first-seen order over (key, is_null).
    var gk = List[Int]()
    var gn = List[Bool]()
    var om = List[List[Int]]()
    for w in range(len(ws)):
        var m = List[Int]()
        for g in range(len(ws[w].keys)):
            var isn = ws[w].nulls[g]
            var k = ws[w].keys[g]
            var at = -1
            for j in range(len(gk)):
                if gn[j] == isn and (isn or gk[j] == k):
                    at = j
                    break
            if at < 0:
                at = len(gk)
                gk.append(0 if isn else k)
                gn.append(isn)
            m.append(at)
        om.append(m^)
    assert_equal(len(d.keys), len(gk), what + ": group count")
    var onull = -1
    for j in range(len(gk)):
        if gn[j]:
            onull = j
        assert_equal(d.keys[j], gk[j], what + ": key order")
    assert_equal(d.null_gid, onull, what + ": null gid")
    for w in range(len(ws)):
        assert_equal(len(maps[w]), len(ws[w].keys), what + ": map length")
        for g in range(len(ws[w].keys)):
            assert_equal(maps[w][g], om[w][g], what + ": wgid")
    for j in range(len(gk)):
        var cnt = 0
        for w in range(len(ws)):
            for g in range(len(ws[w].keys)):
                if om[w][g] == j:
                    cnt += 1
        assert_equal(d.runs[j], cnt, what + ": runs")


def test_interleaved_workers_keep_first_seen_order() raises:
    var ws = List[_W]()
    ws.append(_plain([5, 3, 9, 1]))
    ws.append(_plain([9, 7, 5, 2, 3]))
    ws.append(_plain([1, 2, 3, 4, 5, 6, 7, 8, 9]))
    ws.append(_plain(List[Int]()))  # a worker that saw nothing
    ws.append(_plain([100, 5]))
    _check(ws, "interleaved")


def test_negative_and_extreme_keys() raises:
    var ws = List[_W]()
    ws.append(_plain([-3, 0, 4, Int(Int64.MIN) + 1]))
    ws.append(_plain([4, -7, -3, 12, Int(Int64.MAX) - 1]))
    _check(ws, "negative / extreme")


def test_the_null_group_keeps_its_first_seen_position() raises:
    var ws = List[_W]()
    # worker 0: key 0 then NULL (whose placeholder word is 0) — they are TWO
    # groups, and the NULL one must not alias the real 0.
    var k0: List[Int] = [0, 0, 8]
    var n0: List[Bool] = [False, True, False]
    ws.append(_W(k0^, n0^))
    # worker 1: NULL first, then a real 0 LAST — the two must still land on
    # worker 0's two groups, in the opposite local order.
    var k1: List[Int] = [8, 0, 3, 0]
    var n1: List[Bool] = [False, True, False, False]
    ws.append(_W(k1^, n1^))
    _check(ws, "null")
    var d = CdGlobalDir()
    _ = d.map_worker(ws[0].keys, ws[0].nulls)
    _ = d.map_worker(ws[1].keys, ws[1].nulls)
    assert_equal(d.null_gid, 1)
    assert_equal(d.runs[1], 2, "both workers' NULL cells map to one group")
    assert_equal(d.runs[0], 2, "both workers' real 0 cells map to another")


def test_an_all_null_input_is_one_group() raises:
    var ws = List[_W]()
    var k: List[Int] = [0]
    var n: List[Bool] = [True]
    ws.append(_W(k^, n^))
    ws.append(_W([Int(0)], [True]))
    _check(ws, "all-null")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
