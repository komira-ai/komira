# =============================================================================
# komira_http_server/middleware/fault_report.mojo — ATTRIBUTE every boundary 500.
# =============================================================================
#
# THE PROBLEM. Without this file a 500 out of a
# service built on this transport is a DEAD END, and not because nobody
# instrumented it — because the cause is COMPUTED AND THEN DISCARDED at every
# boundary site that issues one:
#
#   * an unchained serve path that catches the raise as `except e: _ = e`
#     and answers `HttpResponse.internal_error()` — status 500,
#     `content-length: 0`. The `Error` is dropped on the floor.
#   * a chain that answers the same empty 500 whenever no error mapper is
#     configured.
#   * an error mapper that appends the message to a `List[String]` FIELD
#     with ZERO readers outside its own two accessors. On a hosted platform
#     an operator reads stdout/stderr; a private in-process list is not
#     observable by anything, so the message never leaves the process.
#
# Net: nothing on the wire, nothing in the log — a 500 with no artifact to
# read.
#
# =============================================================================
# THE DISCLOSURE SPLIT, AND WHY IT IS DRAWN HERE AND NOT ELSEWHERE
# =============================================================================
#
# An error body that names an internal collection, a project id or a secret
# name is a disclosure. An error body that says only "internal error" is the
# dead end above. So the split is:
#
#   ON THE WIRE   — a STABLE, NON-SECRET cause `code` + an `incidentId`.
#                   Nothing derived from the raise text.
#   IN THE LOG    — the incident id + the RAW detail, one line, stdout.
#
# ⚠ THIS IS DELIBERATELY STRICTER THAN THE REPO'S EXISTING PRECEDENT, and the
# difference is the SIZE OF THE POPULATION, not squeamishness.
# `komira_handler_kit.error_envelope.serialize_error_response` puts `String(e)`
# straight into the response body — and that is FINE there, because it covers
# one audited surface (a read / serialize fault on a known store call) whose
# error texts were reviewed. THIS boundary catches every uncaught raise from
# every handler, every store, every codec, on every route. That population
# cannot be pre-cleared for disclosure, so it does not go on the wire. An
# operator loses nothing: the id in the response leads to the line in the log.
#
# ⚠ THE QUERY STRING IS NEVER LOGGED. `HttpRequest` keeps `path` and
# `query_string` as separate fields, and the query component is exactly where a
# credential shows up (`?token=`, `?code=`, a signed URL). The path is logged
# because an operator cannot act without knowing the route; it carries ids, not
# credentials.
#
# ⚠ CR/LF IN THE DETAIL IS FOLDED TO A SPACE. The detail is the one field on
# the line that can contain client-influenced bytes, and a raw newline there
# would let a raise forge a SECOND log line — the log-injection shape the
# error-mapper suite has always tested for on the response body, applied to the
# sink that now actually exists.
#
# =============================================================================
# REFUSAL vs FAULT — the distinction this file exists to make legible
# =============================================================================
#
# A deliberate fail-closed REFUSAL and an unexpected FAULT must not look alike
# to an operator: a 503 a route returns ON PURPOSE (say, because a store it
# needs is not configured) is working as designed, and must not read as a
# defect.
#
# The two populations are already structurally distinct and the boundary does
# not have to guess between them:
#
#   REFUSAL — the dispatcher RETURNS a response it chose, with its own status
#             and its own code (`ApiError` / `render_error_envelope`). It never
#             reaches this file. `report_fault` MUST NOT rewrite it — see
#             `map_chain_error`'s contract and the direction-2 falsifier.
#   FAULT   — a RAISE reached the boundary. That is this file's whole subject.
#
# The residue is a refusal EXPRESSED AS A RAISE (e.g. a dispatcher raising
# "backend not configured"), which lands here and is rendered
# `internal.unattributed`. The boundary deliberately does NOT try to classify
# it — guessing a refusal from error text is substring archaeology and would be
# wrong in both directions. What it does instead is make the anonymity VISIBLE
# and the raise text READABLE: `code=internal.unattributed` names the gap, and
# the operator now sees the actual sentence in the log. Converting those raise
# sites into declared refusals is route work, and belongs to the route owner.
#
# =============================================================================

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_clock import now_ns as _now_ns
from komira_log.log_write import LineWrite, write_log_line
from komira_log.structured_log import (
    SEVERITY_ERROR,
    StructuredLogLine,
    TRACE_HEADER,
    qualified_trace,
    trace_id_from_header,
)

