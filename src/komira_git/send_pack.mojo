# =============================================================================
# komira_git/send_pack.mojo -- the client half of a push (gitprotocol-pack;
# send-pack.c): reading receive-pack's ref advertisement, writing the
# commands, and reading the report-status.
# =============================================================================
#
# `SendPackClient` is sans-I/O, like the other state machines here. The
# command request is byte for byte what git's client writes for the same
# push: the capabilities follow a NUL on the first command and start with a
# space, the command lines end without an LF, push options follow a flush
# of their own. The packfile, when one is needed, is the caller's to append
# after the request.
# =============================================================================

from .bytes_util import _append_str
from .object_id import ObjectFormat, ObjectId
from .pkt_line import (
    PKT_DATA,
    PKT_FLUSH,
    PKT_NEED_MORE,
    PktLine,
    append_pkt_data,
    append_pkt_flush,
    read_pkt_line,
)
from .pkt_stream import PktReader, _pkt_text, _utf8
from .protocol_types import AdvertisedRef, _check_agent, _parse_id, _text_pkt
from .receive_pack import PushCommand


struct PushAdvertisement(Copyable, Movable):
    """receive-pack's advertisement: its refs (no `capabilities^{}`, no
    `.have`), its capability words, and the shallow commits it listed.
    `complete` is False while it is not all in."""

    var refs: List[AdvertisedRef]
    var capabilities: List[String]
    var shallows: List[ObjectId]
    var complete: Bool

    def __init__(out self):
        self.refs = List[AdvertisedRef]()
        self.capabilities = List[String]()
        self.shallows = List[ObjectId]()
        self.complete = False

    def supports(self, name: String) -> Bool:
        """The server listed `name` (with or without a value)."""
        for i in range(len(self.capabilities)):
            if self.capabilities[i] == name or self.capabilities[i].startswith(name + "="):
                return True
        return False

    def value(self, name: String) -> Optional[String]:
        """The value of `name=value`, None without one."""
        for i in range(len(self.capabilities)):
            var c = self.capabilities[i]
            if c.startswith(name + "="):
                return String(c[byte=name.byte_length() + 1 : c.byte_length()])
        return None


struct PushStatus(Copyable, Movable):
    """The report-status of a push: the unpack status (`ok` or the error),
    each ref's result in the order reported (`reasons` is "" for `ok`), and
    the band-2 messages that came with it. `complete` is False while the
    report is not all in."""

    var unpack_status: String
    var ref_names: List[String]
    var reasons: List[String]
    var messages: List[String]
    var complete: Bool

    def __init__(out self):
        self.unpack_status = String()
        self.ref_names = List[String]()
        self.reasons = List[String]()
        self.messages = List[String]()
        self.complete = False


