# =============================================================================
# komira_git/upload_pack_v2.mojo -- the server half of git protocol v2
# (gitprotocol-v2): the capability advertisement, the reading of a command
# request, and the ls-refs response.
# =============================================================================
#
# `UploadPackV2Server` is sans-I/O. The caller writes the advertisement,
# feeds what the client sends and asks for the next complete request; a
# request is read whole or not at all, so a short read returns
# `V2_NEED_MORE` and consumes nothing. Over a connection (file://, ssh) one
# server reads requests until the client sends a lone flush (`V2_END`);
# over smart HTTP each POST body is one request.
#
# The advertisement is git's own default one:
#   agent=<agent>, ls-refs=unborn, fetch=shallow wait-for-done,
#   server-option, object-format=<format>
# A request naming a feature not advertised is refused with git's words
# for it (serve.c, ls-refs.c, upload-pack.c): `filter`, `want-ref`,
# `sideband-all` and `packfile-uris` are "unexpected line", and the
# `session-id`, `object-info`, `bundle-uri` and `promisor-remote`
# capabilities are unknown.
#
# `shallow` promises the shallow arguments `shallow`, `deepen`,
# `deepen-relative`, `deepen-since` and `deepen-not`, and all are read into
# `FetchArgs`; which commits they cut is the caller's to compute (a
# `deepen-not` ref is passed on as sent, for the repository to resolve).
#
# Two deliberate differences from git:
#   - `deepen <n>` and `deepen-since <timestamp>` take a plain decimal (no
#     sign, no leading zero; at most 2147483647 and 2^63-1). git reads them
#     with strtol and strtoumax, so it would also take `0x10`, octal `010`
#     or an empty `deepen-since `; git's own client writes `%d` and a
#     decimal timestamp;
#   - `deepen` with `deepen-since` or `deepen-not` is refused with git's
#     words when the request is read; git refuses it only when it would
#     send the shallow-info, so a negotiation round without `done` is
#     answered first.
# =============================================================================

from .object_id import ObjectFormat, ObjectId
from .pkt_line import (
    PKT_DATA,
    PKT_DELIM,
    PKT_FLUSH,
    PKT_NEED_MORE,
    PKT_RESPONSE_END,
    append_pkt_flush,
)
from .pkt_stream import PktReader, _pkt_text
from .protocol_types import (
    AdvertisedRef,
    FetchArgs,
    LsRefsArgs,
    _check_agent,
    _line_pkt,
    _parse_id,
    _sorted_by_name,
)

comptime V2_NEED_MORE: Int = -1
"""`next_request` needs more input."""
comptime V2_END: Int = 0
"""The client ended the session (a flush with no command)."""
comptime V2_LS_REFS: Int = 1
"""An ls-refs command."""
comptime V2_FETCH: Int = 2
"""A fetch command."""

comptime _TOO_MANY_PREFIXES: Int = 65536
comptime _MAX_DEEPEN: Int = 2147483647


struct V2Request(Copyable, Movable):
    """One protocol v2 request: its command (`V2_*`), the capabilities the
    client sent with it, and the command's arguments (`ls_refs` or `fetch`,
    by `command`). `agent` and `object_format` are "" when not sent."""

    var command: Int
    var agent: String
    var object_format: String
    var server_options: List[String]
    var ls_refs: LsRefsArgs
    var fetch: FetchArgs

    def __init__(out self, command: Int):
        self.command = command
        self.agent = String()
        self.object_format = String()
        self.server_options = List[String]()
        self.ls_refs = LsRefsArgs()
        self.fetch = FetchArgs()