# The `wiring_unwired` value meaning "this boundary was not told". Reporting 0
# there would be a LIE: 0 is
# the value that means "wiring complete", so an un-plumbed call site would
# assert a clean deployment it never checked. `-1` renders as `unknown`.
comptime WIRING_UNWIRED_UNKNOWN: Int = -1


# =============================================================================
# §1 — the cause-code vocabulary.
# =============================================================================
#
# Codes are STABLE, NON-SECRET, dotted identifiers emitted verbatim into the
# envelope. They name a CLASS of cause, never an instance — no collection name,
# no project id, no account id, nothing read out of the raise.

# The raise carried no declared cause. This is the honest code for "the
# boundary caught something and cannot name it" — and it is the string the
# falsifier keys on, because a deployment that emits it is telling you a raise
# site still needs a cause. It is NOT a failure of this mechanism: an
# unattributed fault with an incident id and a log line is diagnosable in
# seconds, which an empty 500 never was.
comptime FAULT_CODE_UNATTRIBUTED: String = "internal.unattributed"

# The transport caught a raise OUTSIDE any middleware chain (the unchained
# `serve_one_iteration_dispatch` path). Distinguished from the chained code so
# an operator can tell WHICH boundary answered without reading the source.
comptime FAULT_CODE_TRANSPORT: String = "internal.transport_fault"

# `source` values. THE FIELD THAT SEPARATES A REFUSAL FROM A FAULT IN THE LOG.
#
# ⚠ THIS IS THE OTHER HALF OF THE MECHANISM. A handler that RETURNS a
# deliberate 5xx (say a 503 carrying operator-actionable refusal text
# VERBATIM) is
# not broken —
# it is a deliberate, well-formed answer. It RETURNS, so it
# never raises, so it never reaches the fault path above, so without this arm
# it is logged by NOTHING. An operator reading logs sees silence and concludes defect.
#
# So the general mechanism is two arms, not one:
#   RAISE    -> attributed, and the response is CREATED here    (`report_fault`)
#   RETURNED -> OBSERVED, and the response is NOT TOUCHED  (`observe_error_response`)
#
# Both emit at severity ERROR under the same schema, so one query finds both,
# and `source` is what tells them apart. Collapsing the two — logging them
# identically, or worse, rewriting the returned one so it "has a code too" — is
# precisely what direction 2 of the falsifier fails on.
comptime FAULT_SOURCE_RAISE: String = "raise"
comptime FAULT_SOURCE_RESPONSE: String = "returned"


# =============================================================================
# §2 — incident ids.
# =============================================================================


def new_incident_id() -> String:
    """A short, opaque correlation id tying a response to its log line.

    Derived from the monotonic clock, NOT from a UUID generator, for one
    reason: this runs inside an `except` arm on the response path, and
    `generate_uuidv7` raises. A correlation id whose construction can itself
    fail is a correlation id that goes missing exactly when a fault is already
    in flight. `now_ns()` cannot fail and is unique per request on a host at
    nanosecond resolution; a collision costs an operator one extra grep, which
    is not the failure mode worth engineering against here.

    Opaque by construction — it encodes only a boot-relative timestamp, so it
    discloses nothing about the request, the account, or the deployment."""
    return _hex16(_now_ns())


