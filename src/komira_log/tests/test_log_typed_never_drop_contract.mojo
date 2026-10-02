# =============================================================================
# test_log_typed_never_drop_contract.mojo — the never-drop contract, asserted
# on BOTH emit surfaces and at BOTH never-drop levels.
# =============================================================================
#
# WHY THIS FILE EXISTS. `test_log_facade_error_escalation.mojo` pins the
# never-drop arm of the AMBIENT facade at ERROR. That is one surface and one
# level; this file covers the other three corners:
#
#   |            | ERROR                          | WARN                    |
#   |------------|--------------------------------|-------------------------|
#   | ambient    | PINNED (the sibling file)      | ⬅ this file             |
#   | typed      | ⬅ this file (the headline)     | ⬅ this file             |
#
# THE HEADLINE (case 1). `logger._emit_through` must CHECK its push result,
# never `_ = ring.try_push(rec)`. The ambient facade, for the same record at
# the same level on the same ring, checks it and escalates; a typed handle
# that discarded it would give ONE contract TWO behaviours depending on which
# handle the caller happens to hold — an ERROR emitted through `ctx.logger`
# dropped where the identical call through `log.error` survives.
#
# THE SECOND CORNER (case 2). The escalation must be gated on
# `level >= LEVEL_WARN`, not `LEVEL_ERROR`: the guarantee is "drop
# TRACE/DEBUG/INFO; never drop WARN/ERROR" (`shared_engine.mojo`'s module
# header).
#
# ⚠ THIS IS AN A/B TEST, DELIBERATELY. The typed arm and the ambient arm run
# the SAME scenario against two engines with two files, and the final assertion
# compares what came out. A test that only checked "the typed arm writes
# something" would pass on an escalation that rendered a different shape — and
# the two surfaces rendering differently is the class of defect this whole file
# is about.
#
# THE MECHANISM (inherited from the sibling file, restated so a change to the
# engine's default makes this test fail loudly rather than silently stop
# exercising the arm):
#   * a per-WORKER ring is `OVERFLOW_DROP` with `DEFAULT_RING_CAPACITY = 4096`;
#   * nothing drains it here, so 4096 admitted pushes fill it exactly;
#   * push 4097 is rejected -> the emit must NOT drop it at WARN or above.
# =============================================================================

from std.os import remove
from std.io import FileHandle

from std.testing import TestSuite, assert_true, assert_equal

from komira_log import SharedEngine, Logger
from komira_log.engine.log_manager import LogManager
from komira_log.engine.rotation import RotationPolicy
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE
from komira_log.log_arg import ArgStr

import komira_log as log
from komira_runtime_paths import test_tmpdir


comptime _RING_CAPACITY = 4096
"""`DEFAULT_RING_CAPACITY` (`komira_spsc_ring`). Restated rather than
imported so a change to the engine's default makes THIS test fail loudly (the
fill loop stops filling) instead of silently ceasing to exercise the arm."""


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. Two runs of the same test may
# execute at once on one machine, and a fixed `/tmp` path is shared by all of
# them. The test runner makes `TEST_TMPDIR` private to each run;
# `komira_runtime_paths.test_tmpdir` is the one helper that reads it.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    try:
        return test_tmpdir()
    except:
        return String("/tmp")


def _base(tag: String) -> String:
    return _scratch_dir() + String("/komira_log_neverdrop_") + tag


def _filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def _read(path: String) raises -> String:
    var f = FileHandle(path, "r")
    return String(f.read())


def _read_or_empty(path: String) -> String:
    try:
        return _read(path)
    except:
        return String("")


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0:
        return True
    if len(n) > len(h):
        return False
    for i in range(len(h) - len(n) + 1):
        var hit = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                hit = False
                break
        if hit:
            return True
    return False


# ---------------------------------------------------------------------------
# ARM B — the TYPED surface. Its own engine, its own file; no LogManager.
# ---------------------------------------------------------------------------


def _typed_arm_lines(tag: String) raises -> String:
    """Fill a typed engine's worker ring to capacity, then emit one ERROR and
    one WARN through `Logger`. Returns whatever reached the sink.

    Every emit here goes through `Logger.error` / `Logger.warn` ->
    `logger._emit_through` — the surface under test. The fill records are
    ERROR too, so the ONLY thing distinguishing the escalated records from the
    fill is that the ring had no room for them.
    """
    var live = _base(tag) + ".log"
    _rm(live)

    var eng = SharedEngine(num_workers=1, filter=_filter())
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())
    # Bind THIS thread as worker 0 so the typed emit takes the RING path
    # (`wid != WORKER_ID_UNSET`). Without this the test would exercise the
    # non-worker fallback and pass while saying nothing — the failure mode a
    # reviewer should look for first.
    eng.bind_worker_thread(UInt16(0))

    var logger = Logger.borrow(eng)
    for i in range(_RING_CAPACITY):
        logger.error["fill {}", "typ"](ArgStr(String("x")))
        _ = i

    # CONTROL: the DROP ring absorbed every admitted push, so nothing has
    # reached the sink. This is what makes the next assertion about the
    # ESCALATION rather than about ordinary emission.
    assert_equal(
        _read_or_empty(live).byte_length(),
        0,
        (
            "typed arm: the DROP ring absorbed every admitted push; nothing"
            " should have reached the sink yet"
        ),
    )

    logger.error["ESCALATED {}", "typ"](ArgStr(String("typed_err")))
    logger.warn["ESCALATED {}", "typ"](ArgStr(String("typed_warn")))

    return _read_or_empty(live)


