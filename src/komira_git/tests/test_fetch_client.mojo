# =============================================================================
# komira_git/tests/test_fetch_client.mojo -- the protocol v2 client: the
# advertisement, ls-refs and fetch requests, and reading their responses.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: gitprotocol-v2 and git's connect.c and
# fetch-pack.c at v2.56.0 (which lines end in LF, the order of the request
# lines, the refusals' words). The comparison with what git itself writes
# and reads is in src/tests/conformance/komira_git_protocol_conformance.
#
# WHAT EACH TEST CATCHES:
#   * test_advertisement: a capability lost or misread (`fetch=shallow
#     wait-for-done` has the feature `shallow`, `ls-refs` with no value is
#     still offered); an advertisement not starting `version 2` accepted; a
#     short read that consumes input.
#   * test_ls_refs: the request's bytes (LF after `command=ls-refs`, none
#     after `agent=`; `unborn` only when offered; `peel` dropped for a
#     push); the response's symref-target, peeled and unborn HEAD lines.
#   * test_fetch_request: the order of the arguments, `deepen`,
#     `deepen-since` and `deepen-not` without LF and `deepen-relative` with
#     one, `done`; refusals for a deepen-since before the epoch, a deepen,
#     deepen-since or deepen-not each sent alone to a server without
#     `shallow` (nothing written), server options it does not
#     take, and a format it does not use.
#   * test_fetch_events: each event of a round without `ready`, of one
#     with acknowledgments, shallow-info and a packfile, and of a `done`
#     request (no acknowledgments section).
#   * test_fetch_refusals: each malformed response by its exact message.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    FETCH_ACK,
    FETCH_END,
    FETCH_NAK,
    FETCH_NEED_MORE,
    FETCH_PACK_DATA,
    FETCH_PROGRESS,
    FETCH_READY,
    FETCH_ROUND_END,
    FETCH_SHALLOW,
    FETCH_UNSHALLOW,
    FetchArgs,
    FetchV2Client,
    ObjectFormat,
    ObjectId,
    append_pkt_data,
    append_pkt_delim,
    append_pkt_flush,
    append_pkt_response_end,
    append_pkt_text,
)

comptime A = "1111111111111111111111111111111111111111"
comptime B = "2222222222222222222222222222222222222222"
comptime GIT_ADV = (
    "000eversion 2\n001bagent=git/2.56.0-Linux\n0013ls-refs=unborn\n"
    "0020fetch=shallow wait-for-done\n0012server-option\n0017object-format=sha1\n0000"
)


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


def _client(adv: String) raises -> FetchV2Client:
    var c = FetchV2Client("git/2.56.0-Linux", ObjectFormat.sha1())
    var b = List[UInt8](adv.as_bytes())
    c.feed(Span(b))
    assert_true(c.read_advertisement())
    return c^


def _id(hex: String) raises -> ObjectId:
    return ObjectId.parse_hex(ObjectFormat.sha1(), hex)


def test_advertisement() raises:
    var c = FetchV2Client("git/2.56.0-Linux", ObjectFormat.sha1())
    var b = List[UInt8](String(GIT_ADV).as_bytes())
    for i in range(len(b) - 1):
        c.feed(Span(b)[i : i + 1])
        assert_false(c.read_advertisement())
    c.feed(Span(b)[len(b) - 1 : len(b)])
    assert_true(c.read_advertisement())
    ref caps = c.capabilities
    assert_equal(len(caps.lines), 5)
    assert_true(caps.supports("ls-refs"))
    assert_true(caps.supports_feature("ls-refs", "unborn"))
    assert_true(caps.supports_feature("fetch", "shallow"))
    assert_true(caps.supports_feature("fetch", "wait-for-done"))
    assert_false(caps.supports_feature("fetch", "filter"))
    assert_false(caps.supports("fetc"))
    assert_true(caps.supports("server-option"))
    var algo = caps.value("object-format")
    assert_equal(algo.value(), "sha1")
    assert_true(not caps.value("server-option"))
    var v1 = FetchV2Client("x", ObjectFormat.sha1())
    var w = List[UInt8]()
    append_pkt_text(w, "version 1\n")
    append_pkt_flush(w)
    v1.feed(Span(w))
    try:
        _ = v1.read_advertisement()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: fetch: expected 'version 2', got 'version 1'")


