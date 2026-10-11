# =============================================================================
# komira_git/receive_pack.mojo -- the server half of a push
# (gitprotocol-pack, "Pushing Data To a Server"; builtin/receive-pack.c).
# Push is protocol v0 even when the client asks for v2: protocol v2 defines
# no push command, and git's receive-pack answers a v2 client in v0 too.
# =============================================================================
#
# `ReceivePackServer` is sans-I/O: it writes the ref advertisement, reads
# the client's commands (and push options) as they are fed, and once they
# are all in hands back the input that follows them, which is the packfile
# when any command creates or updates a ref. The caller unpacks it and
# decides each command; `PushReport` collects those verdicts and writes the
# report-status git's client reads. `reject` takes the verdicts git's
# update() makes (non-fast-forward, funny refname, an update hook's
# refusal), and for those git's rules hold:
#   - an unpack failure fails every command with `unpacker error` (git
#     reports it before any update runs, atomic or not);
#   - in an atomic push, the first refused command (in command order)
#     keeps its reason and every other command, refused or not, reports
#     `atomic push failure` (git stops at the first update() that fails).
# One difference from git: git makes some refusals before update() runs
# (a hidden ref, missing objects, a pre-receive hook's decline,
# inconsistent push options). For those, git keeps each refused command's
# own reason and, in an atomic push, still applies the other commands.
# Given to `reject`, such a refusal fails the whole atomic push here: the
# first refused command keeps its reason and every other one reports
# `atomic push failure`.
# `refuse_funny_refnames` applies the one verdict that needs no repository:
# a ref outside `refs/`, or one `git check-ref-format` refuses (one level
# allowed for a delete), is `funny refname`.
#
# Advertised, as git advertises them by default:
#   report-status report-status-v2 delete-refs side-band-64k quiet atomic
#   ofs-delta [push-options] object-format=<format> agent=<agent>
# `atomic` and `push-options` are switches of `ReceivePackConfig`
# (receive.advertiseAtomic, receive.advertisePushOptions). The report is the
# same bytes for report-status and report-status-v2: the v2 form adds
# `option` lines only for refs a proc-receive hook rewrote, and there is
# none here. `ofs-delta` promises that the caller's pack reader accepts
# OFS_DELTA entries. `quiet` asks for no progress, and this server writes
# none. A push certificate (`push-cert`) is not advertised and is refused
# with this module's own message; git's receive-pack would read an
# unsolicited one.
#
# Each command, shallow and push-option line loses one trailing LF (only
# one) before it is read, as git reads them with PACKET_READ_CHOMP_NEWLINE
# (git's send-pack writes none; libgit2 ends each command line with one).
# =============================================================================

from .bytes_util import _append_str
from .object_id import ObjectFormat, ObjectId
from .pkt_line import PKT_DATA, PKT_FLUSH, PKT_NEED_MORE, append_pkt_data, append_pkt_flush
from .pkt_stream import (
    SIDEBAND_DATA,
    SIDEBAND_PROGRESS,
    PktReader,
    _utf8,
    append_sideband,
)
from .protocol_types import (
    AdvertisedRef,
    _check_agent,
    _line_pkt,
    _parse_id,
    _sorted_by_name,
)
from .ref_name import check_ref_format

comptime ATOMIC_PUSH_FAILURE = "atomic push failure"
"""The reason every other command of a failed atomic push reports."""
comptime UNPACKER_ERROR = "unpacker error"
"""The reason every command reports when the pack did not unpack."""
comptime FUNNY_REFNAME = "funny refname"
"""The reason for a ref name receive-pack will not update."""


struct ReceivePackConfig(Copyable, Movable):
    """What a receive-pack server advertises: its agent string (printable
    ASCII without spaces), the object format of its repositories, and
    whether it offers `atomic` and `push-options`."""

    var agent: String
    var format: ObjectFormat
    var atomic: Bool
    var push_options: Bool

    def __init__(
        out self,
        agent: String,
        format: ObjectFormat,
        atomic: Bool = True,
        push_options: Bool = False,
    ) raises:
        _check_agent(agent)
        self.agent = agent
        self.format = format
        self.atomic = atomic
        self.push_options = push_options

    def capability_list(self) -> String:
        """The capabilities, space-separated, as the first ref line holds
        them after its NUL."""
        var caps = String(
            "report-status report-status-v2 delete-refs side-band-64k quiet"
        )
        if self.atomic:
            caps += " atomic"
        caps += " ofs-delta"
        if self.push_options:
            caps += " push-options"
        caps += " object-format=" + self.format.name()
        caps += " agent=" + self.agent
        return caps^


