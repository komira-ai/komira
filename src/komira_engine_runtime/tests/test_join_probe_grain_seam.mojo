# =============================================================================
# test_join_probe_grain_seam.mojo — the tier that existed and was never consulted
# =============================================================================
#
# `MORSEL_TIER_JOIN_PROBE` and its stricter `MIN_MORSEL_ROWS_JOIN_PROBE = 4096`
# have been in `morsel_sizing_policy.mojo` since the tier table was written, and
# a census of the whole tree found ZERO production consumers: only
# `tests/unit/test_morsel_sizing_policy.mojo`, which drives
# `pol.join_probe_morsel_rows(...)` directly and pins the clamp perfectly, and a
# passthrough accessor on `EngineContext` that nothing called. Meanwhile
# `materialize_join`'s in-mem probe driver — the one site the tier was written
# for — read the DEFAULT tier.
#
# ⚠ SO THE EXISTING SUITE COULD NOT HAVE CAUGHT IT, AND STILL CANNOT. Every
# assertion over there is about the POLICY; none is about which tier the probe
# ASKS FOR. That is the gap this file covers: it drives
# `join_probe_morsel_rows_swept`, the one seam `materialize_join` calls, and
# asserts the shipped arm is the JOIN_PROBE tier and NOT the DEFAULT one.
#
# THE SCHEMA IS THE WIDE 100xINT64 ONE, REUSED FROM THE POLICY SUITE, for one
# reason: it is the shape on which the two tiers give DIFFERENT answers. The
# fixture profile leaves the E-core L2 fields unset, so the budget accessor
# falls back to `l2_cache_bytes` = 256 KiB with divisor 1 -> a 128 KiB budget
# -> base = 131072/800 = 163 rows, so DEFAULT clamps to 1024 and JOIN_PROBE to
# 4096. (The sizing input used to be l1d/2 = 64 KiB -> base 81; both
# land on the same clamps, which is why this file did not move when the L2
# budget became the default.) On a narrow schema both tiers return the same
# number and every assertion below would pass with the seam wired to either —
# a vacuous green. `test_the_two_tiers_actually_differ_here` asserts that
# precondition FIRST, so the file cannot go vacuous silently if a clamp moves.
#
# ⚠ THIS GUARDS THE SEAM, NOT THE WIRING. Unlike the collect sizing site — whose
# choice is observable through `EngineContext.last_collect_morsel_rows()` — the
# probe grain has no context handle to record itself on, so a revert of
# `materialize_join`'s call back to `policy.default_morsel_rows(...)` reds
# nothing here. What covers that today is the dark `[MORSEL_ROWS]
# site=join_probe` line and the corpus census taken with it (24 of 82 cells
# reach this seam). Said plainly rather than left to be assumed.
# =============================================================================

