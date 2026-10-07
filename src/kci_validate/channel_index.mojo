# =============================================================================
# src/kci_validate/channel_index.mojo -- check 1, "channel": the channel's
#   index lists each file the release made, with its sha256, and serves those
#   bytes. Read anonymously, from this machine, before any container runs.
# =============================================================================
#
# For each subdir the pinned files live in:
#
#   GET <channel>/<subdir>/repodata.json, ANONYMOUS (no Authorization header,
#   no netrc: the request carries what `get_following_redirects` is given,
#   and it is given nothing), redirects followed under komira_http_client's
#   policy (prefix.dev answers 303 to a signed URL on another host).
#
# THE URL. The index is read at `<location>/<subdir>/repodata.json`, the
# location exactly as the channels file declares it, or the LOCAL channel
# `file:///<dir>` a validation-only run names (kci run --channel): the same
# reads, answered from that directory by `FileChannelTransport`
# (file_channel.mojo), and the same rows. For prefix.dev that is
# the web host (`https://prefix.dev/<org>/<channel>`); it answers the index
# path the same way `repo.prefix.dev` does: 303 to a signed URL on its
# package host once the subdir has an index, 404 before. The redirect target
# is followed but never written into a row or a log line (it is a one-time
# signed address, not the channel).
#
# THE WAIT. A registry indexes an upload a little after it lands, so only
# the ABSENCE of a file is waited for, up to `wait_s` seconds, polling every
# `WAIT_POLL_SECONDS`: an index that answers 404 (a subdir nothing was
# published to yet, or not indexed yet: prefix.dev took about 15 minutes to
# make a new subdir's first index), one that cannot be reached, or one that
# does not list every pinned file yet. Nothing else is waited for: a 401 or 403 ends the
# wait at once (the channel is not public), and so does a listed file whose
# sha256 is not the build's (another build of the same name, or other bytes:
# waiting cannot fix that). When the budget is spent, what was read last is
# judged, and an absent file or a 404 is a FAIL: FAIL CLOSED.
#
# Each read is a POLL, and each poll is one line on the `IndexPollLog`
# (stderr in the CLI), so a long wait shows its progress:
#
#   kci: channel index poll <n>: <index url> answered <answer>; waited <w> of <b> s
#
# where <answer> is `404`, `200[ after a redirect], lists <k> of <m> pinned
# files`, `could not be read` (no transport detail: it can name an address),
# and so on. The rows state the same: every index row's expected and got
# say `waited <w> of <b> s over <n> poll(s)`. <w> counts the seconds slept
# between polls.
#
# Then, for each index that answered 200, a passing row
#
#   channel: <url> answered 200[ after a redirect]; waited <w> of <b> s over <n> poll(s)
#
# and for each of its pinned files one row, in the words of the shell
# reference this ports (tools/build/package/validate_published.sh, check 1):
#
#   channel: <f> is listed and served, sha256 <s>, the bytes the build made
#   channel: the index does not list <f> (it lists of that name: <files>)
#   channel: the index lists <f> with sha256 <got>, the build made <want>
#   channel: GET <f> answered '<status>'
#   channel: the channel serves <f> with sha256 <got>, the build made <want>
#
# and for an index that did not answer 200:
#
#   channel: <url> answered 401: the channel is not readable anonymously
#            (a consumer cannot install from it)          (also 403)
#   channel: <url> answered 404 at poll <n>, after waiting <w> of <b> s: no
#            such channel, nothing published to it, or the registry has not
#            indexed it yet
#   channel: reading the index answered '<status or transport fault>'
#
# The file is fetched (GET <channel>/<subdir>/<f>, the same redirects) and
# its sha256 computed here: the index's word for it is not the bytes.
#
# Encapsulation: owned values; the transport, the sleeper and the poll log
# are borrowed `mut`. No pointer, no wildcard origin.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256
from komira_json import JsonValue, parse_json_value
from komira_retry import Sleeper

from kci_api import ResultValidationCheck
from kci_pkg_upload import PkgTransport
from kci_pkg_upload.conda_repodata import CONDA_PACKAGES_KEY
from kci_pkg_upload.http_read import GetResult, get_following_redirects
from kci_pkg_upload.wire import decode_utf8

from .request import InstallPin

comptime WAIT_POLL_SECONDS: Int = 15
"""How often the index is read again while a file is not listed yet."""

comptime CHECK_CHANNEL: String = "channel"
"""The check name of every row this file writes."""

comptime FILE_CHANNEL_PREFIX: String = "file:///"
"""How a LOCAL channel location starts: `file:///<absolute directory>`."""