struct PushCommand(Copyable, Movable):
    """One ref update: the value the client saw, the value it sends (the
    null id deletes) and the ref."""

    var old_id: ObjectId
    var new_id: ObjectId
    var ref_name: String

    def __init__(out self, old_id: ObjectId, new_id: ObjectId, ref_name: String):
        self.old_id = old_id
        self.new_id = new_id
        self.ref_name = ref_name

    def is_delete(self) -> Bool:
        return self.new_id.is_zero()

    def is_create(self) -> Bool:
        return self.old_id.is_zero()


struct PushRequest(Copyable, Movable):
    """The commands of a push and what the client asked for with them
    (`agent` and `object_format` are "" when not sent). `complete` is False
    while the commands are not all in."""

    var commands: List[PushCommand]
    var shallows: List[ObjectId]
    var push_options: List[String]
    var report_status: Bool
    var report_status_v2: Bool
    var side_band: Bool
    var quiet: Bool
    var atomic: Bool
    var use_push_options: Bool
    var agent: String
    var object_format: String
    var complete: Bool

    def __init__(out self):
        self.commands = List[PushCommand]()
        self.shallows = List[ObjectId]()
        self.push_options = List[String]()
        self.report_status = False
        self.report_status_v2 = False
        self.side_band = False
        self.quiet = False
        self.atomic = False
        self.use_push_options = False
        self.agent = String()
        self.object_format = String()
        self.complete = False

    def needs_pack(self) -> Bool:
        """A pack follows unless every command deletes (a push of only
        deletes sends none)."""
        for i in range(len(self.commands)):
            if not self.commands[i].is_delete():
                return True
        return False


def append_receive_pack_advertisement(
    mut out: List[UInt8], config: ReceivePackConfig, refs: List[AdvertisedRef]
) raises:
    """The ref advertisement: every ref in name order, the capabilities on
    the first line (on `capabilities^{}` with the null id when there are no
    refs), then a flush. Symbolic refs and peeled values are not listed
    (receive-pack lists neither)."""
    var order = _sorted_by_name(refs)
    var caps = config.capability_list()
    for k in range(len(order)):
        ref r = refs[order[k]]
        if r.is_unborn():
            raise Error("komira_git: receive-pack: ref '" + r.name + "' names no object")
        if k == 0:
            _first_line(out, r.id.to_hex(), r.name, caps)
        else:
            _line_pkt(out, r.id.to_hex() + " " + r.name)
    if len(order) == 0:
        _first_line(out, ObjectId.zero(config.format).to_hex(), "capabilities^{}", caps)
    append_pkt_flush(out)


def _first_line(mut out: List[UInt8], hex: String, name: String, caps: String) raises:
    var b = List[UInt8]()
    _append_str(b, hex + " " + name)
    b.append(0)
    _append_str(b, caps)
    b.append(10)
    append_pkt_data(out, Span(b))


def _has_word(words_text: String, word: String) -> Bool:
    """`word` is one of the space-separated words of `words_text`."""
    var words = words_text.split(" ")
    for i in range(len(words)):
        if String(words[i]) == word:
            return True
    return False


def _word_value(words_text: String, key: String) -> Optional[String]:
    """The value of the `key=value` word of `words_text`, None without one."""
    var words = words_text.split(" ")
    for i in range(len(words)):
        var w = String(words[i])
        if w.startswith(key + "="):
            return String(w[byte=key.byte_length() + 1 : w.byte_length()])
    return None


