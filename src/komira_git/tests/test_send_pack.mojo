# =============================================================================
# komira_git/tests/test_send_pack.mojo -- the push client: reading the ref
# advertisement, writing the commands, reading the report-status.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: gitprotocol-pack and git's send-pack.c at
# v2.56.0 (the capability string after the NUL starts with a space, command
# lines have no LF, push options follow their own flush; receive_status's
# refusals). The comparison with git itself is in
# src/tests/conformance/komira_git_protocol_conformance.
#
# WHAT EACH TEST CATCHES:
#   * test_advertisement: `capabilities^{}` or `.have` taken for a ref; the
#     capability words lost; a leading `version 1` line or a shallow line
#     misread; an `ERR` line not raised.
#   * test_request: the request's bytes (report-status-v2 preferred, quiet
#     only when asked, atomic and push-options only when asked); refusals
#     when the server lacks atomic, push-options, delete-refs or the
#     client's object format.
#   * test_status: the report read with and without side-band, band-2
#     messages kept, `ng` reasons split from the ref name, a truncated
#     report waiting for more input, and each malformed report by message.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    ObjectFormat,
    ObjectId,
    PushCommand,
    SendPackClient,
    append_pkt_data,
    append_pkt_delim,
    append_pkt_flush,
    append_pkt_text,
    append_sideband,
)

comptime Z = "0000000000000000000000000000000000000000"
comptime A = "1111111111111111111111111111111111111111"
comptime B = "2222222222222222222222222222222222222222"
comptime GIT_CAPS = (
    "report-status report-status-v2 delete-refs side-band-64k quiet atomic"
    " ofs-delta push-options object-format=sha1 agent=git/2.56.0-Linux"
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


def _id(hex: String) raises -> ObjectId:
    return ObjectId.parse_hex(ObjectFormat.sha1(), hex)


def _first(line: String, caps: String) -> List[UInt8]:
    var b = List[UInt8](line.as_bytes())
    b.append(0)
    for i in range(caps.byte_length()):
        b.append(caps.as_bytes()[i])
    b.append(10)
    return b^


def _client(caps: String) raises -> SendPackClient:
    var w = List[UInt8]()
    append_pkt_data(w, Span(_first(A + " refs/heads/main", caps)))
    append_pkt_text(w, B + " refs/heads/topic\n")
    append_pkt_text(w, A + " .have\n")
    append_pkt_flush(w)
    var c = SendPackClient("komira-git/1", ObjectFormat.sha1())
    c.feed(Span(w))
    assert_true(c.read_advertisement())
    return c^


def test_advertisement() raises:
    var c = _client(GIT_CAPS)
    ref adv = c.advertisement
    assert_equal(len(adv.refs), 2)
    assert_equal(adv.refs[1].name, "refs/heads/topic")
    assert_true(adv.refs[1].id == _id(B))
    assert_equal(len(adv.capabilities), 10)
    assert_true(adv.supports("atomic"))
    var agent = adv.value("agent")
    assert_equal(agent.value(), "git/2.56.0-Linux")
    var w = List[UInt8]()
    append_pkt_text(w, "version 1\n")
    append_pkt_data(w, Span(_first(Z + " capabilities^{}", "report-status delete-refs")))
    append_pkt_text(w, "shallow " + B + "\n")
    append_pkt_flush(w)
    var e = SendPackClient("komira-git/1", ObjectFormat.sha1())
    e.feed(Span(w)[0 : len(w) - 2])
    assert_false(e.read_advertisement())
    e.feed(Span(w)[len(w) - 2 : len(w)])
    assert_true(e.read_advertisement())
    assert_equal(len(e.advertisement.refs), 0)
    assert_equal(len(e.advertisement.capabilities), 2)
    assert_equal(len(e.advertisement.shallows), 1)
    var err = List[UInt8]()
    append_pkt_text(err, "ERR access denied\n")
    var x = SendPackClient("komira-git/1", ObjectFormat.sha1())
    x.feed(Span(err))
    try:
        _ = x.read_advertisement()
        assert_true(False)
    except ex:
        assert_equal(String(ex), "komira_git: push: remote error: access denied")


def _commands() raises -> List[PushCommand]:
    var cmds = List[PushCommand]()
    cmds.append(PushCommand(_id(A), _id(B), "refs/heads/main"))
    cmds.append(PushCommand(_id(B), ObjectId.zero(ObjectFormat.sha1()), "refs/heads/topic"))
    return cmds^


def test_request() raises:
    var c = _client(GIT_CAPS)
    var out = List[UInt8]()
    var opts: List[String] = ["ci.skip"]
    c.append_push_request(out, _commands(), atomic=True, push_options=opts)
    assert_equal(
        _show(out),
        "00c5" + A + " " + B + " refs/heads/main\\x00 report-status-v2 side-band-64k quiet"
        + " atomic push-options object-format=sha1 agent=komira-git/1"
        + "0066" + B + " " + Z + " refs/heads/topic0000000bci.skip0000",
    )
    var old = _client("report-status delete-refs")
    out.clear()
    old.append_push_request(out, _commands(), quiet=False)
    assert_equal(
        _show(out),
        "0074" + A + " " + B + " refs/heads/main\\x00 report-status"
        + "0066" + B + " " + Z + " refs/heads/topic0000",
    )
    var bare = _client("report-status")
    try:
        bare.append_push_request(out, _commands(), atomic=True)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push: the receiving end does not support --atomic push")
    try:
        bare.append_push_request(out, _commands(), push_options=opts)
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push: the receiving end does not support push options")
    try:
        bare.append_push_request(out, _commands())
        assert_true(False)
    except e:
        assert_equal(
            String(e), "komira_git: push: remote does not support deleting refs: refs/heads/topic"
        )
    var other = _client("report-status object-format=sha256")
    try:
        other.append_push_request(out, _commands())
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            "komira_git: push: the receiving end does not support this repository's hash algorithm",
        )


