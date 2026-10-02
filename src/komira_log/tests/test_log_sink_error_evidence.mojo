# =============================================================================
# test_log_sink_error_evidence.mojo — a swallowed sink error must LEAVE
# EVIDENCE, and the cold emit path must not touch shared state it cannot use.
# =============================================================================
#
# CASES 1, 2, 3 — three sites that swallow a sink error.
#
#   shared_engine.drain_worker      a fully decoded record
#   shared_engine.emit_fallback_line a log-mirroring thread's write; every unbound-thread
#                                    log in a service takes this path
#   shared_engine.escalate_line      the "ERROR is never dropped" path itself
#
# Swallowing is the RIGHT policy — a logger must never wedge a worker loop on a
# transient sink error — but `LogSink` has no counter of any kind
# (output_sink.mojo declares `_kind`, `_lock`, `_file`, `_segments`,
# `_n_segments` and nothing else), so a swallowed error must be counted by the
# engine. A log line that vanishes with no trace is indistinguishable from a
# log line that was never emitted.
#
# ⚠ WHY THE COUNTER IS ON THE ENGINE AND NOT ON THE SINK. The subject is "a
# write the ENGINE swallowed", which is an engine fact: two of the three sites
# are not drains at all and run on threads that own no sink state. A sink-side
# counter answers a different question (how many write(2) calls short-wrote or
# retried — `komira_log.log_write`'s loss counters); the two are complementary,
# not duplicates.
#
# HOW A SINK ERROR IS PROVOKED DETERMINISTICALLY. `SegmentFile.append_line`
# rotates at the line boundary when the policy fires, and `_rotate` calls
# `rename_path`, which RAISES when `rename(2)` fails. So: a size-1 rotation
# policy (every line rotates) + unlinking the live file = the next append
# writes into the still-open fd, then tries to rename a path that no longer
# exists and raises ENOENT. No fault injection hook, no mock sink, no
# unsynchronised state — just POSIX.
#
# CASE 4 (the ordering half) — see the last test.
# =============================================================================

from std.os import remove

from std.testing import TestSuite, assert_true, assert_equal

from komira_log import SharedEngine, Logger
from komira_log.engine.rotation import RotationPolicy
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE
from komira_log.log_arg import ArgStr

from komira_runtime_paths import test_tmpdir


def _scratch_dir() -> String:
    try:
        return test_tmpdir()
    except:
        return String("/tmp")


def _base(tag: String) -> String:
    return _scratch_dir() + String("/komira_log_sinkerr_") + tag


def _filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


def _engine() raises -> SharedEngine:
    return SharedEngine(num_workers=1, filter=_filter())


def _break_sink(mut eng: SharedEngine, tag: String) raises:
    """Install a file sink and then make every subsequent write RAISE.

    `by_size(1)` makes the policy fire on every line, so each `append_line`
    ends in `_rotate`. Priming once moves the live file to `.0.log` and reopens
    it; unlinking that reopened live file leaves the fd valid (the write still
    succeeds) and the rename with no source, which raises. Deterministic, and
    it exercises the REAL `write_line_core`, not a stand-in.
    """
    eng.set_sink_single_file(_base(tag), RotationPolicy.by_size(1))
    # Prime: this write + rotate succeeds, and leaves a fresh live file open.
    eng.emit_fallback_line(String("prime"))
    assert_equal(
        eng.sink_dropped_line_count(),
        Int64(0),
        "the priming write must SUCCEED — otherwise the test proves nothing",
    )
    _rm(_base(tag) + ".log")


def _cleanup(tag: String):
    _rm(_base(tag) + ".log")
    for i in range(4):
        _rm(_base(tag) + String(".") + String(i) + ".log")


# ---------------------------------------------------------------------------
# CASE 2 — emit_fallback_line. A log-mirroring thread's write, and the path every
# unbound-thread log in a service takes.
# ---------------------------------------------------------------------------


def test_fallback_line_sink_error_leaves_evidence() raises:
    var tag = String("fallback")
    var eng = _engine()
    _break_sink(eng, tag)

    eng.emit_fallback_line(String("this line cannot be written"))

    assert_equal(
        eng.sink_dropped_line_count(),
        Int64(1),
        (
            "a line `emit_fallback_line` could not write must be COUNTED — it"
            " was swallowed with no trace at all"
        ),
    )
    _cleanup(tag)


# ---------------------------------------------------------------------------
# CASE 3 — escalate_line. This is the "ERROR is never dropped" path, so a
# silent failure here makes the guarantee not a guarantee.
# ---------------------------------------------------------------------------


def test_escalate_line_sink_error_leaves_evidence() raises:
    var tag = String("escalate")
    var eng = _engine()
    _break_sink(eng, tag)

    eng.escalate_line(String("an ERROR that could not be written"))

    assert_equal(
        eng.sink_dropped_line_count(),
        Int64(1),
        (
            "an ERROR the sink refused must be COUNTED — this is the"
            " never-dropped path, and a silent failure here means the"
            " guarantee is not one"
        ),
    )
    _cleanup(tag)