# ---------------------------------------------------------------------------
# ARM A — the AMBIENT facade. The control: its ERROR corner is already pinned
# by test_log_facade_error_escalation.mojo, so a failure HERE at ERROR means
# something broke in the shared cold path rather than in the typed surface.
# ---------------------------------------------------------------------------


def _ambient_arm_lines(tag: String) raises -> String:
    var live = _base(tag) + ".log"
    _rm(live)

    LogManager.install(SharedEngine(num_workers=1, filter=_filter()))
    ref e = LogManager._resolve()[]
    e.set_sink_single_file(_base(tag), RotationPolicy.none())
    e.bind_worker_thread(UInt16(0))

    for i in range(_RING_CAPACITY):
        log.error["fill {}", "typ"](ArgStr(String("x")))
        _ = i

    assert_equal(
        _read_or_empty(live).byte_length(),
        0,
        (
            "ambient arm: the DROP ring absorbed every admitted push; nothing"
            " should have reached the sink yet"
        ),
    )

    log.error["ESCALATED {}", "typ"](ArgStr(String("typed_err")))
    log.warn["ESCALATED {}", "typ"](ArgStr(String("typed_warn")))

    return _read_or_empty(live)


# ---------------------------------------------------------------------------
# The tests.
# ---------------------------------------------------------------------------


def test_typed_logger_dropped_error_escalates() raises:
    """CASE 1 — the headline. A dropped ERROR on the TYPED surface must
    reach the sink, exactly as it does on the ambient facade.

    RED before the fix: `_emit_through` ended `_ = ring.try_push(rec)`, so the
    rejected record went nowhere and the file is empty.
    """
    var out = _typed_arm_lines(String("typed_err"))
    assert_true(
        out.byte_length() > 0,
        (
            "a dropped ERROR on the TYPED surface must reach the sink — an"
            " empty file means `logger._emit_through` discarded the push"
            " result (case 1)"
        ),
    )
    assert_true(
        _contains(out, String("ESCALATED typed_err")),
        (
            "the escalated typed ERROR carries its INTERPOLATED message, the"
            " same shape the ambient facade renders"
        ),
    )
    assert_true(
        _contains(out, String("ERROR")),
        "the escalated typed line carries its LEVEL word",
    )
    assert_true(
        _contains(out, String("[typ]")),
        "the escalated typed line carries its `[module]` tag",
    )
    assert_true(
        not _contains(out, String("fill ")),
        (
            "only the rejected records escalate; the 4096 accepted ones stay"
            " in the ring"
        ),
    )
    _rm(_base(String("typed_err")) + ".log")


def test_typed_logger_dropped_warn_escalates() raises:
    """CASE 2 (typed corner) — WARN is in the never-drop set.

    "drop TRACE/DEBUG/INFO; never drop WARN/ERROR". RED if the escalation is
    gated `level >= LEVEL_ERROR`.
    """
    var out = _typed_arm_lines(String("typed_warn"))
    assert_true(
        _contains(out, String("ESCALATED typed_warn")),
        (
            "a dropped WARN must reach the sink — the design's never-drop set"
            " is WARN/ERROR, not ERROR alone (case 2)"
        ),
    )
    assert_true(
        _contains(out, String("WARN")),
        "the escalated WARN line carries its LEVEL word",
    )
    _rm(_base(String("typed_warn")) + ".log")


def test_both_surfaces_escalate_identically() raises:
    """THE A/B. One contract, two surfaces — the bytes must agree.

    Both arms emit the same two records against the same ring capacity with
    the same module tag. The rendered lines carry a timestamp, so the
    comparison is on the SHAPE that follows it: level word, `[module]` tag and
    interpolated message, for each of the two escalated records.
    """
    var ambient = _ambient_arm_lines(String("amb"))
    var typed = _typed_arm_lines(String("typ"))

    assert_true(
        ambient.byte_length() > 0,
        (
            "ambient control arm produced nothing — the shared cold path is"
            " broken, not just the typed surface"
        ),
    )
    assert_true(
        typed.byte_length() > 0,
        "typed arm produced nothing (case 1)",
    )

    # The four shape facts, asserted on BOTH arms with the same needles. A
    # divergence in ANY of them is the two-surfaces-one-contract defect.
    var needles = List[String]()
    needles.append(String("ERROR"))
    needles.append(String("WARN"))
    needles.append(String("[typ]"))
    needles.append(String("ESCALATED typed_err"))
    needles.append(String("ESCALATED typed_warn"))

    for i in range(len(needles)):
        var needle = needles[i]
        assert_equal(
            _contains(ambient, needle),
            _contains(typed, needle),
            (
                "the ambient and typed surfaces must escalate the SAME way;"
                " they disagree on the presence of: "
            )
            + needle,
        )
        assert_true(
            _contains(typed, needle),
            String("the typed escalation is missing: ") + needle,
        )

    _rm(_base(String("amb")) + ".log")
    _rm(_base(String("typ")) + ".log")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
