# =============================================================================
# kci_logs/gcp_logging_query.mojo — the GCP arm, PURE: the filter, the
#   `entries:list` request body, and the FIELD-ALLOW-LISTED response parse.
# =============================================================================
#
# Nothing here names a socket. The whole request shape and every failure branch
# are provable with no network, so an offline test can assert on the EXACT
# bytes that go on the wire.
#
# THE WIRE, from Google's own reference (logging/v2/entries/list):
#   POST https://logging.googleapis.com/v2/entries:list
#   {"resourceNames":["projects/<p>"],"filter":"...","orderBy":"timestamp asc",
#    "pageSize":200}
#   -> {"entries":[{"textPayload":"...","severity":"INFO",
#                   "timestamp":"2026-09-12T10:00:00.123456Z", ...}],
#       "nextPageToken":"..."}
#
# ── ⛔ THE ALLOW-LIST IS THE SECURITY BOUNDARY, AND IT IS ON *FIELDS* ─────────
# `GCP_LOG_ENTRY_FIELD_ALLOWLIST` is the complete set of keys that can leave this
# parser. A key that is not on it is SKIPPED — not stored, not rendered, not
# counted. The thing on the other end of this pipe is an operator's terminal
# during a failed deploy, and a log ENTRY carries far more than its text:
# `labels`, `resource.labels`, `httpRequest` and `jsonPayload` are all
# free-form maps the emitting service controls. Echoing an entry wholesale would
# make this parser's blast radius equal to every service that ever logged into
# the project. It is the identical rule `run_log_tail.mojo` states one stream
# over, and it is stated again rather than inherited because the WIRE is
# different and the temptation ("just print the entry") is stronger here.
#
# ⛔ AND A RESPONSE BODY IS NEVER ECHOED — not on a 4xx, not on a 5xx, not on an
# unparseable 200. Faults report a byte COUNT and a position. A 403 from an
# auth-adjacent API is exactly the body that carries material.
#
# def-based, Mojo 1.0.0b2. No UnsafePointer, no wildcard origin, no FFI.
# =============================================================================

from kci_logs.cloud_log_source import (
    CloudLogEntry,
    CloudLogPage,
    DEFAULT_CONTAINER_LOG_LIMIT,
)
from kci_logs.json_scan import (
    json_scan_string,
    json_skip_space,
    json_skip_value,
)


comptime LOGGING_HOST: String = "logging.googleapis.com"
comptime ENTRIES_LIST_PATH: String = "/v2/entries:list"

comptime GCP_LOG_ENTRY_FIELD_ALLOWLIST: String = (
    "textPayload,severity,timestamp"
)
"""The complete set of LogEntry keys this parser lets out. See the header."""

comptime NON_TEXT_PAYLOAD_MARKER: String = (
    "(entry has no textPayload — a structured payload, omitted by the field"
    " allow-list)"
)
"""What an entry with no `textPayload` renders as.

⛔ THE ENTRY IS KEPT, NOT DROPPED, and that is a deliberate choice against the
easier one. A container that logs STRUCTURED JSON produces `jsonPayload` and no
`textPayload`; dropping those entries would render a 40-line stream as 0 lines
and tell the operator "the stream is empty" about a stream that is full. Keeping
the entry preserves the COUNT and the TIMESTAMP — which is what says "there is
output here and this parser is not the way to read it" — while the allow-list
still refuses to emit the payload's free-form contents."""


# =============================================================================
# §1 — handle arithmetic (pure String work on a self-addressing resource name).
# =============================================================================
def segment_after(s: String, marker: String) -> String:
    """The single path segment following `marker` in `s` (up to the next `/`), or
    EMPTY when `marker` is absent or nothing follows it.

    The same arithmetic the GCP bridge uses privately, restated here because
    this leaf must not depend on that package. Two derivations of the same arithmetic is a real cost; a dependency
    edge from a zero-socket leaf onto the whole GCP bridge is a bigger one."""
    var at = s.find(marker)
    if at < 0:
        return String("")
    var start = at + marker.byte_length()
    var rest = String(s[byte=start:])
    var slash = rest.find(String("/"))
    if slash < 0:
        return rest^
    return String(rest[byte=:slash])


def execution_project(exec_resource_name: String) -> String:
    """The project id out of a Cloud Run execution resource name, or EMPTY.

    The leading-slash NORMALISE means ONE marker
    set then matches both the live shape (`projects/...`, no leading slash) and
    an already-absolute form."""
    return segment_after(
        String("/") + exec_resource_name, String("/projects/")
    )


def execution_leaf(exec_resource_name: String) -> String:
    """The execution's LEAF id out of its resource name, or EMPTY.

    ⚠ THE LEAF, NOT THE RESOURCE NAME, is what the
    `run.googleapis.com/execution_name` label carries — a filter built on the
    full name matches nothing, silently, and reads as "the container printed
    nothing"."""
    return segment_after(
        String("/") + exec_resource_name, String("/executions/")
    )


