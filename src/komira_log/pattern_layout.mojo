# =============================================================================
# komira_log.pattern_layout — render a record to a human-readable line.
# =============================================================================
#
# The P1 layout: `{ts} {LEVEL} [{module}] {message} {k=v fields}`
#
#   2026-10-01T14:32:07.182Z INFO [komira_job_supervisor] job abc finished phase=DONE
#
# `{message}` is the `fmt` literal with its `{}` placeholders substituted
# left-to-right by the POSITIONAL rendered args (the structured-positional
# model — each `{}` is a typed field). Trailing `Field` (key=value) args are
# appended after the message as ` key=value` pairs (the explicit-structured
# model). Both come from the SAME `*args` pack — the layout walks the
# already-rendered strings + a parallel "is this a key=value Field" flag.
#
# The facade pre-renders each arg to a `String` and tags whether it is a
# positional value or a key=value `Field`, so the layout is a pure string
# operation with no trait dispatch (the trait `@parameter for` happens in the
# facade where the comptime pack is in scope).
#
# Timestamp: P1 uses wall-clock `now_unix_ms()` formatted as an ISO-ish
# `YYYY-MM-DDThh:mm:ss.mmmZ` for readability (the design's stated P1 option —
# the raw-counter is a P2 optimization). We format from the epoch-ms integer
# with a small civil-date computation (no `strftime` FFI needed).
#
# Encapsulation: pure string building; no pointers, no slab storage. The one
# exception is the process-global layout selector (`select_log_layout`), a
# one-word C cell set at startup.
# =============================================================================

from std.ffi import external_call

from komira_log.levels import level_name
from komira_log.structured_log import (
    gcp_severity_for_level,
    json_escape,
    log_format_is_json,
)


# -----------------------------------------------------------------------------
# THE LAYOUT SELECTOR — one process-global decision, made at startup.
#
# Every line in a process renders in ONE layout, decided once from two facts the
# binary was given: its `--log-format` value (`json` / `text`, empty when not
# supplied) and whether it runs on a deployed platform (a flag the deployer
# sets). `komira_log.structured_log.log_format_is_json` combines them; the
# answer is parked in a one-word C cell (`engine/_log_holder_shim.c`) so every
# render site — the P1 `render_line` and the drain's runtime-module twin —
# reads the SAME decision and neither threads it as a parameter two call sites
# could disagree about. Until a binary selects, the layout is TEXT, which is
# what an unconfigured local process has always rendered.
# -----------------------------------------------------------------------------


def select_log_layout(log_format: String, on_deployed_platform: Bool):
    """Select the process's line layout: JSON iff `log_format` says `json`, or
    it is empty/malformed and the process runs on a deployed platform (see
    `komira_log.structured_log.log_format_is_json` for the full rule).

    Call at startup, before workers exist; `config.init_logging_from_spec`
    calls it. A later call re-selects (tests use that to drive both arms)."""
    var json = log_format_is_json(log_format, on_deployed_platform)
    external_call["komira_log_layout_set", NoneType](
        Int32(1) if json else Int32(0)
    )


@always_inline
def log_layout_is_json() -> Bool:
    """The selected layout: True = Cloud-Logging JSON, False = the text line.
    A single aligned load of the C cell."""
    return external_call["komira_log_layout_get", Int32]() != Int32(0)


# -----------------------------------------------------------------------------
# Interpolate `fmt`'s `{}` placeholders with positional values, left-to-right.
# A `{{` escapes a literal `{`; `}}` escapes a literal `}` (mirrors Mojo/Rust
# format conventions so a fmt that wants a literal brace can produce one).
# -----------------------------------------------------------------------------