def _hex16(v: UInt64) -> String:
    """Lower-case, zero-padded 16-hex-digit rendering of a `UInt64`."""
    var digits = String("0123456789abcdef")
    var dref = digits.as_bytes()
    var out = String("")
    var i = 15
    while i >= 0:
        var nib = Int((v >> UInt64(i * 4)) & UInt64(0xF))
        out += chr(Int(dref[nib]))
        i = i - 1
    return out^


# =============================================================================
# §3 — the log line (the ONLY place the raw detail is written).
# =============================================================================


# (A local CR/LF folder used to live here. It is GONE, not disabled:
# `StructuredLogLine` escapes every byte below 0x20 via `json_escape`, which is
# a strictly stronger version of the same property — a raw 0x01 makes the line
# invalid JSON and the collector DROPS it, which would be a silent logger. Two
# overlapping sanitizers would mean neither is the one to read when the rule
# changes.)


def fault_log_line(
    incident: String,
    code: String,
    status: Int32,
    method: String,
    path: String,
    detail: String,
    wiring_unwired: Int,
    trace: String,
    trace_project: String,
) -> String:
    """The EXACT single line this boundary writes for one fault — rendered, not
    emitted, so a test can assert the bytes without capturing stdout.

    ⚠ IT IS STRUCTURED JSON, NOT `key=value` FREE TEXT, AND THAT IS A
    REQUIREMENT — the correction that a `key=value` `print` does NOT satisfy.
    Free text lands in Cloud Logging's `textPayload` at severity DEFAULT, so:
    it is invisible to `severity>=ERROR` (the filter an operator actually
    types), and it carries no field in common with the REQUEST entry that
    records the 500: several 5xx request entries and stdout lines with
    **no field in common but the timestamp** — and a
    timestamp join stops being a join under concurrency. A single-line JSON
    object is lifted into `jsonPayload`, `severity` is promoted onto the entry,
    and `logging.googleapis.com/trace` JOINS it to the request entry.

    `detail` (the raw `String(e)`) goes through `redact_log_text` inside
    `StructuredLogLine` — EVERY value does, not the ones a caller remembers to
    wrap. `path` is the path ONLY; the caller must never pass the query string
    (header, §2).

    `wiring_unwired` is the count of capabilities this deployment booted
    WITHOUT — the join with the boot report that previously spoke to nobody.
    `WIRING_UNWIRED_UNKNOWN` renders `unknown` rather than the misleading 0.
    Only the COUNT travels; the NAMES stay in the boot log.

    `trace_project` is the cloud project id the canonical trace field is
    qualified with (`projects/<id>/traces/<trace>`). The process supplies it
    from its configuration; an empty one omits that field and keeps the plain
    `trace_id`."""
    var line = StructuredLogLine(SEVERITY_ERROR, String("http fault"))
    line.with_str("incident_id", incident)
    line.with_str("cause_code", code)
    line.with_str("source", FAULT_SOURCE_RAISE)
    line.with_int("status", Int(status))
    line.with_str("method", method)
    line.with_str("route", path)
    if wiring_unwired == WIRING_UNWIRED_UNKNOWN:
        line.with_str("wiring_unwired", String("unknown"))
    else:
        line.with_int("wiring_unwired", wiring_unwired)
    if trace.byte_length() > 0:
        var tid = trace_id_from_header(trace)
        # The plain field always: it is what an operator joins on when the
        # process supplies no project id.
        line.with_str("trace_id", tid)
        # The CANONICAL field only when it can be built correctly. A malformed
        # `logging.googleapis.com/trace` is silently ignored by the collector,
        # which looks exactly like the feature working.
        var qual = qualified_trace(tid, trace_project)
        if qual.byte_length() > 0:
            line.with_str("logging.googleapis.com/trace", qual)
    line.with_str("detail", detail)
    return line.render()


