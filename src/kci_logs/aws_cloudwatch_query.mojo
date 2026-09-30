# =============================================================================
# kci_logs/aws_cloudwatch_query.mojo — the AWS arm, PURE: the log-stream
#   derivation, the `GetLogEvents` request body, and the FIELD-ALLOW-LISTED
#   response parse.
# =============================================================================
#
# ⚠⚠ WHAT IS HERE AND WHAT IS NOT:
#     * HERE, and hermetically tested: every PURE half — the stream name, the
#       request body, the parse, the refusals.
#     * NOT HERE: the live transport conformer, which is
#       `komira_aws_iac_live.LiveEcsTaskLogs`. This file names no socket.
#
# ★ THIS FILE IS ALSO THE PROOF THAT THE SEAM IS CLOUD-NEUTRAL. It demonstrates
#   that `CloudLogSource`'s one verb, keyed on the provider's OWN self-addressing
#   handle, carries the CloudWatch shape without a single change to the trait,
#   to `CloudLogPage`, or to the `RunLogTail` adapter.
#
# THE WIRE (CloudWatch Logs, JSON 1.1 over the `Logs_20140328` target prefix):
#   POST /  X-Amz-Target: Logs_20140328.GetLogEvents
#   {"logGroupName":"/ecs/<family>","logStreamName":"<prefix>/<container>/<id>",
#    "limit":200,"startFromHead":true}
#   -> {"events":[{"timestamp":1789200000000,"message":"...",
#                  "ingestionTime":1789200000123}],
#       "nextForwardToken":"f/3...","nextBackwardToken":"b/3..."}
#
# ── ⛔ THE ALLOW-LIST IS THE SECURITY BOUNDARY (the GCP arm's rule, restated).
# `AWS_LOG_EVENT_FIELD_ALLOWLIST` is the complete set of keys that can leave this
# parser; anything else is SKIPPED. And ⛔ a response body is never echoed —
# faults report a byte count and a position.
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
    json_scan_number,
    json_skip_space,
    json_skip_value,
)


comptime CLOUDWATCH_LOGS_TARGET: String = "Logs_20140328.GetLogEvents"
comptime AWS_LOG_EVENT_FIELD_ALLOWLIST: String = "message,timestamp"
"""The complete set of OutputLogEvent keys this parser lets out.

⚠ `ingestionTime` IS DELIBERATELY OFF IT. It is the time CloudWatch RECEIVED the
line, not the time the container wrote it, and two clocks in one rendered stream
is how a reader concludes an event happened after something it preceded."""


# =============================================================================
# §1 — handle arithmetic on an ECS task ARN (self-addressing, like its GCP twin).
# =============================================================================
def ecs_task_id(task_arn: String) -> String:
    """The task id — the LAST `/`-separated segment of an ECS task ARN
    (`arn:aws:ecs:<region>:<acct>:task/<cluster>/<taskId>`), or EMPTY.

    ⚠ THE **LAST** SEGMENT, NOT THE THIRD. Both ARN shapes are live: the long
    form above and the legacy `…:task/<taskId>` with no cluster segment. Taking
    a fixed index gets the CLUSTER NAME on one of them — a string that looks
    entirely plausible in a log-stream name and matches nothing."""
    if task_arn.byte_length() == 0:
        return String("")
    var rest = task_arn.copy()
    while True:
        var slash = rest.find(String("/"))
        if slash < 0:
            return rest^
        var tail = String(rest[byte = slash + 1 :])
        if tail.byte_length() == 0:
            return String("")
        rest = tail^


def ecs_task_arn_region(task_arn: String) -> String:
    """The REGION an ECS task ARN names — segment 3 of
    `arn:aws:ecs:<region>:<acct>:task/<cluster>/<taskId>` — or EMPTY.

    ⭐⭐ THIS IS WHY THE AWS CONFORMER CARRIES NO REGION FIELD, and it is the
    SAME property the GCP conformer gets for free by carrying no PROJECT field.
    `LiveCloudRunExecutionLogs`' docstring states it: *"a project field could
    DISAGREE with the handle, and the failure mode of that disagreement is
    reading a different project's entries and presenting them as this
    execution's."* A CloudWatch read needs a region twice — to pick the endpoint
    host AND to compute the SigV4 credential scope — so a `_region` field would
    be a second source for a fact the handle already carries, and the wrong one
    reads ANOTHER REGION'S log group of the same name.

    ⛔ EMPTY IS A REFUSAL, never a default region. `us-east-1` is the tempting
    fallback precisely because it is where most things are; a task in
    `us-west-2` whose logs were read from `us-east-1` answers
    `ResourceNotFoundException`, which the caller renders as "the container
    printed nothing"."""
    var b = task_arn.as_bytes()
    var seen = 0
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord(":")):
            seen += 1
            if seen == 3:
                start = i + 1
            elif seen == 4:
                if start >= i:
                    return String("")
                return String(task_arn[byte=start:i])
    return String("")


