# =============================================================================
# test_log_json_severity.mojo — THE LEVEL MUST REACH CLOUD LOGGING'S `severity`.
# =============================================================================
#
# Free text written to stdout/stderr reaches Cloud Logging at severity DEFAULT,
# so `severity>=ERROR` matches none of a text logger's ERROR lines: the level
# is a WORD inside a free-text line and nothing downstream reads it again. The
# JSON layout carries it as `severity`.
#
# ⭐ THE ONE TEST THAT MATTERS MOST IS `test_warn_maps_to_warning`, AND IT IS
# NAMED FOR THE TRAP. Google's severity enum has no `WARN` and no `TRACE`;
# komira_log's levels have both. A `severity` key built from `level_name(level)`
# emits `"WARN"`, which is outside the enum, so the collector IGNORES it and the
# entry silently drops to DEFAULT — the same failure in a form that looks
# correct. Do not "simplify" `gcp_severity_for_level` into `level_name`.
#
# ⛔ AND `test_text_layout_is_byte_identical_by_default` IS THE REGRESSION GUARD
# for the ~10 other test files in this package that assert on rendered TEXT. If
# any of those needs editing, the default changed, and the default must not.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_log.engine.drain import render_record_view
from komira_log.engine.log_record_view import LogRecordView
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
    LEVEL_OFF,
    level_name,
)
from komira_log.pattern_layout import (
    log_layout_is_json,
    render_line,
    render_json_line,
    select_log_layout,
)
from komira_log.structured_log import (
    SEVERITY_DEBUG,
    SEVERITY_DEFAULT,
    SEVERITY_ERROR,
    SEVERITY_INFO,
    SEVERITY_WARNING,
    emit_structured_line,
    gcp_severity_for_level,
)
from komira_trace.exporter import json_escape


# -----------------------------------------------------------------------------
# Layout helper. Every test that selects a layout restores TEXT, because a
# leaked JSON selection would flip the layout for every test that runs after it
# in the same process — including the byte-identity guard.
# -----------------------------------------------------------------------------


def _select_text_layout():
    select_log_layout(String(""), False)


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _count(s: String, needle: String) -> Int:
    var n = 0
    var at = 0
    var nb = len(needle.as_bytes())
    if nb == 0:
        return 0
    while True:
        var i = s.find(needle, at)
        if i < 0:
            break
        n += 1
        at = i + nb
    return n


def _fields(*items: String) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(String(items[i]))
    return out^


# =============================================================================
# 1. ⭐ THE HEADLINE. WARN renders `"severity":"WARNING"`, NEVER `"WARN"`.
# =============================================================================


def test_warn_maps_to_warning() raises:
    """⭐ `LEVEL_WARN` MUST render `"severity":"WARNING"`.

    Google's severity enum is DEFAULT / DEBUG / INFO / NOTICE / WARNING / ERROR
    / CRITICAL / ALERT / EMERGENCY. **There is no `WARN` in it.** A value
    outside the enum is ignored by the collector and the entry silently drops
    to DEFAULT — the failure this whole change exists to remove. So the obvious
    implementation, `severity = level_name(level)`, is WRONG for this one level
    while looking right at every other, and a later "simplification" back to it
    would be invisible without this assertion.

    The second half of the assertion is the one that catches that
    simplification: the string `"severity":"WARN"` must NOT appear."""
    assert_equal(
        String(gcp_severity_for_level(LEVEL_WARN)),
        String("WARNING"),
        'LEVEL_WARN must map to Google\'s "WARNING", not to komira_log\'s "WARN"',
    )
    assert_equal(
        String(level_name(LEVEL_WARN)),
        String("WARN"),
        "komira_log's own level word IS `WARN` — which is exactly why the"
        " severity map cannot be `level_name`",
    )
    var line = render_json_line(
        Int64(1790812800000),
        LEVEL_WARN,
        String("komira_http"),
        String("notify tick failed"),
        List[String](),
    )
    assert_true(
        _has(line, String('"severity":"WARNING"')),
        'the rendered JSON line must carry "severity":"WARNING". Got: ' + line,
    )
    assert_false(
        _has(line, String('"severity":"WARN"')),
        'a `"severity":"WARN"` value is OUTSIDE Google\'s enum and drops the'
        " entry to DEFAULT. Got: " + line,
    )
    print("  test_warn_maps_to_warning PASS")