# =============================================================================
# §2 — the FILTER.
# =============================================================================
def cloud_run_execution_log_filter(exec_resource_name: String) -> String:
    """The Cloud Logging filter that selects ONE Cloud Run Job execution's
    container output, from its resource name alone. EMPTY when the name carries
    no execution id.

    ⛔ EMPTY IS A REFUSAL AND MUST STAY ONE. This is the same discipline the
    printed `gcloud logging read` fallback command follows: a filter with no execution id matches
    every job execution in the project, and a caller that ran it would show the
    operator SOMEBODY ELSE'S rows under this step's name. A command — or a
    query — that silently reads the wrong thing is worse than none.

    ⚠ THE PROJECT IS **NOT** IN THE FILTER, and that is not the same refusal.
    On the REST API the project is the `resourceNames` scope, a separate field
    (`entries_list_body` refuses an empty one there); in the `gcloud` command it
    has to be `--project`, which is why that command checks both. Stated because
    the two functions look like they should agree and correctly do not.

    The filter text is BYTE-IDENTICAL to the one in the `gcloud` command a
    failure report prints, deliberately: an operator comparing the
    tool's output to their own `gcloud` run must not have to wonder whether two
    different queries were asked."""
    var leaf = execution_leaf(exec_resource_name)
    if leaf.byte_length() == 0:
        return String("")
    return (
        String(
            'resource.type="cloud_run_job" AND'
            ' labels."run.googleapis.com/execution_name"="'
        )
        + leaf
        + String('"')
    )


# =============================================================================
# §3 — the REQUEST BODY.
# =============================================================================
def json_escape(s: String) -> String:
    """Escape `s` for a JSON string literal: `\\` `"` and the three control
    characters an operator-visible string realistically carries.

    ⚠ IT IS NOT OPTIONAL HERE AND THE REASON IS SPECIFIC. The value this escapes
    is the FILTER, and a Cloud Logging filter is made almost entirely of double
    quotes (`resource.type="cloud_run_job" AND labels."..."="..."`). An unescaped
    filter does not produce a wrong query — it produces a body that is not JSON
    at all, and the failure surfaces as an opaque 400 from the provider.

    ⛔ IT ACCUMULATES **BYTES** AND DOES NOT GO THROUGH `chr(Int(byte))`. `chr`
    maps a CODEPOINT to UTF-8, so a non-ASCII byte would come back out as its own
    two-byte character and the value would be mojibake before it reached the
    wire. That is the defect written up on `run_log_tail.mojo`'s scanner, and it
    is the same defect on the WRITE side — where it is worse, because the
    corrupted bytes go INTO a request rather than into a diagnostic."""
    var buf = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord('"')):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord('"')))
        elif c == UInt8(ord("\\")):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("\\")))
        elif c == UInt8(0x0A):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("n")))
        elif c == UInt8(0x0D):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("r")))
        elif c == UInt8(0x09):
            buf.append(UInt8(ord("\\")))
            buf.append(UInt8(ord("t")))
        else:
            buf.append(c)
    return String(unsafe_from_utf8=Span(buf))


def entries_list_body(
    project: String,
    filter_expr: String,
    page_size: Int = DEFAULT_CONTAINER_LOG_LIMIT,
    # ★ THE CONTINUATION. DEFAULTED EMPTY, so a first-page call
    # emits no `pageToken` key — a `pageToken` key is only ever added when
    # a caller has one the provider itself handed back.
    page_token: String = String(""),
) -> String:
    """The FULLY-FORMED `entries:list` request body. EMPTY when `project` or
    `filter_expr` is empty — the refusal, same reason as §2.

    ★ `orderBy: "timestamp asc"` — OLDEST FIRST, which is load-bearing twice. It
    is what `CloudLogPage.entries` promises its consumers, and it is what puts a
    validator's failing rows and its `VERDICT:` line at the END of the page,
    where the bounded renderer's "show the LAST N" keeps them. Asking for
    descending and reversing locally would produce the same list and would
    silently produce the WRONG list the moment the page bound truncates: the
    provider would hand back the NEWEST N of the whole stream rather than the
    oldest N, and a stream longer than the bound would render its head as its
    tail.

    ⚠ `resourceNames` is an ARRAY even for one project — the API's shape, not a
    convenience. A scalar is a 400.

    ⛔ `pageToken` IS ECHOED BACK VERBATIM AND IS NEVER SYNTHESISED. It is an
    opaque provider string; a caller may only pass one the provider returned as
    `nextPageToken`. ⚠ AND IT IS ESCAPED like every other value here — a token is
    base64-ish today, which is exactly the kind of "it never needs escaping"
    assumption that produces an opaque 400 the first time it does."""
    if project.byte_length() == 0 or filter_expr.byte_length() == 0:
        return String("")
    var size = page_size if page_size > 0 else DEFAULT_CONTAINER_LOG_LIMIT
    return (
        String('{"resourceNames":["projects/')
        + json_escape(project)
        + String('"],"filter":"')
        + json_escape(filter_expr)
        + String('","orderBy":"timestamp asc","pageSize":')
        + String(size)
        + (
            String(',"pageToken":"') + json_escape(page_token) + String('"')
            if page_token.byte_length() > 0
            else String("")
        )
        + String("}")
    )


