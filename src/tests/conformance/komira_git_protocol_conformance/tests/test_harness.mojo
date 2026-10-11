# =============================================================================
# test_harness.mojo -- the conformance library's own checks: the refusals
# the transcript tests rely on to say what went wrong, and the parts of the
# scenario's repository (TranscriptGraph) the transcripts do not reach.
# =============================================================================
#
# The transcript tests only ever see well-formed git output, so the library's
# refusals never fire there; a refusal that silently passed would let a
# broken pack or a truncated transcript through. Each case here names the
# exact message.
#
# WHAT EACH TEST CATCHES:
#   * test_check_pack: a 32-byte pack refused (the bound off by one), any one
#     of the four `PACK` bytes or the version not checked, a trailer compared
#     on fewer than its 20 bytes (first and last byte each flipped).
#   * test_read_git_packfile: band-2 progress taken into the pack, the
#     offset after the flush wrong, a section without its flush, a delim or
#     empty line read as data, band 3 accepted.
#   * test_graph: an unknown object called a commit, parents of an unknown
#     object raising instead of being none, a tag of a tag peeled one step
#     only, descends_from not walking parents or not reflexive, a merge
#     walked through its first parent only or its last parent only (a push
#     of a merge whose second parent is the old tip is a fast-forward).
#   * test_expect_bytes: the offset or either side of the refusal wrong, the
#     60-byte window off by one, a `got` longer than git's bytes read past
#     them or a start past their end not clamped, show() escaping a
#     printable byte or not escaping 0x7f / 0x1f.
#   * test_scenario_files: a scenario with no connection loaded, a refs.txt
#     line with two or with four fields accepted, HEAD invented when head.txt is
#     absent. The scenarios are fixtures/ (BUCK maps them under
#     transcripts/), not capture.sh output.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import sha1
from komira_git import (
    ObjectFormat,
    ObjectId,
    append_pkt_data,
    append_pkt_delim,
    append_pkt_flush,
)
from komira_git_protocol_conformance import (
    Scenario,
    TranscriptGraph,
    check_pack,
    expect_bytes,
    read_git_packfile,
)


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _pack(magic: String, version: UInt8) -> List[UInt8]:
    """A packfile header (`magic`, `version`, zero objects) and its SHA-1."""
    var p = _b(magic)
    p.append(0)
    p.append(0)
    p.append(0)
    p.append(version)
    for _ in range(4):
        p.append(0)
    var d = sha1(Span(p))
    for i in range(20):
        p.append(d[i])
    return p^


def _check_pack_refusal(pack: List[UInt8], want: String) raises:
    var refused = False
    try:
        check_pack(pack, "t")
    except e:
        refused = True
        assert_equal(String(e), want)
    assert_true(refused)


def test_check_pack() raises:
    var good = _pack("PACK", 2)
    assert_equal(len(good), 32)
    check_pack(good, "t")
    var short = List[UInt8]()
    for i in range(31):
        short.append(good[i])
    _check_pack_refusal(short, "t: the pack is 31 bytes")
    var bad_magic: List[String] = ["XACK", "PXCK", "PAXK", "PACX"]
    for i in range(len(bad_magic)):
        _check_pack_refusal(
            _pack(bad_magic[i], 2), "t: the pack does not start with PACK"
        )
    _check_pack_refusal(_pack("PACK", 3), "t: the pack is not version 2")
    for at in [12, 31]:
        var p = good.copy()
        p[at] ^= 1
        _check_pack_refusal(p, "t: the pack's trailer is not the SHA-1 of its bytes")


def _band(band: Int, data: Span[UInt8, _]) raises -> List[UInt8]:
    var payload = List[UInt8]()
    payload.append(UInt8(band))
    for i in range(len(data)):
        payload.append(data[i])
    var out = List[UInt8]()
    append_pkt_data(out, Span(payload))
    return out^


def _packfile_refusal(response: List[UInt8], want: String) raises:
    var refused = False
    try:
        _ = read_git_packfile(response, 0, "t")
    except e:
        refused = True
        assert_equal(String(e), want)
    assert_true(refused)


def test_read_git_packfile() raises:
    var pack = _pack("PACK", 2)
    var progress = _b("Counting objects: 1\r")
    var r = _b("lead")
    r += _band(2, Span(progress))
    r += _band(1, Span(pack)[0:10])
    r += _band(2, Span(progress))
    r += _band(1, Span(pack)[10:32])
    append_pkt_flush(r)
    var end = len(r)
    r += _b("0000")
    var got = read_git_packfile(r, 4, "t")
    assert_equal(got.end, end)
    assert_equal(len(got.pack), 32)
    for i in range(32):
        assert_equal(got.pack[i], pack[i])
    # No flush: the section runs off the end of the response.
    var early = _band(1, Span(pack))
    _packfile_refusal(early, "t: git's packfile section ends early")
    var delim = List[UInt8]()
    append_pkt_delim(delim)
    _packfile_refusal(delim, "t: a packfile line without a band")
    _packfile_refusal(_b("0004"), "t: a packfile line without a band")
    var fatal = _b("fatal")
    _packfile_refusal(_band(3, Span(fatal)), "t: band 3 in git's packfile")


def _id(c: String) raises -> ObjectId:
    var hex = String()
    for _ in range(40):
        hex += c
    return ObjectId.parse_hex(ObjectFormat.sha1(), hex)


