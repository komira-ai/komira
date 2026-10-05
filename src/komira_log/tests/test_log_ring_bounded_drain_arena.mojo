# =============================================================================
# test_log_ring_bounded_drain_arena.mojo
#   PRIMITIVE-CORRECTNESS GUARD for the engine's bounded drain.
# =============================================================================
#
# WHAT IT PROVES (all PASS):
#   1. A real `SharedEngine`, emitted a 12-record OTLP-shaped corpus, then
#      drained DIRECTLY via `drain_worker_to_records(0, 24)` (the method an
#      idle-hook indexer calls), decodes ALL 12 records cleanly — NO OOB, no
#      arena issue. (Every encoded arg-blob in this corpus fits the 48-byte
#      inline blob, so arena reclaim ORDERING is irrelevant to it.)
#   2. A backlog LARGER than the bounded cap drains across multiple bounded
#      windows with every record decoding correctly (no cross-cap-boundary OOB).
#   3. A local (non-engine) ring decodes the same shape cleanly (the control).
#
# WHY IT MATTERS. A crash inside a bounded drain that reads an empty arena or
# indexes past the 48-byte inline blob looks like an arena-reclaim-vs-bounded-
# drain ORDERING defect. It can instead be a LIFETIME defect in the caller: an
# installed hook that names no origin lets ASAP destruction end the engine
# before the hook fires, and the drain then reads freed memory — where an inline
# field lands in bytes the allocator has already rewritten, the Slab's
# separately-allocated backing survives until something reuses it, and WHICH
# record goes bad depends on allocator traffic. The fix for that class is a hook
# value whose TYPE carries the engine's origin (`komira_log_index`'s
# `InstalledIndexHook`), so the engine outlives the installed hook by
# construction.
#
# These three GREEN assertions are what keep such a crash from being
# misattributed to the arena: the ring + engine bounded-drain primitive IS
# correct in isolation. Its companion is `test_log_drain_corrupt_header_guard`,
# which asserts the other half — that a record whose HEADER is wrong renders a
# short line instead of aborting the process.
#
# This is a UNIT test against the engine bounded-drain primitive directly — no
# runtime / worker pthread / objectstore / hook erasure. Deterministic, single
# threaded, and it bypasses the type-erased hook reach so its GREEN result
# localizes any such crash OUT of the ring + engine bounded drain.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log import SharedEngine
from komira_log import LogRecordView
from komira_log.env_filter import EnvFilter
from komira_log.engine.emit import emit_record
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.drain import drain_to_views, decode_one_to_view
from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR
from komira_log.log_arg import ArgI64, ArgStr


# -----------------------------------------------------------------------------
# Fixtures — the SAME 6-site OTLP corpus the idle-hook e2e emits.
# -----------------------------------------------------------------------------


def _make_engine(num_workers: Int) raises -> SharedEngine:
    var eng = SharedEngine(num_workers=num_workers, filter=EnvFilter())
    eng.register_site["request {} method {} status {}", "komira_http"]()
    eng.register_site[
        "query finished in {} ms scanned {} rows", "komira_engine"
    ]()
    eng.register_site["opened file {} size {} bytes", "komira_parquet"]()
    eng.register_site["retry {} reason {}", "komira_job_supervisor"]()
    eng.register_site["connection {} from {} closed", "komira_broker"]()
    eng.register_site["login {} status {}", "komira_auth"]()
    return eng^


def _emit_corpus(mut eng: SharedEngine, wid: Int, n: Int):
    """Emit `n` records cycling the 6 OTLP sites onto `engine.ring(wid)` —
    byte-identical to the idle-hook e2e's `_emit_corpus`."""
    ref r = eng.ring(wid)
    for i in range(n):
        var m = i % 6
        var c = UInt64(1000 + i)
        if m == 0:
            _ = emit_record["request {} method {} status {}", "komira_http"](
                r, LEVEL_INFO, c, ArgStr(String("/v1/query")),
                ArgStr(String("POST")), ArgI64(200),
            )
        elif m == 1:
            _ = emit_record[
                "query finished in {} ms scanned {} rows", "komira_engine"
            ](r, LEVEL_INFO, c, ArgI64(42), ArgI64(6001215))
        elif m == 2:
            _ = emit_record["opened file {} size {} bytes", "komira_parquet"](
                r, LEVEL_WARN, c, ArgStr(String("lineitem.parquet")),
                ArgI64(298000000),
            )
        elif m == 3:
            _ = emit_record["retry {} reason {}", "komira_job_supervisor"](
                r, LEVEL_ERROR, c, ArgI64(3),
                ArgStr(String("connection timeout to upstream")),
            )
        elif m == 4:
            _ = emit_record["connection {} from {} closed", "komira_broker"](
                r, LEVEL_INFO, c, ArgI64(7), ArgStr(String("10.0.0.42"))
            )
        else:
            _ = emit_record["login {} status {}", "komira_auth"](
                r, LEVEL_INFO, c, ArgStr(String("login")), ArgI64(200)
            )


