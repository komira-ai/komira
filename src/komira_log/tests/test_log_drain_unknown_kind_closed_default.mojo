# =============================================================================
# test_log_drain_unknown_kind_closed_default.mojo
#   A RECORD KIND NO DRAIN RECOGNISES IS REFUSED AND COUNTED — NEVER RENDERED.
# =============================================================================
#
# WHAT THIS GUARDS. `LogEventRecord.kind` is the ring's discriminant, and every
# drain over that ring routes on it. An OPEN routing — test for the SPAN kinds a
# drain knows and let EVERYTHING ELSE fall into the log decode — would have
# `decode_one` read `rec.n_args` and walk the 48-byte inline blob as an arg
# table (on a record that is not a log record those bytes are not an arg
# table), miss the site dictionary, and render `"<unknown site N>"` (drain.mojo,
# the two site-miss returns).
#
# WHY THAT MATTERS BEYOND TIDINESS. `drain_worker_to_records` is the indexing
# path (`komira_log_index`'s `ServiceLogSink.pump`), and `drain_to_views` is
# the free fn a deployed service reaches. An open `else` on those paths turns a
# record kind the drains predate into GARBAGE ROWS in a production log index —
# silently, because a mis-rendered row is a perfectly well-formed row.
#
# THE SIX CONSUMERS — every caller of the ring's pop seam (`try_pop`):
#
#   1. shared_engine.drain_worker            -> sink        (the hot path)
#   2. shared_engine.drain_worker_to_lines   -> List[String]
#   3. shared_engine.drain_worker_to_records -> List[LogRecordView]
#   4. span_drain.drain_unified              -> UnifiedDrainResult
#   5. drain.drain_to_lines                  -> List[String]
#   6. drain.drain_to_views                  -> List[LogRecordView]
#
# ⛔ THE FALSIFIER, AND ITS METHODOLOGY: revert ONLY the consumer arms in
# `drain.mojo` / `span_drain.mojo` / `shared_engine.mojo`, KEEP the counter API
# on `record_ring.mojo` + `SharedEngine`, so every failure is an assertion and
# not a compile error. Each case then fails at its own named assertion, one per
# consumer arm plus the span case:
#
#   drain_worker_to_lines      "unknown kind produced NO text line"
#   drain_worker_to_records    "unknown kind produced NO index view"
#   drain_worker               "the refusal was counted"
#   drain_unified              "unknown kind produced NO log line"
#   drain_to_lines             "unknown kind produced NO text line"
#   drain_to_views             "the refusal was counted"
#   drain_to_lines (spans)     "ONLY the log record rendered, not the 2 spans"
#
# EXCEPT ONE, AND IT HAS TO PASS: `test_known_log_record_still_renders_and_
# counts_nothing` is the negative control. A REC_LOG record rendering, and
# rendering without `"<unknown site"`, is behaviour the closed default does NOT
# change. A control that went RED with the arms reverted would not be a control
# — it would mean the drain was broken for ordinary log records too.
#
# ⛔ AN ARM-REVERT RED DOES NOT PROVE THE ARM IS PINNED. Take `drain_worker`,
# the hot path, arm 1, and apply this MUTATION: keep `r.note_unknown_kind()`,
# delete ONLY the following `n += 1` / `continue`, so the drain COUNTS the drop
# and then falls straight into `var line = decode_one(rec, r, ...)` +
# `write_line_core` — i.e. the garbage line the closed default exists to
# suppress is written to the sink, and counted as refused in the same breath.
#
# Assertions on `n == 1`, `unknown_kind_dropped_count() == 1` and
# `ring.is_empty()` ALL STAY TRUE UNDER THAT MUTATION — they describe the ring
# and the counter, never the sink. The other five arms return their output, so
# `len(output) == 0` reds them under the same mutation; arm 1 returns a count,
# so its output side has to be read some other way. The case therefore installs
# a PER-CORE FILE SINK and asserts `segment_bytes(0) == 0`; the mutation reds at
# `NOTHING REACHED THE SINK: ...` (the bytes of the rendered garbage line).
#
# `test_drain_worker_writes_a_known_record_to_the_sink` is that assertion's
# positive control — `segment_bytes` returns a hard-coded 0 for every non
# per-core sink kind, so a zero-bytes assertion needs a witness that bytes can
# move at all.
#
# Encapsulation: pure value/ref flow — a local engine, a local ring, a
# local dictionary, POD records built field-by-field. No `UnsafePointer`, no
# wildcard origin.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO
from komira_log.engine.drain import drain_to_lines, drain_to_views
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_SPAN_OPEN,
    REC_SPAN_CLOSE,
)
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.span_drain import OpenSpanTable, drain_unified
from komira_log.engine.output_sink import SINK_PER_CORE_SEGMENTS
from komira_log.engine.rotation import RotationPolicy