def error_response_log_line(
    status: Int32,
    method: String,
    path: String,
    detail: String,
    trace: String,
    trace_project: String,
) -> String:
    """The EXACT line written for a 5xx the handler RETURNED (a deliberate
    refusal, or any error response it chose) — rendered, not emitted.

    ⚠ A DELIBERATE 5xx IS THIS ARM. A handler that answers a 503 refusal
    whose text names the configuration to set
    is CORRECT and
    passes that text through verbatim. Nothing
    about that response needs fixing. It would be logged by NOTHING, because it
    RETURNS rather than raises, and every other diagnostic on this boundary
    hangs off the `except` arm. An operator reading logs sees silence, and silence reads
    as defect.

    ⛔ THIS FUNCTION DOES NOT TOUCH THE RESPONSE, AND MUST NOT. Observing is
    the entire job. The tempting next step — "while we're here, give it an
    incident id too" — rewrites a deliberate answer, destroys the operator text
    that makes it actionable, and is exactly what direction 2 of the falsifier
    fails on. The response is an input here, by `ref`, and no returned value
    replaces it.

    `detail` is the response BODY for a 5xx: our own envelope or refusal text,
    never request or user content. It is capped and redacted by `StructuredLogLine`
    like every other value. A 2xx body IS user content and must never be
    passed here — the caller gates on `status >= 500`."""
    var line = StructuredLogLine(SEVERITY_ERROR, String("http error response"))
    line.with_str("cause_code", String("returned.error_response"))
    line.with_str("source", FAULT_SOURCE_RESPONSE)
    line.with_int("status", Int(status))
    line.with_str("method", method)
    line.with_str("route", path)
    if trace.byte_length() > 0:
        var tid = trace_id_from_header(trace)
        line.with_str("trace_id", tid)
        var qual = qualified_trace(tid, trace_project)
        if qual.byte_length() > 0:
            line.with_str("logging.googleapis.com/trace", qual)
    line.with_str("detail", detail)
    return line.render()


def response_body_text(ref resp: HttpResponse) -> String:
    """The response body as text, for the log detail of a 5xx.

    ⚠ CALLERS MUST GATE ON `status >= 500`. A 2xx body is user content and
    has no business in a retained, replicated log line; a 4xx is the caller's
    own error and logging it at ERROR trains operators to ignore ERROR."""
    var out = String("")
    var i = 0
    var n = len(resp.body)
    while i < n:
        out += chr(Int(resp.body[i]))
        i = i + 1
    return out^


def observe_error_response(
    ref resp: HttpResponse,
    method: String,
    path: String,
    trace: String,
    trace_project: String,
):
    """Emit the observation line for a 5xx the handler RETURNED. Returns
    NOTHING and takes the response by `ref` — the type signature is the
    guarantee that observing cannot become rewriting."""
    if resp.status < Int32(500):
        return
    _emit_line(
        error_response_log_line(
            resp.status,
            method,
            path,
            response_body_text(resp),
            trace,
            trace_project,
        )
    )


def _emit_line(line: String):
    """Write `line` + newline to fd 1 with ONE unbuffered `write(2)`, and if
    that does not land WHOLE, say so on fd 2.

    ⚠ NOT `print`, AND THE REASON IS THE SUBJECT MATTER. `print` goes through a
    userspace buffer; when stdout is a pipe (which it is under a container log
    collector) that buffer is block-buffered, so a fault line can still be
    sitting in it when the process dies. A container that is SIGKILLed — the
    Cloud Run norm on a crash, an OOM, or a revision replace — takes the buffer
    with it, and the line describing WHY is exactly the line lost. A diagnostic
    that survives only a graceful exit is not a diagnostic for the crashing
    case.

    One `write` per line also keeps the line ATOMIC. `O_APPEND` writes under
    PIPE_BUF are not interleaved by the kernel, so two workers faulting
    concurrently cannot splice half of one JSON object into the other — which
    would produce an unparseable entry that the collector drops, i.e. a silent
    logger.

    ★ AND A PARTIAL WRITE DOES THE SAME DAMAGE AS THAT SPLICE, WHICH IS WHY
    THIS LOOP IS NOT HAND-WRITTEN: a hand-written
    write loop that
    `break`s on the first non-positive `write(2)` return, with no retry, no
    errno classification and nothing counted, truncates under pressure. This line is JSON, so a truncated
    write does not produce a damaged entry the collector keeps — it produces an
    unparseable one the collector DROPS, which is the same silent logger the
    paragraph above exists to prevent. And it fires during a 5xx burst, exactly
    when fd 1 is most likely to be congested and the diagnostic matters most.
    `komira_log.log_write` classifies the errno, retries EINTR/EAGAIN within a
    bounded budget, and gives up at once on a dead fd."""
    _ = emit_line_to_fd(Int32(1), line)


