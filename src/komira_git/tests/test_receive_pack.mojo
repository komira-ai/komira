# =============================================================================
# komira_git/tests/test_receive_pack.mojo -- the push server: advertisement,
# reading commands and push options, and the report-status.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: gitprotocol-pack ("Reference Discovery",
# "Pushing Data To a Server", "Report Status") and builtin/receive-pack.c at
# v2.56.0 (show_ref's capability list, read_head_info, report(), and the
# reasons `unpacker error`, `atomic push failure`, `funny refname`). The
# comparison with git itself is in
# src/tests/conformance/komira_git_protocol_conformance.
#
# WHAT EACH TEST CATCHES:
#   * test_advertisement: refs not sorted, the capabilities on a line other
#     than the first, `capabilities^{}` missing for an empty repository, a
#     switch (atomic, push-options) not honored.
#   * test_read_request: a command or capability misread; push options not
#     read after the flush; the pack's first bytes swallowed; a request
#     split at any byte not reread; `atomic`/`push-options` taken although
#     not advertised.
#   * test_request_refusals: each malformed request by its exact message.
#   * test_report: ok/ng lines; an atomic push not failing every other
#     command; an unpack error not failing all, in an atomic push with a
#     refusal too; band-1 framing and the closing flush for side-band;
#     nothing written without report-status or without commands.
#   * test_funny_refnames: a ref outside refs/ or failing check-ref-format
#     accepted; a one-level delete refused; in an atomic push with two
#     funny refs, the second keeping its own reason (git reports `atomic
#     push failure` for every command after the first failed update()).
#   * test_lf_terminated_request: git chomps one LF from each command,
#     shallow and push-option line; libgit2 ends each command line with
#     one; the test puts an LF on every kind. Catches the LF not chomped
#     (side-band-64k missed, ref names carrying the LF) and more than one
#     LF chomped (a ref `refs/heads/x` plus two LFs read as `refs/heads/x`
#     rather than a funny refname; a push option losing both).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    AdvertisedRef,
    ObjectFormat,
    ObjectId,
    PushReport,
    PushRequest,
    ReceivePackConfig,
    ReceivePackServer,
    append_pkt_data,
    append_pkt_delim,
    append_pkt_flush,
    append_pkt_text,
    append_push_message,
    append_push_report,
    append_receive_pack_advertisement,
)

comptime Z = "0000000000000000000000000000000000000000"
comptime A = "1111111111111111111111111111111111111111"
comptime B = "2222222222222222222222222222222222222222"


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


def _config(atomic: Bool, push_options: Bool) raises -> ReceivePackConfig:
    return ReceivePackConfig("komira-git/1", ObjectFormat.sha1(), atomic, push_options)


def test_advertisement() raises:
    var out = List[UInt8]()
    append_receive_pack_advertisement(out, _config(True, False), List[AdvertisedRef]())
    assert_equal(
        _show(out),
        "00b3" + Z + " capabilities^{}\\x00report-status report-status-v2 delete-refs"
        + " side-band-64k quiet atomic ofs-delta object-format=sha1 agent=komira-git/1\\x0a0000",
    )
    var refs = List[AdvertisedRef]()
    refs.append(AdvertisedRef("refs/heads/main", _id(A)))
    refs.append(AdvertisedRef("refs/heads/feature", _id(B)))
    out.clear()
    append_receive_pack_advertisement(out, _config(False, True), refs)
    assert_equal(
        _show(out),
        "00bc" + B + " refs/heads/feature\\x00report-status report-status-v2 delete-refs"
        + " side-band-64k quiet ofs-delta push-options object-format=sha1 agent=komira-git/1\\x0a"
        + "003d" + A + " refs/heads/main\\x0a0000",
    )


def _request_bytes(caps: String, with_options: Bool) raises -> List[UInt8]:
    var w = List[UInt8]()
    var first = List[UInt8](String(A + " " + B + " refs/heads/main").as_bytes())
    first.append(0)
    for i in range(caps.byte_length()):
        first.append(caps.as_bytes()[i])
    append_pkt_data(w, Span(first))
    append_pkt_text(w, Z + " " + A + " refs/heads/new")
    append_pkt_text(w, B + " " + Z + " refs/heads/old")
    append_pkt_flush(w)
    if with_options:
        append_pkt_text(w, "ci.skip")
        append_pkt_text(w, "note=two")
        append_pkt_flush(w)
    var pack = String("PACK\x00\x00\x00\x02")
    for i in range(pack.byte_length()):
        w.append(pack.as_bytes()[i])
    return w^