def has_dot_segment(path: String) -> Bool:
    """True when a `/`-separated path holds a `.` or `..` segment."""
    var parts = path.split(String("/"))
    for i in range(len(parts)):
        var seg = String(parts[i])
        if seg == String(".") or seg == String(".."):
            return True
    return False

comptime _STDERR: FileDescriptor = FileDescriptor(2)


trait IndexPollLog(Movable):
    """Where each poll of the channel's index is said (file header): one
    line per index read, as it happens."""

    def poll(mut self, line: String):
        ...


struct StderrIndexPollLog(IndexPollLog):
    """Each poll line on stderr, as it happens.

    Layout: no field."""

    def __init__(out self):
        pass

    def poll(mut self, line: String):
        print(line, file=_STDERR)


struct RecordingIndexPollLog(IndexPollLog):
    """Each poll line kept in `lines`, in order (the tests' log).

    Layout: an owned List of Strings. No pointer field."""

    var lines: List[String]

    def __init__(out self):
        self.lines = List[String]()

    def poll(mut self, line: String):
        self.lines.append(line.copy())


struct ChannelUrl(Copyable, Movable):
    """A channel location, split: `host` and `path` (with its leading `/`,
    no trailing one; "" for a bare host). An https:// URL, or a LOCAL
    channel `file:///<absolute directory>` (kci run --channel, a
    validation-only run): its `host` is "" (`is_local`), which only
    file_channel.mojo's `FileChannelTransport` answers, and its path is
    the directory. A file:// location holding a `..` segment is refused.

    Layout: owned Strings. No pointer field."""

    var url: String
    var host: String
    var path: String

    def is_local(self) -> Bool:
        """True for a `file:///` location (no host)."""
        return self.host.byte_length() == 0

    def __init__(out self, url: String) raises:
        var local = String(FILE_CHANNEL_PREFIX)
        if url.startswith(local):
            var p = String(url[byte = local.byte_length() - 1 :])
            while p.byte_length() > 1 and p.endswith(String("/")):
                var trimmed = String(p[byte = 0 : p.byte_length() - 1])
                p = trimmed^
            if p == String("/") or p.find(String("//")) >= 0 or has_dot_segment(p):
                raise Error(
                    String("channel location '") + url
                    + String("' is not file:///<absolute directory> (no `.` or `..` segment, no empty one)")
                )
            self.url = String("file://") + p
            self.host = String("")
            self.path = p^
            return
        var prefix = String("https://")
        if not url.startswith(prefix):
            raise Error(String("channel location '") + url + String("' is not an https:// or file:/// URL"))
        var rest = String(url[byte = prefix.byte_length() :])
        var slash = rest.find(String("/"))
        if slash == 0 or rest.byte_length() == 0:
            raise Error(String("channel location '") + url + String("' names no host"))
        self.url = url.copy()
        if slash < 0:
            self.host = rest.copy()
            self.path = String("")
        else:
            self.host = String(rest[byte=0:slash])
            var p = String(rest[byte=slash:])
            while p.endswith(String("/")):
                var trimmed = String(p[byte = 0 : p.byte_length() - 1])
                p = trimmed^
            self.path = p^


struct _Index(Copyable, Movable):
    """The last read of one subdir's repodata.json: `ok` False is a
    transport fault (`detail`); otherwise `status`, and when 200 the parsed
    `doc` (`parsed` False when the body is not a JSON object);
    `redirected` when the answer came from another host than the
    channel's.

    Layout: owned values. No pointer field."""

    var subdir: String
    var ok: Bool
    var status: Int
    var detail: String
    var redirected: Bool
    var parsed: Bool
    var doc: JsonValue

    def __init__(out self, var subdir: String):
        self.subdir = subdir^
        self.ok = False
        self.status = 0
        self.detail = String("not read")
        self.redirected = False
        self.parsed = False
        self.doc = JsonValue.empty_object()


def _listed_sha(index: _Index, file: String) -> String:
    """The sha256 the index lists for `file`; "" when it does not list it;
    `<no sha256>` when it lists it without one."""
    if not index.parsed:
        return String("")
    try:
        if not index.doc.has(String(CONDA_PACKAGES_KEY)):
            return String("")
        var pkgs = index.doc.get(String(CONDA_PACKAGES_KEY))
        if not pkgs.is_object() or not pkgs.has(file):
            return String("")
        var entry = pkgs.get(file)
        if entry.is_object() and entry.has(String("sha256")):
            var v = entry.get(String("sha256"))
            if v.is_string():
                return v.as_string()
        return String("<no sha256>")
    except:
        return String("")