from komira_runtime_paths import test_tmpdir


comptime _FMT = "login {} status {}"
comptime _MODULE = "komira_auth"

# The unknown kind. Deliberately NOT 3: `REC_METRIC = 3` is the next kind this
# repo will define, and a test that pins 3 would start passing for the wrong
# reason the day it lands. 200 is unreachable by any planned discriminant.
comptime _UNKNOWN_KIND: UInt8 = UInt8(200)


def _dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register[_FMT, _MODULE]()
    return d^


def _anchor() -> CalibrationAnchor:
    return CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_780_272_000) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )


def _record_of_kind(kind: UInt8) raises -> LogEventRecord:
    """A record whose SITE fields are all well-formed and whose `kind` is the
    only thing under test. Well-formed on purpose: if the drain refuses this
    record it is refusing it for its KIND, not because anything else is wrong.
    """
    var rec = LogEventRecord()
    rec.kind = kind
    rec.level = LEVEL_INFO
    rec.site_id = fnv1a_32(_FMT)
    rec.module_id = fnv1a_32(_MODULE)
    rec.timestamp = UInt64(0)
    rec.corr_id = UInt64(7)
    return rec^


def _ring_with(kind: UInt8) raises -> LogRecordRing:
    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    assert_true(ring.try_push(_record_of_kind(kind)), "record pushed")
    return ring^


def _engine_with(kind: UInt8) raises -> SharedEngine:
    var f = EnvFilter()
    var eng = SharedEngine(num_workers=1, filter=f^)
    # The ENGINE carries its own `SiteDictionary`, distinct from the `_dict()`
    # the free-fn drains are handed. Register the site there too, or the
    # negative control below renders `<unknown site N>` for a perfectly good
    # REC_LOG record and "passes" for entirely the wrong reason.
    eng.register_site[_FMT, _MODULE]()
    assert_true(eng.ring(0).try_push(_record_of_kind(kind)), "record pushed")
    return eng^


# -----------------------------------------------------------------------------
# ⛔ THE HOT PATH HAS NO RETURN VALUE, SO IT NEEDS A SINK OBSERVABLE.
#
# `drain_worker` writes to `self._sink` and returns only a COUNT. Its two
# siblings (`_to_lines` / `_to_records`) return the rendered output, so
# `len(out) == 0` pins their refusal directly. The hot path has no such handle,
# and a case built out of only `n`, the counter and `ring.is_empty()` is
# SATISFIED BY A DRAIN THAT COUNTS THE DROP AND RENDERS THE RECORD ANYWAY —
# see the mutation in the header.
#
# The observable is the sink's own byte counter. `segment_bytes(core)` is
# `SegmentFile._cur_bytes`, advanced by `append_line`, which is the ONLY thing
# `write_line_core` calls in PER_CORE_SEGMENTS mode — so `segment_bytes(0) == 0`
# says "write_line_core was never reached for worker 0", which is exactly the
# behaviour under test.
#
# ⚠ `segment_bytes` RETURNS 0 FOR EVERY OTHER SINK KIND (`output_sink.mojo`:
# `if self._kind != SINK_PER_CORE_SEGMENTS: return 0`). The engine's default
# sink is STDERR, so a case that forgot to install the per-core sink would read
# a hard-coded 0 and pass no matter what the drain did. Two guards, both
# required: this helper ASSERTS the installed kind, and
# `test_drain_worker_writes_a_known_record_to_the_sink` below is the positive
# control proving bytes DO move on this exact seam.
#
# ⚠ $TEST_TMPDIR (via `komira_runtime_paths.test_tmpdir`), not a hard-coded
# `/tmp` path — two runs of the same test may execute at once, and only
# TEST_TMPDIR is private to each. Same rule as `test_log_p3_output.mojo`.
# -----------------------------------------------------------------------------


