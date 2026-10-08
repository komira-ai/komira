# =============================================================================
# komira_git/fetch_v2_client.mojo -- the client half of git protocol v2
# (gitprotocol-v2; connect.c, fetch-pack.c): reading the capability
# advertisement, writing ls-refs and fetch requests, and reading their
# responses.
# =============================================================================
#
# `FetchV2Client` is sans-I/O: the caller feeds what the server sends and
# reads values or events out; the request writers append bytes to a buffer
# the caller sends. A short read consumes nothing and reports that more
# input is needed.
#
# The requests are byte for byte what git's own client writes for the same
# arguments, including where git ends a line with LF and where it does not
# (`command=ls-refs` has one; `command=fetch`, `deepen <n>`,
# `deepen-since <timestamp>` and `deepen-not <ref>` do not).
#
# The client asks only for what komira_git reads: no `filter`, `want-ref`,
# `sideband-all` or `packfile-uris`, and a response holding a
# `wanted-refs` or `packfile-uris` section is refused.
# =============================================================================

from .object_id import ObjectFormat, ObjectId
from .pkt_line import (
    PktLine,
    PKT_DATA,
    PKT_DELIM,
    PKT_FLUSH,
    PKT_NEED_MORE,
    append_pkt_delim,
    append_pkt_flush,
)
from .pkt_stream import PktReader, _pkt_text, _utf8
from .protocol_types import (
    AdvertisedRef,
    FetchArgs,
    _check_agent,
    _line_pkt,
    _parse_id,
    _text_pkt,
)
from .bytes_util import _to_list

comptime FETCH_NEED_MORE: Int = -1
"""`next_event` needs more input."""
comptime FETCH_ACK: Int = 1
"""`ACK <id>`: the server has `id`."""
comptime FETCH_NAK: Int = 2
"""`NAK`: the server has none of this round's haves."""
comptime FETCH_READY: Int = 3
"""`ready`: the packfile follows in this response."""
comptime FETCH_ROUND_END: Int = 4
"""The acknowledgments ended without `ready`: send the next request."""
comptime FETCH_SHALLOW: Int = 5
"""`shallow <id>`: `id` becomes a shallow commit."""
comptime FETCH_UNSHALLOW: Int = 6
"""`unshallow <id>`: `id` is no longer shallow."""
comptime FETCH_PACK_DATA: Int = 7
"""Bytes of the packfile (band 1; may be empty, a keepalive)."""
comptime FETCH_PROGRESS: Int = 8
"""Progress text (band 2)."""
comptime FETCH_END: Int = 9
"""The flush after the pack: the response is complete."""

comptime _ST_IDLE: Int = 0
comptime _ST_ACK_HEADER: Int = 1
comptime _ST_ACKS: Int = 2
comptime _ST_SECTION: Int = 3
comptime _ST_SHALLOW: Int = 4
comptime _ST_PACK: Int = 5


struct FetchEvent(Movable):
    """One event of a fetch response: its kind (`FETCH_*`), the id of an
    ACK, shallow or unshallow line, and the bytes of pack data or
    progress."""

    var kind: Int
    var id: ObjectId
    var data: List[UInt8]

    def __init__(out self, kind: Int, id: ObjectId, var data: List[UInt8]):
        self.kind = kind
        self.id = id
        self.data = data^


struct ServerCapabilities(Copyable, Movable):
    """The capability lines of a v2 advertisement (`key` or `key=value`),
    in order. `complete` is False when the advertisement is not all in."""

    var lines: List[String]
    var complete: Bool

    def __init__(out self):
        self.lines = List[String]()
        self.complete = False

    def supports(self, key: String) -> Bool:
        """The server advertised `key`, with or without a value."""
        for i in range(len(self.lines)):
            if self.lines[i] == key or self.lines[i].startswith(key + "="):
                return True
        return False

    def value(self, key: String) -> Optional[String]:
        """The value of `key=value`, None when `key` has none."""
        for i in range(len(self.lines)):
            if self.lines[i].startswith(key + "="):
                var s = self.lines[i]
                return String(s[byte=key.byte_length() + 1 : s.byte_length()])
        return None

    def supports_feature(self, key: String, feature: String) -> Bool:
        """`feature` is one of the space-separated words of `key`'s value
        (`fetch=shallow wait-for-done` has `shallow`)."""
        var v = self.value(key)
        if not v:
            return False
        var words = v.value().split(" ")
        for i in range(len(words)):
            if String(words[i]) == feature:
                return True
        return False


