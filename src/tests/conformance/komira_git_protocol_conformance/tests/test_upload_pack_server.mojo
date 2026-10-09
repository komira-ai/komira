# =============================================================================
# test_upload_pack_server.mojo -- komira_git's protocol v2 server answers
# every request the pinned git client sent, byte for byte as the pinned git
# server answered it.
# =============================================================================
#
# For each fetch scenario and connection: UploadPackV2Server's advertisement
# must equal git's; the client's bytes are fed in 7-byte pieces and each
# request read is answered from the scenario's repository
# (append_ls_refs_response; negotiate over TranscriptGraph, FetchResponder)
# and compared with git's answer at the same offset. The pack itself is
# git's to make (pack writing is not part of komira_git's protocol layer):
# its section is read with read_git_packfile, which checks that it is a
# whole pack, and the comparison resumes after it. Every byte git sent is
# accounted for.
#
# What the scenarios exercise (capture.sh): ls-refs with prefixes, peel,
# symrefs and unborn; fetch with no haves and `done` (clone), with haves
# and a server option (ACK, ready), `deepen 1` (shallow-info), `deepen 1`
# with `deepen-relative` (shallow and unshallow) and a tag-following second
# connection that sends `shallow` with no deepen (an empty shallow-info),
# `deepen-since` with `deepen-not` (shallow-info for a date and an excluded
# ref),
# an empty repository (unborn HEAD) and `wait-for-done` (acknowledgments,
# never ready).
#
# The shallow and unshallow commits are the client's shallow list after the
# fetch less the list before it, and the reverse: which commits a depth
# cuts is the store's to compute, not the protocol's.
#
# A defect this catches that the unit tests could not: any difference from
# what git writes (an LF git does not write, a section git would not send,
# an ACK git would not send, a ref order or attribute git does not use).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    V2_END,
    V2_LS_REFS,
    V2_NEED_MORE,
    FetchResponder,
    ObjectFormat,
    ObjectId,
    UploadPackV2Server,
    append_ls_refs_response,
    negotiate,
)
from komira_git_protocol_conformance import (
    Scenario,
    TranscriptGraph,
    expect_bytes,
    ids,
    minus,
    read_git_packfile,
)

comptime AGENT = "git/2.56.0-Linux"


def _serve(name: String) raises -> Int:
    """Answer every request of scenario `name`; returns how many requests
    were answered."""
    var sc = Scenario(name)
    var graph = TranscriptGraph(sc.objects, sc.parents, sc.tags)
    var answered = 0
    for k in range(len(sc.connections)):
        ref conn = sc.connections[k]
        var what = name + " conn" + String(k + 1)
        var server = UploadPackV2Server(AGENT, ObjectFormat.sha1())
        var out = List[UInt8]()
        server.append_advertisement(out)
        var at = expect_bytes(out, Span(conn.response), 0, what + " advertisement")
        var fed = 0
        while True:
            var r = server.next_request()
            if r.command == V2_NEED_MORE:
                if fed == len(conn.request):
                    break
                var end = fed + 7 if fed + 7 < len(conn.request) else len(conn.request)
                server.feed(Span(conn.request)[fed:end])
                fed = end
                continue
            if r.command == V2_END:
                assert_equal(fed, len(conn.request))
                break
            answered += 1
            assert_equal(r.agent, AGENT)
            out.clear()
            if r.command == V2_LS_REFS:
                append_ls_refs_response(out, r.ls_refs, sc.head(), sc.refs)
                at = expect_bytes(out, Span(conn.response), at, what + " ls-refs")
                continue
            var responder = FetchResponder(r.fetch)
            var pack_follows = responder.append_acknowledgments(
                out, negotiate(r.fetch, graph)
            )
            if not pack_follows:
                at = expect_bytes(out, Span(conn.response), at, what + " acknowledgments")
                continue
            var shallow = List[ObjectId]()
            var unshallow = List[ObjectId]()
            var cuts = r.fetch.deepen > 0 or Bool(r.fetch.deepen_since)
            if cuts or len(r.fetch.deepen_not) > 0:
                shallow = ids(minus(sc.shallow_after, sc.shallow_before))
                unshallow = ids(minus(sc.shallow_before, sc.shallow_after))
            responder.append_shallow_info(out, shallow, unshallow)
            responder.append_packfile_header(out)
            at = expect_bytes(out, Span(conn.response), at, what + " fetch")
            var pack = read_git_packfile(conn.response, at, what + " packfile")
            at = pack.end
        if at != len(conn.response):
            raise Error(
                what + ": git sent " + String(len(conn.response) - at)
                + " bytes komira_git did not"
            )
    return answered


def test_clone() raises:
    assert_equal(_serve("v2_clone"), 2)


def test_fetch() raises:
    assert_equal(_serve("v2_fetch"), 2)


def test_shallow() raises:
    assert_equal(_serve("v2_shallow"), 2)


def test_deepen() raises:
    assert_equal(_serve("v2_deepen"), 4)


def test_since() raises:
    assert_equal(_serve("v2_since"), 2)
    # git's client sent both arguments, and the clone is cut at one commit.
    var sc = Scenario("v2_since")
    var parser = UploadPackV2Server(AGENT, ObjectFormat.sha1())
    parser.feed(Span(sc.connections[0].request))
    var r = parser.next_request()
    while r.command == V2_LS_REFS:
        r = parser.next_request()
    assert_equal(r.fetch.deepen_since.value(), 1790000150)
    assert_equal(len(r.fetch.deepen_not), 1)
    assert_equal(r.fetch.deepen_not[0], "v1")
    assert_equal(r.fetch.deepen, 0)
    assert_equal(len(sc.shallow_after), 1)


def test_unborn() raises:
    assert_equal(_serve("v2_unborn"), 1)


def test_negotiate_only() raises:
    assert_true(_serve("v2_negotiate") >= 1)


def main() raises:
    test_clone()
    test_fetch()
    test_shallow()
    test_deepen()
    test_since()
    test_unborn()
    test_negotiate_only()
    print("komira_git conformance: upload-pack v2 server passed")
