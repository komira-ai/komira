# =============================================================================
# test_shared_engine_tls_key_reclaimed.mojo — a destroyed engine gives its
#   pthread TLS key back.
# =============================================================================
#
# ★ THE PROPERTY THIS PINS. `SharedEngine.__init__` calls
# `create_worker_id_key()` -> `pthread_key_create`. A pthread key is a
# PROCESS-WIDE resource with a HARD CAP (`PTHREAD_KEYS_MAX` — 512 on macOS, 1024
# on glibc), so an engine that does not give its key back is not merely
# untidy: once the keys run out, the next engine in the process CANNOT BE
# CONSTRUCTED AT ALL.
#
# It is reachable from a shipped surface, not just from a test loop.
# `EngineContext` builds one `SharedEngine` per context, and an embedder that
# builds one `EngineContext` PER CALL would turn the cap into a cap on QUERIES
# PER PROCESS — `pthread_key_create` failing with EAGAIN after a few hundred.
#
# WHY THIS TEST AND NOT AN EngineContext LOOP. `EngineContext` spawns one
# pthread per core per construction, so a 600-iteration loop is many thousands
# of thread create/joins. `SharedEngine` is the thing that OWNS the key;
# testing it directly isolates the invariant and runs in well under a second.
#
# WHY 600. Above the macOS cap (512) and below glibc's (1024) is not enough — a
# linux run must fail too. 600 exceeds macOS's cap outright; the loop asserts
# it can build MORE engines than the platform has keys, which is only possible
# if each one is returned. Without the key delete this raises; with it, it
# completes.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_WARN


def _filter_at(level: UInt8) -> EnvFilter:
    var f = EnvFilter()
    f.global_level = level
    return f^


def test_engines_beyond_the_pthread_key_cap_can_be_built() raises:
    """600 construct/drop cycles — more than macOS's 512-key `PTHREAD_KEYS_MAX`.

    RED BEFORE THE FIX: raises `pthread_key_create failed rc=35` (EAGAIN)
    partway through, because every prior engine still holds its key.
    """
    comptime CYCLES = 600
    var last_key = UInt64(0)
    for i in range(CYCLES):
        var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
        last_key = eng.tls_key()
        # Touch the key so a hypothetical "never actually created" regression
        # cannot pass this test: an unbound thread reads the UNSET sentinel.
        assert_equal(
            Int(eng.current_worker_id()),
            0xFFFF,
            "an unbound thread reads WORKER_ID_UNSET",
        )
        _ = i
    # The key ID is RECYCLED once released, so after 600 cycles the last key
    # must still be a small number rather than ~600. This is what separates
    # "returned" from "the platform happened to have enough".
    assert_true(
        Int(last_key) < 512,
        "the 600th engine's key id must be a RECYCLED slot, got "
        + String(last_key),
    )
    print("  test_engines_beyond_the_pthread_key_cap_can_be_built PASS")


def _one_engine_key() raises -> UInt64:
    """Build ONE engine, read its key, drop it before returning. A function
    body is the scope — `if True:` would read as a condition and `var _ = ...`
    cannot express "destroyed HERE"."""
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
    return eng.tls_key()


def test_key_is_reused_across_sequential_engines() raises:
    """Two engines built one-after-the-other, the first destroyed before the
    second, get the SAME key id — the sharpest statement of reclamation."""
    var k1 = _one_engine_key()
    var k2 = _one_engine_key()
    assert_equal(
        Int(k1), Int(k2), "a released key id is handed back to the next engine"
    )
    print("  test_key_is_reused_across_sequential_engines PASS")


def test_two_live_engines_get_distinct_keys() raises:
    """The reclamation must not go so far as to share a key between two LIVE
    engines — each would then overwrite the other's per-thread worker id."""
    var a = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
    var b = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
    assert_true(
        a.tls_key() != b.tls_key(),
        "two LIVE engines must hold distinct pthread keys",
    )
    print("  test_two_live_engines_get_distinct_keys PASS")


def main() raises:
    print("test_shared_engine_tls_key_reclaimed")
    test_two_live_engines_get_distinct_keys()
    test_key_is_reused_across_sequential_engines()
    test_engines_beyond_the_pthread_key_cap_can_be_built()
    print("ALL PASS")