def _listed_of_name(index: _Index, name: String) -> String:
    """Every listed file of package `name`, `, `-joined ("" for none)."""
    var out = String("")
    if not index.parsed:
        return out^
    try:
        var pkgs = index.doc.get(String(CONDA_PACKAGES_KEY))
        if not pkgs.is_object():
            return out^
        var prefix = name + String("-")
        for i in range(pkgs.num_members()):
            var k = pkgs.key_at(i)
            # `<name>-<version>-<build>.conda`: the name is all but the last two `-` parts
            if not k.startswith(prefix):
                continue
            var rest = String(k[byte = prefix.byte_length() :])
            if rest.find(String("-")) < 0:
                continue
            var tail = String(rest[byte = rest.find(String("-")) + 1 :])
            if tail.find(String("-")) >= 0:
                continue
            if out.byte_length() > 0:
                out += String(", ")
            out += k
    except:
        pass
    return out^


def _read_index[T: PkgTransport](mut transport: T, ch: ChannelUrl, subdir: String) -> _Index:
    var out = _Index(subdir.copy())
    var got = get_following_redirects(
        transport, ch.host, ch.path + String("/") + subdir + String("/repodata.json"), String("application/json"), String("")
    )
    if not got.ok:
        out.detail = got.detail.copy()
        return out^
    out.ok = True
    out.status = got.response.status
    out.detail = String("")
    out.redirected = got.host != ch.host
    if out.status == 200:
        try:
            var doc = parse_json_value(decode_utf8(Span(got.response.body), String("repodata.json")))
            if doc.is_object():
                out.doc = doc^
                out.parsed = True
        except:
            pass
    return out^


def _subdirs(pins: List[InstallPin]) -> List[String]:
    var out = List[String]()
    for i in range(len(pins)):
        var seen = False
        for j in range(len(out)):
            if out[j] == pins[i].subdir:
                seen = True
        if not seen:
            out.append(pins[i].subdir.copy())
    return out^


def _index_url(ch: ChannelUrl, subdir: String) -> String:
    return ch.url + String("/") + subdir + String("/repodata.json")


def _settled(indexes: List[_Index], pins: List[InstallPin]) -> Bool:
    """True when waiting longer cannot change the verdict: every index
    answered 200 and lists every pinned file, or one answered 401/403, or a
    listed file has another sha256."""
    var all_listed = True
    for i in range(len(indexes)):
        ref ix = indexes[i]
        if ix.ok and (ix.status == 401 or ix.status == 403):
            return True
        for p in range(len(pins)):
            if pins[p].subdir != ix.subdir:
                continue
            var listed = _listed_sha(ix, pins[p].file_name())
            if listed.byte_length() == 0:
                all_listed = False
            elif listed != pins[p].sha256:
                return True
        if not ix.ok or ix.status != 200 or not ix.parsed:
            all_listed = False
    return all_listed


def _polls(n: Int) -> String:
    return String(n) + (String(" poll") if n == 1 else String(" polls"))


def _waited(waited: Int, wait_s: Int) -> String:
    return String("waited ") + String(waited) + String(" of ") + String(wait_s) + String(" s")


def _answer(ix: _Index, pins: List[InstallPin]) -> String:
    """What one read of an index answered, for a poll line: never a
    transport detail or a redirect target (either can name an address)."""
    if not ix.ok:
        return String("could not be read")
    var s = String("answered ") + String(ix.status)
    if ix.redirected:
        s += String(" after a redirect")
    if ix.status != 200:
        return s^
    if not ix.parsed:
        return s + String(" with a body that is not a JSON object")
    var listed = 0
    var pinned = 0
    for p in range(len(pins)):
        if pins[p].subdir != ix.subdir:
            continue
        pinned += 1
        if _listed_sha(ix, pins[p].file_name()).byte_length() > 0:
            listed += 1
    return s + String(", lists ") + String(listed) + String(" of ") + String(pinned) + String(" pinned files")


def poll_line(n: Int, url: String, answer: String, waited: Int, wait_s: Int) -> String:
    """One poll's log line (file header)."""
    return (
        String("kci: channel index poll ") + String(n) + String(": ") + url + String(" ") + answer + String("; ")
        + _waited(waited, wait_s)
    )


def _row(var expected: String, var got: String, ok: Bool) -> ResultValidationCheck:
    return ResultValidationCheck(String(CHECK_CHANNEL), expected^, got^, ok)