def emit_line_to_fd(fd: Int32, line: String) -> LineWrite:
    """`_emit_line`'s seam: the same emission against a caller-named fd,
    returning what happened.

    ⚠ IT EXISTS FOR TWO REASONS, AND ONLY ONE OF THEM IS THE TEST. The other is
    that `komira_log.structured_log.emit()` is being converted from a buffered
    `print` to an unbuffered `write(2)` modelled on this function — so this is
    about to be a template, and a template whose failure handling is inlined
    into a `def f(line: String)` cannot be reused without transcribing it,
    which is how the three-copy defect happened in the first place.

    THE FALLBACK IS AN SOS ON THE OTHER FD, NOT A COUNTER, and that is a
    deliberate divergence from the two `komira_log` sinks. Those hang their
    counters on a process-static owner (`LogConfig` owns the `StderrSink`,
    `SharedEngine` owns the `LogSink`); this is a free function with no owner,
    and Mojo 1.0.0 has no mutable module-level globals — a counter here would
    need a new C translation unit, which is far more machinery than the
    diagnostic warrants. An SOS on fd 2 is strictly better evidence anyway: the
    collector ingests stderr too, so the INCIDENT ID survives even when the
    JSON envelope carrying it did not, and an operator who has the id from the
    HTTP response can still find the fault.

    ⛔ IT DOES NOT RAISE, and it does not retry the SOS. `the core packages
    fd_write_all.mojo` rules that a logger gives up rather than wedges the
    process; a diagnostic about a failed diagnostic must be even less
    insistent than the thing it describes."""
    var outcome = write_log_line(fd, line + String("\n"))
    if not outcome.complete():
        # One attempt, on the OTHER fd, plain text rather than JSON — the
        # collector's JSON parser is not the thing to depend on while
        # reporting that a JSON line was mangled. Its own outcome is
        # deliberately ignored: if fd 2 is broken too there is nowhere left
        # to say so, and looping would be the spin this whole change exists
        # to avoid.
        _ = write_log_line(Int32(2), fault_sos_line(fd, outcome, line))
    return outcome^


def fault_sos_line(fd: Int32, imm outcome: LineWrite, line: String) -> String:
    """The stderr SOS for a fault line that did not land whole. Pure, so what
    an operator will actually read is assertable without breaking fd 2.

    It carries the ORIGINAL line, not a summary. The fault line's whole purpose
    is to be the only place the incident id and the raw cause exist — the HTTP
    response carries the id and nothing else, by the disclosure split at the
    top of this file — so an SOS that said merely "a line was lost" would leave
    the operator holding an id that leads nowhere."""
    var what = String("LOST")
    if outcome.truncated():
        what = String("TRUNCATED")
    return (
        String("komira_http: fault report line ")
        + what
        + String(" on fd ")
        + String(Int(fd))
        + String(" after ")
        + String(outcome.written)
        + String(" of ")
        + String(outcome.total)
        + String(" bytes, errno=")
        + String(Int(outcome.last_errno))
        + String(
            ". The JSON envelope did not land whole, so the collector will"
            " drop it rather than keep a damaged copy; this line carries what"
            " it said: "
        )
        + line
        + String("\n")
    )