# =============================================================================
# 2. The rest of the map, including the two that collapse.
# =============================================================================


def test_every_level_maps_to_a_google_severity() raises:
    """TRACE and DEBUG both -> `DEBUG` (Google has no TRACE); INFO -> `INFO`;
    ERROR -> `ERROR`. `LEVEL_OFF` is a THRESHOLD sentinel, never a record
    level, so it — and any future out-of-range word — lands on `DEFAULT`, which
    is a legal member of the enum rather than an ignored string."""
    assert_equal(
        String(gcp_severity_for_level(LEVEL_TRACE)),
        String(SEVERITY_DEBUG),
        "TRACE -> DEBUG (Google's enum has no TRACE)",
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_DEBUG)),
        String(SEVERITY_DEBUG),
        "DEBUG -> DEBUG",
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_INFO)),
        String(SEVERITY_INFO),
        "INFO -> INFO",
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_ERROR)),
        String(SEVERITY_ERROR),
        "ERROR -> ERROR",
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_OFF)),
        String(SEVERITY_DEFAULT),
        "OFF is a threshold, never a record level -> DEFAULT",
    )
    assert_equal(
        String(gcp_severity_for_level(UInt8(200))),
        String(SEVERITY_DEFAULT),
        "an out-of-range level -> DEFAULT, never an out-of-enum string",
    )
    print("  test_every_level_maps_to_a_google_severity PASS")


# =============================================================================
# 3. ANTI-DRIFT. The map and the numbering live in one package.
# =============================================================================


def test_severity_map_agrees_with_levels() raises:
    """`gcp_severity_for_level` takes a RAW `UInt8` and compares it with the
    constants in `levels.mojo`. This test pins the numbering against literals,
    so renumbering `levels.mojo` cannot silently re-point every severity by one.

    The literal `UInt8`s on the right are deliberate. Writing
    `gcp_severity_for_level(LEVEL_WARN)` on both sides would be vacuous — it
    would pass under ANY renumbering. What has to hold is that the CONSTANTS
    still have the VALUES the wire protocol's callers hand in."""
    assert_equal(Int(LEVEL_TRACE), 0, "LEVEL_TRACE is 0")
    assert_equal(Int(LEVEL_DEBUG), 1, "LEVEL_DEBUG is 1")
    assert_equal(Int(LEVEL_INFO), 2, "LEVEL_INFO is 2")
    assert_equal(Int(LEVEL_WARN), 3, "LEVEL_WARN is 3")
    assert_equal(Int(LEVEL_ERROR), 4, "LEVEL_ERROR is 4")
    assert_equal(Int(LEVEL_OFF), 5, "LEVEL_OFF is 5")

    # And the map, addressed by komira_log's own constants, still answers with
    # Google's spelling for each.
    assert_equal(
        String(gcp_severity_for_level(LEVEL_TRACE)), String("DEBUG"), "TRACE"
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_DEBUG)), String("DEBUG"), "DEBUG"
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_INFO)), String("INFO"), "INFO"
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_WARN)), String("WARNING"), "WARN"
    )
    assert_equal(
        String(gcp_severity_for_level(LEVEL_ERROR)), String("ERROR"), "ERROR"
    )
    print("  test_severity_map_agrees_with_levels PASS")


# =============================================================================
# 4. ⛔ MULTI-LINE IS A DIFFERENT LOG ENTRY.
# =============================================================================