def cloud_run_execution_entries_list_body(
    exec_resource_name: String,
    page_size: Int = DEFAULT_CONTAINER_LOG_LIMIT,
    page_token: String = String(""),
) -> String:
    """`entries_list_body` composed straight off an execution resource name — the
    ONE call a conformer needs. EMPTY when the name yields no project or no
    execution leaf, which a conformer must report as a refusal rather than send.

    Composed here rather than at each conformer so the GCP arm has exactly ONE
    derivation of its request, instead of several call sites that would have to
    be kept in agreement by hand."""
    return entries_list_body(
        execution_project(exec_resource_name),
        cloud_run_execution_log_filter(exec_resource_name),
        page_size,
        page_token,
    )


# =============================================================================
# §4 — the ALLOW-LISTED object parse.
# =============================================================================
def _parse_entry_object(
    b: Span[UInt8, _], start: Int, mut entry: CloudLogEntry
) -> Int:
    """Parse ONE `LogEntry` object at `start` (`b[start] == '{'`) through the
    field allow-list. Returns the index after its closing brace, or -1.

    `has_text` tracks whether a `textPayload` was seen AT ALL, which is what
    distinguishes an entry with an empty text payload from one that carried a
    structured payload this parser refuses to emit."""
    entry = CloudLogEntry.empty()
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var sval = String()
    var has_text = False
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            if not has_text:
                entry.text = String(NON_TEXT_PAYLOAD_MARKER)
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var nk = json_scan_string(b, j, key)
        if nk < 0:
            return -1
        j = json_skip_space(b, nk)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = json_skip_space(b, j + 1)
        if key == String("textPayload"):
            var nv = json_scan_string(b, j, sval)
            if nv < 0:
                return -1
            entry.text = sval.copy()
            has_text = True
            j = nv
        elif key == String("severity"):
            var nv2 = json_scan_string(b, j, sval)
            if nv2 < 0:
                return -1
            entry.severity = sval.copy()
            j = nv2
        elif key == String("timestamp"):
            var nv3 = json_scan_string(b, j, sval)
            if nv3 < 0:
                return -1
            entry.timestamp = sval.copy()
            j = nv3
        else:
            # ⛔ NOT ON THE ALLOW-LIST. Skipped whole — never stored, never
            # rendered, never counted.
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _find_key(body: String, b: Span[UInt8, _], key: String) -> Int:
    """The index of the VALUE of top-level `key`, or -1.

    ⚠ A `find` ON THE QUOTED KEY, which is the same bounded-diagnostic trade
    `run_log_tail.mojo` makes: it would also match a key nested inside a value.
    That is acceptable HERE and only here because the two keys read this way
    (`entries`, `nextPageToken`) are ones whose nested homonyms do not occur in
    a `ListLogEntriesResponse`, and because the cost of a wrong hit is a
    diagnostic that fails to parse, never a wrong verdict."""
    var needle = String('"') + key + String('"')
    var idx = body.find(needle)
    if idx < 0:
        return -1
    var j = json_skip_space(b, idx + needle.byte_length())
    if j >= len(b) or b[j] != UInt8(ord(":")):
        return -1
    return json_skip_space(b, j + 1)


# =============================================================================
# §5 — the PARSE.
# =============================================================================
def parse_entries_list_body(body: String, handle: String) -> CloudLogPage:
    """Parse a `ListLogEntriesResponse` into a `CloudLogPage`, through the field
    allow-list. ⛔ NEVER RAISES and ⛔ NEVER ECHOES THE BODY — a parse failure
    reports a byte count and a position.

    AN EMPTY `entries` ARRAY IS A SUCCESS, and an ABSENT one is too: Cloud
    Logging omits the key entirely when a filter matches nothing. Both mean "the
    provider answered and there is nothing there", which the renderer states as
    NO STAGE RECORDS. ⛔ Neither is an error, and modelling them as one is how a
    container that crashed before printing gets reported as an observability
    fault."""
    var b = body.as_bytes()
    var page = CloudLogPage.empty(200)
    if body.byte_length() == 0:
        return page^
    var tok = _find_key(body, b, String("nextPageToken"))
    if tok >= 0:
        var tval = String()
        if json_scan_string(b, tok, tval) >= 0:
            page.next_token = tval^
    var ei = _find_key(body, b, String("entries"))
    if ei < 0:
        return page^
    var j = json_skip_space(b, ei)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return CloudLogPage.failed(
            200,
            String("`entries` was not an array at byte ")
            + String(j)
            + String(" of a ")
            + String(body.byte_length())
            + String("-byte body (NOT echoed)"),
        )
    j += 1
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return CloudLogPage.failed(
                200,
                String("unterminated `entries` array in a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        if b[j] == UInt8(ord("]")):
            return page^
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var entry = CloudLogEntry.empty()
        var nx = _parse_entry_object(b, j, entry)
        if nx < 0:
            return CloudLogPage.failed(
                200,
                String("malformed log entry at byte ")
                + String(j)
                + String(" of a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        page.entries.append(entry^)
        j = nx