def interpolate(fmt: String, positionals: List[String]) -> String:
    var out = String("")
    var fb = fmt.as_bytes()
    var n = len(fb)
    var ai = 0
    var k = 0
    while k < n:
        var c = fb[k]
        if c == UInt8(ord("{")):
            if k + 1 < n and fb[k + 1] == UInt8(ord("{")):
                out += "{"
                k += 2
                continue
            if k + 1 < n and fb[k + 1] == UInt8(ord("}")):
                if ai < len(positionals):
                    out += positionals[ai]
                    ai += 1
                else:
                    out += "{}"
                k += 2
                continue
            # A lone '{' that is not '{{' or '{}' — emit verbatim.
            out += "{"
            k += 1
        elif c == UInt8(ord("}")):
            if k + 1 < n and fb[k + 1] == UInt8(ord("}")):
                out += "}"
                k += 2
                continue
            out += "}"
            k += 1
        else:
            # BYTE-EXACT literal copy. ⛔ NOT `out += chr(Int(c))` — `chr` maps
            # a CODE POINT to its UTF-8 ENCODING, so every literal byte >= 0x80
            # of the format string was RE-ENCODED into two and EVERY rendered
            # log line built from a non-ASCII `fmt` would be mojibaked (`用户 {}`
            # and any message with an accented word). ASCII is the corruption's
            # fixed point, which is why an ASCII-only layout suite cannot see
            # it. Runs of literal bytes are copied in one go, which also drops
            # the per-byte `String` append.
            var run_start = k
            while k < n:
                var lc = fb[k]
                if lc == UInt8(ord("{")) or lc == UInt8(ord("}")):
                    break
                k += 1
            var run = List[UInt8]()
            for j in range(run_start, k):
                run.append(fb[j])
            out += String(StringSlice(unsafe_from_utf8=Span(run)))
    return out


# -----------------------------------------------------------------------------
# Wall-clock timestamp formatting: epoch-ms → `YYYY-MM-DDThh:mm:ss.mmmZ` (UTC).
# A self-contained civil-date computation (Howard Hinnant's days-from-civil
# inverse) so no `gmtime`/`strftime` FFI is needed. Microsecond cost, off the
# disabled path (only runs on an enabled, formatted line).
# -----------------------------------------------------------------------------


def _pad2(v: Int) -> String:
    if v < 10:
        return "0" + String(v)
    return String(v)


def _pad3(v: Int) -> String:
    if v < 10:
        return "00" + String(v)
    elif v < 100:
        return "0" + String(v)
    return String(v)


def format_timestamp_ms(epoch_ms: Int64) -> String:
    """Format milliseconds-since-Unix-epoch as `YYYY-MM-DDThh:mm:ss.mmmZ`."""
    var ms_total = Int(epoch_ms)
    if ms_total < 0:
        ms_total = 0
    var secs = ms_total // 1000
    var millis = ms_total % 1000
    var days = secs // 86400
    var rem = secs % 86400
    var hour = rem // 3600
    var minute = (rem % 3600) // 60
    var second = rem % 60

    # days -> civil (y, m, d). Hinnant's algorithm with epoch shifted to
    # 0000-03-01. days here are days since 1970-01-01.
    var z = days + 719468
    # Mojo's `//` floors, so Hinnant's truncation adjustment for a negative
    # `z` is not needed (and would make the era one too low).
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1

    return (
        String(y)
        + "-"
        + _pad2(Int(m))
        + "-"
        + _pad2(Int(d))
        + "T"
        + _pad2(Int(hour))
        + ":"
        + _pad2(Int(minute))
        + ":"
        + _pad2(Int(second))
        + "."
        + _pad3(Int(millis))
        + "Z"
    )


# -----------------------------------------------------------------------------
# Assemble the full line: `{ts} {LEVEL} [{module}] {message}{ k=v...}`.
# `message` is the interpolated fmt; `fields` are the already-rendered
# `key=value` strings from trailing `Field` args (each appended with a leading
# space). The line is returned WITHOUT a trailing newline (the sink adds it).
# -----------------------------------------------------------------------------