def _scratch_dir() -> String:
    try:
        return test_tmpdir()
    except:
        return String("/tmp")


def _tmp(name: String) -> String:
    return (_scratch_dir() + String("/komira_log_unknown_kind_")) + name


def _engine_with_sink(kind: UInt8, base: String) raises -> SharedEngine:
    """`_engine_with`, plus a PER-CORE FILE SINK so the hot path's writes are
    observable. The record is already on the ring before the sink is installed;
    nothing has been drained yet, so the sink starts at zero bytes."""
    var eng = _engine_with(kind)
    eng.set_sink_per_core_segments(base, RotationPolicy.none())
    assert_equal(
        Int(eng.sink_kind()),
        Int(SINK_PER_CORE_SEGMENTS),
        (
            "the per-core sink is INSTALLED -- segment_bytes() returns a"
            " hard-coded 0 for every other sink kind, which would make the"
            " zero-bytes assertions below vacuous"
        ),
    )
    assert_equal(eng.segment_bytes(0), 0, "the sink starts empty")
    return eng^


# -----------------------------------------------------------------------------
# 1-3. The three engine drains.
# -----------------------------------------------------------------------------


def test_drain_worker_to_lines_refuses_unknown_kind() raises -> None:
    var eng = _engine_with(_UNKNOWN_KIND)
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 0, "unknown kind produced NO text line")
    assert_equal(
        Int(eng.unknown_kind_dropped_count()), 1, "the refusal was counted"
    )


def test_drain_worker_to_records_refuses_unknown_kind() raises -> None:
    """The DEPLOYED indexing path — the one whose open `else` would have written
    a `<unknown site N>` row into a production log index."""
    var eng = _engine_with(_UNKNOWN_KIND)
    var views = eng.drain_worker_to_records(0, 64)
    assert_equal(len(views), 0, "unknown kind produced NO index view")
    assert_equal(
        Int(eng.unknown_kind_dropped_count()), 1, "the refusal was counted"
    )


def test_drain_worker_refuses_unknown_kind() raises -> None:
    """THE DEPLOYED HOT PATH (`ServiceLogSink.pump` -> the worker idle loop).
    Its output goes to the sink rather than a return value, so the refusal is
    pinned on the SINK: the record is taken off the ring, counted, and
    `write_line_core` is NEVER reached — zero bytes at the segment.

    ⛔ `n`, the counter and `is_empty()` DO NOT PIN THIS. All three hold for a
    drain that counts the drop and then renders the record anyway; the
    zero-bytes assertion is the only one of the four that does not."""
    var eng = _engine_with_sink(_UNKNOWN_KIND, _tmp("hot_unknown"))
    var n = eng.drain_worker(0, 64)
    assert_equal(n, 1, "the record was consumed off the ring")
    assert_equal(
        Int(eng.unknown_kind_dropped_count()), 1, "the refusal was counted"
    )
    assert_true(eng.ring(0).is_empty(), "ring fully drained")
    assert_equal(
        eng.segment_bytes(0),
        0,
        (
            "NOTHING REACHED THE SINK: the unknown-kind record was never"
            " handed to decode_one/write_line_core"
        ),
    )


def test_drain_worker_writes_a_known_record_to_the_sink() raises -> None:
    """THE POSITIVE CONTROL FOR THE SINK OBSERVABLE. Without it,
    `segment_bytes(0) == 0` above is satisfied by a sink that can never be
    written to at all (wrong sink kind, unopened segment, a `write_line_core`
    that silently no-ops) — a green assertion measuring nothing.

    Same engine, same drain call, same segment: only the record's KIND differs,
    and bytes DO move."""
    var eng = _engine_with_sink(REC_LOG, _tmp("hot_known"))
    var n = eng.drain_worker(0, 64)
    assert_equal(n, 1, "the record was consumed off the ring")
    assert_equal(
        Int(eng.unknown_kind_dropped_count()),
        0,
        "a known kind is NOT counted as a refusal",
    )
    assert_true(
        eng.segment_bytes(0) > 0,
        (
            "a REC_LOG record DOES reach the sink through drain_worker -- this"
            " is what makes the zero-bytes assertion above a measurement"
        ),
    )