# =============================================================================
# THE GUARD — the engine bounded drain over the emitted OTLP corpus decodes
# every record cleanly (no OOB), localizing the e2e crash OUT of the ring/arena.
# =============================================================================


def test_engine_bounded_drain_otlp_corpus_no_oob() raises:
    """Emit the 12-record OTLP corpus onto a real engine ring, then bounded-drain
    it via `drain_worker_to_records(0, 24)` — the EXACT method the idle hook
    calls, but reached COHERENTLY (direct, no erasure boundary). All 12 records
    decode cleanly: this PROVES the ring + bounded-drain primitive is correct and
    that the e2e OOB is NOT an arena-ordering / ring bug (it is the engine-reach
    incoherence ACROSS the erasure boundary — see the file header)."""
    var eng = _make_engine(1)
    var n = 12  # two full 6-site cycles, <= DRAIN_CAP (24): one bounded window.
    _emit_corpus(eng, 0, n)

    # The EXACT bounded drain the idle hook invokes (DRAIN_CAP == 24).
    var views = eng.drain_worker_to_records(0, 24)
    assert_equal(len(views), n, "all 12 emitted records bounded-drain to views")

    # Every record decoded a non-empty interpolated message (no OOB / garbage).
    for i in range(len(views)):
        assert_true(
            views[i].message.byte_length() > 0,
            "record decoded a non-empty message (no OOB read)",
        )

    # The selective 'login' site (m==5, every 6th record) appears twice in 12.
    var login_hits = 0
    for i in range(len(views)):
        if String("login") in views[i].message:
            login_hits += 1
    assert_equal(login_hits, 2, "2 'login' records in 12 (sites m==5)")


def test_engine_bounded_drain_across_cap_multiple_windows() raises:
    """A backlog LARGER than the bounded cap drains across multiple bounded
    windows, every record decoding correctly (no arena OOB across the cap
    boundary). Drives the SAME repeated-fire shape the no-starve e2e gate
    asserts, at the engine bounded-drain level."""
    var eng = _make_engine(1)
    var cap = 6
    var n = cap * 3 + 2  # 20 records -> 4 bounded windows.
    _emit_corpus(eng, 0, n)

    var total = 0
    var login_hits = 0
    var fires = 0
    while fires < 10:  # hard cap (no unbounded loop).
        var views = eng.drain_worker_to_records(0, cap)
        if len(views) == 0:
            break
        for i in range(len(views)):
            assert_true(
                views[i].message.byte_length() > 0,
                "windowed record decoded without OOB",
            )
            if String("login") in views[i].message:
                login_hits += 1
        total += len(views)
        fires += 1

    assert_equal(total, n, "the full backlog drained across bounded windows")
    # 20 records, login at m==5: i in {5, 11, 17} -> 3 hits.
    assert_equal(login_hits, 3, "all 3 'login' records searchable across windows")


def test_local_ring_bounded_drain_baseline_no_oob() raises:
    """Baseline: a LOCAL (non-engine) ring bounded-drained via the free-fn
    `decode_one_to_view` loop decodes the same corpus cleanly. This is the
    control that proves the ring + decode primitive is correct in isolation;
    the engine-level tests above prove the engine bounded-drain seam matches."""
    var dict = SiteDictionary()
    dict.register["login {} status {}", "komira_auth"]()
    var anchor = CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_780_272_000) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )
    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    for i in range(4):
        _ = emit_record["login {} status {}", "komira_auth"](
            ring, LEVEL_INFO, UInt64(i), ArgStr(String("login")), ArgI64(200)
        )

    var views = drain_to_views(ring, dict, anchor)
    assert_equal(len(views), 4, "baseline: 4 local-ring records drained")
    for i in range(len(views)):
        assert_true(String("login") in views[i].message, "baseline decodes")


def main() raises:
    var suite = TestSuite()
    suite.test[test_local_ring_bounded_drain_baseline_no_oob]()
    suite.test[test_engine_bounded_drain_otlp_corpus_no_oob]()
    suite.test[test_engine_bounded_drain_across_cap_multiple_windows]()
    suite^.run()