def _check_served[T: PkgTransport](
    mut transport: T,
    ch: ChannelUrl,
    index: _Index,
    pin: InstallPin,
    budget: String,
    mut checks: List[ResultValidationCheck],
):
    var f = pin.file_name()
    var want = pin.sha256.copy()
    var expected = (
        String("the index lists ") + f + String(" with sha256 ") + want + String(" and the channel serves those bytes")
        + budget
    )
    var got = _listed_sha(index, f)
    if got.byte_length() == 0:
        var have = _listed_of_name(index, pin.name)
        if have.byte_length() == 0:
            have = String("nothing")
        checks.append(
            _row(expected^, String("channel: the index does not list ") + f + String(" (it lists of that name: ") + have + String(")"), False)
        )
        return
    if got != want:
        checks.append(
            _row(expected^, String("channel: the index lists ") + f + String(" with sha256 ") + got + String(", the build made ") + want, False)
        )
        return
    var served = get_following_redirects(
        transport, ch.host, ch.path + String("/") + pin.subdir + String("/") + f, String(""), String("")
    )
    if not served.ok or served.response.status != 200:
        var code = String(served.response.status) if served.ok else served.detail.copy()
        checks.append(_row(expected^, String("channel: GET ") + f + String(" answered '") + code + String("'"), False))
        return
    var sha = hex_lower_array_32(sha256(Span(served.response.body)))
    if sha != want:
        checks.append(
            _row(expected^, String("channel: the channel serves ") + f + String(" with sha256 ") + sha + String(", the build made ") + want, False)
        )
        return
    checks.append(
        _row(expected^, String("channel: ") + f + String(" is listed and served, sha256 ") + want + String(", the bytes the build made"), True)
    )


def check_channel[T: PkgTransport, S: Sleeper, L: IndexPollLog](
    mut transport: T,
    mut sleeper: S,
    mut log: L,
    channel_url: String,
    pins: List[InstallPin],
    wait_s: Int,
    mut checks: List[ResultValidationCheck],
) -> Bool:
    """Check 1 (file header): appends its rows to `checks`; True when every
    row passed; each poll is a line on `log`. Never raises."""
    var ch: ChannelUrl
    try:
        ch = ChannelUrl(channel_url)
    except e:
        checks.append(_row(String("an https:// or file:/// channel location"), String("channel: ") + String(e), False))
        return False
    var subdirs = _subdirs(pins)
    var indexes = List[_Index]()
    var waited = 0
    var polls = 0
    while True:
        indexes = List[_Index]()
        polls += 1
        for i in range(len(subdirs)):
            indexes.append(_read_index(transport, ch, subdirs[i]))
            log.poll(poll_line(polls, _index_url(ch, subdirs[i]), _answer(indexes[i], pins), waited, wait_s))
        if _settled(indexes, pins) or waited >= wait_s:
            break
        var step = WAIT_POLL_SECONDS
        if wait_s - waited < step:
            step = wait_s - waited
        try:
            sleeper.sleep_ms(Int64(step * 1000))
        except:
            break
        waited += step
    var all_ok = True
    var spent = _waited(waited, wait_s) + String(" over ") + _polls(polls)
    var budget = String(" (read anonymously; ") + spent + String(")")
    for i in range(len(indexes)):
        ref ix = indexes[i]
        var url = _index_url(ch, ix.subdir)
        var expected = String("GET ") + url + String(" answers 200") + budget
        if not ix.ok:
            checks.append(_row(expected^, String("channel: reading the index answered '") + ix.detail + String("'"), False))
            all_ok = False
            continue
        if ix.status == 401 or ix.status == 403:
            checks.append(
                _row(
                    expected^,
                    String("channel: ") + url + String(" answered ") + String(ix.status)
                    + String(": the channel is not readable anonymously (a consumer cannot install from it)"),
                    False,
                )
            )
            all_ok = False
            continue
        if ix.status == 404:
            checks.append(
                _row(
                    expected^,
                    String("channel: ") + url + String(" answered 404 at poll ") + String(polls) + String(", after ")
                    + String("waiting ") + String(waited) + String(" of ") + String(wait_s) + String(" s")
                    + String(": no such channel, nothing published to it, or the registry has not indexed it yet"),
                    False,
                )
            )
            all_ok = False
            continue
        if ix.status != 200:
            checks.append(_row(expected^, String("channel: reading the index answered '") + String(ix.status) + String("'"), False))
            all_ok = False
            continue
        if not ix.parsed:
            checks.append(
                _row(expected^, String("channel: reading the index answered '200 with a body that is not a JSON object'"), False)
            )
            all_ok = False
            continue
        var via = String(" after a redirect") if ix.redirected else String("")
        checks.append(_row(expected^, String("channel: ") + url + String(" answered 200") + via + String("; ") + spent, True))
        for p in range(len(pins)):
            if pins[p].subdir != ix.subdir:
                continue
            var before = len(checks)
            _check_served(transport, ch, ix, pins[p], budget, checks)
            if not checks[before].ok:
                all_ok = False
    return all_ok