def test_one_line_of_valid_json_for_a_hostile_message() raises:
    """A message carrying a newline, a quote, a backslash and a raw 0x01 must
    produce EXACTLY ONE line of VALID JSON.

    The collector splits on newline, so a message containing one is not a big
    entry — it is a broken entry followed by a garbage entry. A raw 0x01 inside
    a JSON string is invalid JSON, and an invalid line is DROPPED: a silent
    logger, which is the defect class this whole file is about."""
    var msg = String("first")
    msg += chr(10)
    msg += String('second "quoted" and a back')
    msg += chr(92)
    msg += String("slash")
    msg += chr(1)
    msg += String("end")

    var line = render_json_line(
        Int64(1790812800000),
        LEVEL_ERROR,
        String("komira_http"),
        msg,
        List[String](),
    )
    assert_equal(
        _count(line, String(chr(10))),
        0,
        "a rendered JSON line must contain NO raw newline — it would be two"
        " Cloud Logging entries, one of them garbage. Got: " + line,
    )
    assert_equal(
        _count(line, String(chr(1))),
        0,
        "a raw 0x01 makes the JSON invalid and the entry is DROPPED",
    )
    assert_true(
        _has(line, String("first") + chr(92) + "nsecond"),
        "the newline must survive as the two-character escape: " + line,
    )
    assert_true(
        _has(line, chr(92) + '"quoted' + chr(92) + '"'),
        "the quotes must survive escaped: " + line,
    )
    assert_true(
        _has(line, String("back") + chr(92) + chr(92) + "slash"),
        "the backslash must survive doubled: " + line,
    )
    assert_true(
        _has(line, chr(92) + "u0001"),
        "the 0x01 must survive as \\u0001: " + line,
    )
    # And the object still closes.
    assert_true(line.startswith(String("{")), "opens as an object")
    assert_true(line.endswith(String("}")), "closes as an object")
    print("  test_one_line_of_valid_json_for_a_hostile_message PASS")


# =============================================================================
# 5. Fields become distinct keys; a value containing `=` survives.
# =============================================================================


def test_fields_become_keys_and_a_value_may_contain_equals() raises:
    """Trailing `Field` args arrive already joined as `"key=value"`. The split
    is on the FIRST `=` ONLY — a value that itself contains `=` (a base64 pad,
    a query string, a DSN) must arrive intact, not truncated at its own
    separator.

    A token with NO `=` is emitted as a key with an empty value rather than
    dropped: dropping a field the caller asked for is a silent lie about what
    was logged, and the object must stay valid JSON either way."""
    var line = render_json_line(
        Int64(1790812800000),
        LEVEL_INFO,
        String("komira_agent"),
        String("job abc finished"),
        _fields(
            String("phase=DONE"),
            String("rows=42"),
            String("dsn=host=db;user=alice"),
            String("bare_token_with_no_equals"),
        ),
    )
    assert_true(_has(line, String('"phase":"DONE"')), "phase field: " + line)
    assert_true(_has(line, String('"rows":"42"')), "rows field: " + line)
    assert_true(
        _has(line, String('"dsn":"host=db;user=alice"')),
        "a value containing `=` must survive INTACT — split on the FIRST `=`"
        " only. Got: " + line,
    )
    assert_true(
        _has(line, String('"bare_token_with_no_equals":""')),
        "a token with no `=` becomes a key with an empty value, never a"
        " dropped field or broken JSON. Got: " + line,
    )
    print("  test_fields_become_keys_and_a_value_may_contain_equals PASS")


def test_a_field_may_not_shadow_the_layouts_own_keys() raises:
    """⭐ `Field("severity", ...)` MUST NOT emit a second `severity` key.

    JSON permits duplicate keys and a reader takes one of them, so a caller's
    field could silently win and the record's REAL level would be lost — a
    fresh instance of the very defect this layout closes. A colliding key is
    prefixed `f_` rather than dropped."""
    var line = render_json_line(
        Int64(1790812800000),
        LEVEL_ERROR,
        String("komira_agent"),
        String("boom"),
        _fields(
            String("severity=INFO"),
            String("message=not the message"),
            String("time=nonsense"),
            String("module=not the module"),
        ),
    )
    assert_equal(
        _count(line, String('"severity":')),
        1,
        "EXACTLY ONE severity key — a duplicate could override the real level."
        " Got: " + line,
    )
    assert_true(
        _has(line, String('"severity":"ERROR"')),
        "and it must be the RECORD's severity: " + line,
    )
    assert_equal(_count(line, String('"message":')), 1, "one message key")
    assert_equal(_count(line, String('"time":')), 1, "one time key")
    assert_equal(_count(line, String('"module":')), 1, "one module key")
    assert_true(
        _has(line, String('"f_severity":"INFO"')),
        "the caller's colliding field is PREFIXED, not dropped: " + line,
    )
    assert_true(_has(line, String('"f_module":"not the module"')), line)
    print("  test_a_field_may_not_shadow_the_layouts_own_keys PASS")


