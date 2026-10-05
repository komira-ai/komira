# =============================================================================
# test_log_effective_level_resolution.mojo — the level gate resolves to ONE
# effective level, and a per-module rule may LOWER it.
# =============================================================================
#
# WHAT IS GUARDED. The gate must NOT be two sequential comparisons:
#
#     if level < e.global_level():     return      # (2) the cheap atomic
#     if level < e.effective_level(module): return  # (3) the per-module rule
#
# The first one RETURNS, so a per-module rule could only ever RAISE a module's
# threshold. That makes `env_filter.mojo`'s advertised semantics unreachable —
# its own module header documents
#
#     --log-level=info,komira_pg=debug
#         -> global default = INFO; module "komira_pg" = DEBUG.
#
# and `EnvFilter.effective_level` implements exactly that (longest-prefix to a
# SINGLE effective level). The two-gate sequence throws the answer away: a
# DEBUG record on `komira_pg` is rejected by the INFO global before the rule is
# ever consulted. "Turn DEBUG on for one module" — the single most common thing
# anyone does with a log filter — cannot be expressed.
#
# ⚠ THE RAISE DIRECTION IS A REGRESSION THIS FILE ALSO GUARDS. The tempting
# fix ("admit early when the global admits") breaks `--log-level=info,x=warn`:
# an INFO record on module `x` would be admitted by the global before the rule
# that suppresses it is read. Both directions are asserted below, and a fix
# that only restores one of them fails here.
#
# ⚠ AND A SECOND PROPERTY OF THE SAME SHAPE: `set_global_level` writes the
# atomic, while `effective_level` falls back to the EnvFilter's PARSED global.
# If the gate consulted the parsed global, lowering the runtime knob would
# clear gate (2) and be rejected by gate (3) — the runtime threshold could be
# raised and not lowered. `test_log_text_emit.test_global_gate_suppresses_
# below_threshold` asserts only on the predicate and never that the record
# survived, so it cannot see this. Pinned here.
#
# HOW ADMISSION IS OBSERVED: `drain_worker_to_lines` returns the decoded lines
# rather than writing them to a sink, so "was the record admitted" is a list
# length, with no file and no sink in the way.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_log import SharedEngine, Logger
from komira_log.env_filter import EnvFilter
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
)
from komira_log.log_arg import ArgStr


def _engine(spec: String) raises -> SharedEngine:
    """An engine whose filter is parsed from a `--log-level`-shaped spec — the
    same parse production code takes, not a hand-set field."""
    var f = EnvFilter(spec)
    return SharedEngine(num_workers=1, filter=f^)


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


def _drained(mut eng: SharedEngine) raises -> List[String]:
    return eng.drain_worker_to_lines(0, 64)


# ---------------------------------------------------------------------------
# FINDING 3 — the LOWER direction, which was unreachable.
# ---------------------------------------------------------------------------


def test_per_module_rule_below_the_global_admits() raises:
    """`--log-level=info,zzdbg=debug` must turn DEBUG ON for module `zzdbg`.

    RED before the fix: the INFO global gate returned first, so the DEBUG
    record never reached the rule that admits it and the drain is empty.
    """
    var eng = _engine(String("info,zzdbg=debug"))
    eng.bind_worker_thread(UInt16(0))

    # The filter itself resolves correctly — the defect is in the GATE that
    # consumes it, not in the parse. Asserted so a failure here points at
    # env_filter rather than at the gate.
    assert_equal(
        Int(eng.effective_level("zzdbg")),
        Int(LEVEL_DEBUG),
        "EnvFilter must resolve the per-module rule to DEBUG",
    )
    assert_equal(
        Int(eng.global_level()),
        Int(LEVEL_INFO),
        "the global threshold is INFO",
    )

    var logger = Logger.borrow(eng)
    logger.debug["admitted {}", "zzdbg"](ArgStr(String("by-rule")))

    var lines = _drained(eng)
    assert_equal(
        len(lines),
        1,
        (
            "a per-module rule BELOW the global default must admit the record"
            " — `--log-level=info,zzdbg=debug` is the documented spelling of"
            " 'DEBUG on for one module'"
        ),
    )
    assert_true(
        _contains(lines[0], String("admitted by-rule")),
        "the admitted record decodes to its interpolated message",
    )


def test_module_without_a_rule_still_uses_the_global() raises:
    """The same engine must NOT become verbose everywhere. A module with no
    matching rule keeps the global INFO threshold."""
    var eng = _engine(String("info,zzdbg=debug"))
    eng.bind_worker_thread(UInt16(0))

    var logger = Logger.borrow(eng)
    logger.debug["should not appear {}", "zzother"](ArgStr(String("x")))

    assert_equal(
        len(_drained(eng)),
        0,
        (
            "lowering one module's threshold must not lower every module's —"
            " `zzother` has no rule and the global is INFO"
        ),
    )