# -----------------------------------------------------------------------------
# 4. drain_unified (span_drain.mojo).
# -----------------------------------------------------------------------------


def test_drain_unified_refuses_unknown_kind() raises -> None:
    var ring = _ring_with(_UNKNOWN_KIND)
    var tbl = OpenSpanTable()
    var res = drain_unified(ring, 0, _dict(), _anchor(), tbl)
    assert_equal(len(res.log_lines), 0, "unknown kind produced NO log line")
    assert_equal(len(res.span_lines), 0, "unknown kind produced NO span line")
    assert_equal(
        Int(ring.unknown_kind_dropped_count()), 1, "the refusal was counted"
    )


# -----------------------------------------------------------------------------
# 5-6. The two free-function drains.
# -----------------------------------------------------------------------------


def test_drain_to_lines_refuses_unknown_kind() raises -> None:
    var ring = _ring_with(_UNKNOWN_KIND)
    var lines = drain_to_lines(ring, _dict(), _anchor())
    assert_equal(len(lines), 0, "unknown kind produced NO text line")
    assert_equal(
        Int(ring.unknown_kind_dropped_count()), 1, "the refusal was counted"
    )


def test_drain_to_views_refuses_unknown_kind() raises -> None:
    """This arm was ALREADY closed (`if rec.kind != REC_LOG: continue`) but
    SILENT, so a deliberate span skip and an unrecognised kind were indistin-
    guishable. The zero-output half passed before the fix; the COUNTER half is
    what this case adds."""
    var ring = _ring_with(_UNKNOWN_KIND)
    var views = drain_to_views(ring, _dict(), _anchor())
    assert_equal(len(views), 0, "unknown kind produced NO view")
    assert_equal(
        Int(ring.unknown_kind_dropped_count()), 1, "the refusal was counted"
    )


# -----------------------------------------------------------------------------
# THE ONE ARM WITH LIVE HARM TODAY.
# -----------------------------------------------------------------------------


def test_drain_to_lines_skips_spans_instead_of_rendering_them() raises -> None:
    """`drain_to_lines` made NO kind decision AT ALL: it decoded every record as
    text, REC_SPAN_OPEN / REC_SPAN_CLOSE included. Both are LIVE kinds that
    `span_emit.mojo` produces today, so unlike the unknown-kind cases above this
    one is a defect with a real producer — weaker than an open `else`, because
    there was no `else` to widen.

    Spans are SKIPPED, not counted as unknown: the bare free fn has no
    `OpenSpanTable` to ingest them into (the same reason `drain_to_views` skips
    them), so this is a deliberate omission, not a refusal."""
    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    assert_true(ring.try_push(_record_of_kind(REC_SPAN_OPEN)), "open pushed")
    assert_true(ring.try_push(_record_of_kind(REC_SPAN_CLOSE)), "close pushed")
    assert_true(ring.try_push(_record_of_kind(REC_LOG)), "log pushed")

    var lines = drain_to_lines(ring, _dict(), _anchor())
    assert_equal(len(lines), 1, "ONLY the log record rendered, not the 2 spans")
    assert_equal(
        Int(ring.unknown_kind_dropped_count()),
        0,
        "a span is a known kind: skipped, NOT counted as unknown",
    )


# -----------------------------------------------------------------------------
# The negative control. Without this the suite above is satisfied by a drain
# that refuses EVERYTHING, which would be a passing test over a broken logger.
# -----------------------------------------------------------------------------


def test_known_log_record_still_renders_and_counts_nothing() raises -> None:
    var eng = _engine_with(REC_LOG)
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1, "a REC_LOG record still renders")
    assert_true(
        lines[0].find("<unknown site") < 0,
        "and renders as a real line, not a site miss",
    )
    assert_equal(
        Int(eng.unknown_kind_dropped_count()),
        0,
        "a known kind is NOT counted as a refusal",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