struct SendPackClient(Movable):
    """The client side of one push."""

    var agent: String
    var format: ObjectFormat
    var advertisement: PushAdvertisement
    var _reader: PktReader
    var _side_band: Bool

    def __init__(out self, agent: String, format: ObjectFormat) raises:
        _check_agent(agent)
        self.agent = agent
        self.format = format
        self.advertisement = PushAdvertisement()
        self._reader = PktReader()
        self._side_band = False

    def feed(mut self, data: Span[UInt8, _]):
        """Append bytes the server sent."""
        self._reader.feed(data)

    def read_advertisement(mut self) raises -> Bool:
        """Read the ref advertisement into `advertisement`; False (nothing
        consumed) when it is not all in. A leading `version 1` line is
        accepted, and an `ERR` line is raised as the server's error."""
        var mark = self._reader.mark()
        var adv = PushAdvertisement()
        var first = True
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                self._reader.rewind(mark)
                return False
            if line.kind == PKT_FLUSH:
                break
            if line.kind != PKT_DATA:
                raise Error("komira_git: push: bad ref advertisement")
            ref p = line.payload
            var nul = -1
            for i in range(len(p)):
                if p[i] == 0:
                    nul = i
                    break
            var end = len(p) if nul < 0 else nul
            if end > 0 and p[end - 1] == 10:
                end -= 1
            var text = _utf8(Span(p), 0, end, "push")
            if text.startswith("ERR "):
                raise Error(
                    "komira_git: push: remote error: "
                    + String(text[byte=4 : text.byte_length()])
                )
            if first and text == "version 1":
                first = False
                continue
            if nul >= 0 and len(adv.capabilities) == 0:
                var cend = len(p)
                if cend > nul + 1 and p[cend - 1] == 10:
                    cend -= 1
                var caps = _utf8(Span(p), nul + 1, cend, "push").split(" ")
                for i in range(len(caps)):
                    if caps[i].byte_length() > 0:
                        adv.capabilities.append(String(caps[i]))
            first = False
            if text.startswith("shallow "):
                var id = _parse_id(self.format, String(text[byte=8 : text.byte_length()]))
                if not id:
                    raise Error("komira_git: push: protocol error: bad shallow line: " + text)
                adv.shallows.append(id.value())
                continue
            var hs = self.format.hex_size()
            if text.byte_length() < hs + 2 or text.as_bytes()[hs] != 32:
                raise Error("komira_git: push: protocol error: bad ref line: " + text)
            var id = _parse_id(self.format, String(text[byte=0:hs]))
            if not id:
                raise Error("komira_git: push: protocol error: bad ref line: " + text)
            var name = String(text[byte=hs + 1 : text.byte_length()])
            if name == "capabilities^{}" or name == ".have":
                continue
            adv.refs.append(AdvertisedRef(name, id.value()))
        adv.complete = True
        self.advertisement = adv^
        return True

    def append_push_request(
        mut self,
        mut out: List[UInt8],
        commands: List[PushCommand],
        atomic: Bool = False,
        quiet: Bool = True,
        push_options: List[String] = List[String](),
    ) raises:
        """The commands of a push, as send-pack.c writes them: report-status
        (v2 when offered), side-band-64k and quiet when offered (quiet when
        asked), atomic and push-options when asked (refused when not
        offered), object-format and agent, then the flush. A delete needs
        the server's `delete-refs`. The caller appends the pack after this
        when any command is not a delete."""
        ref adv = self.advertisement
        if not adv.complete:
            raise Error("komira_git: push: the advertisement has not been read")
        if atomic and not adv.supports("atomic"):
            raise Error("komira_git: push: the receiving end does not support --atomic push")
        if len(push_options) > 0 and not adv.supports("push-options"):
            raise Error("komira_git: push: the receiving end does not support push options")
        var algo = adv.value("object-format")
        if algo:
            if algo.value() != self.format.name():
                raise Error(
                    "komira_git: push: the receiving end does not support this repository's hash algorithm"
                )
        elif adv.supports("object-format") or self.format.name() != "sha1":
            raise Error(
                "komira_git: push: the receiving end does not support this repository's hash algorithm"
            )
        var caps = String()
        if adv.supports("report-status-v2"):
            caps += " report-status-v2"
        elif adv.supports("report-status"):
            caps += " report-status"
        self._side_band = adv.supports("side-band-64k")
        if self._side_band:
            caps += " side-band-64k"
        if quiet and adv.supports("quiet"):
            caps += " quiet"
        if atomic:
            caps += " atomic"
        if len(push_options) > 0:
            caps += " push-options"
        if algo:
            caps += " object-format=" + self.format.name()
        if adv.supports("agent"):
            caps += " agent=" + self.agent
        for i in range(len(commands)):
            ref c = commands[i]
            if c.is_delete() and not adv.supports("delete-refs"):
                raise Error(
                    "komira_git: push: remote does not support deleting refs: "
                    + c.ref_name
                )
            var line = c.old_id.to_hex() + " " + c.new_id.to_hex() + " " + c.ref_name
            if i == 0:
                var b = List[UInt8]()
                _append_str(b, line)
                b.append(0)
                _append_str(b, caps)
                append_pkt_data(out, Span(b))
            else:
                _text_pkt(out, line)
        if len(push_options) > 0:
            append_pkt_flush(out)
            for i in range(len(push_options)):
                _text_pkt(out, push_options[i])
        append_pkt_flush(out)

    def read_status(mut self) raises -> PushStatus:
        """The report-status (demultiplexed from band 1 when side-band-64k
        is in use); `complete` False (nothing consumed) when it is not all
        in. A band-3 message is raised as the server's error."""
        var mark = self._reader.mark()
        var status = PushStatus()
        var body = List[UInt8]()
        if self._side_band:
            while True:
                var line = self._reader.read()
                if line.kind == PKT_NEED_MORE:
                    self._reader.rewind(mark)
                    return PushStatus()
                if line.kind == PKT_FLUSH:
                    break
                if line.kind != PKT_DATA or len(line.payload) == 0:
                    raise Error("komira_git: push: protocol error: no band designator")
                var band = Int(line.payload[0])
                if band == 1:
                    for i in range(1, len(line.payload)):
                        body.append(line.payload[i])
                elif band == 2:
                    var n = len(line.payload)
                    if n > 1 and line.payload[n - 1] == 10:
                        n -= 1
                    status.messages.append(_utf8(Span(line.payload), 1, n, "push"))
                elif band == 3:
                    raise Error(
                        "komira_git: push: remote error: "
                        + _utf8(Span(line.payload), 1, len(line.payload), "push")
                    )
                else:
                    raise Error("komira_git: push: protocol error: bad band #" + String(band))
            _parse_report(Span(body), status, True)
        else:
            while True:
                var line = self._reader.read()
                if line.kind == PKT_NEED_MORE:
                    self._reader.rewind(mark)
                    return PushStatus()
                _append_line_to(body, line)
                if line.kind == PKT_FLUSH:
                    break
            _parse_report(Span(body), status, False)
        status.complete = True
        return status^


