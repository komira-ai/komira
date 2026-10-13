# =============================================================================
# komira_job_supervisor/tests/test_job_output_bytes_and_crash_json.mojo
#   The job's output keeps its bytes through every product built from its
#   lines (the rings, logs.txt, the FAILED heartbeat's stderr tail and
#   crash_report.json), and crash_report.json is JSON a strict parser takes
#   whatever bytes the job wrote (komira-ai/komira#1393).
# =============================================================================
#
#   test_non_ascii_output_keeps_its_bytes_everywhere
#       A real job writes "café € 🦀" (2-, 3- and 4-byte UTF-8) to stdout and
#       stderr, an ANSI-coloured stderr line (ESC, 0x1B), and exits 1. The
#       stdout and stderr rings, logs.txt, the stderr tail of the FAILED
#       heartbeat and the stderr tail that crash_report.json decodes to all
#       hold the job's exact bytes. Catches a line built one `chr()` per byte
#       (`é`, C3 A9, came back as C3 83 C2 A9) and an escaper that writes ESC
#       raw (the report then fails `parse_json_bytes`).
#   test_a_character_split_across_reads_is_kept_whole
#       `_absorb` fed one 4-byte character in two reads, split inside it:
#       the line holds the character's four bytes. Catches a line decoded
#       per read rather than once at its newline.
#   test_every_control_byte_is_escaped_in_the_crash_report
#       A stderr line holding each byte 0x00..0x1F, `"` and `\`, and a job
#       name and instance name holding `"`, `\` and control bytes: the report
#       carries each control byte as its JSON escape (the two-character
#       escapes \b \t \n \f \r for 0x08 0x09 0x0A 0x0C 0x0D, `\u00xx` with
#       lowercase hex for the rest), holds no raw byte below 0x20 at all, and
#       an independent parser (komira_json.parse_json_bytes, strict RFC 8259)
#       decodes every field back to its exact bytes.
#   test_invalid_utf8_output_becomes_replacement_characters
#       DEFINED BEHAVIOUR for output that is not UTF-8: each line is decoded
#       once, at its newline, with `String(from_utf8_lossy=)`, so an
#       ill-formed sequence becomes U+FFFD (EF BF BD) in the rings, logs.txt,
#       the heartbeat and crash_report.json, and crash_report.json stays
#       valid UTF-8 JSON. A lone 0xFF and a lead byte 0xC3 cut off by the end
#       of its line each become one U+FFFD. The streamed `chunks/0.log`
#       object keeps the job's exact bytes, 0xFF included: it is fed the raw
#       reads before any line is built.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_json import parse_json_bytes
from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.path import Path
from komira_supervisor import ChildSpec

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    JobSupervisorConfig,
    SupervisorHeartbeat,
    build_crash_report_json,
)
from komira_job_supervisor.job_supervisor_state import (
    FailureReport,
    JobSupervisorPhase,
)


struct TailRecorder(HeartbeatReporter):
    """Records the stderr tail of every beat that carries a failure."""

    var tails: ArcPointer[List[List[String]]]

    def __init__(out self, tails: ArcPointer[List[List[String]]]):
        self.tails = tails

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        if hb.failure:
            self.tails[].append(hb.failure.value().stderr_tail.copy())
        return HeartbeatOutcome(True, False, 200)


comptime Js = JobSupervisor[TailRecorder, SharedInMemoryConditionalStore]