struct ReceivePackServer(Movable):
    """The request side of one push."""

    var config: ReceivePackConfig
    var _reader: PktReader

    def __init__(out self, var config: ReceivePackConfig):
        self.config = config^
        self._reader = PktReader()

    def append_advertisement(self, mut out: List[UInt8], refs: List[AdvertisedRef]) raises:
        """`append_receive_pack_advertisement` with this server's config."""
        append_receive_pack_advertisement(out, self.config, refs)

    def feed(mut self, data: Span[UInt8, _]):
        """Append bytes the client sent."""
        self._reader.feed(data)

    def read_request(mut self) raises -> PushRequest:
        """The commands and push options; `complete` False (nothing
        consumed) when they are not all in. A request with no commands is
        a client that had nothing to push: no pack follows and no report
        is written."""
        var mark = self._reader.mark()
        var req = PushRequest()
        var format = self.config.format
        while True:
            var line = self._reader.read()
            if line.kind == PKT_NEED_MORE:
                self._reader.rewind(mark)
                return PushRequest()
            if line.kind == PKT_FLUSH:
                break
            if line.kind != PKT_DATA:
                raise Error("komira_git: receive-pack: protocol error: expected old/new/ref")
            ref p = line.payload
            var n = _chomp_len(Span(p))
            var nul = -1
            for i in range(n):
                if p[i] == 0:
                    nul = i
                    break
            var end = n if nul < 0 else nul
            var text = _utf8(Span(p), 0, end, "receive-pack")
            if n > 8 and text.startswith("shallow "):
                var hex = String(text[byte=8 : text.byte_length()])
                var id = _parse_id(format, hex)
                if not id:
                    raise Error(
                        "komira_git: receive-pack: protocol error: expected shallow sha, got '"
                        + hex + "'"
                    )
                req.shallows.append(id.value())
                continue
            if nul >= 0:
                self._read_features(
                    _utf8(Span(p), nul + 1, n, "receive-pack"), req
                )
            if text == "push-cert":
                raise Error("komira_git: receive-pack: push certificates are not supported")
            req.commands.append(_parse_command(format, text))
        if req.use_push_options and len(req.commands) > 0:
            while True:
                var line = self._reader.read()
                if line.kind == PKT_NEED_MORE:
                    self._reader.rewind(mark)
                    return PushRequest()
                if line.kind != PKT_DATA:
                    break
                req.push_options.append(
                    _utf8(
                        Span(line.payload),
                        0,
                        _chomp_len(Span(line.payload)),
                        "push option",
                    )
                )
        req.complete = True
        return req^

    def _read_features(self, features: String, mut req: PushRequest) raises:
        if _has_word(features, "report-status"):
            req.report_status = True
        if _has_word(features, "report-status-v2"):
            req.report_status_v2 = True
        if _has_word(features, "side-band-64k"):
            req.side_band = True
        if _has_word(features, "quiet"):
            req.quiet = True
        if self.config.atomic and _has_word(features, "atomic"):
            req.atomic = True
        if self.config.push_options and _has_word(features, "push-options"):
            req.use_push_options = True
        var algo = _word_value(features, "object-format")
        if algo:
            req.object_format = algo.value()
        var name = algo.value() if algo else String("sha1")
        if name != self.config.format.name():
            raise Error(
                "komira_git: receive-pack: unsupported object format '" + name + "'"
            )
        var agent = _word_value(features, "agent")
        if agent:
            req.agent = agent.value()

    def take_buffered(mut self) -> List[UInt8]:
        """The input fed after the commands: the start of the packfile."""
        return self._reader.take_buffered()


@always_inline
def _chomp_len(p: Span[UInt8, _]) -> Int:
    """The length of `p` without one trailing LF."""
    var n = len(p)
    if n > 0 and p[n - 1] == 10:
        return n - 1
    return n


def _parse_command(format: ObjectFormat, text: String) raises -> PushCommand:
    """`<old> <new> <ref>`."""
    var hs = format.hex_size()
    var n = text.byte_length()
    var b = text.as_bytes()
    if n > 2 * hs + 2 and b[hs] == 32 and b[2 * hs + 1] == 32:
        var old = _parse_id(format, String(text[byte=0:hs]))
        var nw = _parse_id(format, String(text[byte=hs + 1 : 2 * hs + 1]))
        if old and nw:
            return PushCommand(
                old.value(), nw.value(), String(text[byte=2 * hs + 2 : n])
            )
    raise Error(
        "komira_git: receive-pack: protocol error: expected old/new/ref, got '"
        + text + "'"
    )