def test_read_request() raises:
    var caps = String(
        " report-status-v2 side-band-64k quiet atomic push-options object-format=sha1 agent=git/2.56.0-Linux"
    )
    var w = _request_bytes(caps, True)
    var s = ReceivePackServer(_config(True, True))
    var pack_at = len(w) - 8
    for i in range(pack_at - 1):
        s.feed(Span(w)[i : i + 1])
        assert_false(s.read_request().complete)
    s.feed(Span(w)[pack_at - 1 : len(w)])
    var r = s.read_request()
    assert_true(r.complete)
    assert_equal(len(r.commands), 3)
    assert_equal(r.commands[0].ref_name, "refs/heads/main")
    assert_true(r.commands[1].is_create())
    assert_true(r.commands[2].is_delete())
    assert_true(r.report_status_v2 and r.side_band and r.quiet and r.atomic)
    assert_false(r.report_status)
    assert_true(r.use_push_options)
    assert_equal(len(r.push_options), 2)
    assert_equal(r.push_options[1], "note=two")
    assert_equal(r.agent, "git/2.56.0-Linux")
    assert_true(r.needs_pack())
    var rest = s.take_buffered()
    assert_equal(_show(rest), "PACK\\x00\\x00\\x00\\x02")
    # atomic and push-options not advertised: not taken; no options read.
    var w2 = _request_bytes(caps, False)
    var s2 = ReceivePackServer(_config(False, False))
    s2.feed(Span(w2))
    var r2 = s2.read_request()
    assert_false(r2.atomic or r2.use_push_options)
    assert_equal(len(r2.push_options), 0)
    assert_equal(len(s2.take_buffered()), 8)
    # A flush alone: nothing to push.
    var w3 = List[UInt8]()
    append_pkt_flush(w3)
    var s3 = ReceivePackServer(_config(True, False))
    s3.feed(Span(w3))
    var r3 = s3.read_request()
    assert_true(r3.complete)
    assert_equal(len(r3.commands), 0)


def _refusal(var first: List[UInt8]) raises -> String:
    var w = List[UInt8]()
    append_pkt_data(w, Span(first))
    append_pkt_flush(w)
    var s = ReceivePackServer(_config(True, False))
    s.feed(Span(w))
    try:
        _ = s.read_request()
        return "accepted"
    except e:
        return String(e)


def _with_caps(line: String, caps: String) -> List[UInt8]:
    var b = List[UInt8](line.as_bytes())
    b.append(0)
    for i in range(caps.byte_length()):
        b.append(caps.as_bytes()[i])
    return b^


def test_request_refusals() raises:
    comptime P = "komira_git: receive-pack: "
    assert_equal(
        _refusal(List[UInt8](String(A + " " + B).as_bytes())),
        P + "protocol error: expected old/new/ref, got '" + A + " " + B + "'",
    )
    assert_equal(
        _refusal(List[UInt8](String(A + "x" + B + " refs/heads/a").as_bytes())),
        P + "protocol error: expected old/new/ref, got '" + A + "x" + B + " refs/heads/a'",
    )
    assert_equal(
        _refusal(_with_caps(A + " " + B + " refs/heads/a", " report-status object-format=sha256")),
        P + "unsupported object format 'sha256'",
    )
    assert_equal(
        _refusal(_with_caps("push-cert", " report-status")),
        P + "push certificates are not supported",
    )
    assert_equal(
        _refusal(List[UInt8](String("shallow 12").as_bytes())),
        P + "protocol error: expected shallow sha, got '12'",
    )


def _request(atomic: Bool, side_band: Bool, report_status: Bool) raises -> PushRequest:
    var caps = String(" agent=x")
    if report_status:
        caps += " report-status"
    if side_band:
        caps += " side-band-64k"
    if atomic:
        caps += " atomic"
    var w = _request_bytes(caps, False)
    var s = ReceivePackServer(_config(True, False))
    s.feed(Span(w))
    return s.read_request()


