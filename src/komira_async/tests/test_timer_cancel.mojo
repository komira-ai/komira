# =============================================================================
# test_timer_cancel.mojo
# =============================================================================
# cancel() implementation tests.
#
# cancel(handle):
#   - Look up self._level_<handle._level>[handle._bucket].
#   - Linear scan for entry with _handle_id == handle._id.
#   - Mark _cancelled = True (tombstone). DO NOT remove physically;
#     advance() sweeps tombstoned entries.
#   - Idempotent: cancel-twice marks the same entry true a second time
#     (no-op).
#   - Cancel after fire (entry no longer exists): silent no-op.
#   - Cancel with stale (different) id: silent no-op.
#   - Post-cascade fallback: if cached (level, bucket) doesn't contain
#     the matching id, scan all 384 buckets for it. (v0.1
#     accepts O(384) worst-case; v0.2 may add a side-table.)
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.timer.timer_wheel import (
    TimerCallback,
    TimerHandle,
    TimerWheel,
)


def _placeholder_cb(arg: UInt64) -> None:
    pass


def test_cancel_marks_entry_tombstoned() raises:
    """Schedule, cancel, assert entry._cancelled == True."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(42))
    var h = w.schedule(Int64(5_000_000), cb)
    assert_equal(Int(h._bucket), 5)
    # Pre-cancel: entry exists, not cancelled.
    assert_false(w._level_0[5][0]._cancelled)
    w.cancel(h)
    # Post-cancel: entry STILL there (not physically removed) but
    # tombstoned.
    assert_equal(len(w._level_0[5]), 1)
    assert_true(w._level_0[5][0]._cancelled)


def test_cancel_specific_entry_among_many() raises:
    """Schedule 3 in same bucket; cancel the middle one; only it is
    tombstoned."""
    var w = TimerWheel()
    var cb_a = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(100))
    var cb_b = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(200))
    var cb_c = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(300))
    var ha = w.schedule(Int64(5_000_000), cb_a)
    var hb = w.schedule(Int64(5_000_000), cb_b)
    var hc = w.schedule(Int64(5_000_000), cb_c)
    w.cancel(hb)
    assert_false(w._level_0[5][0]._cancelled)  # ha alive
    assert_true(w._level_0[5][1]._cancelled)   # hb tombstoned
    assert_false(w._level_0[5][2]._cancelled)  # hc alive


def test_cancel_idempotent() raises:
    """Cancel-twice is safe; the second call is a no-op."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var h = w.schedule(Int64(5_000_000), cb)
    w.cancel(h)
    assert_true(w._level_0[5][0]._cancelled)
    # Cancel again — silent no-op (entry already cancelled).
    w.cancel(h)
    assert_true(w._level_0[5][0]._cancelled)


def test_cancel_stale_id_is_noop() raises:
    """Cancel with an id that no current entry has → silent no-op."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var _h = w.schedule(Int64(5_000_000), cb)
    # Construct a stale handle with a never-issued id.
    var stale = TimerHandle(_id=UInt64(99999), _level=UInt8(0), _bucket=UInt8(5))
    w.cancel(stale)
    # Real entry is unaffected.
    assert_false(w._level_0[5][0]._cancelled)


def test_cancel_handle_with_wrong_cached_location() raises:
    """If handle._level / _bucket don't match where the entry actually is
    (post-cascade fallback case), cancel does a full-wheel scan and finds
    it anyway. We simulate this by constructing a handle by hand whose
    cached location is wrong."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    # Real schedule → level 0 slot 5.
    var real_h = w.schedule(Int64(5_000_000), cb)
    # Construct a "wrong cache" handle with the same id but wrong
    # (level, bucket) — e.g. level 1 slot 2.
    var wrong = TimerHandle(_id=real_h._id, _level=UInt8(1), _bucket=UInt8(2))
    w.cancel(wrong)
    # Despite wrong cache, fallback scan should have found and tombstoned
    # the real entry at level 0 bucket 5.
    assert_true(w._level_0[5][0]._cancelled)


def test_cancel_level1_entry() raises:
    """Cancel works on entries at non-level-0 too."""
    var w = TimerWheel()
    var cb = TimerCallback(_fn=_placeholder_cb, _arg=UInt64(0))
    var h = w.schedule(Int64(200_000_000), cb)  # 200ms → level 1 slot 3
    assert_equal(Int(h._level), 1)
    assert_equal(Int(h._bucket), 3)
    w.cancel(h)
    assert_true(w._level_1[3][0]._cancelled)


def main() raises:
    test_cancel_marks_entry_tombstoned()
    test_cancel_specific_entry_among_many()
    test_cancel_idempotent()
    test_cancel_stale_id_is_noop()
    test_cancel_handle_with_wrong_cached_location()
    test_cancel_level1_entry()
    print("PASS komira_async.timer cancel")