def trace_header_of(ref req: HttpRequest) -> String:
    """The `X-Cloud-Trace-Context` value, or "" — and it CANNOT RAISE.

    A `Dict` lookup raises on a missing key, and the transport rounds that need
    this are non-raising by signature. Swallowing here rather than at each call
    site keeps the property where it belongs: a diagnostic that raises into the
    serve loop would turn a logged 500 into a DROPPED CONNECTION, which is
    strictly worse than the silence being fixed."""
    try:
        if String(TRACE_HEADER) in req.headers:
            return req.headers[String(TRACE_HEADER)]
    except e:
        _ = e
    return String("")


# =============================================================================
# §4 — the wire envelope.
# =============================================================================


def _json_escaped(s: String) -> String:
    """Minimal JSON string-escape (quoted, with the mandatory escapes). Local
    rather than imported: `komira_http` must not depend on an application
    package, and `komira_handler_kit.error_envelope` lives above this layer."""
    var out = String('"')
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c == UInt8(34):
            out += String('\\"')
        elif c == UInt8(92):
            out += String("\\\\")
        elif c == UInt8(10):
            out += String("\\n")
        elif c == UInt8(13):
            out += String("\\r")
        elif c == UInt8(9):
            out += String("\\t")
        elif c < UInt8(32):
            out += String(" ")
        else:
            out += chr(Int(c))
        i = i + 1
    out += String('"')
    return out^


def fault_envelope(
    status: Int32,
    code: String,
    incident: String,
    message: String,
) -> HttpResponse:
    """`{"error":{"code":...,"message":...,"incidentId":...}}` at `status`.

    ⚠ SHAPE CHOICE. This is the common error-envelope shape for deliberate
    refusals, with `incidentId` added.
    That is the point: a fault and a refusal PARSE THE SAME WAY and are
    told apart by `code`, not by the shape of the body. A `text/plain`
    "Internal Server Error" default would make a client special-case
    the fault path, and an operator could not tell a 500 from a 503 by reading
    a body that said nothing in either case. The field names are generic HTTP
    error vocabulary, not any one application's — nothing app-specific is
    compiled in here.

    `message` is STATIC caller-supplied text (never the raise message) and is
    escaped anyway. `code` and `incident` are known-safe by construction."""
    var body = String('{"error":{"code":')
    body += _json_escaped(code)
    body += String(',"message":')
    body += _json_escaped(message)
    body += String(',"incidentId":')
    body += _json_escaped(incident)
    body += String("}}")

    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/json")
    # The id is ALSO a header so an operator can correlate with `curl -I`, and
    # so it survives any intermediary that replaces the body.
    r.headers[String("x-incident-id")] = incident
    var bytes_ref = body.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        r.body.append(bytes_ref[i])
        i = i + 1
    r.headers[String("content-length")] = String(n)
    return r^


# =============================================================================
# §5 — report_fault — the ONE composite entry point.
# =============================================================================


def report_fault(
    e: Error,
    status: Int32,
    code: String,
    method: String,
    path: String,
    message: String,
    wiring_unwired: Int,
    trace: String,
    trace_project: String,
) -> HttpResponse:
    """Attribute one boundary-caught raise: emit the structured log line, return
    the envelope. EVERY boundary that answers a fault calls exactly this — a
    per-site copy is a per-site chance to re-grow the `_ = e` discard.

    Returns a response that ALWAYS carries a non-empty `code` and a non-empty
    `incidentId`; that invariant is what the direction-1 falsifier asserts."""
    var incident = new_incident_id()
    _emit_line(
        fault_log_line(
            incident,
            code,
            status,
            method,
            path,
            String(e),
            wiring_unwired,
            trace,
            trace_project,
        )
    )
    return fault_envelope(status, code, incident, message)