from std.testing import (
    TestSuite, assert_equal, assert_not_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_host_profile.hardware import HardwareProfile
from komira_host_profile.morsel_sizing_policy import (
    MIN_MORSEL_ROWS_DEFAULT,
    MIN_MORSEL_ROWS_JOIN_PROBE,
    MorselSizingPolicy,
    join_probe_morsel_rows_swept,
)


def _wide_100_i64_schema() -> Schema:
    """100 Int64 columns (row_width = 800) — the MIN-clamp shape."""
    var sb = SchemaBuilder()
    for i in range(100):
        sb.add_field(Field("c" + String(i), ArrowType.INT64, False))
    return sb.build()


def _l2pw_256kb_profile() -> HardwareProfile:
    """L2 share = 256 KiB (the E-core fields are unset, so the budget
    accessor falls back to `l2_cache_bytes` with divisor 1) -> a 128 KiB
    budget. `l1d_cache_bytes` is NOT the sizing input -- see this file's
    header -- and is carried only because the ctor is positional."""
    return HardwareProfile(
        4, 4, 128 * 1024, 256 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
    )


def _pol() -> MorselSizingPolicy:
    return MorselSizingPolicy(_l2pw_256kb_profile())


# =============================================================================
# 0 — THE PRECONDITION. Without it every leg below is vacuous.
# =============================================================================


def test_the_two_tiers_actually_differ_here() raises:
    """The fixture must be a shape on which DEFAULT and JOIN_PROBE disagree.

    If a clamp ever moves so they agree, every other assertion in this file
    would pass with the seam wired to EITHER tier. Fail here instead, loudly."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    assert_equal(pol.default_morsel_rows(wide), MIN_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.join_probe_morsel_rows(wide), MIN_MORSEL_ROWS_JOIN_PROBE)
    assert_not_equal(
        MIN_MORSEL_ROWS_DEFAULT, MIN_MORSEL_ROWS_JOIN_PROBE,
        "the two tier MINs are equal, so this file can no longer distinguish"
        " which tier the probe seam consults — pick a new fixture",
    )


# =============================================================================
# 1 — THE SHIPPED ARM. Default arguments -> the JOIN_PROBE tier.
# =============================================================================


def test_shipped_arm_is_the_join_probe_tier() raises:
    """The default arguments return the JOIN_PROBE tier, NOT the DEFAULT one.

    This is the whole change: reverting the seam to `default_morsel_rows` reds
    exactly here."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    var got = join_probe_morsel_rows_swept(pol, wide)
    assert_equal(
        got, MIN_MORSEL_ROWS_JOIN_PROBE,
        "the shipped probe grain must be the JOIN_PROBE tier",
    )
    assert_not_equal(
        got, pol.default_morsel_rows(wide),
        "the shipped probe grain must NOT be the DEFAULT tier — that is the"
        " earlier incumbent this change replaced",
    )


# =============================================================================
# 2 — THE A/B ORACLE. `tier_enabled=False` -> the incumbent, exactly.
# =============================================================================


def test_kill_switch_restores_the_default_tier() raises:
    """`tier_enabled=False` returns `default_morsel_rows` — the Int the
    pre-change call site passed to `BatchMorselSource`. This arm is what the
    landing A/B measured against, so it has to be the incumbent BYTE-FOR-BYTE
    and not merely 'something smaller'."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    assert_equal(
        join_probe_morsel_rows_swept(pol, wide, tier_enabled=False),
        pol.default_morsel_rows(wide),
        "tier_enabled=False must restore the DEFAULT tier",
    )


def test_enabled_keeps_the_tier() raises:
    """`tier_enabled=True` (the default) keeps the JOIN_PROBE tier, whether
    stated or left to the default."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    assert_equal(
        join_probe_morsel_rows_swept(pol, wide, tier_enabled=True),
        MIN_MORSEL_ROWS_JOIN_PROBE,
        "tier_enabled=True must keep the JOIN_PROBE tier",
    )
    assert_equal(
        join_probe_morsel_rows_swept(pol, wide),
        MIN_MORSEL_ROWS_JOIN_PROBE,
        "the default must keep the JOIN_PROBE tier",
    )


# =============================================================================
# 3 — THE SWEEP KNOB, and the `= 1` meaning the landing deliberately preserved.
# =============================================================================


def test_flat_grain_override() raises:
    """`forced_rows=N` (N >= 2) forces a flat grain of N rows.

    The four values are the arms of the landing sweep, so this is also the pin
    that a re-run of that sweep measures what its ledger says it measured."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    for n in [4096, 8192, 16384, 32768]:
        assert_equal(
            join_probe_morsel_rows_swept(pol, wide, forced_rows=n), n,
            "a flat grain override must be returned verbatim",
        )


def test_value_one_still_means_the_tier() raises:
    """⚠ `forced_rows=1` means THE TIER, both before and after the landing — it
    is NOT a flat grain of one row.

    Before the landing, the default was the incumbent and `1` selected the
    tier; after it, the default IS the tier. Had `1` been repurposed as a flat
    grain, the sweep invocation recorded in this campaign's results would
    silently measure a pathological one-row grain when re-run, and it would not
    fail — it would return a number. That trap is closed here rather than in a
    comment."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    assert_equal(
        join_probe_morsel_rows_swept(pol, wide, forced_rows=1),
        MIN_MORSEL_ROWS_JOIN_PROBE,
        "forced_rows=1 must select the JOIN_PROBE tier, not a flat 1-row grain",
    )


def test_flat_override_beats_the_kill_switch() raises:
    """Precedence, stated: an explicit flat grain wins over the tier gate, so a
    sweep arm cannot be silently reinterpreted by a stale kill switch."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    assert_equal(
        join_probe_morsel_rows_swept(
            pol, wide, forced_rows=8192, tier_enabled=False
        ),
        8192,
        "an explicit flat grain must take precedence over the tier gate",
    )


def test_zero_and_negative_are_the_same_shipped_arm() raises:
    """A zero or negative `forced_rows` is not an arm — it falls through to the
    shipped tier."""
    var pol = _pol()
    var wide = _wide_100_i64_schema()
    for v in [0, -1, -4096]:
        assert_equal(
            join_probe_morsel_rows_swept(pol, wide, forced_rows=v),
            MIN_MORSEL_ROWS_JOIN_PROBE,
            "forced_rows=" + String(v) + " must fall through to the shipped tier",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