def cloudwatch_logs_host(region: String) -> String:
    """`logs.<region>.amazonaws.com` — the regional CloudWatch Logs endpoint, or
    EMPTY for an empty region.

    The AWS peer of `LOGGING_HOST`, and the one structural difference between
    the two clouds' transports: Cloud Logging is ONE global host that takes the
    project INSIDE the request, where CloudWatch Logs is PER-REGION and the
    region is in the HOSTNAME. That is why this arm derives a region from the
    handle at all — see `ecs_task_arn_region`."""
    if region.byte_length() == 0:
        return String("")
    return String("logs.") + region + String(".amazonaws.com")


def ecs_task_log_stream(
    stream_prefix: String, container_name: String, task_arn: String
) -> String:
    """The awslogs log-stream name ECS writes a task's container output to:
    `<awslogs-stream-prefix>/<container-name>/<task-id>`. EMPTY when any of the
    three parts is missing.

    ⛔ EMPTY IS A REFUSAL, the same one `cloud_run_execution_log_filter` makes. A
    partially-formed stream name does not fail — CloudWatch answers
    `ResourceNotFoundException`, which a caller can easily render as "the
    container printed nothing". A caller must report that it could not DERIVE the
    stream rather than report an empty stream.

    ⚠ THE PREFIX IS NOT DERIVABLE AND MUST BE PASSED. It is whatever the task
    definition's `logConfiguration.options["awslogs-stream-prefix"]` says; there
    is no convention and no default. A conformer gets it from the task
    definition it converged — ⛔ never from an env var (absent and
    empty are the same bytes to env, and an empty prefix here silently builds a
    stream name for a different container)."""
    if (
        stream_prefix.byte_length() == 0
        or container_name.byte_length() == 0
    ):
        return String("")
    var tid = ecs_task_id(task_arn)
    if tid.byte_length() == 0:
        return String("")
    return stream_prefix + String("/") + container_name + String("/") + tid


# =============================================================================
# §2 — the REQUEST BODY.
# =============================================================================
def get_log_events_body(
    log_group: String,
    log_stream: String,
    limit: Int = DEFAULT_CONTAINER_LOG_LIMIT,
    next_token: String = String(""),
) -> String:
    """The FULLY-FORMED `GetLogEvents` request body. EMPTY when the group or the
    stream is empty — the refusal.

    ★★ `next_token` — THE PROVIDER'S OWN FORWARD CURSOR, omitted
    when empty (the first request of a walk). ⛔ AWS's own contract for this API
    is that a response MAY carry an empty `events` list together with a token
    and that a caller should *"repeat the request with the token until the same
    token is returned twice"* — so a single read is not a walk, and an empty
    first page is not an empty stream. `startFromHead` is already `true`, which
    AWS REQUIRES when a previous `nextForwardToken` is supplied; that is the one
    interaction between these two fields and it is satisfied by construction.

    ★ `startFromHead: true` — OLDEST FIRST, the `orderBy: "timestamp asc"` of
    this arm and load-bearing for the identical reason: `CloudLogPage.entries`
    promises oldest-first, and a bounded read that started from the TAIL would
    hand the renderer the newest N of the stream where it expects the oldest N of
    the page. ⚠ On this API the default is the OPPOSITE (`false`), so omitting
    the field is not the same as stating it.

    ⚠ `limit` IS CAPPED BY THE SERVICE at 10,000 events / 1 MiB per call; this
    seam's bound is two orders below that and is the one that binds."""
    if log_group.byte_length() == 0 or log_stream.byte_length() == 0:
        return String("")
    var n = limit if limit > 0 else DEFAULT_CONTAINER_LOG_LIMIT
    # ⚠ ESCAPED LIKE EVERY OTHER INTERPOLATED VALUE HERE. The token is opaque
    # provider bytes; it is not this layer's business what is in it, and that is
    # precisely why it is never pasted in raw.
    var tok = String("")
    if next_token.byte_length() > 0:
        tok = (
            String(',"nextToken":"') + _json_escape(next_token) + String('"')
        )
    return (
        String('{"logGroupName":"')
        + _json_escape(log_group)
        + String('","logStreamName":"')
        + _json_escape(log_stream)
        + String('","limit":')
        + String(n)
        + tok
        + String(',"startFromHead":true}')
    )


