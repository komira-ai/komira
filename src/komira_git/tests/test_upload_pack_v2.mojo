# =============================================================================
# komira_git/tests/test_upload_pack_v2.mojo -- the protocol v2 server: the
# advertisement, request reading and the ls-refs response.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: gitprotocol-v2 ("Capability Advertisement",
# "Command Request", "ls-refs") and git's serve.c, ls-refs.c and
# upload-pack.c at v2.56.0 for the refusals, whose words the messages keep.
# The byte-for-byte comparison with git itself is in
# src/tests/conformance/komira_git_protocol_conformance.
#
# WHAT EACH TEST CATCHES:
#   * test_advertisement: a capability advertised that is not implemented
#     (`filter`, `ref-in-want`), a missing LF or flush, a wrong length.
#   * test_agent: an agent with a space or a control byte let through.
#   * test_ls_refs_request / test_fetch_request: an argument dropped or
#     read into the wrong field; a request split at any byte not reread.
#   * test_end: a lone flush not taken as the end of the session.
#   * test_refusals: each refusal by its exact message, and that a request
#     with an unadvertised feature (filter, want-ref, sideband-all,
#     packfile-uris, session-id) is refused rather than ignored.
#   * test_deepen: `deepen 0`, a sign, a leading zero, a byte just outside
#     '0'-'9' ('/', ':') or a letter after the first digit, or 2^31 accepted.
#   * test_deepen_since_and_not: `deepen-since` and `deepen-not` dropped
#     or misread (a ref not passed on as sent, its LF kept); an empty, signed,
#     zero-led or over-2^63-1 timestamp, a byte just outside '0'-'9' ('/',
#     ':') or a letter after the first digit, or an empty ref accepted;
#     `deepen-since 0` not asking for shallow-info; `deepen` with either
#     accepted.
#   * test_too_many_prefixes: 65536 prefixes kept as a filter (git drops
#     the filter at that count).
#   * test_ls_refs_response: refs not sorted by name, HEAD not first, a
#     prefix filter not applied, symref-target or peeled sent unasked, an
#     unborn HEAD listed without `unborn` and `symrefs`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    V2_END,
    V2_FETCH,
    V2_LS_REFS,
    V2_NEED_MORE,
    AdvertisedRef,
    LsRefsArgs,
    ObjectFormat,
    ObjectId,
    UploadPackV2Server,
    append_ls_refs_response,
    append_pkt_delim,
    append_pkt_flush,
    append_pkt_response_end,
    append_pkt_text,
)

comptime A = "1111111111111111111111111111111111111111"
comptime B = "2222222222222222222222222222222222222222"
comptime C = "3333333333333333333333333333333333333333"


def _show(b: List[UInt8]) -> String:
    """Printable ASCII as is, every other byte as \\xNN."""
    var s = String()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 32 and c < 127:
            s += chr(c)
        else:
            var h = String("0123456789abcdef")
            s += "\\x" + chr(Int(h.as_bytes()[c >> 4])) + chr(Int(h.as_bytes()[c & 15]))
    return s^


def _wire(lines: List[String]) raises -> List[UInt8]:
    """`0000`, `0001` and `0002` as the special packets, anything else as
    one data line holding exactly those bytes."""
    var out = List[UInt8]()
    for i in range(len(lines)):
        if lines[i] == "0000":
            append_pkt_flush(out)
        elif lines[i] == "0001":
            append_pkt_delim(out)
        elif lines[i] == "0002":
            append_pkt_response_end(out)
        else:
            append_pkt_text(out, lines[i])
    return out^


def _server() raises -> UploadPackV2Server:
    return UploadPackV2Server("komira-git/1", ObjectFormat.sha1())


def _id(hex: String) raises -> ObjectId:
    return ObjectId.parse_hex(ObjectFormat.sha1(), hex)


def _refusal(var lines: List[String]) raises -> String:
    var s = _server()
    var w = _wire(lines)
    s.feed(Span(w))
    try:
        var r = s.next_request()
        return "accepted, command " + String(r.command)
    except e:
        return String(e)