def test_report() raises:
    var plain = _request(False, False, True)
    var rep = PushReport(plain)
    rep.reject(1, "non-fast-forward")
    rep.reject(1, "second reason ignored")
    var out = List[UInt8]()
    append_push_report(out, plain, rep)
    assert_equal(
        _show(out),
        "000eunpack ok\\x0a0017ok refs/heads/main\\x0a0027ng refs/heads/new non-fast-forward\\x0a"
        + "0016ok refs/heads/old\\x0a0000",
    )
    var atomic = _request(True, True, True)
    var arep = PushReport(atomic)
    arep.reject(2, "hook declined")
    out.clear()
    append_push_message(out, atomic, "error: hook declined to update refs/heads/old")
    append_push_report(out, atomic, arep)
    assert_equal(
        _show(out),
        "0033\\x02error: hook declined to update refs/heads/old\\x0a"
        + "0090\\x01000eunpack ok\\x0a002bng refs/heads/main atomic push failure\\x0a"
        + "002ang refs/heads/new atomic push failure\\x0a0024ng refs/heads/old hook declined\\x0a"
        + "00000000",
    )
    var accepted = arep.accepted(atomic)
    # The refused command first: every later one fails too, the last included.
    var first = PushReport(atomic)
    first.reject(0, "non-fast-forward")
    var later = first.final_reasons(atomic)
    assert_equal(later[1], "atomic push failure")
    assert_equal(later[2], "atomic push failure")
    assert_false(accepted[0] or accepted[1] or accepted[2])
    var urep = PushReport(plain)
    urep.set_unpack_error("index-pack abnormal exit")
    out.clear()
    append_push_report(out, plain, urep)
    assert_equal(
        _show(out),
        "0024unpack index-pack abnormal exit\\x0a0026ng refs/heads/main unpacker error\\x0a"
        + "0025ng refs/heads/new unpacker error\\x0a0025ng refs/heads/old unpacker error\\x0a0000",
    )
    # Atomic with a refusal and an unpack error: the unpack error wins, as
    # git reports `unpacker error` before it runs any update.
    var aurep = PushReport(atomic)
    aurep.reject(1, "non-fast-forward")
    aurep.set_unpack_error("index-pack abnormal exit")
    var aureasons = aurep.final_reasons(atomic)
    for i in range(3):
        assert_equal(aureasons[i], "unpacker error")
    # No report-status asked: only side-band's closing flush.
    var quiet = _request(False, True, False)
    out.clear()
    append_push_report(out, quiet, PushReport(quiet))
    assert_equal(_show(out), "0000")
    append_push_message(out, plain, "dropped without side-band")
    assert_equal(_show(out), "0000")
    try:
        rep.reject(3, "x")
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push report: no command 3")
    try:
        urep.set_unpack_error("ok")
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push report: an unpack error needs a message")


def test_funny_refnames() raises:
    var w = List[UInt8]()
    var names: List[String] = [
        "refs/heads/ok", "HEAD", "refs/heads/a..b", "refs/x", "refs/heads/x.lock",
    ]
    for i in range(len(names)):
        var line = A + " " + B + " " + names[i]
        if i == 0:
            append_pkt_data(w, Span(_with_caps(line, " report-status")))
        else:
            append_pkt_text(w, line)
    append_pkt_text(w, A + " " + Z + " refs/y")
    append_pkt_flush(w)
    var s = ReceivePackServer(_config(True, False))
    s.feed(Span(w))
    var r = s.read_request()
    var rep = PushReport(r)
    rep.refuse_funny_refnames(r)
    var reasons = rep.final_reasons(r)
    assert_equal(reasons[0], "")
    assert_equal(reasons[1], "funny refname")
    assert_equal(reasons[2], "funny refname")
    # One level under refs/ is refused for an update, allowed for a delete.
    assert_equal(reasons[3], "funny refname")
    assert_equal(reasons[4], "funny refname")
    assert_equal(reasons[5], "")
    # Atomic, two funny refs: the first keeps its reason, the rest fail.
    var w2 = List[UInt8]()
    append_pkt_data(w2, Span(_with_caps(A + " " + B + " refs/heads/ok", " report-status atomic")))
    append_pkt_text(w2, A + " " + B + " refs/heads/a..b")
    append_pkt_text(w2, A + " " + B + " refs/heads/c..d")
    append_pkt_flush(w2)
    var s2 = ReceivePackServer(_config(True, False))
    s2.feed(Span(w2))
    var r2 = s2.read_request()
    assert_true(r2.atomic)
    var rep2 = PushReport(r2)
    rep2.refuse_funny_refnames(r2)
    var reasons2 = rep2.final_reasons(r2)
    assert_equal(reasons2[0], "atomic push failure")
    assert_equal(reasons2[1], "funny refname")
    assert_equal(reasons2[2], "atomic push failure")


