# =============================================================================
# test_capability_truth.mojo -- every capability komira_git's servers
# advertise is one the pinned git client used in some transcript, so each
# promise is exercised against git and not only advertised.
# =============================================================================
#
# Protocol v2 (UploadPackV2Server): each advertised key, and each word of
# its value (`ls-refs=unborn`, `fetch=shallow wait-for-done`), must be used
# by some request of the fetch scenarios: the command itself; `agent=`,
# `object-format=` and `server-option=` sent with a command; ls-refs'
# `unborn` argument; fetch's `shallow`, `deepen`, `deepen-since` or
# `deepen-not` lines for `shallow`; and
# `wait-for-done`.
#
# receive-pack (ReceivePackConfig with atomic and push-options): each
# advertised word must be in the capability list of some push request, or
# for `delete-refs` a delete command must have been sent. Two are exempt,
# and the test names them so that the list cannot grow unseen:
#   - `report-status`: git 2.56 asks for `report-status-v2` whenever it is
#     offered; the report is the same bytes for both (receive_pack.mojo).
#   - `ofs-delta`: a client uses it in the pack it sends, not in a request
#     line; reading packs is the pack reader's, not the protocol's.
#
# The planted defect this exists for: advertising `fetch=filter` (or any
# capability no transcript uses) fails here, naming it.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    V2_END,
    V2_FETCH,
    V2_LS_REFS,
    V2_NEED_MORE,
    FetchV2Client,
    ObjectFormat,
    ReceivePackConfig,
    ReceivePackServer,
    UploadPackV2Server,
)
from komira_git_protocol_conformance import Scenario

comptime AGENT = "git/2.56.0-Linux"


def _fetch_uses() raises -> List[String]:
    """Every v2 capability the git client used, as `key` or `key:word`."""
    var used = List[String]()
    var names: List[String] = [
        "v2_clone", "v2_fetch", "v2_shallow", "v2_deepen", "v2_since", "v2_unborn",
        "v2_negotiate",
    ]
    for s in range(len(names)):
        var sc = Scenario(names[s])
        for k in range(len(sc.connections)):
            var parser = UploadPackV2Server(AGENT, ObjectFormat.sha1())
            parser.feed(Span(sc.connections[k].request))
            while True:
                var r = parser.next_request()
                if r.command == V2_NEED_MORE or r.command == V2_END:
                    break
                if r.agent.byte_length() > 0:
                    used.append("agent")
                if r.object_format.byte_length() > 0:
                    used.append("object-format")
                if len(r.server_options) > 0:
                    used.append("server-option")
                if r.command == V2_LS_REFS:
                    used.append("ls-refs")
                    if r.ls_refs.unborn:
                        used.append("ls-refs:unborn")
                if r.command == V2_FETCH:
                    used.append("fetch")
                    if r.fetch.asks_shallow():
                        used.append("fetch:shallow")
                    if r.fetch.wait_for_done:
                        used.append("fetch:wait-for-done")
    return used^


def _has(used: List[String], what: String) -> Bool:
    for i in range(len(used)):
        if used[i] == what:
            return True
    return False


def test_upload_pack_v2() raises:
    var used = _fetch_uses()
    var adv = List[UInt8]()
    UploadPackV2Server("komira-git/1", ObjectFormat.sha1()).append_advertisement(adv)
    var client = FetchV2Client("x", ObjectFormat.sha1())
    client.feed(Span(adv))
    assert_true(client.read_advertisement())
    var lines = client.capabilities.lines.copy()
    assert_true(len(lines) > 0)
    for i in range(len(lines)):
        var line = lines[i]
        var eq = line.find("=")
        var key = line if eq < 0 else String(line[byte=0:eq])
        if not _has(used, key):
            raise Error("advertised '" + line + "' but no git request used '" + key + "'")
        if eq < 0 or key == "agent" or key == "object-format":
            continue
        var words = String(line[byte=eq + 1 : line.byte_length()]).split(" ")
        for w in range(len(words)):
            var use = key + ":" + String(words[w])
            if not _has(used, use):
                raise Error(
                    "advertised '" + line + "' but no git request used '" + use + "'"
                )


def test_receive_pack() raises:
    var used = List[String]()
    var deletes = False
    var names: List[String] = ["push_atomic", "push_reject", "push_delete", "push_empty", "push_ff"]
    for s in range(len(names)):
        var sc = Scenario(names[s])
        var parser = ReceivePackServer(
            ReceivePackConfig(AGENT, ObjectFormat.sha1(), True, True)
        )
        parser.feed(Span(sc.connections[0].request))
        var req = parser.read_request()
        assert_true(req.complete)
        if req.report_status:
            used.append("report-status")
        if req.report_status_v2:
            used.append("report-status-v2")
        if req.side_band:
            used.append("side-band-64k")
        if req.quiet:
            used.append("quiet")
        if req.atomic:
            used.append("atomic")
        if req.use_push_options:
            used.append("push-options")
        if req.agent.byte_length() > 0:
            used.append("agent")
        if req.object_format.byte_length() > 0:
            used.append("object-format")
        for i in range(len(req.commands)):
            if req.commands[i].is_delete():
                deletes = True
    if deletes:
        used.append("delete-refs")
    var exempt: List[String] = ["report-status", "ofs-delta"]
    var caps = ReceivePackConfig(AGENT, ObjectFormat.sha1(), True, True).capability_list()
    var words = caps.split(" ")
    assert_equal(len(words), 10)
    for i in range(len(words)):
        var word = String(words[i])
        var eq = word.find("=")
        var key = word if eq < 0 else String(word[byte=0:eq])
        if _has(used, key):
            continue
        if _has(exempt, key):
            continue
        raise Error("receive-pack advertises '" + word + "' but no git push used it")


def main() raises:
    test_upload_pack_v2()
    test_receive_pack()
    print("komira_git conformance: capability truth passed")