# =============================================================================
# THE JSON LAYOUT — the level has to survive the trip to the log collector.
# =============================================================================
#
# Free text written to stdout or stderr lands in Cloud Logging at severity
# **DEFAULT**, on BOTH streams, so a filter like `severity>=ERROR` matches none of
# a text logger's ERROR lines: the level is a WORD inside a free-text line and
# nothing downstream ever reads it again. `OutputSink.write_line_core` branches
# on the SINK KIND and never on `rec.level`, so the layout is the only place the
# level can be carried.
#
# A single-line JSON object on stdout/stderr is instead lifted into
# `jsonPayload`, with `severity`, `message` and `time` promoted onto the
# LogEntry itself. That is the shape this layout emits, and it is the shape
# `komira_log.structured_log` emits for its own lines.
#
# ⭐ `time` IS A PROMOTED KEY — VERIFIED, not assumed. Cloud Logging's structured
# logging searches `jsonPayload` for time-related fields, takes `time` when it is
# an RFC 3339 string, uses it to set `LogEntry.timestamp`, and REMOVES it from
# `jsonPayload` (Cloud Logging's structured-logging documentation). It is worth
# stating because `komira_log.structured_log`'s own list of promoted keys does
# NOT include it. `format_timestamp_ms` already emits exactly
# `YYYY-MM-DDThh:mm:ss.mmmZ`, which is RFC 3339.
#
# WHAT IS DELIBERATELY *NOT* IN THE JSON `message`: the timestamp, the level and
# the module. Each is now its OWN promoted or queryable field, and duplicating
# them inside the display text would make the structured line strictly less
# useful than the text one it replaces.
#
# ⚠ `redact_log_text` IS NOT APPLIED HERE, AND THAT IS A DECISION.
# `komira_log.structured_log.StructuredLogLine` applies it to every value, correctly: its input
# is 5xx RESPONSE BODIES — customer content a handler produced. `komira_log`'s
# input is a call site's OWN `fmt` plus its typed args, it is the SDK/engine
# logger (orders of magnitude more lines), and `redact_log_text` is several O(n)
# passes with a 15-key scan and a `String` append per byte. Two reasons, and the
# first is the load-bearing one:
#   1. THE TEXT LAYOUT DOES NOT REDACT TODAY. Redacting only in the JSON arm
#      would mean that selecting the JSON layout silently changes the CONTENT
#      of log lines, not just their envelope: "my log line says <redacted> now"
#      would appear with no change to the call site.
#   2. Cost, on the highest-volume logger there is.
# ⛔ THE EXPOSURE, STATED PLAINLY: it is byte-for-byte the exposure of the text
# layout. The same bytes reach the collector as text from the same process; the
# JSON layout changes the envelope, not the channel, and widens nothing. A
# call site whose payload genuinely needs scrubbing must route through
# `komira_log.structured_log.StructuredLogLine`, which is what the 5xx path does.


comptime _JSON_KEY_SEVERITY: StaticString = "severity"
comptime _JSON_KEY_MESSAGE: StaticString = "message"
comptime _JSON_KEY_TIME: StaticString = "time"
comptime _JSON_KEY_MODULE: StaticString = "module"


def _json_field_key(raw: String) -> String:
    """The JSON key a trailing `Field` token may use.

    ⭐ A FIELD MAY NOT SHADOW ONE OF THE FOUR KEYS THE LAYOUT ITSELF EMITS.
    `Field("severity", "whatever")` would otherwise put a SECOND `severity` key
    in the object; JSON permits duplicates and a reader takes one of them, so
    the caller's field could silently win and the record's real level would be
    lost — a fresh instance of the exact defect this layout exists to close.
    A colliding key is prefixed `f_` instead of dropped, because dropping a
    field the caller asked for is a silent lie about what was logged."""
    if (
        raw == String(_JSON_KEY_SEVERITY)
        or raw == String(_JSON_KEY_MESSAGE)
        or raw == String(_JSON_KEY_TIME)
        or raw == String(_JSON_KEY_MODULE)
    ):
        return String("f_") + raw
    return raw