struct UploadPackV2Server(Movable):
    """The request side of one protocol v2 session (or one HTTP request)."""

    var agent: String
    var format: ObjectFormat
    var _reader: PktReader

    def __init__(out self, agent: String, format: ObjectFormat) raises:
        """A server for repositories of `format` that names itself `agent`
        (printable ASCII without spaces, such as `komira-git/1`)."""
        _check_agent(agent)
        self.agent = agent
        self.format = format
        self._reader = PktReader()

    def append_advertisement(self, mut out: List[UInt8]) raises:
        """The capability advertisement: what a server writes first on a
        connection, and the body of `GET .../info/refs?service=git-upload-pack`
        (after the HTTP layer's own `# service=` line)."""
        _line_pkt(out, "version 2")
        _line_pkt(out, "agent=" + self.agent)
        _line_pkt(out, "ls-refs=unborn")
        _line_pkt(out, "fetch=shallow wait-for-done")
        _line_pkt(out, "server-option")
        _line_pkt(out, "object-format=" + self.format.name())
        append_pkt_flush(out)

    def feed(mut self, data: Span[UInt8, _]):
        """Append bytes the client sent."""
        self._reader.feed(data)

    def next_request(mut self) raises -> V2Request:
        """The next complete request, consumed; command `V2_NEED_MORE` (with
        nothing consumed) when the input ends inside it."""
        var mark = self._reader.mark()
        var req = self._read_request()
        if req.command == V2_NEED_MORE:
            self._reader.rewind(mark)
        return req^

    def _read_request(mut self) raises -> V2Request:
        var req = V2Request(V2_NEED_MORE)
        var command = String()
        var seen = False
        var has_args = False
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                return V2Request(V2_NEED_MORE)
            if line.kind == PKT_FLUSH:
                if not seen:
                    return V2Request(V2_END)
                break
            if line.kind == PKT_DELIM:
                has_args = True
                break
            if line.kind == PKT_RESPONSE_END:
                raise Error("komira_git: upload-pack: unexpected response end packet")
            var key = _pkt_text(line, "upload-pack")
            if key.startswith("command="):
                var name = String(key[byte=8 : key.byte_length()])
                if command.byte_length() > 0:
                    raise Error(
                        "komira_git: upload-pack: command '" + name
                        + "' requested after already requesting command '"
                        + command + "'"
                    )
                if name != "ls-refs" and name != "fetch":
                    raise Error(
                        "komira_git: upload-pack: invalid command '" + name + "'"
                    )
                command = name
            elif key == "agent":
                pass
            elif key.startswith("agent="):
                req.agent = String(key[byte=6 : key.byte_length()])
            elif key == "server-option":
                pass
            elif key.startswith("server-option="):
                req.server_options.append(
                    String(key[byte=14 : key.byte_length()])
                )
            elif key == "object-format":
                raise Error(
                    "komira_git: upload-pack: object-format capability requires an argument"
                )
            elif key.startswith("object-format="):
                var algo = String(key[byte=14 : key.byte_length()])
                if algo != "sha1" and algo != "sha256":
                    raise Error(
                        "komira_git: upload-pack: unknown object format '"
                        + algo + "'"
                    )
                req.object_format = algo
            else:
                raise Error(
                    "komira_git: upload-pack: unknown capability '" + key + "'"
                )
            seen = True
        if command.byte_length() == 0:
            raise Error("komira_git: upload-pack: no command requested")
        var client_format = req.object_format
        if client_format.byte_length() == 0:
            client_format = "sha1"
        if client_format != self.format.name():
            raise Error(
                "komira_git: upload-pack: mismatched object format: server "
                + self.format.name() + "; client " + client_format
            )
        var complete = False
        if command == "ls-refs":
            req.command = V2_LS_REFS
            complete = self._read_ls_refs_args(req.ls_refs, has_args)
        else:
            req.command = V2_FETCH
            complete = self._read_fetch_args(req.fetch, has_args)
        if not complete:
            return V2Request(V2_NEED_MORE)
        return req^

    def _read_ls_refs_args(
        mut self, mut args: LsRefsArgs, has_args: Bool
    ) raises -> Bool:
        """The arguments after the delimiter, through the closing flush;
        False when the input ends first."""
        if not has_args:
            return True
        var count = 0
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                return False
            if line.kind == PKT_FLUSH:
                break
            if line.kind != PKT_DATA:
                raise Error(
                    "komira_git: upload-pack: expected flush after ls-refs arguments"
                )
            var arg = _pkt_text(line, "ls-refs")
            if arg == "peel":
                args.peel = True
            elif arg == "symrefs":
                args.symrefs = True
            elif arg == "unborn":
                args.unborn = True
            elif arg.startswith("ref-prefix "):
                count += 1
                if count < _TOO_MANY_PREFIXES:
                    args.ref_prefixes.append(
                        String(arg[byte=11 : arg.byte_length()])
                    )
            else:
                raise Error(
                    "komira_git: upload-pack: unexpected line: '" + arg + "'"
                )
        # git: as many prefixes as this or more means "no prefix filter".
        if count >= _TOO_MANY_PREFIXES:
            args.ref_prefixes.clear()
        return True

    def _read_fetch_args(
        mut self, mut args: FetchArgs, has_args: Bool
    ) raises -> Bool:
        if not has_args:
            return True
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                return False
            if line.kind == PKT_FLUSH:
                break
            if line.kind != PKT_DATA:
                raise Error(
                    "komira_git: upload-pack: expected flush after fetch arguments"
                )
            var arg = _pkt_text(line, "fetch")
            if arg.startswith("want "):
                var id = _parse_id(self.format, String(arg[byte=5 : arg.byte_length()]))
                if not id:
                    raise Error(
                        "komira_git: upload-pack: protocol error, expected to get oid, not '"
                        + arg + "'"
                    )
                args.wants.append(id.value())
            elif arg.startswith("have "):
                var hex = String(arg[byte=5 : arg.byte_length()])
                var id = _parse_id(self.format, hex)
                if not id:
                    raise Error(
                        "komira_git: upload-pack: expected SHA1 object, got '"
                        + hex + "'"
                    )
                args.haves.append(id.value())
            elif arg == "thin-pack":
                args.thin_pack = True
            elif arg == "ofs-delta":
                args.ofs_delta = True
            elif arg == "no-progress":
                args.no_progress = True
            elif arg == "include-tag":
                args.include_tag = True
            elif arg == "done":
                args.done = True
            elif arg == "wait-for-done":
                args.wait_for_done = True
            elif arg.startswith("shallow "):
                var id = _parse_id(self.format, String(arg[byte=8 : arg.byte_length()]))
                if not id:
                    raise Error(
                        "komira_git: upload-pack: invalid shallow line: " + arg
                    )
                args.shallows.append(id.value())
            elif arg.startswith("deepen "):
                args.deepen = _parse_deepen(arg)
            elif arg.startswith("deepen-since "):
                args.deepen_since = _parse_deepen_since(arg)
            elif arg.startswith("deepen-not "):
                if arg.byte_length() == 11:
                    raise Error(
                        "komira_git: upload-pack: deepen-not is not a ref: " + arg
                    )
                args.deepen_not.append(String(arg[byte=11 : arg.byte_length()]))
            elif arg == "deepen-relative":
                args.deepen_relative = True
            else:
                raise Error(
                    "komira_git: upload-pack: unexpected line: '" + arg + "'"
                )
        if args.deepen > 0 and (Bool(args.deepen_since) or len(args.deepen_not) > 0):
            raise Error(
                "komira_git: upload-pack: deepen and deepen-since (or deepen-not)"
                + " cannot be used together"
            )
        return True