def _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def _bytes(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _str(b: List[UInt8]) -> String:
    """`b` as a String, byte for byte (the test builds bytes no literal can
    spell, such as NUL and ESC)."""
    return String(unsafe_from_utf8=Span(b))


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    out.extend(Span(b))
    return out^


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _nibble(n: Int) -> String:
    """`n` (0..15) as one lowercase hex digit."""
    if n < 10:
        return chr(0x30 + n)
    return chr(0x61 + n - 10)


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += String(" ")
        out += _nibble(Int(b[i] >> 4))
        out += _nibble(Int(b[i] & 15))
    return out^


def _assert_bytes(got: String, want: List[UInt8], what: String) raises:
    var g = _ascii(got)
    assert_equal(_hex(g), _hex(want), what)


def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    var n = len(needle)
    for i in range(len(hay) - n + 1):
        var hit = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                hit = False
                break
        if hit:
            return True
    return False


# "café € 🦀": é = C3 A9, € = E2 82 AC, 🦀 = F0 9F A6 80.
def _cafe() -> List[UInt8]:
    return _bytes(
        0x63, 0x61, 0x66, 0xC3, 0xA9, 0x20, 0xE2, 0x82, 0xAC, 0x20,
        0xF0, 0x9F, 0xA6, 0x80,
    )


# ESC[31merror ESC[0m
def _ansi() -> List[UInt8]:
    return _cat(
        _cat(_bytes(0x1B), _ascii(String("[31merror"))),
        _cat(_bytes(0x1B), _ascii(String("[0m"))),
    )


def _ufffd() -> List[UInt8]:
    return _bytes(0xEF, 0xBF, 0xBD)


def _config(prefix: String) -> JobSupervisorConfig:
    return JobSupervisorConfig(
        String("bytes"),
        String("instance-1"),
        String("/bin/sh"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
        log_prefix=prefix,
        log_chunk_bytes=1 << 20,
    )


def _run_to_failure(mut js: Js, script: String) raises:
    """Spawn `script`, drive it to its exit, record the FAILED result, send
    the terminal beat and write the terminal artifacts."""
    js.spawn_child_spec(ChildSpec.shell(script))
    var spins = 0
    while not js.child_exited and spins < 2000:
        js.poll_and_drain()
        if js.child_exited:
            break
        _sleep_ms(5)
        spins += 1
    assert_true(js.child_exited, "the job exited within 10 s")
    js.analyze_exit()
    assert_true(js.state.phase == JobSupervisorPhase.failed(), "exit 1 is FAILED")
    _ = js.finalize_heartbeat()
    js.upload_terminal_artifacts()


def _object(store: SharedInMemoryConditionalStore, key: String) raises -> List[UInt8]:
    return store.get(Path.parse(key))


def test_non_ascii_output_keeps_its_bytes_everywhere() raises:
    # printf octal: é \303\251, € \342\202\254, 🦀 \360\237\246\200, ESC \033.
    var cafe_oct = String("caf\\303\\251 \\342\\202\\254 \\360\\237\\246\\200")
    var script = (
        String("printf '") + cafe_oct + String("\\n'; ")
        + String("printf '") + cafe_oct + String("\\n' >&2; ")
        + String("printf '\\033[31merror\\033[0m\\n' >&2; exit 1")
    )
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var tails = ArcPointer[List[List[String]]](List[List[String]]())
    var js = Js(
        _config(String("logs/utf8")),
        TailRecorder(tails),
        Optional[SharedInMemoryConditionalStore](store^),
    )
    _run_to_failure(js, script)
    var cafe = _cafe()
    var ansi = _ansi()

    assert_equal(len(js.stdout_ring), 1, "one stdout line")
    _assert_bytes(js.stdout_ring[0], cafe, "stdout ring keeps the UTF-8 bytes")
    assert_equal(len(js.stderr_ring), 2, "two stderr lines")
    _assert_bytes(js.stderr_ring[0], cafe, "stderr ring keeps the UTF-8 bytes")
    _assert_bytes(js.stderr_ring[1], ansi, "stderr ring keeps ESC")

    # logs.txt: the stdout lines, then the stderr lines, joined with LF.
    var nl = _bytes(0x0A)
    var want_logs = _cat(_cat(_cat(cafe, nl), _cat(cafe, nl)), ansi)
    assert_equal(
        _hex(_object(view, String("logs/utf8/logs.txt"))),
        _hex(want_logs),
        "logs.txt holds the job's bytes",
    )

    # The FAILED heartbeat's stderr tail.
    assert_equal(len(tails[]), 1, "one beat carried a failure")
    assert_equal(len(tails[][0]), 2, "the beat's tail has both lines")
    _assert_bytes(tails[][0][0], cafe, "heartbeat tail keeps the UTF-8 bytes")
    _assert_bytes(tails[][0][1], ansi, "heartbeat tail keeps ESC")

    # crash_report.json: a strict parser takes it, and it decodes to the bytes.
    var report = _object(view, String("logs/utf8/crash_report.json"))
    var doc = parse_json_bytes(report)
    var tail = doc.get(String("stderr_tail"))
    assert_equal(tail.array_len(), 2, "crash report tail has both lines")
    _assert_bytes(tail.element_at(0).as_string(), cafe, "report: UTF-8 line")
    _assert_bytes(tail.element_at(1).as_string(), ansi, "report: ESC line")
    # UTF-8 is copied, not \u-escaped, and ESC is written as \u001b.
    assert_true(_contains(report, cafe), "report holds the UTF-8 bytes verbatim")
    assert_true(
        _contains(report, _ascii(String("\\u001b[31merror\\u001b[0m"))),
        "report escapes ESC as \\u001b",
    )
    print("  test_non_ascii_output_keeps_its_bytes_everywhere: PASS")


def test_a_character_split_across_reads_is_kept_whole() raises:
    var tails = ArcPointer[List[List[String]]](List[List[String]]())
    var js = Js(_config(String("logs/split")), TailRecorder(tails), None)
    # 'a' F0 9F | A6 80 '\n': the read boundary falls inside 🦀.
    js._absorb(_str(_bytes(0x61, 0xF0, 0x9F)), False)
    js._absorb(_str(_bytes(0xA6, 0x80, 0x0A)), False)
    assert_equal(len(js.stderr_ring), 1, "one line")
    _assert_bytes(
        js.stderr_ring[0],
        _bytes(0x61, 0xF0, 0x9F, 0xA6, 0x80),
        "the split character is whole",
    )
    print("  test_a_character_split_across_reads_is_kept_whole: PASS")


def test_every_control_byte_is_escaped_in_the_crash_report() raises:
    # The line: bytes 0x00..0x1F, then `"` and `\`, then "end".
    var line = List[UInt8]()
    for b in range(0x20):
        line.append(UInt8(b))
    line.append(UInt8(0x22))
    line.append(UInt8(0x5C))
    line.extend(String("end").as_bytes())
    var job = _cat(_ascii(String('j"o\\b')), _bytes(0x01, 0x1F))
    var inst = _cat(_bytes(0x00), _ascii(String("inst")))
    var tail = List[String]()
    tail.append(_str(line))
    var json = build_crash_report_json(
        _str(job),
        _str(inst),
        FailureReport(Optional[Int32](Int32(1)), None, tail^, None),
    )
    var jb = _ascii(json)
    for i in range(len(jb)):
        assert_true(
            jb[i] >= UInt8(0x20),
            "raw byte " + String(Int(jb[i])) + " at " + String(i) + " in the report",
        )

    # The exact escape of the line.
    var want = String("")
    for b in range(0x20):
        if b == 0x08:
            want += String("\\b")
        elif b == 0x09:
            want += String("\\t")
        elif b == 0x0A:
            want += String("\\n")
        elif b == 0x0C:
            want += String("\\f")
        elif b == 0x0D:
            want += String("\\r")
        else:
            want += String("\\u00")
            want += _nibble(b >> 4)
            want += _nibble(b & 15)
    want += String('\\"\\\\end')
    assert_true(
        _contains(jb, _ascii(String('"stderr_tail":["') + want + String('"]'))),
        "the line's escape is exact: " + json,
    )
    assert_true(
        _contains(jb, _ascii(String('"job_name":"j\\"o\\\\b\\u0001\\u001f"'))),
        "the job name's escape is exact: " + json,
    )
    assert_true(
        _contains(jb, _ascii(String('"instance_name":"\\u0000inst"'))),
        "the instance name's escape is exact: " + json,
    )

    # An independent, strict parser decodes every field to its exact bytes.
    var doc = parse_json_bytes(jb)
    _assert_bytes(doc.get(String("job_name")).as_string(), job, "job_name")
    _assert_bytes(doc.get(String("instance_name")).as_string(), inst, "instance_name")
    _assert_bytes(
        doc.get(String("stderr_tail")).element_at(0).as_string(), line, "the line"
    )
    assert_equal(doc.get(String("exit_code")).as_int64(), Int64(1), "exit_code")
    assert_false(doc.has(String("signal")), "no signal")
    print("  test_every_control_byte_is_escaped_in_the_crash_report: PASS")


def test_invalid_utf8_output_becomes_replacement_characters() raises:
    # stdout: "bad" FF "end"; stderr: "cut" C3 (a lead byte cut off by LF).
    var script = String(
        "printf 'bad\\377end\\n'; printf 'cut\\303\\n' >&2; exit 1"
    )
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var tails = ArcPointer[List[List[String]]](List[List[String]]())
    var js = Js(
        _config(String("logs/bad")),
        TailRecorder(tails),
        Optional[SharedInMemoryConditionalStore](store^),
    )
    _run_to_failure(js, script)
    var fffd = _ufffd()
    var bad = _cat(_cat(_ascii(String("bad")), fffd), _ascii(String("end")))
    var cut = _cat(_ascii(String("cut")), fffd)

    assert_equal(len(js.stdout_ring), 1)
    _assert_bytes(js.stdout_ring[0], bad, "0xFF becomes one U+FFFD")
    assert_equal(len(js.stderr_ring), 1)
    _assert_bytes(js.stderr_ring[0], cut, "a cut-off C3 becomes one U+FFFD")

    assert_equal(
        _hex(_object(view, String("logs/bad/logs.txt"))),
        _hex(_cat(_cat(bad, _bytes(0x0A)), cut)),
        "logs.txt holds the replaced lines",
    )
    assert_equal(len(tails[]), 1)
    _assert_bytes(tails[][0][0], cut, "heartbeat tail holds the replaced line")

    var doc = parse_json_bytes(_object(view, String("logs/bad/crash_report.json")))
    _assert_bytes(
        doc.get(String("stderr_tail")).element_at(0).as_string(),
        cut,
        "crash_report.json is valid UTF-8 and holds the replaced line",
    )

    # The streamed chunk is the job's raw stdout, 0xFF included.
    assert_equal(
        _hex(_object(view, String("logs/bad/chunks/0.log"))),
        _hex(_cat(_ascii(String("bad")), _cat(_bytes(0xFF), _ascii(String("end\n"))))),
        "the streamed chunk keeps the raw bytes",
    )
    print("  test_invalid_utf8_output_becomes_replacement_characters: PASS")


def main() raises:
    print("test_job_output_bytes_and_crash_json:")
    test_non_ascii_output_keeps_its_bytes_everywhere()
    test_a_character_split_across_reads_is_kept_whole()
    test_every_control_byte_is_escaped_in_the_crash_report()
    test_invalid_utf8_output_becomes_replacement_characters()
    print("test_job_output_bytes_and_crash_json: ALL PASS")
