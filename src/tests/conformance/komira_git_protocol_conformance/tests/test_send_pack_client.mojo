# =============================================================================
# test_send_pack_client.mojo -- komira_git's push client writes the
# commands the pinned git client wrote, byte for byte, and reads the pinned
# git server's advertisement and report-status.
# =============================================================================
#
# For each push scenario: SendPackClient reads git's advertisement (fed in
# 3-byte pieces), whose refs must be the scenario's refs.txt; the commands
# git's client sent are read back (ReceivePackServer as the parser) and
# written again with append_push_request (atomic, quiet and push options as
# git's client asked), which must give git's bytes up to the pack; git's
# report-status is then read with read_status: the unpack status, each
# ref's result and the band-2 messages must be what the scenario's server
# decided (push_verdicts).
#
# A defect this catches: a capability string git's server would parse
# differently (no leading space, quiet when not asked), command lines with
# an LF, push options without their flush, a report misread across the
# side-band framing.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    ObjectFormat,
    ReceivePackConfig,
    ReceivePackServer,
    SendPackClient,
)
from komira_git_protocol_conformance import Scenario, expect_bytes, push_verdicts

comptime AGENT = "git/2.56.0-Linux"


def _push(name: String) raises:
    var sc = Scenario(name)
    ref conn = sc.connections[0]
    var parser = ReceivePackServer(
        ReceivePackConfig(AGENT, ObjectFormat.sha1(), True, True)
    )
    parser.feed(Span(conn.request))
    var req = parser.read_request()
    assert_true(req.complete)
    assert_equal(req.agent, AGENT)
    var client = SendPackClient(AGENT, ObjectFormat.sha1())
    var fed = 0
    var n = len(conn.response)
    while not client.read_advertisement():
        var end = fed + 3 if fed + 3 < n else n
        assert_true(end > fed)
        client.feed(Span(conn.response)[fed:end])
        fed = end
    ref adv = client.advertisement
    assert_equal(len(adv.refs), len(sc.refs))
    for i in range(len(sc.refs)):
        assert_equal(adv.refs[i].name, sc.refs[i].name)
        assert_true(adv.refs[i].id == sc.refs[i].id)
    var out = List[UInt8]()
    client.append_push_request(
        out, req.commands, atomic=req.atomic, quiet=req.quiet, push_options=req.push_options
    )
    var at = expect_bytes(out, Span(conn.request), 0, name + " commands")
    var rest = len(conn.request) - at
    if req.needs_pack():
        assert_true(rest > 32)
    else:
        assert_equal(rest, 0)
    while True:
        var st = client.read_status()
        if st.complete:
            var verdicts = push_verdicts(sc, req)
            var reasons = verdicts.report.final_reasons(req)
            assert_equal(st.unpack_status, "ok")
            assert_equal(len(st.ref_names), len(req.commands))
            for i in range(len(req.commands)):
                assert_equal(st.ref_names[i], req.commands[i].ref_name)
                assert_equal(st.reasons[i], reasons[i])
            assert_equal(len(st.messages), len(verdicts.messages))
            for i in range(len(st.messages)):
                assert_equal(st.messages[i], verdicts.messages[i])
            break
        var end = fed + 3 if fed + 3 < n else n
        assert_true(end > fed)
        client.feed(Span(conn.response)[fed:end])
        fed = end
    assert_equal(fed, n)


def test_atomic_with_options() raises:
    _push("push_atomic")


def test_atomic_refused() raises:
    _push("push_reject")


def test_delete_only() raises:
    _push("push_delete")


def test_empty_repository() raises:
    _push("push_empty")


def test_fast_forward_under_deny() raises:
    _push("push_ff")


def main() raises:
    test_atomic_with_options()
    test_atomic_refused()
    test_delete_only()
    test_empty_repository()
    test_fast_forward_under_deny()
    print("komira_git conformance: send-pack client passed")
