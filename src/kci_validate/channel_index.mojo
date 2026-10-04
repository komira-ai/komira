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
# THE WAIT. A registry indexes an upload a little after it lands, so only
# the ABSENCE of a file is waited for, up to `wait_s` seconds, polling every
# `WAIT_POLL_SECONDS`: an index that answers 404 (a subdir nothing was
# published to yet), one that cannot be reached, or one that does not list
# every pinned file yet. Nothing else is waited for: a 401 or 403 ends the
# wait at once (the channel is not public), and so does a listed file whose
# sha256 is not the build's (another build of the same name, or other bytes:
# waiting cannot fix that). When the budget is spent, what was read last is
# judged, and an absent file or a 404 is a FAIL: FAIL CLOSED.
#
# Then, for each pinned file of an index that answered 200, one row, in the
# words of the shell reference this ports (tools/build/package/
# validate_published.sh, check 1):
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
#   channel: <url> answered 404: no such channel, or nothing published to it
#   channel: reading the index answered '<status or transport fault>'
#
# The file is fetched (GET <channel>/<subdir>/<f>, the same redirects) and
# its sha256 computed here: the index's word for it is not the bytes.
#
# Encapsulation: owned values; the transport and the sleeper are borrowed
# `mut`. No pointer, no wildcard origin.
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


struct ChannelUrl(Copyable, Movable):
    """An https:// channel location, split: `host` and `path` (with its
    leading `/`, no trailing one; "" for a bare host).

    Layout: owned Strings. No pointer field."""

    var url: String
    var host: String
    var path: String

    def __init__(out self, url: String) raises:
        var prefix = String("https://")
        if not url.startswith(prefix):
            raise Error(String("channel location '") + url + String("' is not an https:// URL"))
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
    `doc` (`parsed` False when the body is not a JSON object).

    Layout: owned values. No pointer field."""

    var subdir: String
    var ok: Bool
    var status: Int
    var detail: String
    var parsed: Bool
    var doc: JsonValue

    def __init__(out self, var subdir: String):
        self.subdir = subdir^
        self.ok = False
        self.status = 0
        self.detail = String("not read")
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


def check_channel[T: PkgTransport, S: Sleeper](
    mut transport: T,
    mut sleeper: S,
    channel_url: String,
    pins: List[InstallPin],
    wait_s: Int,
    mut checks: List[ResultValidationCheck],
) -> Bool:
    """Check 1 (file header): appends its rows to `checks`; True when every
    row passed. Never raises."""
    var ch: ChannelUrl
    try:
        ch = ChannelUrl(channel_url)
    except e:
        checks.append(_row(String("an https:// channel location"), String("channel: ") + String(e), False))
        return False
    var subdirs = _subdirs(pins)
    var indexes = List[_Index]()
    var waited = 0
    while True:
        indexes = List[_Index]()
        for i in range(len(subdirs)):
            indexes.append(_read_index(transport, ch, subdirs[i]))
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
    var budget = String(" (read anonymously; waited ") + String(waited) + String(" of ") + String(wait_s) + String(" s)")
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
                _row(expected^, String("channel: ") + url + String(" answered 404: no such channel, or nothing published to it"), False)
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
        for p in range(len(pins)):
            if pins[p].subdir != ix.subdir:
                continue
            var before = len(checks)
            _check_served(transport, ch, ix, pins[p], budget, checks)
            if not checks[before].ok:
                all_ok = False
    return all_ok
