# =============================================================================
# test_fetch_client.mojo -- komira_git's protocol v2 client writes the
# requests the pinned git client wrote, byte for byte, and reads everything
# the pinned git server sent back.
# =============================================================================
#
# For each fetch scenario and connection: FetchV2Client reads git's
# advertisement; each request git's client sent is read back into its
# arguments (UploadPackV2Server as the parser) and written again with
# FetchV2Client.append_ls_refs_request / append_fetch_request, which must
# give git's bytes at the same offset. git's response to it, fed in 5-byte
# pieces, is then read with read_ls_refs or next_event:
#   - ls-refs: every ref a prefix of the request matches, and HEAD with its
#     symref, as the server's refs.txt and
#     head.txt list them (peeled only when git's client asked for peel);
#   - fetch: the pack's band-1 bytes make a whole pack (trailer checked),
#     and the shallow and unshallow lines are the client's shallow list
#     changes.
# What remains of git's request after the last one is a lone flush (the
# client ending the session) or nothing.
#
# A defect this catches: a request git's server would read differently (an
# LF on `command=fetch` or `deepen-since`, `deepen` before `shallow`,
# `deepen-not` before `deepen-since`, an argument git does not send), a
# response line or section the client misreads, or pack bytes
# lost across pkt-lines.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    FETCH_ACK,
    FETCH_END,
    FETCH_NEED_MORE,
    FETCH_PACK_DATA,
    FETCH_ROUND_END,
    FETCH_SHALLOW,
    FETCH_UNSHALLOW,
    V2_END,
    V2_LS_REFS,
    V2_NEED_MORE,
    AdvertisedRef,
    FetchV2Client,
    ObjectFormat,
    UploadPackV2Server,
)
from komira_git_protocol_conformance import Scenario, check_pack, expect_bytes, minus

comptime AGENT = "git/2.56.0-Linux"


def _client_run(name: String) raises -> Int:
    var sc = Scenario(name)
    var requests = 0
    for k in range(len(sc.connections)):
        ref conn = sc.connections[k]
        var what = name + " conn" + String(k + 1)
        var client = FetchV2Client(AGENT, ObjectFormat.sha1())
        var parser = UploadPackV2Server(AGENT, ObjectFormat.sha1())
        parser.feed(Span(conn.request))
        var fed = 0
        var resp_len = len(conn.response)
        # The advertisement.
        while not client.read_advertisement():
            var end = fed + 5 if fed + 5 < resp_len else resp_len
            assert_true(end > fed)
            client.feed(Span(conn.response)[fed:end])
            fed = end
        var req_at = 0
        while True:
            var r = parser.next_request()
            if r.command == V2_NEED_MORE:
                break
            if r.command == V2_END:
                req_at += 4
                break
            requests += 1
            var out = List[UInt8]()
            if r.command == V2_LS_REFS:
                client.append_ls_refs_request(
                    out, r.ls_refs.ref_prefixes, r.ls_refs.peel, r.server_options
                )
                req_at = expect_bytes(out, Span(conn.request), req_at, what + " ls-refs request")
                while True:
                    var result = client.read_ls_refs()
                    if result.complete:
                        _check_refs(sc, result.refs, r.ls_refs.peel, r.ls_refs.ref_prefixes, what)
                        break
                    var end = fed + 5 if fed + 5 < resp_len else resp_len
                    assert_true(end > fed)
                    client.feed(Span(conn.response)[fed:end])
                    fed = end
                continue
            client.append_fetch_request(out, r.fetch, r.server_options)
            req_at = expect_bytes(out, Span(conn.request), req_at, what + " fetch request")
            var pack = List[UInt8]()
            var shallow = List[String]()
            var unshallow = List[String]()
            var acks = 0
            while True:
                var ev = client.next_event()
                if ev.kind == FETCH_NEED_MORE:
                    var end = fed + 5 if fed + 5 < resp_len else resp_len
                    assert_true(end > fed)
                    client.feed(Span(conn.response)[fed:end])
                    fed = end
                    continue
                if ev.kind == FETCH_ACK:
                    acks += 1
                elif ev.kind == FETCH_SHALLOW:
                    shallow.append(ev.id.to_hex())
                elif ev.kind == FETCH_UNSHALLOW:
                    unshallow.append(ev.id.to_hex())
                elif ev.kind == FETCH_PACK_DATA:
                    for i in range(len(ev.data)):
                        pack.append(ev.data[i])
                elif ev.kind == FETCH_ROUND_END:
                    assert_true(len(r.fetch.haves) > 0)
                    break
                elif ev.kind == FETCH_END:
                    check_pack(pack, what + " pack")
                    var cuts = r.fetch.deepen > 0 or Bool(r.fetch.deepen_since)
                    if cuts or len(r.fetch.deepen_not) > 0:
                        _same(shallow, minus(sc.shallow_after, sc.shallow_before), what)
                        _same(unshallow, minus(sc.shallow_before, sc.shallow_after), what)
                    else:
                        assert_equal(len(shallow) + len(unshallow), 0)
                    break
        assert_equal(req_at, len(conn.request))
        assert_equal(fed, resp_len)
    return requests


def _same(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want))
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error(what + ": shallow line " + got[i] + ", want " + want[i])


def _matches(prefixes: List[String], name: String) -> Bool:
    if len(prefixes) == 0:
        return True
    for i in range(len(prefixes)):
        if name.startswith(prefixes[i]):
            return True
    return False


def _check_refs(
    sc: Scenario,
    refs: List[AdvertisedRef],
    peel: Bool,
    prefixes: List[String],
    what: String,
) raises:
    """`refs` are the server's refs that a prefix matches, each once, with
    their ids (and peeled ids when asked), and HEAD when it names an object
    and a prefix matches it."""
    var want = 0
    for j in range(len(sc.refs)):
        if _matches(prefixes, sc.refs[j].name):
            want += 1
    var head = sc.head()
    var head_listed = Bool(head) and not head.value().is_unborn() and _matches(prefixes, "HEAD")
    if head_listed:
        want += 1
    assert_equal(len(refs), want)
    for i in range(len(refs)):
        if refs[i].name == "HEAD":
            assert_true(head_listed)
            assert_equal(refs[i].symref_target, sc.head_target)
            continue
        var found = False
        for j in range(len(sc.refs)):
            if sc.refs[j].name == refs[i].name:
                found = True
                assert_true(_matches(prefixes, refs[i].name))
                assert_true(sc.refs[j].id == refs[i].id)
                if peel:
                    assert_true(sc.refs[j].peeled == refs[i].peeled)
                else:
                    assert_false(refs[i].has_peeled())
        if not found:
            raise Error(what + ": ls-refs read a ref the server does not have: " + refs[i].name)


def test_clone() raises:
    assert_equal(_client_run("v2_clone"), 2)


def test_fetch() raises:
    assert_equal(_client_run("v2_fetch"), 2)


def test_shallow() raises:
    assert_equal(_client_run("v2_shallow"), 2)


def test_deepen() raises:
    assert_equal(_client_run("v2_deepen"), 4)


def test_since() raises:
    assert_equal(_client_run("v2_since"), 2)


def test_unborn() raises:
    assert_equal(_client_run("v2_unborn"), 1)


def test_negotiate_only() raises:
    assert_true(_client_run("v2_negotiate") >= 1)


def main() raises:
    test_clone()
    test_fetch()
    test_shallow()
    test_deepen()
    test_since()
    test_unborn()
    test_negotiate_only()
    print("komira_git conformance: fetch v2 client passed")