def _append_line_to(mut out: List[UInt8], line: PktLine) raises:
    """Re-frame `line` into `out` (a flush or a data line)."""
    if line.kind == PKT_FLUSH:
        append_pkt_flush(out)
    else:
        append_pkt_data(out, Span(line.payload))


def _parse_report(body: Span[UInt8, _], mut status: PushStatus, framed: Bool) raises:
    """`unpack <status>` then `ok <ref>` / `ng <ref> <reason>` (and the
    `option` lines of report-status-v2, which are skipped) to a flush."""
    var pos = 0
    var first = True
    while True:
        var line = read_pkt_line(body, pos)
        if line.kind == PKT_NEED_MORE:
            raise Error("komira_git: push: the report-status ends early")
        pos += line.consumed
        if line.kind == PKT_FLUSH:
            if first:
                raise Error("komira_git: push: unexpected flush packet while reading remote unpack status")
            break
        if line.kind != PKT_DATA:
            raise Error("komira_git: push: bad report-status")
        var text = _pkt_text(line, "push")
        if first:
            if not text.startswith("unpack "):
                raise Error("komira_git: push: unable to parse remote unpack status: " + text)
            status.unpack_status = String(text[byte=7 : text.byte_length()])
            first = False
            continue
        if text.startswith("ok "):
            status.ref_names.append(String(text[byte=3 : text.byte_length()]))
            status.reasons.append(String())
        elif text.startswith("ng "):
            var rest = String(text[byte=3 : text.byte_length()])
            var sp = rest.find(" ")
            if sp < 0:
                status.ref_names.append(rest)
                status.reasons.append(String("failed"))
            else:
                status.ref_names.append(String(rest[byte=0:sp]))
                status.reasons.append(String(rest[byte=sp + 1 : rest.byte_length()]))
        elif text.startswith("option "):
            continue
        else:
            raise Error("komira_git: push: invalid status line from remote: " + text)
    if pos != len(body) and framed:
        raise Error("komira_git: push: bytes after the report-status")