# ---------------------------------------------------------------------------
# CASE 1 — drain_worker. A fully decoded record, thrown away.
# ---------------------------------------------------------------------------


def test_drain_sink_error_leaves_evidence() raises:
    var tag = String("drain")
    var eng = _engine()
    eng.bind_worker_thread(UInt16(0))

    var logger = Logger.borrow(eng)
    logger.info["record {}", "zzs"](ArgStr(String("a")))
    logger.info["record {}", "zzs"](ArgStr(String("b")))
    logger.info["record {}", "zzs"](ArgStr(String("c")))

    _break_sink(eng, tag)

    var n = eng.drain_worker(0, 16)
    assert_equal(
        n, 3, "all three records were drained (the decode side is fine)"
    )
    assert_equal(
        eng.sink_dropped_line_count(),
        Int64(3),
        (
            "every decoded record the sink refused must be COUNTED — LogSink"
            " has no counter of its own"
        ),
    )
    _cleanup(tag)


def test_a_healthy_sink_counts_nothing() raises:
    """The control. A counter that only ever goes up is not evidence."""
    var tag = String("healthy")
    var eng = _engine()
    eng.bind_worker_thread(UInt16(0))
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())

    var logger = Logger.borrow(eng)
    logger.info["fine {}", "zzs"](ArgStr(String("a")))
    _ = eng.drain_worker(0, 16)
    eng.emit_fallback_line(String("fine"))
    eng.escalate_line(String("fine"))

    assert_equal(
        eng.sink_dropped_line_count(),
        Int64(0),
        "a healthy sink drops nothing",
    )
    assert_equal(
        eng.sink_flush_failure_count(),
        Int64(0),
        "a healthy sink flushes cleanly",
    )
    _cleanup(tag)


# ---------------------------------------------------------------------------
# CASE 4 (the half that is testable here) — the ORDERING invariant.
#
# ⚠ READ THIS BEFORE "FIXING" THE RACE WITH THIS TEST AS YOUR GUIDE. Moving
# `register_site` below the bound-worker check does NOT make `SiteDictionary`
# thread-safe, and this test does not claim it does. Two BOUND workers emitting
# a new site concurrently still append to the same unsynchronised `List`. What
# the reordering buys is narrower and real: the cold path no longer mutates
# shared state it has no use for. A record rendered on the caller and written
# through `emit_fallback_line` never reaches a drain, so its (fmt, module) is
# never looked up in the dictionary — registering it was pure cost AND pure
# hazard, and it put EVERY unbound thread in the process (HTTP handlers, the
# agent heartbeat, CLI tools) into the set of racers for no benefit at all.
#
# What is pinned below is exactly that: the unbound path does not touch the
# dictionary. The residual — synchronising the dictionary for the bound
# workers — needs `site_dictionary.mojo` and is reported, not smuggled in here.
# ---------------------------------------------------------------------------


def test_unbound_thread_emit_does_not_touch_the_site_dictionary() raises:
    """An emit from a thread with no worker_id must not mutate shared state.

    RED before the fix: `register_site` ran BEFORE the `wid == WORKER_ID_UNSET`
    check on every emit path, so an unbound thread appended to the shared
    dictionary on its way to a synchronous write that never consults it.
    """
    var tag = String("register")
    var eng = _engine()
    # Deliberately NOT bound: `current_worker_id()` is WORKER_ID_UNSET, so
    # this emit takes the synchronous render-and-write arm.
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())

    var before = eng.site_dict_len()
    assert_equal(before, 0, "a fresh engine has an empty site dictionary")

    var logger = Logger.borrow(eng)
    logger.info["unbound {}", "zzu"](ArgStr(String("x")))

    assert_equal(
        eng.site_dict_len(),
        0,
        (
            "the unbound-thread arm renders on the caller and never reaches a"
            " drain, so it must not append to the shared SiteDictionary — an"
            " unsynchronised List.append from an arbitrary thread, for an"
            " entry nothing will ever read"
        ),
    )
    _cleanup(tag)


def test_bound_worker_emit_does_register_its_site() raises:
    """The other half: a record that WILL be decoded by a drain must still be
    registered, or the drain cannot reconstruct its line. This is what stops
    the fix above from being 'delete the registration'."""
    var eng = _engine()
    eng.bind_worker_thread(UInt16(0))

    assert_equal(eng.site_dict_len(), 0, "empty to start")

    var logger = Logger.borrow(eng)
    logger.info["bound {}", "zzb"](ArgStr(String("x")))

    assert_true(
        eng.site_dict_len() > 0,
        "the ring path must register its site so the drain can decode it",
    )

    var lines = eng.drain_worker_to_lines(0, 8)
    assert_equal(len(lines), 1, "the record drains")
    assert_true(
        lines[0].byte_length() > 0,
        "and decodes to a real line, not an empty one",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