def _report() raises -> List[UInt8]:
    var body = List[UInt8]()
    append_pkt_text(body, "unpack ok\n")
    append_pkt_text(body, "ok refs/heads/main\n")
    append_pkt_text(body, "ng refs/heads/topic non-fast-forward\n")
    append_pkt_flush(body)
    return body^


def test_status() raises:
    var c = _client(GIT_CAPS)
    var out = List[UInt8]()
    c.append_push_request(out, _commands())
    var w = List[UInt8]()
    var msg = List[UInt8](String("error: denying non-fast-forward\n").as_bytes())
    append_sideband(w, 2, Span(msg))
    var body = _report()
    append_sideband(w, 1, Span(body))
    append_pkt_flush(w)
    c.feed(Span(w)[0 : len(w) - 1])
    assert_false(c.read_status().complete)
    c.feed(Span(w)[len(w) - 1 : len(w)])
    var st = c.read_status()
    assert_true(st.complete)
    assert_equal(st.unpack_status, "ok")
    assert_equal(len(st.ref_names), 2)
    assert_equal(st.ref_names[1], "refs/heads/topic")
    assert_equal(st.reasons[0], "")
    assert_equal(st.reasons[1], "non-fast-forward")
    assert_equal(len(st.messages), 1)
    assert_equal(st.messages[0], "error: denying non-fast-forward")
    # Without side-band the report is read as is.
    var p = _client("report-status delete-refs")
    p.append_push_request(out, _commands())
    var plain = _report()
    p.feed(Span(plain))
    var ps = p.read_status()
    assert_true(ps.complete)
    assert_equal(ps.reasons[1], "non-fast-forward")
    var bad = _client("report-status delete-refs")
    bad.append_push_request(out, _commands())
    var b2 = List[UInt8]()
    append_pkt_text(b2, "unpack index-pack failed\n")
    append_pkt_text(b2, "what refs/heads/main\n")
    append_pkt_flush(b2)
    bad.feed(Span(b2))
    try:
        _ = bad.read_status()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push: invalid status line from remote: what refs/heads/main")
    var b3 = List[UInt8]()
    append_pkt_text(b3, "status ok\n")
    append_pkt_flush(b3)
    var bad3 = _client("report-status delete-refs")
    bad3.append_push_request(out, _commands())
    bad3.feed(Span(b3))
    try:
        _ = bad3.read_status()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push: unable to parse remote unpack status: status ok")