def render_json_line(
    epoch_ms: Int64,
    level: UInt8,
    module: String,
    message: String,
    fields: List[String],
) -> String:
    """ONE line of Cloud-Logging-shaped JSON, newline excluded.

        {"severity":"ERROR","message":"...","time":"2026-10-01T19:35:25.081Z",
         "module":"komira_http","k":"v",...}

    ⛔ THIS IS *THE* JSON BODY — BOTH layouts call it. `pattern_layout.
    render_line` (comptime `StaticString` module) and `engine/drain.
    _render_runtime_module` (runtime `String` module from the site dictionary)
    both dispatch here, exactly as `drain.mojo` already demands of the TEXT
    layout: *"⛔ IT RE-STATES NO LAYOUT ... so a mirrored line and a
    sink-drained line cannot drift."* If this changes, both change or neither
    compiles.

    `fields` arrive as already-joined `"key=value"` strings (that is what
    `_decode_args` and `render_record_view` produce). Each is split on the
    **FIRST** `=` only, so a value that itself contains `=` — a base64 pad, a
    query string, a DSN — survives intact. A token with NO `=` is emitted as a
    key with an EMPTY string value rather than dropped: the token's text is
    preserved, the object stays valid JSON, and two distinct such tokens stay
    two distinct keys.

    ⛔ MULTI-LINE IS A DIFFERENT LOG ENTRY. The collector splits on newline, so
    a message containing one is not a big entry, it is a broken entry followed
    by a garbage entry. Every string that goes in here goes through
    `json_escape`, which turns every control byte into its escape — that is
    what makes "one line" a property of the code rather than a hope."""
    var out = String('{"')
    out += String(_JSON_KEY_SEVERITY)
    out += String('":"')
    out += String(gcp_severity_for_level(level))
    out += String('","')
    out += String(_JSON_KEY_MESSAGE)
    out += String('":"')
    out += json_escape(message)
    out += String('","')
    out += String(_JSON_KEY_TIME)
    out += String('":"')
    # Already `YYYY-MM-DDThh:mm:ss.mmmZ` — RFC 3339, the shape Cloud Logging
    # promotes onto `LogEntry.timestamp`. Escaped anyway: a layout that trusts
    # one of its own inputs to be well formed is a layout with one untested arm.
    out += json_escape(format_timestamp_ms(epoch_ms))
    out += String('","')
    out += String(_JSON_KEY_MODULE)
    out += String('":"')
    out += json_escape(module)
    out += String('"')

    for i in range(len(fields)):
        ref tok = fields[i]
        var tb = tok.as_bytes()
        var n = len(tb)
        var eq = 0
        while eq < n and tb[eq] != UInt8(ord("=")):
            eq += 1
        # BYTE-EXACT slices. ⛔ NOT a per-byte `chr` rebuild — see
        # `interpolate` below and `json_escape`'s docstring: `chr` maps a CODE
        # POINT to its UTF-8 ENCODING and doubles every byte >= 0x80.
        var key = String(StringSlice(unsafe_from_utf8=tb[:eq]))
        var val = String("")
        if eq < n:
            val = String(StringSlice(unsafe_from_utf8=tb[eq + 1 :]))
        out += String(',"')
        out += json_escape(_json_field_key(key))
        out += String('":"')
        out += json_escape(val)
        out += String('"')

    out += String("}")
    return out^


def render_line(
    epoch_ms: Int64,
    level: UInt8,
    module: StaticString,
    message: String,
    fields: List[String],
) -> String:
    """Assemble one log line in whichever layout this process should emit.

    ⛔ THE TEXT BODY BELOW IS THE STABLE TEXT LAYOUT, and the default is text:
    `log_layout_is_json()` is False until the binary selects JSON with
    `select_log_layout` (its `--log-format`, or the deployed-platform fact).
    Roughly ten test files in this package assert on the rendered text and must
    keep passing untouched; `test_log_json_severity.test_text_layout_is_byte_identical_by_
    default` is the guard that says so in one place."""
    if log_layout_is_json():
        return render_json_line(
            epoch_ms, level, String(module), message, fields
        )
    var out = format_timestamp_ms(epoch_ms)
    out += " "
    out += String(level_name(level))
    out += " ["
    out += String(module)
    out += "] "
    out += message
    for i in range(len(fields)):
        out += " "
        out += fields[i]
    return out