# ---------------------------------------------------------------------------
# THE RAISE DIRECTION — the property a careless fix breaks.
# ---------------------------------------------------------------------------


def test_per_module_rule_above_the_global_still_suppresses() raises:
    """`--log-level=debug,zzwarn=warn` must SUPPRESS an INFO on `zzwarn`.

    This already worked; it is asserted because the obvious wrong fix for the
    test above ("return True as soon as the global admits") breaks it.
    """
    var eng = _engine(String("debug,zzwarn=warn"))
    eng.bind_worker_thread(UInt16(0))

    assert_equal(
        Int(eng.effective_level("zzwarn")),
        Int(LEVEL_WARN),
        "EnvFilter resolves the raising rule to WARN",
    )

    var logger = Logger.borrow(eng)
    logger.info["suppressed {}", "zzwarn"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)),
        0,
        (
            "a per-module rule ABOVE the global must still suppress — a gate"
            " that short-circuits on the global loses this"
        ),
    )

    # ...and the same module admits at its own level.
    logger.warn["admitted {}", "zzwarn"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)),
        1,
        "the raising rule admits at its own level",
    )


def test_longest_prefix_wins_through_the_gate() raises:
    """The gate must honour the LONGEST-prefix resolution, not the first rule.

    `komira_job_supervisor=warn` + `komira_job_supervisor.heartbeat=trace`: a TRACE on the
    dotted child is admitted even though its parent rule AND the global would
    both reject it — two levels of the same defect at once.
    """
    var eng = _engine(
        String("info,zzagent=warn,zzagent.heartbeat=trace")
    )
    eng.bind_worker_thread(UInt16(0))

    assert_equal(
        Int(eng.effective_level("zzagent.heartbeat")),
        Int(LEVEL_TRACE),
        "longest-prefix resolves the child to TRACE",
    )

    var logger = Logger.borrow(eng)
    logger.trace["hb {}", "zzagent.heartbeat"](ArgStr(String("tick")))
    assert_equal(
        len(_drained(eng)),
        1,
        "the longest-prefix rule admits the child's TRACE record",
    )

    logger.info["parent {}", "zzagent"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)),
        0,
        "the parent rule (WARN) still suppresses its own INFO",
    )


# ---------------------------------------------------------------------------
# THE SECOND DEFECT — `set_global_level` could raise but not lower.
# ---------------------------------------------------------------------------


def test_set_global_level_can_lower_the_threshold() raises:
    """`set_global_level` is the RUNTIME knob. It must work in both directions.

    RED before the fix: it stored into the atomic only, while gate (3) read
    the EnvFilter's parsed global — so lowering cleared gate (2) and was
    rejected by gate (3).
    """
    var eng = _engine(String("error"))
    eng.bind_worker_thread(UInt16(0))

    var logger = Logger.borrow(eng)
    logger.debug["before {}", "zzk"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)), 0, "at ERROR, a DEBUG is suppressed"
    )

    eng.set_global_level(LEVEL_TRACE)
    assert_equal(
        Int(eng.global_level()),
        Int(LEVEL_TRACE),
        "the atomic knob took the new value",
    )

    var logger2 = Logger.borrow(eng)
    logger2.debug["after {}", "zzk"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)),
        1,
        (
            "lowering the global threshold at runtime must ADMIT records that"
            " were suppressed before it — a knob that can only be raised is"
            " not a knob"
        ),
    )


def test_set_global_level_can_still_raise_the_threshold() raises:
    """The direction that already worked, kept honest."""
    var eng = _engine(String("trace"))
    eng.bind_worker_thread(UInt16(0))

    eng.set_global_level(LEVEL_ERROR)
    var logger = Logger.borrow(eng)
    logger.info["suppressed {}", "zzk"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)), 0, "raising the knob suppresses below it"
    )
    logger.error["admitted {}", "zzk"](ArgStr(String("x")))
    assert_equal(
        len(_drained(eng)), 1, "and still admits at or above it"
    )


# ---------------------------------------------------------------------------
# The no-override case: the common path, and the one the perf argument is
# about. It must behave EXACTLY as before.
# ---------------------------------------------------------------------------


def test_no_overrides_is_the_plain_global_threshold() raises:
    var eng = _engine(String("info"))
    eng.bind_worker_thread(UInt16(0))
    assert_equal(
        eng.filter_rule_count(),
        0,
        "no per-module rules parsed — this is the hot common case",
    )

    var logger = Logger.borrow(eng)
    logger.debug["no {}", "zzk"](ArgStr(String("x")))
    assert_equal(len(_drained(eng)), 0, "below the global: suppressed")
    logger.info["yes {}", "zzk"](ArgStr(String("x")))
    assert_equal(len(_drained(eng)), 1, "at the global: admitted")
    logger.error["yes {}", "zzk"](ArgStr(String("x")))
    assert_equal(len(_drained(eng)), 1, "above the global: admitted")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