def _digits(n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += "3"
    return s^


def _adv_error(var w: List[UInt8]) raises -> String:
    var c = SendPackClient("komira-git/1", ObjectFormat.sha1())
    c.feed(Span(w))
    try:
        _ = c.read_advertisement()
        return "accepted"
    except e:
        return String(e)


def _status_error(side_band: Bool, var body: List[UInt8], var extra: List[UInt8]) raises -> String:
    """Feed `body` (inside band 1 when `side_band`, then `extra` and the
    closing flush) as the report and read it."""
    var c = _client(GIT_CAPS if side_band else "report-status delete-refs")
    var out = List[UInt8]()
    c.append_push_request(out, _commands())
    var w = List[UInt8]()
    if side_band:
        append_sideband(w, 1, Span(body))
        for i in range(len(extra)):
            w.append(extra[i])
        append_pkt_flush(w)
    else:
        w = body^
    c.feed(Span(w))
    try:
        var st = c.read_status()
        if not st.complete:
            return "incomplete"
        return "ok " + st.reasons[1]
    except e:
        return String(e)


def test_more_refusals() raises:
    comptime P = "komira_git: push: "
    var d = List[UInt8]()
    append_pkt_delim(d)
    assert_equal(_adv_error(d^), P + "bad ref advertisement")
    var sh = List[UInt8]()
    append_pkt_text(sh, "shallow zz\n")
    assert_equal(_adv_error(sh^), P + "protocol error: bad shallow line: shallow zz")
    var short = List[UInt8]()
    append_pkt_text(short, "abc\n")
    assert_equal(_adv_error(short^), P + "protocol error: bad ref line: abc")
    var badhex = List[UInt8]()
    append_pkt_text(badhex, "z" + String(A[byte=1:40]) + " refs/heads/x\n")
    assert_equal(
        _adv_error(badhex^),
        P + "protocol error: bad ref line: z" + String(A[byte=1:40]) + " refs/heads/x",
    )
    var unread = SendPackClient("komira-git/1", ObjectFormat.sha1())
    var out = List[UInt8]()
    try:
        unread.append_push_request(out, _commands())
        assert_true(False)
    except e:
        assert_equal(String(e), P + "the advertisement has not been read")
    var w = List[UInt8]()
    append_pkt_data(w, Span(_first(A + " refs/heads/main", "report-status delete-refs")))
    append_pkt_flush(w)
    var c256 = SendPackClient("komira-git/1", ObjectFormat.sha256())
    c256.feed(Span(w))
    try:
        _ = c256.read_advertisement()
        assert_true(False)
    except e:
        # A sha1 id is not a sha256 one: the ref line is refused first.
        assert_equal(String(e), P + "protocol error: bad ref line: " + A + " refs/heads/main")
    var w2 = List[UInt8]()
    append_pkt_data(w2, Span(_first(_digits(64) + " refs/heads/main", "report-status delete-refs")))
    append_pkt_flush(w2)
    var c2 = SendPackClient("komira-git/1", ObjectFormat.sha256())
    c2.feed(Span(w2))
    assert_true(c2.read_advertisement())
    try:
        c2.append_push_request(out, List[PushCommand]())
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            P + "the receiving end does not support this repository's hash algorithm",
        )
    # Reports.
    var ok = _report()
    assert_equal(_status_error(True, ok^, List[UInt8]()), "ok non-fast-forward")
    var plain = _report()
    var half = List[UInt8]()
    for i in range(len(plain) - 2):
        half.append(plain[i])
    assert_equal(_status_error(False, half^, List[UInt8]()), "incomplete")
    var empty_band = List[UInt8]()
    append_pkt_text(empty_band, "")
    var c3 = _client(GIT_CAPS)
    c3.append_push_request(out, _commands())
    c3.feed(Span(empty_band))
    try:
        _ = c3.read_status()
        assert_true(False)
    except e:
        assert_equal(String(e), P + "protocol error: no band designator")
    for band in range(3, 5):
        var bw = List[UInt8]()
        var msg = List[UInt8](String("disk full").as_bytes())
        if band == 3:
            append_sideband(bw, 3, Span(msg))
        else:
            append_pkt_text(bw, "\x07x")
        var cb = _client(GIT_CAPS)
        cb.append_push_request(out, _commands())
        cb.feed(Span(bw))
        try:
            _ = cb.read_status()
            assert_true(False)
        except e:
            if band == 3:
                assert_equal(String(e), P + "remote error: disk full")
            else:
                assert_equal(String(e), P + "protocol error: bad band #7")
    var truncated = List[UInt8]()
    append_pkt_text(truncated, "unpack ok\n")
    assert_equal(_status_error(True, truncated^, List[UInt8]()), P + "the report-status ends early")
    var flush_first = List[UInt8]()
    append_pkt_flush(flush_first)
    assert_equal(
        _status_error(True, flush_first^, List[UInt8]()),
        P + "unexpected flush packet while reading remote unpack status",
    )
    var delim_body = List[UInt8]()
    append_pkt_text(delim_body, "unpack ok\n")
    append_pkt_delim(delim_body)
    assert_equal(_status_error(True, delim_body^, List[UInt8]()), P + "bad report-status")
    var no_reason = List[UInt8]()
    append_pkt_text(no_reason, "unpack ok\n")
    append_pkt_text(no_reason, "option refname refs/heads/x\n")
    append_pkt_text(no_reason, "ok refs/heads/main\n")
    append_pkt_text(no_reason, "ng refs/heads/topic\n")
    append_pkt_flush(no_reason)
    assert_equal(_status_error(True, no_reason^, List[UInt8]()), "ok failed")
    var after = _report()
    append_pkt_text(after, "x")
    assert_equal(_status_error(True, after^, List[UInt8]()), P + "bytes after the report-status")


def main() raises:
    test_advertisement()
    test_request()
    test_status()
    test_more_refusals()
    print("komira_git send-pack tests passed")