def test_ls_refs() raises:
    var c = _client(GIT_ADV)
    var out = List[UInt8]()
    var prefixes: List[String] = ["refs/heads/", "HEAD"]
    var opts: List[String] = ["o1"]
    c.append_ls_refs_request(out, prefixes, server_options=opts)
    assert_equal(
        _show(out),
        "0014command=ls-refs\\x0a001aagent=git/2.56.0-Linux0016object-format=sha1"
        + "0014server-option=o10001"
        + "0009peel\\x0a000csymrefs\\x0a000bunborn\\x0a"
        + "001bref-prefix refs/heads/\\x0a0014ref-prefix HEAD\\x0a0000",
    )
    # For a push: no peel; no unborn when ls-refs has no value.
    var bare = _client(
        "000eversion 2\n000cls-refs\n0012fetch=shallow\n0000"
    )
    out.clear()
    bare.append_ls_refs_request(out, List[String](), peel=False)
    assert_equal(
        _show(out), "0014command=ls-refs\\x0a0001000csymrefs\\x0a0000"
    )
    var resp = List[UInt8]()
    append_pkt_text(resp, A + " HEAD symref-target:refs/heads/main\n")
    append_pkt_text(resp, A + " refs/heads/main\n")
    append_pkt_text(resp, B + " refs/tags/v1 peeled:" + A + "\n")
    append_pkt_text(resp, "unborn refs/heads/x\n")
    append_pkt_flush(resp)
    c.feed(Span(resp)[0 : len(resp) - 1])
    assert_false(c.read_ls_refs().complete)
    c.feed(Span(resp)[len(resp) - 1 : len(resp)])
    var r = c.read_ls_refs()
    assert_true(r.complete)
    assert_equal(len(r.refs), 3)
    assert_equal(r.refs[0].name, "HEAD")
    assert_equal(r.refs[0].symref_target, "refs/heads/main")
    assert_true(r.refs[2].peeled == _id(A))
    assert_false(r.refs[1].has_peeled())
    assert_equal(r.unborn_head_target, "")
    var empty = List[UInt8]()
    append_pkt_text(empty, "unborn HEAD symref-target:refs/heads/trunk\n")
    append_pkt_flush(empty)
    c.feed(Span(empty))
    var u = c.read_ls_refs()
    assert_equal(len(u.refs), 0)
    assert_equal(u.unborn_head_target, "refs/heads/trunk")
    var bad = List[UInt8]()
    append_pkt_text(bad, "zz refs/heads/main\n")
    c.feed(Span(bad))
    try:
        _ = c.read_ls_refs()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: fetch: invalid ls-refs response: zz refs/heads/main")


