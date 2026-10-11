# =============================================================================
# komira_git/fetch_negotiation.mojo -- the server's answer to a protocol v2
# fetch (gitprotocol-v2, "fetch"; upload-pack.c): which of the client's
# haves to acknowledge, whether to say `ready`, and the order and framing
# of the response sections.
# =============================================================================
#
# `negotiate` reads the repository through a `CommitGraph`, the one thing
# the caller supplies. It follows upload-pack: a have the server lacks is
# ignored; a have that is a commit marks its parents as known to the client;
# a have is acknowledged unless it is already known that way, in the order
# the client sent it. `ready` is said when every want reaches a known
# object through its parents (a want that is not a commit, after peeling
# tags, counts as reached), never with `wait-for-done`, and never before
# some have was acknowledged.
#
# One difference: git stops that walk at commits older than the oldest
# acknowledged have (a guard against walking the whole history). This walk
# does not, so it can say `ready` in a round where git would not; the pack
# is the same, it only ends negotiation sooner.
#
# `FetchResponder` writes the sections in the one order the protocol
# allows and refuses any other:
#   acknowledgments  (when the client sent haves and not `done`)
#   shallow-info     (when the client sent `shallow`, `deepen`,
#                     `deepen-since` or `deepen-not`, or the repository
#                     is shallow)
#   packfile         (side-band: pack data on band 1, progress on band 2,
#                     a fatal error on band 3), then a flush.
# The shallow and unshallow lines are the caller's to compute (which commits
# a depth, a date or an excluded ref cuts); they are written as git writes them, without an LF.
# =============================================================================

from std.collections import Set

from .object_id import ObjectId
from .pkt_line import append_pkt_delim, append_pkt_flush
from .pkt_stream import (
    SIDEBAND_DATA,
    SIDEBAND_ERROR,
    SIDEBAND_PROGRESS,
    append_sideband,
)
from .protocol_types import FetchArgs, _line_pkt, _text_pkt


trait CommitGraph:
    """What `negotiate` needs to know about the server's repository."""

    def has_object(self, id: ObjectId) -> Bool:
        """True when the repository holds object `id`."""
        ...

    def is_commit(self, id: ObjectId) -> Bool:
        """True when `id` is a commit the repository holds."""
        ...

    def parents(self, id: ObjectId) raises -> List[ObjectId]:
        """The parents of commit `id`, in order."""
        ...

    def peel(self, id: ObjectId) raises -> ObjectId:
        """The object annotated tag `id` names, following tags of tags;
        `id` itself when it is not a tag."""
        ...


struct Negotiation(Copyable, Movable):
    """The haves to acknowledge, in the order the client sent them, and
    whether to say `ready`."""

    var common: List[ObjectId]
    var ready: Bool

    def __init__(out self):
        self.common = List[ObjectId]()
        self.ready = False


def negotiate[G: CommitGraph](args: FetchArgs, graph: G) raises -> Negotiation:
    """The acknowledgments for fetch `args`. Raises `not our ref <id>` for a
    want the repository does not hold (upload-pack's ERR)."""
    for i in range(len(args.wants)):
        if not graph.has_object(args.wants[i]):
            raise Error(
                "komira_git: upload-pack: not our ref " + args.wants[i].to_hex()
            )
    var result = Negotiation()
    var known = Set[String]()
    for i in range(len(args.haves)):
        var have = args.haves[i]
        if not graph.has_object(have):
            continue
        if graph.is_commit(have):
            var parents = graph.parents(have)
            for p in range(len(parents)):
                known.add(parents[p].to_hex())
        var hex = have.to_hex()
        if hex in known:
            continue
        known.add(hex)
        result.common.append(have)
    if len(result.common) > 0 and not args.wait_for_done:
        result.ready = _all_wants_reach(args.wants, known, graph)
    return result^


def _all_wants_reach[G: CommitGraph](
    wants: List[ObjectId], known: Set[String], graph: G
) raises -> Bool:
    for i in range(len(wants)):
        var start = graph.peel(wants[i])
        if not graph.is_commit(start):
            continue
        if not _reaches(start, known, graph):
            return False
    return True


def _reaches[G: CommitGraph](
    start: ObjectId, known: Set[String], graph: G
) raises -> Bool:
    """True when commit `start` or one of its ancestors is in `known`."""
    var seen = Set[String]()
    var stack = List[ObjectId]()
    stack.append(start)
    seen.add(start.to_hex())
    while len(stack) > 0:
        var c = stack.pop()
        if c.to_hex() in known:
            return True
        if not graph.is_commit(c):
            continue
        var parents = graph.parents(c)
        for p in range(len(parents)):
            var hex = parents[p].to_hex()
            if hex not in seen:
                seen.add(hex)
                stack.append(parents[p])
    return False


comptime _FR_START: Int = 0
comptime _FR_PACK_NEXT: Int = 1
comptime _FR_SHALLOW_DONE: Int = 2
comptime _FR_PACKFILE: Int = 3
comptime _FR_ENDED: Int = 4