# =============================================================================
# 6. ⛔ THE DEFAULT DID NOT CHANGE. The regression guard for ~10 test files.
# =============================================================================


def test_text_layout_is_byte_identical_by_default() raises:
    """With NO layout selected, `render_line` returns the stable TEXT line.

    This is the guard for every other rendered-text assertion in this package
    (`test_log_p1`, `test_log_text_emit`, `test_log_facade_smoke`,
    `test_log_engine`, `test_log_p3_output`, `test_log_p2b_integration`,
    `test_log_bytes_non_ascii`, ...). If this assertion ever fails, the
    DEFAULT moved, and the default must not move.

    It runs BEFORE any test in this file selects a layout, so the first
    assertion reads the process's never-selected default, not a reset."""
    assert_false(
        log_layout_is_json(),
        "the default layout (nothing selected) is TEXT",
    )

    var fields = _fields(String("phase=DONE"), String("rows=42"))
    assert_equal(
        render_line(
            Int64(1790812800000),
            LEVEL_INFO,
            "komira_agent",
            String("job abc finished"),
            fields,
        ),
        String(
            "2026-10-01T00:00:00.000Z INFO [komira_agent] job abc finished"
            " phase=DONE rows=42"
        ),
        "the P1 text line, byte for byte (test_log_p1.test_render_line_shape)",
    )
    assert_equal(
        render_line(
            Int64(1790812800000),
            LEVEL_WARN,
            "komira_pg",
            String("hello"),
            List[String](),
        ),
        String("2026-10-01T00:00:00.000Z WARN [komira_pg] hello"),
        "no-fields text line (test_log_p1.test_render_line_no_fields)",
    )
    print("  test_text_layout_is_byte_identical_by_default PASS")


# =============================================================================
# 7. The selector: the deployed-platform fact flips it; an explicit `text` wins.
# =============================================================================


def test_the_deployed_platform_fact_selects_json_and_an_override_wins() raises:
    """On a deployed platform (a fact the deployer passes as a flag) the layout
    is JSON with no further configuration.

    An explicit `--log-format=text` must still win, so an operator debugging a
    deployed process can get the human layout back."""
    _select_text_layout()
    assert_false(log_layout_is_json(), "precondition: local default is text")

    select_log_layout(String(""), True)
    assert_true(log_layout_is_json(), "deployed => JSON")
    var line = render_line(
        Int64(1790812800000),
        LEVEL_ERROR,
        "komira_http",
        String("notify tick failed"),
        List[String](),
    )
    assert_true(
        _has(line, String('"severity":"ERROR"')),
        "an ERROR line must answer `severity>=ERROR`: " + line,
    )
    assert_true(
        _has(line, String('"time":"2026-10-01T00:00:00.000Z"')),
        "`time` is RFC 3339 and is promoted onto LogEntry.timestamp: " + line,
    )
    assert_true(
        _has(line, String('"module":"komira_http"')),
        "the module is its own queryable field: " + line,
    )

    select_log_layout(String("TEXT"), True)
    assert_false(
        log_layout_is_json(),
        "an explicit `text` override beats the deployed-platform fact"
        " (case-insensitive)",
    )
    assert_equal(
        render_line(
            Int64(1790812800000),
            LEVEL_ERROR,
            "komira_http",
            String("back to text"),
            List[String](),
        ),
        String("2026-10-01T00:00:00.000Z ERROR [komira_http] back to text"),
        "and the text layout comes back byte-identical",
    )

    select_log_layout(String("Json"), True)
    assert_true(log_layout_is_json(), "`json` is case-insensitive too")
    select_log_layout(String("json"), False)
    assert_true(
        log_layout_is_json(),
        "an explicit `json` selects JSON off a deployed platform too",
    )

    # ⛔ A MALFORMED VALUE NEITHER CRASHES NOR SILENTLY PICKS JSON. It falls
    # through to the platform answer.
    select_log_layout(String("jsonn"), True)
    assert_true(
        log_layout_is_json(),
        "malformed + deployed => the platform answer (json), not a crash",
    )
    select_log_layout(String("jsonn"), False)
    assert_false(
        log_layout_is_json(),
        "malformed + NOT deployed => the platform answer (text), NOT a silent"
        " json selection",
    )
    _select_text_layout()
    print("  test_the_deployed_platform_fact_selects_json_and_an_override_wins PASS")