def test_graph() raises:
    var c1 = _id("1")
    var c2 = _id("2")
    var t1 = _id("a")
    var t2 = _id("b")
    var blob = _id("c")
    var unknown = _id("d")
    # c4 is a root on a side branch; c3 merges c4 (first parent) and c2.
    var c3 = _id("3")
    var c4 = _id("4")
    var objects: List[String] = [
        c1.to_hex() + " commit",
        c2.to_hex() + " commit",
        c3.to_hex() + " commit",
        c4.to_hex() + " commit",
        t1.to_hex() + " tag",
        t2.to_hex() + " tag",
        blob.to_hex() + " blob",
    ]
    var parents: List[String] = [
        c2.to_hex() + " " + c1.to_hex(),
        c1.to_hex(),
        c3.to_hex() + " " + c4.to_hex() + " " + c2.to_hex(),
        c4.to_hex(),
    ]
    # t2 tags t1, which tags c2.
    var tags: List[String] = [t2.to_hex() + " " + t1.to_hex(), t1.to_hex() + " " + c2.to_hex()]
    var g = TranscriptGraph(objects, parents, tags)
    assert_true(g.has_object(blob))
    assert_false(g.has_object(unknown))
    assert_true(g.is_commit(c1))
    assert_false(g.is_commit(blob))
    assert_false(g.is_commit(t1))
    assert_false(g.is_commit(unknown))
    var ps = g.parents(c2)
    assert_equal(len(ps), 1)
    assert_true(ps[0] == c1)
    assert_equal(len(g.parents(c1)), 0)
    assert_equal(len(g.parents(unknown)), 0)
    assert_true(g.peel(t2) == c2)
    assert_true(g.peel(t1) == c2)
    assert_true(g.peel(c1) == c1)
    assert_true(g.descends_from(c2, c1))
    assert_true(g.descends_from(c2, c2))
    assert_false(g.descends_from(c1, c2))
    assert_false(g.descends_from(unknown, c1))
    # A merge: both parents, in order; each line of history reached.
    var mps = g.parents(c3)
    assert_equal(len(mps), 2)
    assert_true(mps[0] == c4)
    assert_true(mps[1] == c2)
    assert_true(g.descends_from(c3, c4))
    assert_true(g.descends_from(c3, c1))
    assert_false(g.descends_from(c4, c1))


def _bytes_refusal(
    got: List[UInt8], want: List[UInt8], at: Int, msg: String
) raises:
    var refused = False
    try:
        _ = expect_bytes(got, Span(want), at, "t")
    except e:
        refused = True
        assert_equal(String(e), msg)
    assert_true(refused)


def test_expect_bytes() raises:
    assert_equal(expect_bytes(_b("ab"), Span(_b("xaby")), 1, "t"), 3)
    assert_equal(expect_bytes(List[UInt8](), Span(_b("x")), 1, "t"), 1)
    _bytes_refusal(
        _b("abc"), _b("xxabd"), 2,
        "t: differs from git at byte 4\n  komira_git: c\n  git:        d",
    )
    # Longer than git's bytes: git's side is empty from the first extra byte.
    _bytes_refusal(
        _b("abcd"), _b("ab"), 0,
        "t: differs from git at byte 2\n  komira_git: cd\n  git:        ",
    )
    # Starting past the end of git's bytes: git's side is empty.
    _bytes_refusal(
        _b("a"), _b("b"), 5,
        "t: differs from git at byte 5\n  komira_git: a\n  git:        ",
    )
    var odd = List[UInt8]()
    for c in [0x1F, 0x20, 0x41, 0x7E, 0x7F, 0xFF]:
        odd.append(UInt8(c))
    var nul = List[UInt8]()
    nul.append(0)
    _bytes_refusal(
        odd, nul, 0,
        "t: differs from git at byte 0\n  komira_git: \\x1f A~\\x7f\\xff\n  git:        \\x00",
    )
    # At most 60 bytes of each side are shown.
    var a = List[UInt8](length=100, fill=UInt8(0x61))
    var b = List[UInt8](length=100, fill=UInt8(0x62))
    var sixty_a = String()
    var sixty_b = String()
    for _ in range(60):
        sixty_a += "a"
        sixty_b += "b"
    _bytes_refusal(
        a, b, 0,
        "t: differs from git at byte 0\n  komira_git: " + sixty_a + "\n  git:        " + sixty_b,
    )


def test_scenario_files() raises:
    var refused = False
    try:
        _ = Scenario("no_such_scenario")
    except e:
        refused = True
        assert_equal(String(e), "transcripts: scenario no_such_scenario has no connection")
    assert_true(refused)
    refused = False
    try:
        _ = Scenario("bad_refs")
    except e:
        refused = True
        assert_equal(
            String(e),
            "transcripts: bad refs.txt line: 1111111111111111111111111111111111111111 refs/heads/main",
        )
    assert_true(refused)
    refused = False
    try:
        _ = Scenario("bad_refs_four")
    except e:
        refused = True
        assert_equal(
            String(e),
            "transcripts: bad refs.txt line: 1111111111111111111111111111111111111111 refs/heads/main - extra",
        )
    assert_true(refused)
    var sc = Scenario("no_head")
    assert_equal(len(sc.connections), 1)
    assert_equal(String(StringSlice(from_utf8=Span(sc.connections[0].request))), "request\n")
    assert_equal(len(sc.refs), 2)
    assert_false(sc.refs[0].has_peeled())
    assert_true(sc.refs[1].peeled == _id("1"))
    assert_equal(sc.head_target, "")
    assert_false(Bool(sc.head()))


def main() raises:
    test_check_pack()
    test_read_git_packfile()
    test_graph()
    test_expect_bytes()
    test_scenario_files()
    print("komira_git conformance: harness checks passed")