struct LsRefsResult(Movable):
    """The refs of an ls-refs response, HEAD included as `HEAD`, and the
    branch an unborn HEAD points at ("" when none was listed). `complete`
    is False when the response is not all in."""

    var refs: List[AdvertisedRef]
    var unborn_head_target: String
    var complete: Bool

    def __init__(out self):
        self.refs = List[AdvertisedRef]()
        self.unborn_head_target = String()
        self.complete = False


struct FetchV2Client(Movable):
    """The client side of one protocol v2 session."""

    var agent: String
    var format: ObjectFormat
    var capabilities: ServerCapabilities
    var _reader: PktReader
    var _state: Int
    var _ready: Bool
    var _seen_shallow: Bool

    def __init__(out self, agent: String, format: ObjectFormat) raises:
        """A client for repositories of `format` that names itself `agent`
        (printable ASCII without spaces)."""
        _check_agent(agent)
        self.agent = agent
        self.format = format
        self.capabilities = ServerCapabilities()
        self._reader = PktReader()
        self._state = _ST_IDLE
        self._ready = False
        self._seen_shallow = False

    def feed(mut self, data: Span[UInt8, _]):
        """Append bytes the server sent."""
        self._reader.feed(data)

    def read_advertisement(mut self) raises -> Bool:
        """Read the capability advertisement into `capabilities`; False
        (nothing consumed) when it is not all in."""
        var mark = self._reader.mark()
        var caps = ServerCapabilities()
        var first = True
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                self._reader.rewind(mark)
                return False
            if line.kind == PKT_FLUSH and not first:
                break
            if line.kind != PKT_DATA:
                raise Error("komira_git: fetch: bad capability advertisement")
            var text = _pkt_text(line, "capability advertisement")
            if first:
                if text != "version 2":
                    raise Error(
                        "komira_git: fetch: expected 'version 2', got '" + text + "'"
                    )
                first = False
                continue
            caps.lines.append(text)
        caps.complete = True
        self.capabilities = caps^
        return True

    def _server_names_format(self) raises -> Bool:
        """True when the server advertised `object-format`, which must then
        be this client's; without it, the format is sha1 (connect.c)."""
        var algo = self.capabilities.value("object-format")
        if algo:
            var name = algo.value()
            if name != "sha1" and name != "sha256":
                raise Error(
                    "komira_git: fetch: unknown object format '" + name
                    + "' specified by server"
                )
            if name != self.format.name():
                raise Error(
                    "komira_git: fetch: mismatched algorithms: client "
                    + self.format.name() + "; server " + name
                )
            return True
        if self.format.name() != "sha1":
            raise Error(
                "komira_git: fetch: the server does not support algorithm '"
                + self.format.name() + "'"
            )
        return False

    def _append_agent(self, mut out: List[UInt8]) raises:
        if self.capabilities.supports("agent"):
            _text_pkt(out, "agent=" + self.agent)

    def _append_server_options(
        self, mut out: List[UInt8], server_options: List[String]
    ) raises:
        if len(server_options) == 0:
            return
        if not self.capabilities.supports("server-option"):
            raise Error("komira_git: fetch: server doesn't support 'server-option'")
        for i in range(len(server_options)):
            _text_pkt(out, "server-option=" + server_options[i])

    def _require(self, command: String) raises:
        if not self.capabilities.complete:
            raise Error("komira_git: fetch: the advertisement has not been read")
        if not self.capabilities.supports(command):
            raise Error("komira_git: fetch: server doesn't support '" + command + "'")

    def append_ls_refs_request(
        self,
        mut out: List[UInt8],
        ref_prefixes: List[String],
        peel: Bool = True,
        server_options: List[String] = List[String](),
    ) raises:
        """An ls-refs request: `peel` (False for a push), `symrefs`,
        `unborn` when the server offers it, and one `ref-prefix` per entry
        of `ref_prefixes` (none lists every ref)."""
        self._require("ls-refs")
        _line_pkt(out, "command=ls-refs")
        self._append_agent(out)
        if self._server_names_format():
            _text_pkt(out, "object-format=" + self.format.name())
        self._append_server_options(out, server_options)
        append_pkt_delim(out)
        if peel:
            _line_pkt(out, "peel")
        _line_pkt(out, "symrefs")
        if self.capabilities.supports_feature("ls-refs", "unborn"):
            _line_pkt(out, "unborn")
        for i in range(len(ref_prefixes)):
            _line_pkt(out, "ref-prefix " + ref_prefixes[i])
        append_pkt_flush(out)

    def read_ls_refs(mut self) raises -> LsRefsResult:
        """The ls-refs response; `complete` False (nothing consumed) when it
        is not all in."""
        var mark = self._reader.mark()
        var result = LsRefsResult()
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                self._reader.rewind(mark)
                return LsRefsResult()
            if line.kind == PKT_FLUSH:
                break
            if line.kind != PKT_DATA:
                raise Error("komira_git: fetch: expected flush after ref listing")
            var text = _pkt_text(line, "ls-refs")
            self._parse_ref_line(text, result)
        result.complete = True
        return result^

    def _parse_ref_line(self, text: String, mut result: LsRefsResult) raises:
        var fields = text.split(" ")
        if len(fields) < 2:
            raise Error("komira_git: fetch: invalid ls-refs response: " + text)
        if fields[0] == "unborn":
            if fields[1] == "HEAD":
                for i in range(2, len(fields)):
                    if fields[i].startswith("symref-target:"):
                        var f = fields[i]
                        result.unborn_head_target = String(
                            f[byte=14 : f.byte_length()]
                        )
                        break
            return
        var id = _parse_id(self.format, String(fields[0]))
        if not id:
            raise Error("komira_git: fetch: invalid ls-refs response: " + text)
        var symref = String()
        var peeled: Optional[ObjectId] = None
        for i in range(2, len(fields)):
            var f = fields[i]
            if f.startswith("symref-target:"):
                symref = String(f[byte=14 : f.byte_length()])
            elif f.startswith("peeled:"):
                var p = _parse_id(self.format, String(f[byte=7 : f.byte_length()]))
                if not p:
                    raise Error("komira_git: fetch: invalid ls-refs response: " + text)
                peeled = p.value()
        result.refs.append(
            AdvertisedRef(String(fields[1]), id.value(), symref, peeled)
        )

    def append_fetch_request(
        mut self,
        mut out: List[UInt8],
        args: FetchArgs,
        server_options: List[String] = List[String](),
    ) raises:
        """A fetch request for `args`, in fetch-pack.c's order; the client
        then reads the response with `next_event`."""
        self._require("fetch")
        if Bool(args.deepen_since) and args.deepen_since.value() < 0:
            raise Error(
                "komira_git: fetch: deepen-since "
                + String(args.deepen_since.value()) + " is before the epoch"
            )
        # Refused before anything is written to `out`.
        if args.asks_shallow() or args.deepen_relative:
            if not self.capabilities.supports_feature("fetch", "shallow"):
                raise Error("komira_git: fetch: Server does not support shallow requests")
        var names_format = self._server_names_format()
        _text_pkt(out, "command=fetch")
        self._append_agent(out)
        self._append_server_options(out, server_options)
        if names_format:
            _text_pkt(out, "object-format=" + self.format.name())
        append_pkt_delim(out)
        if args.thin_pack:
            _text_pkt(out, "thin-pack")
        if args.no_progress:
            _text_pkt(out, "no-progress")
        if args.include_tag:
            _text_pkt(out, "include-tag")
        if args.ofs_delta:
            _text_pkt(out, "ofs-delta")
        if args.wait_for_done:
            _text_pkt(out, "wait-for-done")
        if args.asks_shallow() or args.deepen_relative:
            for i in range(len(args.shallows)):
                _text_pkt(out, "shallow " + args.shallows[i].to_hex())
            if args.deepen > 0:
                _text_pkt(out, "deepen " + String(args.deepen))
            if args.deepen_since:
                _text_pkt(out, "deepen-since " + String(args.deepen_since.value()))
            for i in range(len(args.deepen_not)):
                _text_pkt(out, "deepen-not " + args.deepen_not[i])
            if args.deepen_relative:
                _line_pkt(out, "deepen-relative")
        for i in range(len(args.wants)):
            _line_pkt(out, "want " + args.wants[i].to_hex())
        for i in range(len(args.haves)):
            _line_pkt(out, "have " + args.haves[i].to_hex())
        if args.done:
            _line_pkt(out, "done")
        append_pkt_flush(out)
        self._state = _ST_SECTION if args.done else _ST_ACK_HEADER
        self._ready = False
        self._seen_shallow = False

    def next_event(mut self) raises -> FetchEvent:
        """The next event of the fetch response (`FETCH_*`)."""
        var none = ObjectId.zero(self.format)
        while True:
            if self._state == _ST_IDLE:
                raise Error("komira_git: fetch: no fetch response is expected")
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                return FetchEvent(FETCH_NEED_MORE, none, List[UInt8]())
            if self._state == _ST_PACK:
                if line.kind == PKT_FLUSH:
                    self._state = _ST_IDLE
                    return FetchEvent(FETCH_END, none, List[UInt8]())
                if line.kind != PKT_DATA or len(line.payload) == 0:
                    raise Error("komira_git: fetch: protocol error: no band designator")
                var band = Int(line.payload[0])
                var rest = _to_list(Span(line.payload), 1, len(line.payload))
                if band == 1:
                    return FetchEvent(FETCH_PACK_DATA, none, rest^)
                if band == 2:
                    return FetchEvent(FETCH_PROGRESS, none, rest^)
                if band == 3:
                    raise Error(
                        "komira_git: fetch: remote error: "
                        + _utf8(Span(rest), 0, len(rest), "fetch")
                    )
                raise Error("komira_git: fetch: protocol error: bad band #" + String(band))
            if self._state == _ST_ACK_HEADER:
                self._expect_header(line, "acknowledgments")
                self._state = _ST_ACKS
                continue
            if self._state == _ST_ACKS:
                if line.kind == PKT_FLUSH:
                    if self._ready:
                        raise Error("komira_git: fetch: expected packfile to be sent after 'ready'")
                    self._state = _ST_IDLE
                    return FetchEvent(FETCH_ROUND_END, none, List[UInt8]())
                if line.kind == PKT_DELIM:
                    if not self._ready:
                        raise Error(
                            "komira_git: fetch: expected no other sections to be sent after no 'ready'"
                        )
                    self._state = _ST_SECTION
                    continue
                if line.kind != PKT_DATA:
                    raise Error("komira_git: fetch: bad acknowledgments section")
                var text = _pkt_text(line, "fetch")
                if text == "NAK":
                    return FetchEvent(FETCH_NAK, none, List[UInt8]())
                if text == "ready":
                    self._ready = True
                    return FetchEvent(FETCH_READY, none, List[UInt8]())
                if text.startswith("ACK "):
                    var id = _parse_id(self.format, String(text[byte=4 : text.byte_length()]))
                    if id:
                        return FetchEvent(FETCH_ACK, id.value(), List[UInt8]())
                raise Error("komira_git: fetch: unexpected acknowledgment line: '" + text + "'")
            if self._state == _ST_SECTION:
                if line.kind != PKT_DATA:
                    raise Error("komira_git: fetch: expected 'packfile'")
                var text = _pkt_text(line, "fetch")
                if text == "shallow-info" and not self._seen_shallow:
                    self._seen_shallow = True
                    self._state = _ST_SHALLOW
                    continue
                if text == "packfile":
                    self._state = _ST_PACK
                    continue
                raise Error(
                    "komira_git: fetch: expected 'packfile', received '" + text + "'"
                )
            # _ST_SHALLOW
            if line.kind == PKT_DELIM:
                self._state = _ST_SECTION
                continue
            if line.kind != PKT_DATA:
                raise Error("komira_git: fetch: expected 'packfile'")
            var text = _pkt_text(line, "fetch")
            if text.startswith("shallow "):
                var id = _parse_id(self.format, String(text[byte=8 : text.byte_length()]))
                if not id:
                    raise Error("komira_git: fetch: invalid shallow line: " + text)
                return FetchEvent(FETCH_SHALLOW, id.value(), List[UInt8]())
            if text.startswith("unshallow "):
                var id = _parse_id(self.format, String(text[byte=10 : text.byte_length()]))
                if not id:
                    raise Error("komira_git: fetch: invalid unshallow line: " + text)
                return FetchEvent(FETCH_UNSHALLOW, id.value(), List[UInt8]())
            raise Error("komira_git: fetch: expected shallow/unshallow, got " + text)

    def _expect_header(self, line: PktLine, section: String) raises:
        if line.kind != PKT_DATA:
            raise Error("komira_git: fetch: expected '" + section + "'")
        var text = _pkt_text(line, "fetch")
        if text != section:
            raise Error(
                "komira_git: fetch: expected '" + section + "', received '" + text + "'"
            )