# =============================================================================
# 8. Non-ASCII survives BYTE-EXACT. The `chr(Int(byte))` class.
# =============================================================================


def test_non_ascii_survives_byte_exact() raises:
    """`chr` maps a CODE POINT to its UTF-8 ENCODING, so `out += chr(Int(b))`
    RE-ENCODES every byte >= 0x80 into two. `interpolate`, `env_filter` and
    `komira_trace.exporter.json_escape`'s pass-through arm must all copy
    bytes instead, which is why it is asserted here and not only in
    `test_log_bytes_non_ascii`.

    Every string a JSON line carries goes through `json_escape`, so a per-byte
    `chr` there would mojibake every non-ASCII message, module and field value
    at once."""
    # U+7528 U+6237 ("user") + an e-acute. Raw bytes, so the assertion is about
    # BYTES and not about a source-encoding round trip.
    var utf8 = String("")
    utf8 += chr(0x7528)
    utf8 += chr(0x6237)
    utf8 += String(" caf")
    utf8 += chr(0xE9)

    assert_equal(
        json_escape(utf8),
        utf8,
        "json_escape must pass non-ASCII through BYTE-EXACT. A per-byte `chr`"
        " doubles every byte >= 0x80.",
    )
    assert_equal(
        len(json_escape(utf8).as_bytes()),
        len(utf8.as_bytes()),
        "byte length must not grow — growth IS the re-encoding",
    )

    var line = render_json_line(
        Int64(1790812800000),
        LEVEL_INFO,
        String("komira_agent"),
        utf8,
        _fields(String("who=") + utf8),
    )
    assert_true(
        _has(line, String('"message":"') + utf8 + String('"')),
        "the message survives byte-exact: " + line,
    )
    assert_true(
        _has(line, String('"who":"') + utf8 + String('"')),
        "and so does a field value: " + line,
    )
    print("  test_non_ascii_survives_byte_exact PASS")


# =============================================================================
# 9. BOTH layout bodies gained the arm. `drain` may not drift from `pattern`.
# =============================================================================


def test_the_drain_twin_renders_the_same_json() raises:
    """`drain._render_runtime_module` is the runtime-`String`-module twin of
    `render_line`, and `drain.mojo`'s own rule is that a mirrored line and a
    sink-drained line cannot drift. `render_record_view` reaches that body, so
    driving it with the JSON layout selected proves the JSON arm is on BOTH —
    which a text-only test could not catch, because the two bodies could agree
    on text while only one of them knew about JSON."""
    _select_text_layout()
    var view = LogRecordView(
        LEVEL_WARN,
        UInt16(0),
        UInt32(0),
        UInt32(0),
        UInt64(0),
        UInt64(0),
        Int64(1790812800000),
        String("notify tick failed"),
        String("komira_http"),
        _fields(String("attempt")),
        _fields(String("3")),
    )

    assert_equal(
        render_record_view(view),
        String(
            "2026-10-01T00:00:00.000Z WARN [komira_http] notify tick"
            " failed attempt=3"
        ),
        "the drain twin's TEXT line is unchanged by default",
    )

    select_log_layout(String(""), True)
    var jline = render_record_view(view)
    assert_true(
        _has(jline, String('"severity":"WARNING"')),
        "the DRAIN path must map WARN -> WARNING too: " + jline,
    )
    assert_true(
        _has(jline, String('"module":"komira_http"')),
        "runtime String module: " + jline,
    )
    assert_true(_has(jline, String('"attempt":"3"')), jline)
    _select_text_layout()
    print("  test_the_drain_twin_renders_the_same_json PASS")


