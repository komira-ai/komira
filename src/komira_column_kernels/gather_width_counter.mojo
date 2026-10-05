# =============================================================================
# gather_width_counter -- the STRUCTURAL falsifier for the 2-byte / 1-byte
# fixed-width GATHER arms
# =============================================================================
#
# WHY THIS EXISTS. A fixed-width gather that specialises only `width == 8` and
# `width == 4` onto a typed-store loop drops every other width into an `else:`
# that copies `width` bytes per row. Narrowing a payload column to 2 bytes then
# makes the gather SLOWER on strictly fewer useful bytes, because every row
# pays a 2-byte `memcpy`. The typed 2-byte and 1-byte arms fix that, and this
# file's counters are what make those arms OBSERVABLE.
#
# THE PROBLEM THIS FILE SOLVES -- the same one `join_index_window_counter.mojo`
# solves, for the same reason. A typed 2-byte store and a 2-byte `memcpy`
# produce BYTE-IDENTICAL output. Every value assertion stays green whichever
# arm ran. A correctness test therefore cannot see the arm stop applying, and
# a perf A/B whose treatment arm silently ran the control loop compares the
# shipped path against itself and reports a null forever. So the arm is
# guarded by an OBSERVATION OF WHICH LOOP RAN, not by an output comparison.
#
# WHAT IS OBSERVED, at every fixed-width gather site:
#
#   * `typed_colrows`   -- column-rows served by a TYPED-STORE arm at width 2 or
#                         1. Reads ZERO if the narrow arms are absent or
#                         unreachable, whatever the output looks like.
#   * `narrow_fallback_colrows` -- column-rows a width-1 or width-2 column sent
#                         into the per-row byte-copy `else:`. THIS IS THE
#                         WHOLE INVARIANT, and it is a SHAPE assertion, not a
#                         threshold: it must read EXACTLY ZERO. It moves in the
#                         opposite direction to `typed_colrows`, which is what
#                         makes a zero on either one negative evidence rather
#                         than void.
#   * `wide_fallback_colrows` -- column-rows a width the arms do NOT serve sent
#                         into the same `else:`. ITS JOB IS TO STOP THE
#                         INVARIANT ABOVE FROM BEING VACUOUS. The fallback is
#                         legitimate and must survive -- DECIMAL128 and
#                         INTERVAL_MONTH_DAY_NANO are 16 bytes, DECIMAL256 is 32
#                         -- so "narrow_fallback == 0" would also be satisfied by
#                         DELETING the fallback, or by a fixture that never
#                         reaches any gather at all. A test that asserts
#                         `narrow == 0` must assert `wide > 0` beside it, on the
#                         same run, or it is a test of nothing.
#
# THE SPLIT IS AT THE WRITE, NOT AT THE READ, BECAUSE `Atomic` HAS NO
# `fetch_or` (`Atomic[DType.int64]` exposes `fetch_add` / `load` / `store` and
# no bitwise RMW, so a `1 << width` bitmask does not compile). Two counters and
# a branch at the call site is strictly better anyway: `narrow == 0` is
# readable as an invariant where `mask & 0b110 == 0` is a puzzle, and neither
# needs a CAS loop.
#
# WHY THE 8-BYTE AND 4-BYTE ARMS ARE **NOT** INSTRUMENTED. They are the hot
# path of every join, sort and projection in the engine. An atomic RMW on that
# path -- even a relaxed one, even once per slice -- is a permanent tax paid by
# the CONTROL arm of the very measurement this file exists to make readable.
# The narrow arms and the fallback are cold, so instrumenting them costs
# nothing anyone is measuring.
#
# COST. ONE relaxed `fetch_add` per gather CALL (per record x column x row
# range), never per row, on the narrow and fallback arms only.
#
# Same `GlobalCounter` primitive (`global_counter.mojo`) as
# `join_index_window_counter.mojo` -- no environment read, no
# `unsafe_from_address` laundering, no wildcard-origin field.
# =============================================================================

from komira_counters.global_counter import GlobalCounter


comptime _GW_TYPED = GlobalCounter["komira_column_kernels_gather_narrow_typed"]
comptime _GW_NARROW_FB = GlobalCounter[
    "komira_column_kernels_gather_narrow_fallback"
]
comptime _GW_WIDE_FB = GlobalCounter[
    "komira_column_kernels_gather_wide_fallback"
]


@always_inline
def gather_width_has_typed_arm(width: Int) -> Bool:
    """Whether a typed-store gather arm exists for element width `width`.

    STATED ONCE so the counter's own classification cannot drift from the
    kernels'.
    """
    return width == 8 or width == 4 or width == 2 or width == 1


@always_inline
def gather_note_narrow_typed(colrows: Int) raises:
    """Record `colrows` element copies served by a width-2 or width-1 TYPED arm.

    Args:
        colrows: Elements this call copied through the typed-store loop.
    """
    _GW_TYPED.add(colrows)


@always_inline
def gather_note_width_fallback(colrows: Int, width: Int) raises:
    """Record `colrows` element copies served by the per-row byte-copy `else:`.

    Args:
        colrows: Elements this call copied one at a time.
        width: The element width that reached the fallback. It selects WHICH
            counter is bumped, so a test can assert a SHAPE ("no width with a
            typed arm reached the fallback") rather than a total, which drifts
            with every fixture.
    """
    if gather_width_has_typed_arm(width):
        # A width WITH a typed arm reached the fallback anyway. That is the
        # defect this file exists to make visible, and it is counted separately
        # so the assertion can be `== 0` rather than a comparison.
        _GW_NARROW_FB.add(colrows)
    else:
        _GW_WIDE_FB.add(colrows)


def gather_narrow_typed_colrows() raises -> Int:
    """Column-rows served by a width-2 / width-1 typed-store arm."""
    return _GW_TYPED.read()


def gather_narrow_fallback_colrows() raises -> Int:
    """Column-rows a width WITH a typed arm sent into the fallback anyway.

    MUST read 0. This is the defect indicator: it is what a removed, unreachable
    or mis-gated narrow arm turns positive, and no value assertion anywhere can
    see that happen because both arms produce identical bytes.
    """
    return _GW_NARROW_FB.read()


def gather_wide_fallback_colrows() raises -> Int:
    """Column-rows legitimately served by the fallback (widths 16, 32, ...).

    The ANTI-VACUITY twin of `gather_narrow_fallback_colrows`. Assert it
    POSITIVE on the same run, or `narrow == 0` is also satisfied by a fallback
    that was deleted and by a fixture that gathered nothing.
    """
    return _GW_WIDE_FB.read()


def reset_gather_width_counters() raises:
    """Reset all three process-wide counters to 0 (test setup)."""
    _GW_TYPED.reset()
    _GW_NARROW_FB.reset()
    _GW_WIDE_FB.reset()
