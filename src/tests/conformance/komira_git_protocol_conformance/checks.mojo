# =============================================================================
# komira_git_protocol_conformance/checks.mojo -- what the conformance tests
# share: reading git's packfile section, checking a pack's trailer, and the
# verdicts a scenario's server gave each push command.
# =============================================================================

from komira_crypto import sha1
from komira_git import (
    PKT_DATA,
    PKT_FLUSH,
    PushReport,
    PushRequest,
    read_pkt_line,
)

from .graph import TranscriptGraph
from .transcript import Scenario


struct GitPack(Movable):
    """Where git's packfile section ended, and the pack it carried."""

    var end: Int
    var pack: List[UInt8]

    def __init__(out self, end: Int, var pack: List[UInt8]):
        self.end = end
        self.pack = pack^


struct PushVerdicts(Movable):
    """A push's report and the messages sent before it."""

    var report: PushReport
    var messages: List[String]

    def __init__(out self, var report: PushReport, var messages: List[String]):
        self.report = report^
        self.messages = messages^


def check_pack(pack: List[UInt8], what: String) raises:
    """`pack` is a whole packfile: `PACK`, version 2, and a trailer that is
    the SHA-1 of everything before it (so no byte was lost or added)."""
    if len(pack) < 32:
        raise Error(what + ": the pack is " + String(len(pack)) + " bytes")
    if pack[0] != 0x50 or pack[1] != 0x41 or pack[2] != 0x43 or pack[3] != 0x4B:
        raise Error(what + ": the pack does not start with PACK")
    if pack[7] != 2:
        raise Error(what + ": the pack is not version 2")
    var n = len(pack) - 20
    var digest = sha1(Span(pack)[0:n])
    for i in range(20):
        if digest[i] != pack[n + i]:
            raise Error(what + ": the pack's trailer is not the SHA-1 of its bytes")


def read_git_packfile(
    response: List[UInt8], at: Int, what: String
) raises -> GitPack:
    """git's packfile section from `at` (after the `packfile` line): band-1
    and band-2 pkt-lines to a flush. Returns the offset after the flush and
    the band-1 bytes, which must be a whole pack."""
    var pos = at
    var pack = List[UInt8]()
    while True:
        var line = read_pkt_line(Span(response), pos)
        if line.consumed == 0:
            raise Error(what + ": git's packfile section ends early")
        pos += line.consumed
        if line.kind == PKT_FLUSH:
            break
        if line.kind != PKT_DATA or len(line.payload) == 0:
            raise Error(what + ": a packfile line without a band")
        var band = Int(line.payload[0])
        if band == 1:
            for i in range(1, len(line.payload)):
                pack.append(line.payload[i])
        elif band != 2:
            raise Error(what + ": band " + String(band) + " in git's packfile")
    check_pack(pack, what)
    return GitPack(pos, pack^)


def push_verdicts(sc: Scenario, request: PushRequest) raises -> PushVerdicts:
    """What the scenario's server decided for each command, from its
    settings: with `deny-non-fast-forwards`, an update under refs/heads/
    whose new commit does not descend from the old one is refused as
    `non-fast-forward`, with git's message for it. Returns the report and
    the messages, in the order git sends them."""
    var graph = TranscriptGraph(List[String](), sc.parents_after, List[String]())
    var report = PushReport(request)
    var messages = List[String]()
    var deny = sc.has_setting("deny-non-fast-forwards")
    for i in range(len(request.commands)):
        ref c = request.commands[i]
        if not deny or c.is_create() or c.is_delete():
            continue
        if not c.ref_name.startswith("refs/heads/"):
            continue
        if not graph.descends_from(c.new_id, c.old_id):
            messages.append(
                "error: denying non-fast-forward " + c.ref_name + " (you should pull first)"
            )
            report.reject(i, "non-fast-forward")
    return PushVerdicts(report^, messages^)