def test_fetch_request() raises:
    var c = _client(GIT_ADV)
    var a = FetchArgs()
    a.thin_pack = True
    a.no_progress = True
    a.include_tag = True
    a.ofs_delta = True
    a.shallows.append(_id(B))
    a.deepen = 1
    a.deepen_relative = True
    a.wants.append(_id(A))
    a.haves.append(_id(B))
    a.done = True
    var out = List[UInt8]()
    var opts: List[String] = ["opt-a"]
    c.append_fetch_request(out, a, server_options=opts)
    assert_equal(
        _show(out),
        "0011command=fetch001aagent=git/2.56.0-Linux0017server-option=opt-a"
        + "0016object-format=sha10001000dthin-pack000fno-progress000finclude-tag"
        + "000dofs-delta0034shallow " + B + "000cdeepen 10014deepen-relative\\x0a"
        + "0032want " + A + "\\x0a0032have " + B + "\\x0a0009done\\x0a0000",
    )
    # fetch-pack.c's add_shallow_requests order; no LF on either line.
    var since = FetchArgs()
    since.deepen_since = 1790000150
    since.deepen_not.append("v1")
    since.deepen_not.append("refs/heads/topic")
    since.deepen_relative = True
    since.wants.append(_id(A))
    out.clear()
    c.append_fetch_request(out, since)
    assert_equal(
        _show(out),
        "0011command=fetch001aagent=git/2.56.0-Linux0016object-format=sha10001"
        + "001bdeepen-since 17900001500011deepen-not v1001fdeepen-not refs/heads/topic"
        + "0014deepen-relative\\x0a0032want " + A + "\\x0a0000",
    )
    var before_epoch = FetchArgs()
    before_epoch.deepen_since = -1
    out.clear()
    try:
        c.append_fetch_request(out, before_epoch)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: fetch: deepen-since -1 is before the epoch")
    assert_equal(len(out), 0)
    var negotiate_only = FetchArgs()
    negotiate_only.wait_for_done = True
    negotiate_only.haves.append(_id(A))
    out.clear()
    c.append_fetch_request(out, negotiate_only)
    assert_equal(
        _show(out),
        "0011command=fetch001aagent=git/2.56.0-Linux0016object-format=sha10001"
        + "0011wait-for-done0032have " + A + "\\x0a0000",
    )
    var plain = _client("000eversion 2\n0011fetch=filter\n0000")
    # Each of deepen, deepen-since and deepen-not alone needs `shallow`.
    for k in range(3):
        var deep = FetchArgs()
        if k == 0:
            deep.deepen = 2
        elif k == 1:
            deep.deepen_since = 1790000150
        else:
            deep.deepen_not.append("v1")
        out.clear()
        try:
            plain.append_fetch_request(out, deep)
            assert_true(False)
        except e:
            assert_equal(String(e), "komira_git: fetch: Server does not support shallow requests")
        assert_equal(len(out), 0)
    try:
        plain.append_fetch_request(out, FetchArgs(), server_options=opts)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: fetch: server doesn't support 'server-option'")
    try:
        plain.append_ls_refs_request(out, List[String]())
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: fetch: server doesn't support 'ls-refs'")
    var sha256 = _client("000eversion 2\n0012fetch=shallow\n0019object-format=sha256\n0000")
    try:
        sha256.append_fetch_request(out, FetchArgs())
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: fetch: mismatched algorithms: client sha1; server sha256")


def _events(mut c: FetchV2Client) raises -> String:
    var s = String()
    while True:
        var ev = c.next_event()
        if ev.kind == FETCH_NEED_MORE:
            return s + "|more"
        s += "|" + String(ev.kind)
        if ev.kind == FETCH_ACK or ev.kind == FETCH_SHALLOW or ev.kind == FETCH_UNSHALLOW:
            s += ":" + String(Int(ev.id.byte_at(0)) & 15)
        if ev.kind == FETCH_PACK_DATA or ev.kind == FETCH_PROGRESS:
            s += ":" + _show(ev.data)
        if ev.kind == FETCH_END or ev.kind == FETCH_ROUND_END:
            return s


def _band(mut out: List[UInt8], band: Int, text: String) raises:
    var b = List[UInt8]()
    b.append(UInt8(band))
    for i in range(text.byte_length()):
        b.append(text.as_bytes()[i])
    append_pkt_data(out, Span(b))