def _parse_deepen(arg: String) raises -> Int:
    """The <n> of `deepen <n>`: 1 to 2147483647, plain decimal."""
    var b = arg.as_bytes()
    var n = 0
    var digits = len(b) - 7
    var ok = digits >= 1 and digits <= 10 and b[7] != 48
    if ok:
        for i in range(7, len(b)):
            if b[i] < 48 or b[i] > 57:
                ok = False
                break
            n = n * 10 + Int(b[i]) - 48
    if not ok or n > _MAX_DEEPEN:
        raise Error("komira_git: upload-pack: Invalid deepen: " + arg)
    return n


def _parse_deepen_since(arg: String) raises -> Int:
    """The <timestamp> of `deepen-since <timestamp>`: 0 to 2^63-1 seconds,
    plain decimal (no sign, no leading zero)."""
    comptime _MAX = "9223372036854775807"
    var b = arg.as_bytes()
    var digits = len(b) - 13
    var ok = digits >= 1 and digits <= 19 and (b[13] != 48 or digits == 1)
    var n = 0
    if ok:
        for i in range(13, len(b)):
            if b[i] < 48 or b[i] > 57:
                ok = False
                break
        if ok and digits == 19:
            ok = String(arg[byte=13 : len(b)]) <= String(_MAX)
    if ok:
        for i in range(13, len(b)):
            n = n * 10 + Int(b[i]) - 48
    else:
        raise Error("komira_git: upload-pack: Invalid deepen-since: " + arg)
    return n


def _prefix_match(prefixes: List[String], name: String) -> Bool:
    if len(prefixes) == 0:
        return True
    for i in range(len(prefixes)):
        if name.startswith(prefixes[i]):
            return True
    return False


def _append_ref_line(mut out: List[UInt8], args: LsRefsArgs, r: AdvertisedRef) raises:
    var line: String
    if r.is_unborn():
        line = "unborn " + r.name
    else:
        line = r.id.to_hex() + " " + r.name
    if args.symrefs and r.is_symref():
        line += " symref-target:" + r.symref_target
    if args.peel and not r.is_unborn() and r.has_peeled():
        line += " peeled:" + r.peeled.to_hex()
    _line_pkt(out, line)


def append_ls_refs_response(
    mut out: List[UInt8],
    args: LsRefsArgs,
    head: Optional[AdvertisedRef],
    refs: List[AdvertisedRef],
) raises:
    """The response to ls-refs `args` (ls-refs.c): HEAD first, then `refs`
    in name order, each kept when one of the request's prefixes starts its
    name (all when there are none), then a flush. `head` is the repository's
    HEAD (named `HEAD`), None when it resolves to nothing; an unborn HEAD is
    listed only when the client asked for `unborn` and `symrefs`. Every ref
    in `refs` is under `refs/` and names an object."""
    if head:
        var h = head.value().copy()
        if h.name != "HEAD":
            raise Error("komira_git: ls-refs: the head ref is named '" + h.name + "', not 'HEAD'")
        var send = not h.is_unborn() or (args.unborn and args.symrefs and h.is_symref())
        if send and _prefix_match(args.ref_prefixes, h.name):
            _append_ref_line(out, args, h)
    var order = _sorted_by_name(refs)
    for k in range(len(order)):
        var i = order[k]
        if not refs[i].name.startswith("refs/"):
            raise Error("komira_git: ls-refs: ref '" + refs[i].name + "' is not under refs/")
        if refs[i].is_unborn():
            raise Error("komira_git: ls-refs: ref '" + refs[i].name + "' names no object")
        if _prefix_match(args.ref_prefixes, refs[i].name):
            _append_ref_line(out, args, refs[i])
    append_pkt_flush(out)