struct FetchResponder(Movable):
    """The response to one fetch request, written section by section."""

    var _state: Int
    var _done: Bool
    var _has_haves: Bool
    var _has_wants: Bool
    var _wait_for_done: Bool
    var _no_progress: Bool
    var _shallow_asked: Bool

    def __init__(out self, args: FetchArgs):
        self._state = _FR_START
        self._done = args.done
        self._has_haves = len(args.haves) > 0
        self._has_wants = len(args.wants) > 0
        self._wait_for_done = args.wait_for_done
        self._no_progress = args.no_progress
        self._shallow_asked = args.asks_shallow()

    def append_acknowledgments(
        mut self, mut out: List[UInt8], negotiation: Negotiation
    ) raises -> Bool:
        """The acknowledgments section, when the request calls for one (it
        sent haves and not `done`). True when a packfile follows (the caller
        goes on to `append_shallow_info`); False when the response is
        complete: after acknowledgments without `ready`, the client sends
        another request, and a request with no wants and no
        `wait-for-done` gets no response at all."""
        if self._state != _FR_START:
            raise Error("komira_git: fetch response: acknowledgments come first, once")
        if not self._has_wants and not self._wait_for_done:
            # upload-pack sends nothing at all for a request with no wants.
            self._state = _FR_ENDED
            return False
        if self._done or not self._has_haves:
            # No section: `negotiation` is not used.
            self._state = _FR_PACK_NEXT
            return True
        if negotiation.ready and (
            len(negotiation.common) == 0 or self._wait_for_done
        ):
            raise Error(
                "komira_git: fetch response: 'ready' needs an acknowledged have and no wait-for-done"
            )
        _line_pkt(out, "acknowledgments")
        if len(negotiation.common) == 0:
            _line_pkt(out, "NAK")
        for i in range(len(negotiation.common)):
            _line_pkt(out, "ACK " + negotiation.common[i].to_hex())
        if negotiation.ready:
            _line_pkt(out, "ready")
            append_pkt_delim(out)
            self._state = _FR_PACK_NEXT
            return True
        append_pkt_flush(out)
        self._state = _FR_ENDED
        return False

    def append_shallow_info(
        mut self,
        mut out: List[UInt8],
        shallow: List[ObjectId],
        unshallow: List[ObjectId],
        repository_is_shallow: Bool = False,
    ) raises:
        """The shallow-info section: written when the client sent `shallow`,
        `deepen`, `deepen-since` or `deepen-not` lines or the repository is
        itself shallow, and refused lines otherwise."""
        if self._state != _FR_PACK_NEXT:
            raise Error(
                "komira_git: fetch response: shallow-info comes after the acknowledgments, before the packfile"
            )
        self._state = _FR_SHALLOW_DONE
        if not self._shallow_asked and not repository_is_shallow:
            if len(shallow) > 0 or len(unshallow) > 0:
                raise Error(
                    "komira_git: fetch response: shallow lines for a request that is not shallow"
                )
            return
        _line_pkt(out, "shallow-info")
        for i in range(len(shallow)):
            _text_pkt(out, "shallow " + shallow[i].to_hex())
        for i in range(len(unshallow)):
            _text_pkt(out, "unshallow " + unshallow[i].to_hex())
        append_pkt_delim(out)

    def append_packfile_header(mut self, mut out: List[UInt8]) raises:
        """The `packfile` section line; pack data follows."""
        if self._state == _FR_PACK_NEXT:
            self._state = _FR_SHALLOW_DONE
        if self._state != _FR_SHALLOW_DONE:
            raise Error(
                "komira_git: fetch response: no packfile follows this response"
            )
        _line_pkt(out, "packfile")
        self._state = _FR_PACKFILE

    def append_pack_data(mut self, mut out: List[UInt8], data: Span[UInt8, _]) raises:
        """Pack bytes on band 1 (empty `data` writes nothing)."""
        self._in_packfile()
        append_sideband(out, SIDEBAND_DATA, data)

    def append_progress(mut self, mut out: List[UInt8], text: String) raises:
        """Progress text on band 2, unless the client sent `no-progress`."""
        self._in_packfile()
        if not self._no_progress:
            append_sideband(out, SIDEBAND_PROGRESS, text.as_bytes())

    def append_fatal_error(mut self, mut out: List[UInt8], text: String) raises:
        """A fatal error on band 3; the response ends with it (no flush)."""
        self._in_packfile()
        append_sideband(out, SIDEBAND_ERROR, text.as_bytes())
        self._state = _FR_ENDED

    def finish(mut self, mut out: List[UInt8]) raises:
        """The flush after the pack."""
        self._in_packfile()
        append_pkt_flush(out)
        self._state = _FR_ENDED

    def _in_packfile(self) raises:
        if self._state != _FR_PACKFILE:
            raise Error("komira_git: fetch response: not inside the packfile section")
