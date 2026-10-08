# =============================================================================
# komira_git/tests/test_fetch_negotiation.mojo -- the server's answer to a
# protocol v2 fetch: negotiate() over a CommitGraph, and FetchResponder's
# sections.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: gitprotocol-v2 ("fetch": acknowledgments,
# shallow-info, packfile and their order) and upload-pack.c at v2.56.0
# (do_got_oid marks a have's parents as known before deciding whether to
# acknowledge it; ok_to_give_up; send_shallow writes no LF). The graph:
#
#     c1 <- c2 <- c3 <- c5        tag t1 -> c1, blob b1
#            ^
#            +--- c4                 r1 (unrelated; its parent m9 is not in the
#                                    repository, as in a shallow one)
#
# WHAT EACH TEST CATCHES:
#   * test_acks: a have acknowledged although an earlier have's parent made
#     it known; a missing have acknowledged; the order of the client's haves
#     not kept; a duplicate have acknowledged twice.
#   * test_ready: `ready` without every want reaching a known commit; a
#     tag want not peeled; ready under wait-for-done or with no common
#     object; a want missing from the repository not refused.
#   * test_responder_bytes: the exact sections for NAK, ACK+ready, a done
#     request and an empty request; shallow lines with an LF; the
#     packfile's band bytes; progress written despite `no-progress`;
#     shallow lines refused for a request holding only `deepen-since` or
#     only `deepen-not`.
#   * test_responder_order: a section written out of order or twice.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    CommitGraph,
    FetchArgs,
    FetchResponder,
    Negotiation,
    ObjectFormat,
    ObjectId,
    negotiate,
)


def _hex(c: Int) -> String:
    """A 40-digit id spelled with digit `c` (1..9) repeated."""
    var s = String()
    for _ in range(40):
        s += chr(48 + c)
    return s^


def _id(c: Int) raises -> ObjectId:
    return ObjectId.parse_hex(ObjectFormat.sha1(), _hex(c))


comptime C1 = 1
comptime C2 = 2
comptime C3 = 3
comptime C4 = 4
comptime C5 = 5
comptime T1 = 6
comptime B1 = 7
comptime R1 = 8
comptime MISSING = 9


struct Toy(CommitGraph):
    """The graph in the header, by digit."""

    def __init__(out self):
        pass

    def _digit(self, id: ObjectId) -> Int:
        return Int(id.byte_at(0)) & 15

    def has_object(self, id: ObjectId) -> Bool:
        return self._digit(id) != MISSING

    def is_commit(self, id: ObjectId) -> Bool:
        var d = self._digit(id)
        return d == C1 or d == C2 or d == C3 or d == C4 or d == C5 or d == R1

    def parents(self, id: ObjectId) raises -> List[ObjectId]:
        var d = self._digit(id)
        var out = List[ObjectId]()
        if d == C2 or d == C4:
            out.append(_id(C1 if d == C2 else C2))
        elif d == C3:
            out.append(_id(C2))
        elif d == R1:
            # A parent the repository does not hold (a shallow repository).
            out.append(_id(MISSING))
        elif d == C5:
            out.append(_id(C3))
        return out^

    def peel(self, id: ObjectId) raises -> ObjectId:
        if self._digit(id) == T1:
            return _id(C1)
        return id


def _args(wants: List[Int], haves: List[Int]) raises -> FetchArgs:
    var a = FetchArgs()
    for i in range(len(wants)):
        a.wants.append(_id(wants[i]))
    for i in range(len(haves)):
        a.haves.append(_id(haves[i]))
    return a^


def _common(n: Negotiation) -> String:
    var s = String()
    for i in range(len(n.common)):
        s += String(Int(n.common[i].byte_at(0)) & 15)
    return s^


def test_acks() raises:
    var g = Toy()
    # c4's parent c2 is known before c2 itself arrives; c9 is missing.
    var n = negotiate(_args([C5], [C4, MISSING, C2, C3, C3, C1]), g)
    assert_equal(_common(n), "43")
    var n2 = negotiate(_args([C5], [C1, C2]), g)
    assert_equal(_common(n2), "12")
    var n3 = negotiate(_args([C5], [B1, T1]), g)
    assert_equal(_common(n3), "76")


def test_ready() raises:
    var g = Toy()
    assert_true(negotiate(_args([C5], [C3]), g).ready)
    # c4 reaches c2, a parent of the have c3.
    assert_true(negotiate(_args([C4], [C3]), g).ready)
    assert_false(negotiate(_args([C4, R1], [C3]), g).ready)
    assert_false(negotiate(_args([C5], [MISSING]), g).ready)
    # A tag want is peeled to its commit; a blob want counts as reached.
    assert_true(negotiate(_args([T1, B1], [C2]), g).ready)
    # t1 peels to c1, which r1 (whose parent m9 is absent) does not reach.
    assert_false(negotiate(_args([T1], [R1]), g).ready)
    var waiting = _args([C5], [C3])
    waiting.wait_for_done = True
    var w = negotiate(waiting, g)
    assert_false(w.ready)
    assert_equal(_common(w), "3")
    try:
        _ = negotiate(_args([MISSING], [C3]), g)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: upload-pack: not our ref " + _hex(MISSING))


