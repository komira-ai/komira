# =============================================================================
# test_receive_pack_server.mojo -- komira_git's receive-pack server answers
# every push the pinned git client made, byte for byte as the pinned git
# server answered it.
# =============================================================================
#
# For each push scenario: the ref advertisement (the scenario's refs, with
# push-options when the server advertised it) must equal git's; the
# client's bytes are fed in 11-byte pieces until the commands are read; what
# follows them must be a whole pack exactly when a command creates or
# updates a ref; the verdicts are the scenario server's (push_verdicts:
# receive.denyNonFastForwards), and the messages and report-status
# komira_git writes must equal the rest of git's response.
#
# The scenarios: an atomic push with push options that updates, creates and
# deletes (all ok); an atomic push where one non-fast-forward update is
# refused and the other command fails with `atomic push failure`; a
# delete-only push (no pack) to a server without push-options; the
# first push into an empty repository (`capabilities^{}`); and, under
# denyNonFastForwards, a fast-forward of a branch and a forced update
# outside refs/heads/, both accepted.
#
# A defect this catches: a capability git advertises and komira_git does
# not (or the reverse), an atomic push that lets one ref through, a pack
# expected after a delete-only push, a report-status git's client would
# read differently (the side-band framing, the closing flush), and in the
# verdicts (push_verdicts): a fast-forward refused, or the
# non-fast-forward rule applied outside refs/heads/.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    ObjectFormat,
    ReceivePackConfig,
    ReceivePackServer,
    append_push_message,
    append_push_report,
    append_receive_pack_advertisement,
)
from komira_git_protocol_conformance import Scenario, check_pack, expect_bytes, push_verdicts

comptime AGENT = "git/2.56.0-Linux"


def _serve(name: String) raises -> List[String]:
    """Answer scenario `name`'s push; returns the reasons reported."""
    var sc = Scenario(name)
    assert_equal(len(sc.connections), 1)
    ref conn = sc.connections[0]
    var config = ReceivePackConfig(
        AGENT, ObjectFormat.sha1(), True, sc.has_setting("push-options")
    )
    var out = List[UInt8]()
    append_receive_pack_advertisement(out, config, sc.refs)
    var at = expect_bytes(out, Span(conn.response), 0, name + " advertisement")
    var server = ReceivePackServer(config^)
    var fed = 0
    var n = len(conn.request)
    while True:
        var req = server.read_request()
        if req.complete:
            var pack = server.take_buffered()
            for i in range(fed, n):
                pack.append(conn.request[i])
            if req.needs_pack():
                check_pack(pack, name + " pack")
            else:
                assert_equal(len(pack), 0)
            var verdicts = push_verdicts(sc, req)
            out.clear()
            for i in range(len(verdicts.messages)):
                append_push_message(out, req, verdicts.messages[i])
            append_push_report(out, req, verdicts.report)
            at = expect_bytes(out, Span(conn.response), at, name + " report")
            assert_equal(at, len(conn.response))
            return verdicts.report.final_reasons(req)
        assert_true(fed < n)
        var end = fed + 11 if fed + 11 < n else n
        server.feed(Span(conn.request)[fed:end])
        fed = end


def test_atomic_with_options() raises:
    var reasons = _serve("push_atomic")
    assert_equal(len(reasons), 3)
    for i in range(3):
        assert_equal(reasons[i], "")


def test_atomic_refused() raises:
    var reasons = _serve("push_reject")
    assert_equal(len(reasons), 2)
    assert_equal(reasons[0], "non-fast-forward")
    assert_equal(reasons[1], "atomic push failure")


def test_delete_only() raises:
    var reasons = _serve("push_delete")
    assert_equal(len(reasons), 1)
    assert_equal(reasons[0], "")


def test_empty_repository() raises:
    var reasons = _serve("push_empty")
    assert_equal(len(reasons), 1)
    assert_equal(reasons[0], "")


def test_fast_forward_under_deny() raises:
    # git accepts both: main moves forward, and the forced update is
    # outside refs/heads/, where denyNonFastForwards does not apply.
    var reasons = _serve("push_ff")
    assert_equal(len(reasons), 2)
    assert_equal(reasons[0], "")
    assert_equal(reasons[1], "")


def main() raises:
    test_atomic_with_options()
    test_atomic_refused()
    test_delete_only()
    test_empty_repository()
    test_fast_forward_under_deny()
    print("komira_git conformance: receive-pack server passed")