def test_fetch_events() raises:
    var c = _client(GIT_ADV)
    var a = FetchArgs()
    a.wants.append(_id(A))
    a.haves.append(_id(B))
    var out = List[UInt8]()
    c.append_fetch_request(out, a)
    var r1 = List[UInt8]()
    append_pkt_text(r1, "acknowledgments\n")
    append_pkt_text(r1, "NAK\n")
    append_pkt_flush(r1)
    c.feed(Span(r1)[0:10])
    assert_equal(_events(c), "|more")
    c.feed(Span(r1)[10 : len(r1)])
    assert_equal(_events(c), "|2|4")
    c.append_fetch_request(out, a)
    var r2 = List[UInt8]()
    append_pkt_text(r2, "acknowledgments\n")
    append_pkt_text(r2, "ACK " + B + "\n")
    append_pkt_text(r2, "ready\n")
    append_pkt_delim(r2)
    append_pkt_text(r2, "shallow-info\n")
    append_pkt_text(r2, "shallow " + A)
    append_pkt_text(r2, "unshallow " + B)
    append_pkt_delim(r2)
    append_pkt_text(r2, "packfile\n")
    _band(r2, 2, "Enumerating\n")
    _band(r2, 1, "PACK")
    _band(r2, 1, "")
    append_pkt_flush(r2)
    c.feed(Span(r2))
    assert_equal(
        _events(c), "|1:2|3|5:1|6:2|8:Enumerating\\x0a|7:PACK|7:|9"
    )
    var d = FetchArgs()
    d.wants.append(_id(A))
    d.done = True
    c.append_fetch_request(out, d)
    var r3 = List[UInt8]()
    append_pkt_text(r3, "packfile\n")
    _band(r3, 1, "PACK")
    append_pkt_flush(r3)
    c.feed(Span(r3))
    assert_equal(_events(c), "|7:PACK|9")


def _response_error(done: Bool, var lines: List[String]) raises -> String:
    var c = _client(GIT_ADV)
    var a = FetchArgs()
    a.wants.append(_id(A))
    a.haves.append(_id(B))
    a.done = done
    var out = List[UInt8]()
    c.append_fetch_request(out, a)
    var r = List[UInt8]()
    for i in range(len(lines)):
        if lines[i] == "0000":
            append_pkt_flush(r)
        elif lines[i] == "0002":
            append_pkt_response_end(r)
        elif lines[i] == "0001":
            append_pkt_delim(r)
        elif lines[i].startswith("band"):
            _band(r, Int(lines[i].as_bytes()[4]) - 48, String(lines[i][byte=5 : lines[i].byte_length()]))
        else:
            append_pkt_text(r, lines[i])
    c.feed(Span(r))
    try:
        while True:
            var ev = c.next_event()
            if ev.kind == FETCH_NEED_MORE or ev.kind == FETCH_END or ev.kind == FETCH_ROUND_END:
                return "no error"
    except e:
        return String(e)


def test_fetch_refusals() raises:
    comptime P = "komira_git: fetch: "
    assert_equal(
        _response_error(False, ["packfile\n"]),
        P + "expected 'acknowledgments', received 'packfile'",
    )
    assert_equal(
        _response_error(False, ["acknowledgments\n", "ready\n", "0000"]),
        P + "expected packfile to be sent after 'ready'",
    )
    assert_equal(
        _response_error(False, ["acknowledgments\n", "NAK\n", "0001"]),
        P + "expected no other sections to be sent after no 'ready'",
    )
    assert_equal(
        _response_error(False, ["acknowledgments\n", "ACK zz\n"]),
        P + "unexpected acknowledgment line: 'ACK zz'",
    )
    assert_equal(
        _response_error(True, ["wanted-refs\n"]),
        P + "expected 'packfile', received 'wanted-refs'",
    )
    assert_equal(
        _response_error(True, ["shallow-info\n", "deepen 1", "0001"]),
        P + "expected shallow/unshallow, got deepen 1",
    )
    assert_equal(
        _response_error(True, ["shallow-info\n", "shallow 12", "0001"]),
        P + "invalid shallow line: shallow 12",
    )
    # A second shallow-info section is refused, as git's fetch-pack does.
    assert_equal(
        _response_error(True, ["shallow-info\n", "0001", "shallow-info\n"]),
        P + "expected 'packfile', received 'shallow-info'",
    )
    assert_equal(
        _response_error(True, ["packfile\n", "band3fatal: out of memory"]),
        P + "remote error: fatal: out of memory",
    )
    assert_equal(
        _response_error(True, ["packfile\n", "band5x"]),
        P + "protocol error: bad band #5",
    )