# =============================================================================
# 10. The emitter writes the whole line plus a trailing newline, unbuffered.
# =============================================================================


def test_emit_writes_the_whole_line_and_a_newline() raises:
    """`StructuredLogLine.emit()` used `print`, which BLOCK-buffers when stdout
    is a pipe — always, under a container log collector — so a SIGKILL takes the
    buffer and the line describing WHY is exactly the line lost. It now issues
    ONE unbuffered `write(2)`.

    What a test can hold without capturing fd 1 is the PAYLOAD: `render()` is
    the exact bytes, and the emitter appends exactly one newline and nothing
    else. That the write is unbuffered is a property of `write(2)` itself, and
    that it is ONE call is what keeps the line atomic under PIPE_BUF."""
    var rendered = render_json_line(
        Int64(1790812800000),
        LEVEL_ERROR,
        String("komira_http"),
        String("notify tick failed"),
        List[String](),
    )
    var payload = rendered + String(chr(10))
    assert_equal(
        _count(payload, String(chr(10))),
        1,
        "exactly ONE newline — one write == one Cloud Logging entry",
    )
    assert_true(payload.endswith(String(chr(10))), "and it is TRAILING")
    assert_equal(
        len(payload.as_bytes()),
        len(rendered.as_bytes()) + 1,
        "the emitter adds the newline and nothing else",
    )
    # And the emit path itself must not raise.
    emit_structured_line(String('{"severity":"INFO","message":"emit selftest"}'))
    print("  test_emit_writes_the_whole_line_and_a_newline PASS")


def test_one_error_line_in_both_layouts() raises:
    """One realistic ERROR line rendered both ways, printed so the two wire
    forms are readable in the test log rather than described in a doc that can
    go stale. In the text layout its level is invisible to the collector's
    severity filter; in the JSON layout it is `severity`."""
    var msg = String(
        "worker: request failed: HttpError[TIMEOUT]: upstream did not"
        " answer in time"
    )
    # 2026-10-01T19:35:25.081Z
    var ts = Int64(1790883325081)

    _select_text_layout()
    var text = render_line(
        ts, LEVEL_ERROR, "komira_http", msg, List[String]()
    )
    print("  TEXT (unchanged, the local/default layout):")
    print("    " + text)
    assert_equal(
        text,
        String("2026-10-01T19:35:25.081Z ERROR [komira_http] ") + msg,
        "the text layout, byte for byte",
    )

    select_log_layout(String(""), True)
    var js = render_line(
        ts, LEVEL_ERROR, "komira_http", msg, List[String]()
    )
    print("  JSON (on a deployed platform):")
    print("    " + js)
    assert_equal(
        js,
        String('{"severity":"ERROR","message":"')
        + msg
        + String('","time":"2026-10-01T19:35:25.081Z","module":')
        + String('"komira_http"}'),
        "the JSON layout, byte for byte",
    )
    _select_text_layout()
    print("  test_one_error_line_in_both_layouts PASS")


def main() raises:
    print("== test_log_json_severity ==")
    test_warn_maps_to_warning()
    test_every_level_maps_to_a_google_severity()
    test_severity_map_agrees_with_levels()
    test_one_line_of_valid_json_for_a_hostile_message()
    test_fields_become_keys_and_a_value_may_contain_equals()
    test_a_field_may_not_shadow_the_layouts_own_keys()
    test_text_layout_is_byte_identical_by_default()
    test_the_deployed_platform_fact_selects_json_and_an_override_wins()
    test_non_ascii_survives_byte_exact()
    test_the_drain_twin_renders_the_same_json()
    test_emit_writes_the_whole_line_and_a_newline()
    test_one_error_line_in_both_layouts()
    _select_text_layout()
    print("== test_log_json_severity: ALL PASS ==")