def test_lf_terminated_request() raises:
    var w = List[UInt8]()
    append_pkt_text(w, "shallow " + A + "\n")
    append_pkt_data(
        w, Span(_with_caps(A + " " + B + " refs/heads/main", " report-status side-band-64k push-options\n"))
    )
    append_pkt_text(w, Z + " " + B + " refs/heads/new\n")
    append_pkt_flush(w)
    append_pkt_text(w, "note=one\n")
    append_pkt_flush(w)
    var s = ReceivePackServer(_config(True, True))
    s.feed(Span(w))
    var r = s.read_request()
    assert_true(r.complete)
    assert_true(r.side_band and r.report_status and r.use_push_options)
    assert_equal(len(r.shallows), 1)
    assert_equal(len(r.commands), 2)
    assert_equal(r.commands[0].ref_name, "refs/heads/main")
    assert_equal(r.commands[1].ref_name, "refs/heads/new")
    assert_equal(len(r.push_options), 1)
    assert_equal(r.push_options[0], "note=one")
    var rep = PushReport(r)
    rep.refuse_funny_refnames(r)
    var out = List[UInt8]()
    append_push_report(out, r, rep)
    assert_equal(
        _show(out),
        "0044\\x01000eunpack ok\\x0a0017ok refs/heads/main\\x0a0016ok refs/heads/new\\x0a0000"
        + "0000",
    )
    # Two LFs: one is chomped, the other stays part of the line, so the ref
    # name holds an LF (a funny refname) and so does the push option.
    var w2 = List[UInt8]()
    append_pkt_data(
        w2, Span(_with_caps(A + " " + B + " refs/heads/ok", " report-status push-options"))
    )
    append_pkt_text(w2, A + " " + B + " refs/heads/x\n\n")
    append_pkt_flush(w2)
    append_pkt_text(w2, "note=two\n\n")
    append_pkt_flush(w2)
    var s2 = ReceivePackServer(_config(True, True))
    s2.feed(Span(w2))
    var r2 = s2.read_request()
    assert_true(r2.complete and r2.use_push_options)
    assert_equal(r2.commands[1].ref_name, "refs/heads/x\n")
    assert_equal(r2.push_options[0], "note=two\n")
    var rep2 = PushReport(r2)
    rep2.refuse_funny_refnames(r2)
    var reasons2 = rep2.final_reasons(r2)
    assert_equal(reasons2[0], "")
    assert_equal(reasons2[1], "funny refname")


def test_more_refusals() raises:
    comptime P = "komira_git: receive-pack: "
    var out = List[UInt8]()
    var unborn = List[AdvertisedRef]()
    unborn.append(AdvertisedRef("refs/heads/x", ObjectId.zero(ObjectFormat.sha1())))
    try:
        append_receive_pack_advertisement(out, _config(True, False), unborn)
        assert_true(False)
    except e:
        assert_equal(String(e), P + "ref 'refs/heads/x' names no object")
    var w = List[UInt8]()
    append_pkt_delim(w)
    var s = ReceivePackServer(_config(True, False))
    s.feed(Span(w))
    try:
        _ = s.read_request()
        assert_true(False)
    except e:
        assert_equal(String(e), P + "protocol error: expected old/new/ref")
    # A shallow line, then a delete-only push: no pack follows.
    var w2 = List[UInt8]()
    append_pkt_text(w2, "shallow " + A)
    append_pkt_data(w2, Span(_with_caps(B + " " + Z + " refs/heads/old", " report-status")))
    append_pkt_flush(w2)
    var s2 = ReceivePackServer(_config(True, False))
    s2.feed(Span(w2))
    var r2 = s2.read_request()
    assert_equal(len(r2.shallows), 1)
    assert_true(r2.shallows[0] == _id(A))
    assert_false(r2.needs_pack())
    var rep = PushReport(r2)
    try:
        rep.reject(0, "")
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push report: a refusal needs a reason")
    # A report for a request with no commands is nothing; one for another
    # request is refused.
    var none = PushRequest()
    out.clear()
    append_push_report(out, none, PushReport(none))
    assert_equal(len(out), 0)
    try:
        append_push_report(out, r2, PushReport(none))
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: push report: the report is for another request")


def main() raises:
    test_advertisement()
    test_read_request()
    test_request_refusals()
    test_report()
    test_funny_refnames()
    test_lf_terminated_request()
    test_more_refusals()
    print("komira_git receive-pack tests passed")