def test_advertisement() raises:
    var out = List[UInt8]()
    _server().append_advertisement(out)
    assert_equal(
        _show(out),
        "000eversion 2\\x0a0017agent=komira-git/1\\x0a0013ls-refs=unborn\\x0a"
        + "0020fetch=shallow wait-for-done\\x0a0012server-option\\x0a"
        + "0017object-format=sha1\\x0a0000",
    )


def test_agent() raises:
    try:
        _ = UploadPackV2Server("komira git", ObjectFormat.sha1())
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            "komira_git: the agent string holds byte 32, not printable ASCII without spaces",
        )
    try:
        _ = UploadPackV2Server("", ObjectFormat.sha1())
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: the agent string is empty")


def test_ls_refs_request() raises:
    var w = _wire(
        [
            "command=ls-refs\n",
            "agent=git/2.56.0-Linux",
            "object-format=sha1",
            "server-option=one",
            "0001",
            "peel\n",
            "symrefs\n",
            "unborn\n",
            "ref-prefix refs/heads/\n",
            "ref-prefix HEAD\n",
            "0000",
        ]
    )
    # Fed one byte at a time: no request until the last byte.
    var s = _server()
    for i in range(len(w) - 1):
        s.feed(Span(w)[i : i + 1])
        assert_equal(s.next_request().command, V2_NEED_MORE)
    s.feed(Span(w)[len(w) - 1 : len(w)])
    var r = s.next_request()
    assert_equal(r.command, V2_LS_REFS)
    assert_equal(r.agent, "git/2.56.0-Linux")
    assert_equal(r.object_format, "sha1")
    assert_equal(len(r.server_options), 1)
    assert_equal(r.server_options[0], "one")
    assert_true(r.ls_refs.peel and r.ls_refs.symrefs and r.ls_refs.unborn)
    assert_equal(len(r.ls_refs.ref_prefixes), 2)
    assert_equal(r.ls_refs.ref_prefixes[0], "refs/heads/")
    assert_equal(r.ls_refs.ref_prefixes[1], "HEAD")
    assert_equal(s.next_request().command, V2_NEED_MORE)


def test_fetch_request() raises:
    var w = _wire(
        [
            "command=fetch",
            "agent=git/2.56.0-Linux",
            "0001",
            "thin-pack",
            "no-progress",
            "include-tag",
            "ofs-delta",
            "shallow " + C,
            "deepen 3",
            "deepen-relative\n",
            "want " + A + "\n",
            "want " + A + "\n",
            "have " + B + "\n",
            "done\n",
            "0000",
        ]
    )
    var s = _server()
    s.feed(Span(w))
    var r = s.next_request()
    assert_equal(r.command, V2_FETCH)
    assert_equal(r.object_format, "")
    ref f = r.fetch
    assert_true(f.thin_pack and f.no_progress and f.include_tag and f.ofs_delta)
    assert_true(f.deepen_relative and f.done)
    assert_false(f.wait_for_done)
    assert_equal(f.deepen, 3)
    assert_equal(len(f.wants), 2)
    assert_true(f.wants[1] == _id(A))
    assert_equal(len(f.haves), 1)
    assert_true(f.haves[0] == _id(B))
    assert_equal(len(f.shallows), 1)
    assert_true(f.shallows[0] == _id(C))
    # A command with no arguments ends at its flush.
    var w2 = _wire(["command=fetch", "0000", "command=ls-refs\n", "0000"])
    var s2 = _server()
    s2.feed(Span(w2))
    var first = s2.next_request()
    assert_equal(first.command, V2_FETCH)
    assert_equal(len(first.fetch.wants), 0)
    assert_equal(s2.next_request().command, V2_LS_REFS)


def test_end() raises:
    var w = _wire(["0000"])
    var s = _server()
    s.feed(Span(w))
    assert_equal(s.next_request().command, V2_END)