def _raises_on_advertisement(adv: String) raises -> String:
    var c = FetchV2Client("x", ObjectFormat.sha1())
    var b = List[UInt8](adv.as_bytes())
    c.feed(Span(b))
    try:
        _ = c.read_advertisement()
        return "accepted"
    except e:
        return String(e)


def _raises_on_ls_refs(var resp: List[UInt8]) raises -> String:
    var c = _client(GIT_ADV)
    var out = List[UInt8]()
    c.append_ls_refs_request(out, List[String]())
    c.feed(Span(resp))
    try:
        _ = c.read_ls_refs()
        return "accepted"
    except e:
        return String(e)


def test_more_refusals() raises:
    comptime P = "komira_git: fetch: "
    assert_equal(_raises_on_advertisement("0000"), P + "bad capability advertisement")
    # The server's object format against the client's.
    var md5 = _client("000eversion 2\n0012fetch=shallow\n0016object-format=md5\n0000")
    var out = List[UInt8]()
    try:
        md5.append_fetch_request(out, FetchArgs())
        assert_true(False)
    except e:
        assert_equal(String(e), P + "unknown object format 'md5' specified by server")
    var c256 = FetchV2Client("x", ObjectFormat.sha256())
    var adv = List[UInt8](String("000eversion 2\n0012fetch=shallow\n0000").as_bytes())
    c256.feed(Span(adv))
    assert_true(c256.read_advertisement())
    try:
        c256.append_fetch_request(out, FetchArgs())
        assert_true(False)
    except e:
        assert_equal(String(e), P + "the server does not support algorithm 'sha256'")
    var unread = FetchV2Client("x", ObjectFormat.sha1())
    try:
        unread.append_ls_refs_request(out, List[String]())
        assert_true(False)
    except e:
        assert_equal(String(e), P + "the advertisement has not been read")
    try:
        _ = unread.next_event()
        assert_true(False)
    except e:
        assert_equal(String(e), P + "no fetch response is expected")
    # ls-refs responses.
    var delim = List[UInt8]()
    append_pkt_delim(delim)
    assert_equal(_raises_on_ls_refs(delim^), P + "expected flush after ref listing")
    var one = List[UInt8]()
    append_pkt_text(one, "abc\n")
    assert_equal(_raises_on_ls_refs(one^), P + "invalid ls-refs response: abc")
    var peeled = List[UInt8]()
    append_pkt_text(peeled, A + " refs/tags/x peeled:zz\n")
    assert_equal(
        _raises_on_ls_refs(peeled^), P + "invalid ls-refs response: " + A + " refs/tags/x peeled:zz"
    )
    # Fetch responses.
    assert_equal(_response_error(False, ["0000"]), P + "expected 'acknowledgments'")
    assert_equal(
        _response_error(False, ["acknowledgments\n", "0002"]), P + "bad acknowledgments section"
    )
    assert_equal(_response_error(True, ["0000"]), P + "expected 'packfile'")
    assert_equal(_response_error(True, ["shallow-info\n", "0000"]), P + "expected 'packfile'")
    assert_equal(
        _response_error(True, ["shallow-info\n", "unshallow zz"]),
        P + "invalid unshallow line: unshallow zz",
    )
    assert_equal(
        _response_error(True, ["packfile\n", ""]), P + "protocol error: no band designator"
    )


def main() raises:
    test_advertisement()
    test_ls_refs()
    test_fetch_request()
    test_fetch_events()
    test_fetch_refusals()
    test_more_refusals()
    print("komira_git fetch v2 client tests passed")