def _json_escape(s: String) -> String:
    """Escape `s` for a JSON string literal. The GCP arm's `json_escape`, kept
    module-private here: a log GROUP name is `/ecs/<family>` and a STREAM name
    embeds a customer-chosen prefix, so neither is safe to interpolate raw."""
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


# =============================================================================
# §3 — the ALLOW-LISTED object parse.
# =============================================================================
def _parse_event_object(
    b: Span[UInt8, _], start: Int, mut entry: CloudLogEntry
) -> Int:
    """Parse ONE `OutputLogEvent` at `start` through the field allow-list.
    Returns the index after its closing brace, or -1.

    ⚠ `timestamp` IS A BARE INTEGER HERE (epoch millis), where the GCP arm's is
    an RFC3339 STRING. It is rendered to digits and kept VERBATIM — ⛔ not
    converted to RFC3339. `CloudLogEntry.timestamp` promises the provider's own
    spelling precisely so an operator comparing this output with the CloudWatch
    console is comparing the same string."""
    entry = CloudLogEntry.empty()
    var j = json_skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var sval = String()
    var ival = 0
    while True:
        j = json_skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
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
        if key == String("message"):
            var nv = json_scan_string(b, j, sval)
            if nv < 0:
                return -1
            entry.text = sval.copy()
            j = nv
        elif key == String("timestamp"):
            var nv2 = json_scan_number(b, j, ival)
            if nv2 < 0:
                return -1
            entry.timestamp = String(ival)
            j = nv2
        else:
            var ns = json_skip_value(b, j)
            if ns < 0:
                return -1
            j = ns


def _find_key(body: String, b: Span[UInt8, _], key: String) -> Int:
    var needle = String('"') + key + String('"')
    var idx = body.find(needle)
    if idx < 0:
        return -1
    var j = json_skip_space(b, idx + needle.byte_length())
    if j >= len(b) or b[j] != UInt8(ord(":")):
        return -1
    return json_skip_space(b, j + 1)


# =============================================================================
# §4 — the PARSE.
# =============================================================================
def parse_get_log_events_body(body: String) -> CloudLogPage:
    """Parse a `GetLogEvents` response into a `CloudLogPage`. ⛔ NEVER RAISES and
    ⛔ NEVER ECHOES THE BODY.

    AN EMPTY OR ABSENT `events` ARRAY IS A SUCCESS — the provider answered and
    there is nothing there. ⚠ On this API that is also what a stream that exists
    but has not been flushed yet looks like, which is why the caller's report
    says "the stream is empty" and not "the container printed nothing": the
    second is an inference this layer cannot support.

    ⚠ `nextForwardToken` IS ALWAYS PRESENT on a successful GetLogEvents, even at
    the end of a stream — it is a resume cursor, not an is-more flag. Carrying it
    into `next_token` therefore makes `cloud_log_page_to_run_log_tail` render
    `done=false` for this arm as a rule. That is the HONEST rendering for a
    cursor API (re-reading CAN return more), and it is the one behavioural
    difference between the two arms' reports. Stated here so it is a decision and
    not a surprise."""
    var b = body.as_bytes()
    var page = CloudLogPage.empty(200)
    if body.byte_length() == 0:
        return page^
    var tok = _find_key(body, b, String("nextForwardToken"))
    if tok >= 0:
        var tval = String()
        if json_scan_string(b, tok, tval) >= 0:
            page.next_token = tval^
    var ei = _find_key(body, b, String("events"))
    if ei < 0:
        return page^
    var j = json_skip_space(b, ei)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return CloudLogPage.failed(
            200,
            String("`events` was not an array at byte ")
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
                String("unterminated `events` array in a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        if b[j] == UInt8(ord("]")):
            return page^
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var entry = CloudLogEntry.empty()
        var nx = _parse_event_object(b, j, entry)
        if nx < 0:
            return CloudLogPage.failed(
                200,
                String("malformed log event at byte ")
                + String(j)
                + String(" of a ")
                + String(body.byte_length())
                + String("-byte body (NOT echoed)"),
            )
        page.entries.append(entry^)
        j = nx