struct PushReport(Movable):
    """The verdict on each command of a push ("" accepts it) and on the
    unpack ("" is ok)."""

    var unpack_error: String
    var reasons: List[String]

    def __init__(out self, request: PushRequest):
        self.unpack_error = String()
        self.reasons = List[String]()
        for _ in range(len(request.commands)):
            self.reasons.append(String())

    def reject(mut self, index: Int, reason: String) raises:
        """Refuse command `index` with `reason` (no LF; the first reason
        given for a command stands). The atomic rule of `final_reasons` is
        git's for the refusals git's update() makes; see the module header
        for refusals git makes before update()."""
        if index < 0 or index >= len(self.reasons):
            raise Error("komira_git: push report: no command " + String(index))
        if reason.byte_length() == 0:
            raise Error("komira_git: push report: a refusal needs a reason")
        if self.reasons[index].byte_length() == 0:
            self.reasons[index] = reason

    def set_unpack_error(mut self, message: String) raises:
        """The pack did not unpack: `message` follows `unpack ` in the
        report, and every command fails."""
        if message.byte_length() == 0 or message == "ok":
            raise Error("komira_git: push report: an unpack error needs a message")
        self.unpack_error = message

    def refuse_funny_refnames(mut self, request: PushRequest) raises:
        """Refuse each command whose ref is not under `refs/` or fails `git
        check-ref-format` (one level allowed when it deletes)."""
        for i in range(len(request.commands)):
            ref c = request.commands[i]
            var funny = not c.ref_name.startswith("refs/")
            if not funny:
                try:
                    check_ref_format(
                        String(c.ref_name[byte=5 : c.ref_name.byte_length()]),
                        allow_onelevel=c.is_delete(),
                    )
                except e:
                    funny = True
            if funny:
                self.reject(i, String(FUNNY_REFNAME))

    def final_reasons(self, request: PushRequest) -> List[String]:
        """Each command's reason: all `unpacker error` when the pack failed
        (this wins over the atomic rule, as in git); in an atomic push with
        any refusal, the first refused command keeps its reason and every
        other one gets `atomic push failure`, as git's
        execute_commands_atomic stops at the first update() that fails. For
        a refusal git makes before update() (hidden ref, missing objects,
        pre-receive), git keeps every refused command's own reason and still
        applies the others; this fails the whole push instead."""
        var out = List[String]()
        var first_refused = -1
        for i in range(len(self.reasons)):
            if self.reasons[i].byte_length() > 0:
                first_refused = i
                break
        for i in range(len(self.reasons)):
            if self.unpack_error.byte_length() > 0:
                out.append(String(UNPACKER_ERROR))
            elif request.atomic and first_refused >= 0 and i != first_refused:
                out.append(String(ATOMIC_PUSH_FAILURE))
            elif self.reasons[i].byte_length() > 0:
                out.append(self.reasons[i])
            else:
                out.append(String())
        return out^

    def accepted(self, request: PushRequest) -> List[Bool]:
        """Which commands the caller may apply: none when the push fails
        as a whole, otherwise those not refused."""
        var reasons = self.final_reasons(request)
        var out = List[Bool]()
        for i in range(len(reasons)):
            out.append(reasons[i].byte_length() == 0)
        return out^


def append_push_message(mut out: List[UInt8], request: PushRequest, text: String) raises:
    """A message for the user (git's rp_error and rp_warning), on band 2 when
    the client asked for side-band-64k; without side-band nothing is written
    (git prints it on the server's stderr)."""
    if not request.side_band:
        return
    var b = List[UInt8]()
    _append_str(b, text)
    b.append(10)
    append_sideband(out, SIDEBAND_PROGRESS, Span(b))


def append_push_report(
    mut out: List[UInt8], request: PushRequest, report: PushReport
) raises:
    """The report-status for `request`: `unpack ok` or `unpack <error>`,
    then `ok <ref>` or `ng <ref> <reason>` per command, then a flush; inside
    band 1 followed by a flush when the client asked for side-band-64k.
    Nothing is reported to a client that asked for no report-status, and a
    request with no commands gets no response."""
    if len(request.commands) == 0:
        return
    if len(report.reasons) != len(request.commands):
        raise Error("komira_git: push report: the report is for another request")
    if request.report_status or request.report_status_v2:
        var body = List[UInt8]()
        var unpack = report.unpack_error if report.unpack_error.byte_length() > 0 else String("ok")
        _line_pkt(body, "unpack " + unpack)
        var reasons = report.final_reasons(request)
        for i in range(len(request.commands)):
            if reasons[i].byte_length() == 0:
                _line_pkt(body, "ok " + request.commands[i].ref_name)
            else:
                _line_pkt(
                    body, "ng " + request.commands[i].ref_name + " " + reasons[i]
                )
        append_pkt_flush(body)
        if request.side_band:
            append_sideband(out, SIDEBAND_DATA, Span(body))
        else:
            for i in range(len(body)):
                out.append(body[i])
    if request.side_band:
        append_pkt_flush(out)