def test_refusals() raises:
    comptime P = "komira_git: upload-pack: "
    assert_equal(
        _refusal(["command=ls-refs", "session-id=x", "0000"]),
        P + "unknown capability 'session-id=x'",
    )
    assert_equal(
        _refusal(["command=ls-refs", "fetch=shallow", "0000"]),
        P + "unknown capability 'fetch=shallow'",
    )
    assert_equal(_refusal(["command=object-info", "0000"]), P + "invalid command 'object-info'")
    assert_equal(_refusal(["command=bundle-uri", "0000"]), P + "invalid command 'bundle-uri'")
    assert_equal(
        _refusal(["command=fetch", "command=ls-refs", "0000"]),
        P + "command 'ls-refs' requested after already requesting command 'fetch'",
    )
    assert_equal(_refusal(["agent=x", "0000"]), P + "no command requested")
    assert_equal(
        _refusal(["command=fetch", "object-format=sha256", "0000"]),
        P + "mismatched object format: server sha1; client sha256",
    )
    assert_equal(
        _refusal(["command=fetch", "object-format", "0000"]),
        P + "object-format capability requires an argument",
    )
    assert_equal(
        _refusal(["command=fetch", "object-format=md5", "0000"]),
        P + "unknown object format 'md5'",
    )
    assert_equal(
        _refusal(["command=ls-refs", "0001", "peel", "exclude x", "0000"]),
        P + "unexpected line: 'exclude x'",
    )
    assert_equal(
        _refusal(["command=ls-refs", "0001", "peel", "0001"]),
        P + "expected flush after ls-refs arguments",
    )
    assert_equal(
        _refusal(["command=fetch", "0001", "done", "0002"]),
        P + "expected flush after fetch arguments",
    )
    assert_equal(_refusal(["command=fetch", "0002"]), P + "unexpected response end packet")
    var unadvertised: List[String] = [
        "filter blob:none",
        "want-ref refs/heads/main",
        "sideband-all",
        "packfile-uris https",
    ]
    for i in range(len(unadvertised)):
        var arg = unadvertised[i]
        var lines: List[String] = ["command=fetch", "0001", arg, "0000"]
        assert_equal(_refusal(lines^), P + "unexpected line: '" + arg + "'")
    assert_equal(
        _refusal(["command=fetch", "0001", "want 12345", "0000"]),
        P + "protocol error, expected to get oid, not 'want 12345'",
    )
    assert_equal(
        _refusal(["command=fetch", "0001", "have " + A + "x", "0000"]),
        P + "expected SHA1 object, got '" + A + "x'",
    )
    assert_equal(
        _refusal(["command=fetch", "0001", "shallow zz", "0000"]),
        P + "invalid shallow line: shallow zz",
    )


def test_deepen() raises:
    comptime P = "komira_git: upload-pack: Invalid deepen: "
    var bad: List[String] = [
        "deepen 0", "deepen -1", "deepen +1", "deepen 010", "deepen 0x10",
        "deepen 2147483648", "deepen ", "deepen 1 ", "deepen 1/",
        "deepen 1:", "deepen 1a",
    ]
    for i in range(len(bad)):
        var arg = bad[i]
        var lines: List[String] = ["command=fetch", "0001", arg, "0000"]
        assert_equal(_refusal(lines^), P + arg)
    var w = _wire(["command=fetch", "0001", "deepen 2147483647", "0000"])
    var s = _server()
    s.feed(Span(w))
    assert_equal(s.next_request().fetch.deepen, 2147483647)