def _show(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 32 and c < 127:
            s += chr(c)
        else:
            var h = String("0123456789abcdef")
            s += "\\x" + chr(Int(h.as_bytes()[c >> 4])) + chr(Int(h.as_bytes()[c & 15]))
    return s^


def test_responder_bytes() raises:
    var g = Toy()
    # No common have: NAK and a flush; the client sends another request.
    var a1 = _args([C5], [MISSING])
    var out = List[UInt8]()
    var r1 = FetchResponder(a1)
    assert_false(r1.append_acknowledgments(out, negotiate(a1, g)))
    assert_equal(_show(out), "0014acknowledgments\\x0a0008NAK\\x0a0000")
    # ACK, ready, shallow-info, packfile.
    var a2 = _args([C5], [C3])
    a2.deepen = 1
    var r2 = FetchResponder(a2)
    out.clear()
    assert_true(r2.append_acknowledgments(out, negotiate(a2, g)))
    var shallow = List[ObjectId]()
    shallow.append(_id(C5))
    var unshallow = List[ObjectId]()
    unshallow.append(_id(C3))
    r2.append_shallow_info(out, shallow, unshallow)
    r2.append_packfile_header(out)
    var pack = List[UInt8](String("PACK").as_bytes())
    r2.append_pack_data(out, Span(pack))
    r2.append_progress(out, "Counting\n")
    r2.finish(out)
    assert_equal(
        _show(out),
        "0014acknowledgments\\x0a0031ACK " + _hex(C3) + "\\x0a000aready\\x0a0001"
        + "0011shallow-info\\x0a0034shallow " + _hex(C5)
        + "0036unshallow " + _hex(C3) + "0001"
        + "000dpackfile\\x0a0009\\x01PACK000e\\x02Counting\\x0a0000",
    )
    # `done`: no acknowledgments section at all; no-progress drops band 2.
    var a3 = _args([C5], [C3])
    a3.done = True
    a3.no_progress = True
    var r3 = FetchResponder(a3)
    out.clear()
    assert_true(r3.append_acknowledgments(out, negotiate(a3, g)))
    r3.append_shallow_info(out, List[ObjectId](), List[ObjectId]())
    r3.append_packfile_header(out)
    r3.append_progress(out, "Counting\n")
    r3.append_fatal_error(out, "boom")
    assert_equal(_show(out), "000dpackfile\\x0a0009\\x03boom")
    # No wants and no wait-for-done: nothing.
    var a4 = _args(List[Int](), [C3])
    var r4 = FetchResponder(a4)
    out.clear()
    assert_false(r4.append_acknowledgments(out, negotiate(a4, g)))
    assert_equal(len(out), 0)
    # wait-for-done: acknowledgments without ready, then a flush.
    var a5 = _args(List[Int](), [C5, C3])
    a5.wait_for_done = True
    var r5 = FetchResponder(a5)
    out.clear()
    assert_false(r5.append_acknowledgments(out, negotiate(a5, g)))
    assert_equal(_show(out), "0014acknowledgments\\x0a0031ACK " + _hex(C5) + "\\x0a0000")
    # `deepen-since` alone, and `deepen-not` alone, ask for shallow-info
    # (git's deepen_rev_list): the caller's cut is written.
    for k in range(2):
        var a6 = _args([C5], List[Int]())
        a6.done = True
        if k == 0:
            a6.deepen_since = 1790000150
        else:
            a6.deepen_not.append("v1")
        assert_true(a6.asks_shallow())
        var r6 = FetchResponder(a6)
        out.clear()
        assert_true(r6.append_acknowledgments(out, negotiate(a6, g)))
        var cut = List[ObjectId]()
        cut.append(_id(C3))
        r6.append_shallow_info(out, cut, List[ObjectId]())
        assert_equal(
            _show(out), "0011shallow-info\\x0a0034shallow " + _hex(C3) + "0001"
        )
    assert_false(_args([C5], [C3]).asks_shallow())


def _order_error(step: Int) raises -> String:
    var g = Toy()
    var a = _args([C5], [C3])
    var r = FetchResponder(a)
    var out = List[UInt8]()
    try:
        if step == 0:
            r.append_packfile_header(out)
        elif step == 1:
            _ = r.append_acknowledgments(out, negotiate(a, g))
            _ = r.append_acknowledgments(out, negotiate(a, g))
        elif step == 2:
            _ = r.append_acknowledgments(out, negotiate(a, g))
            r.append_packfile_header(out)
            r.append_shallow_info(out, List[ObjectId](), List[ObjectId]())
        elif step == 3:
            _ = r.append_acknowledgments(out, negotiate(a, g))
            var s = List[ObjectId]()
            s.append(_id(C5))
            r.append_shallow_info(out, s, List[ObjectId]())
        elif step == 4:
            var n = Negotiation()
            n.ready = True
            _ = r.append_acknowledgments(out, n)
        elif step == 5:
            _ = r.append_acknowledgments(out, negotiate(a, g))
            var pack = List[UInt8]()
            r.append_pack_data(out, Span(pack))
        else:
            var miss = _args([C5], [MISSING])
            var r2 = FetchResponder(miss)
            _ = r2.append_acknowledgments(out, negotiate(miss, g))
            r2.append_packfile_header(out)
    except e:
        return String(e)
    return "accepted"


def test_responder_order() raises:
    comptime P = "komira_git: fetch response: "
    assert_equal(_order_error(0), P + "no packfile follows this response")
    assert_equal(_order_error(1), P + "acknowledgments come first, once")
    assert_equal(
        _order_error(2),
        P + "shallow-info comes after the acknowledgments, before the packfile",
    )
    assert_equal(_order_error(3), P + "shallow lines for a request that is not shallow")
    assert_equal(
        _order_error(4),
        P + "'ready' needs an acknowledged have and no wait-for-done",
    )
    assert_equal(_order_error(5), P + "not inside the packfile section")
    assert_equal(_order_error(6), P + "no packfile follows this response")


def main() raises:
    test_acks()
    test_ready()
    test_responder_bytes()
    test_responder_order()
    print("komira_git fetch negotiation tests passed")