def test_deepen_since_and_not() raises:
    comptime P = "komira_git: upload-pack: "
    var w = _wire(
        [
            "command=fetch",
            "0001",
            "shallow " + C,
            "deepen-since 1790000150",
            "deepen-not v1",
            "deepen-not refs/heads/topic\n",
            "want " + A + "\n",
            "done\n",
            "0000",
        ]
    )
    var s = _server()
    s.feed(Span(w))
    var r = s.next_request()
    ref f = r.fetch
    assert_true(Bool(f.deepen_since))
    assert_equal(f.deepen_since.value(), 1790000150)
    assert_equal(f.deepen, 0)
    assert_equal(len(f.deepen_not), 2)
    assert_equal(f.deepen_not[0], "v1")
    assert_equal(f.deepen_not[1], "refs/heads/topic")
    assert_true(f.asks_shallow() and f.done)
    var edges: List[String] = ["0", "9223372036854775807"]
    var want: List[Int] = [0, 9223372036854775807]
    for i in range(len(edges)):
        var lines: List[String] = ["command=fetch", "0001", "deepen-since " + edges[i], "0000"]
        var s2 = _server()
        var w2 = _wire(lines^)
        s2.feed(Span(w2))
        var r2 = s2.next_request()
        var since = r2.fetch.deepen_since
        assert_true(Bool(since))
        assert_equal(since.value(), want[i])
        # git sets deepen_rev_list for any accepted deepen-since, 0 included.
        assert_true(r2.fetch.asks_shallow())
    var bad: List[String] = [
        "deepen-since ", "deepen-since -1", "deepen-since +1", "deepen-since 01",
        "deepen-since 0x10", "deepen-since 9223372036854775808",
        "deepen-since 10000000000000000000", "deepen-since 1 ",
        "deepen-since 1/", "deepen-since 1:", "deepen-since 1a",
    ]
    for i in range(len(bad)):
        var arg = bad[i]
        var lines: List[String] = ["command=fetch", "0001", arg, "0000"]
        assert_equal(_refusal(lines^), P + "Invalid deepen-since: " + arg)
    assert_equal(
        _refusal(["command=fetch", "0001", "deepen-not ", "0000"]),
        P + "deepen-not is not a ref: deepen-not ",
    )
    comptime BOTH = "deepen and deepen-since (or deepen-not) cannot be used together"
    assert_equal(
        _refusal(["command=fetch", "0001", "deepen 1", "deepen-since 5", "0000"]),
        P + BOTH,
    )
    assert_equal(
        _refusal(["command=fetch", "0001", "deepen-not v1", "deepen 2", "0000"]),
        P + BOTH,
    )


def test_too_many_prefixes() raises:
    var lines = List[String]()
    lines.append("command=ls-refs")
    lines.append("0001")
    for _ in range(65535):
        lines.append("ref-prefix refs/x/")
    lines.append("0000")
    var s = _server()
    var w = _wire(lines)
    s.feed(Span(w))
    assert_equal(len(s.next_request().ls_refs.ref_prefixes), 65535)
    lines.insert(2, "ref-prefix refs/y/")
    var s2 = _server()
    var w2 = _wire(lines)
    s2.feed(Span(w2))
    assert_equal(len(s2.next_request().ls_refs.ref_prefixes), 0)


def _refs() raises -> List[AdvertisedRef]:
    var refs = List[AdvertisedRef]()
    refs.append(AdvertisedRef("refs/tags/v1", _id(C), peeled=_id(A)))
    refs.append(AdvertisedRef("refs/heads/topic", _id(B)))
    refs.append(AdvertisedRef("refs/heads/main", _id(A)))
    refs.append(AdvertisedRef("refs/remotes/origin/HEAD", _id(A), "refs/remotes/origin/main"))
    return refs^


def _ls(args: LsRefsArgs, head: Optional[AdvertisedRef]) raises -> String:
    var out = List[UInt8]()
    append_ls_refs_response(out, args, head, _refs())
    return _show(out)


def test_ls_refs_response() raises:
    var head = AdvertisedRef("HEAD", _id(A), "refs/heads/main")
    var all = LsRefsArgs()
    all.peel = True
    all.symrefs = True
    assert_equal(
        _ls(all, head.copy()),
        "0050" + A + " HEAD symref-target:refs/heads/main\\x0a"
        + "003d" + A + " refs/heads/main\\x0a"
        + "003e" + B + " refs/heads/topic\\x0a"
        + "006d" + A + " refs/remotes/origin/HEAD symref-target:refs/remotes/origin/main\\x0a"
        + "006a" + C + " refs/tags/v1 peeled:" + A + "\\x0a"
        + "0000",
    )
    var plain = LsRefsArgs()
    plain.ref_prefixes.append("refs/tags/")
    plain.ref_prefixes.append("refs/heads/m")
    assert_equal(
        _ls(plain, head.copy()),
        "003d" + A + " refs/heads/main\\x0a" + "003a" + C + " refs/tags/v1\\x0a" + "0000",
    )
    # An unborn HEAD: listed only for `unborn` with `symrefs`.
    var unborn_head = AdvertisedRef("HEAD", ObjectId.zero(ObjectFormat.sha1()), "refs/heads/main")
    var out = List[UInt8]()
    var asked = LsRefsArgs()
    asked.unborn = True
    asked.symrefs = True
    append_ls_refs_response(out, asked, unborn_head.copy(), List[AdvertisedRef]())
    assert_equal(_show(out), "002eunborn HEAD symref-target:refs/heads/main\\x0a0000")
    out.clear()
    var no_symrefs = LsRefsArgs()
    no_symrefs.unborn = True
    append_ls_refs_response(out, no_symrefs, unborn_head.copy(), List[AdvertisedRef]())
    assert_equal(_show(out), "0000")
    out.clear()
    append_ls_refs_response(out, asked, None, List[AdvertisedRef]())
    assert_equal(_show(out), "0000")
    var bad = List[AdvertisedRef]()
    bad.append(AdvertisedRef("HEAD", _id(A)))
    try:
        append_ls_refs_response(out, asked, None, bad)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: ls-refs: ref 'HEAD' is not under refs/")


def test_more() raises:
    # A fetch request fed one byte at a time, with wait-for-done.
    var w = _wire(["command=fetch", "0001", "wait-for-done", "have " + A + "\n", "0000"])
    var s = _server()
    for i in range(len(w) - 1):
        s.feed(Span(w)[i : i + 1])
        assert_equal(s.next_request().command, V2_NEED_MORE)
    s.feed(Span(w)[len(w) - 1 : len(w)])
    var r = s.next_request()
    assert_equal(r.command, V2_FETCH)
    assert_true(r.fetch.wait_for_done)
    # A line that is not UTF-8.
    var bad = List[UInt8]()
    bad.append(0x30)
    bad.append(0x30)
    bad.append(0x30)
    bad.append(0x35)
    bad.append(0xFF)
    var s2 = _server()
    s2.feed(Span(bad))
    try:
        _ = s2.next_request()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: upload-pack: line is not UTF-8")
    # Names sort byte by byte, a prefix first.
    var refs = List[AdvertisedRef]()
    refs.append(AdvertisedRef("refs/heads/ab", _id(B)))
    refs.append(AdvertisedRef("refs/heads/a", _id(A)))
    var out = List[UInt8]()
    append_ls_refs_response(out, LsRefsArgs(), None, refs)
    assert_equal(
        _show(out), "003a" + A + " refs/heads/a\\x0a003b" + B + " refs/heads/ab\\x0a0000"
    )
    try:
        append_ls_refs_response(out, LsRefsArgs(), AdvertisedRef("refs/heads/a", _id(A)), refs)
        assert_true(False)
    except e:
        assert_equal(
            String(e), "komira_git: ls-refs: the head ref is named 'refs/heads/a', not 'HEAD'"
        )
    refs.append(AdvertisedRef("refs/heads/c", ObjectId.zero(ObjectFormat.sha1())))
    try:
        append_ls_refs_response(out, LsRefsArgs(), None, refs)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: ls-refs: ref 'refs/heads/c' names no object")


def main() raises:
    test_advertisement()
    test_agent()
    test_ls_refs_request()
    test_fetch_request()
    test_end()
    test_refusals()
    test_deepen()
    test_deepen_since_and_not()
    test_too_many_prefixes()
    test_ls_refs_response()
    test_more()
    print("komira_git upload-pack v2 tests passed")
