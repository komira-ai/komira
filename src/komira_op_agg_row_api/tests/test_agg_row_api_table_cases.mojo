"""Cases of the hash-aggregation table's tests that exercise only this package:
the merge-class width pin, the ingest key-class selector and the staging-window
arithmetic. Each case is copied unchanged from the table's test that owns it."""


from std.testing import TestSuite, assert_equal, assert_true

from komira_column_format.column_format_storage import (
    DT_I64,
    DT_DATE64,
    DT_I32,
    DT_DATE32,
    DT_U32,
    DT_U64,
    DT_I16,
)
from komira_op_agg_row_api.agg_chunk_rows import agg_kbuf_chunk_rows
from komira_op_agg_row_api.agg_key_class import (
    ingest_key_mono_class,
    IKM_NONE,
    IKM_I64,
    IKM_I32,
    IKM_U32,
)
from komira_op_agg_row_api.combine_agg_plan import (
    merge_cell_class_bytes,
    MC_NONE,
    MC_ADD_U64,
    MC_ADD_F64,
    MC_MIN_I64,
    MC_MAX_I64,
    MC_MIN_F64,
    MC_MAX_F64,
    MC_AVG_F64,
    MC_ADD_I128,
    MC_AVG_I128,
)


comptime _ROWS: Int = 12_000
"""Rows per batch. ⛔ IT HAS TO CLEAR 4096 BY A WIDE MARGIN.
`agg_kbuf_chunk_rows` floors the derived window at 4096 rows — the software
prefetch lookahead may not cross a window, so a window near the lookahead
distance would silently disarm it — and a fixture at or under the floor gets
ONE window whatever budget is asked for, i.e. the OFF arm measured twice.
12,000 over a 4096-row window is 3 windows, so a window boundary lands in the
INTERIOR of the batch and not only at its end, and `12000 % 4096 == 3808`
leaves a genuine partial trailing window."""


comptime _WINDOW: Int = 4096
"""The window these fixtures run under — the floor, reached by asking for a
budget below it."""


def _tags(t0: UInt8, t1: UInt8) -> List[UInt8]:
    var l = List[UInt8]()
    l.append(t0)
    l.append(t1)
    return l^


# =============================================================================
# THE PLAN TABLE — pinned by value, independently of any table.
#
# `merge_cell_class` is not exported (it reads the `AGG_*` aliases and lives
# beside them), so what this case pins is the half that IS pure: the class ->
# width map. A class whose width is wrong makes the monomorphic kernel read
# across into the NEXT SLOT's state, which merges a neighbouring group's
# partial and produces a wrong number with no crash. The envelope check in
# `_combvec_envelope` is the only thing standing between that and the data, and
# it is only as good as this map.
# =============================================================================


def test_combvec_merge_class_widths_are_pinned() raises:
    assert_equal(merge_cell_class_bytes(MC_NONE), 0, "MC_NONE addresses nothing")
    assert_equal(merge_cell_class_bytes(MC_ADD_U64), 8, "MC_ADD_U64 is 1 cell")
    assert_equal(merge_cell_class_bytes(MC_ADD_F64), 8, "MC_ADD_F64 is 1 cell")
    assert_equal(merge_cell_class_bytes(MC_MIN_I64), 8, "MC_MIN_I64 is 1 cell")
    assert_equal(merge_cell_class_bytes(MC_MAX_I64), 8, "MC_MAX_I64 is 1 cell")
    assert_equal(merge_cell_class_bytes(MC_MIN_F64), 8, "MC_MIN_F64 is 1 cell")
    assert_equal(merge_cell_class_bytes(MC_MAX_F64), 8, "MC_MAX_F64 is 1 cell")
    assert_equal(
        merge_cell_class_bytes(MC_AVG_F64),
        16,
        "MC_AVG_F64 reads a SECOND cell at +8 — the width that makes the"
        " envelope refuse an 8-byte AVG spec instead of reading the next"
        " slot's state",
    )
    assert_equal(
        merge_cell_class_bytes(MC_ADD_I128),
        16,
        "MC_ADD_I128 (the exact 128-bit SUM cell) reads its HIGH"
        " word at +8 — the same width argument as MC_AVG_F64",
    )
    assert_equal(
        merge_cell_class_bytes(MC_AVG_I128),
        24,
        "MC_AVG_I128 (the exact AVG cell) reads its count at +16",
    )
    # The classes must be DISTINCT codes. A duplicate would make two ops share
    # one kernel silently, which is M1 with no mutation required.
    var seen = List[Int]()
    seen.append(MC_NONE)
    seen.append(MC_ADD_U64)
    seen.append(MC_ADD_F64)
    seen.append(MC_MIN_I64)
    seen.append(MC_MAX_I64)
    seen.append(MC_MIN_F64)
    seen.append(MC_MAX_F64)
    seen.append(MC_AVG_F64)
    seen.append(MC_ADD_I128)
    seen.append(MC_AVG_I128)
    for i in range(len(seen)):
        for j in range(i + 1, len(seen)):
            assert_true(
                seen[i] != seen[j],
                "merge-cell class codes must be distinct: index "
                + String(i)
                + " collides with "
                + String(j),
            )


# =============================================================================
# 1. THE SELECTOR — including the three declines that are DECISIONS.
# =============================================================================


def test_keymono_selector_maps_each_uniform_class() raises:
    assert_equal(ingest_key_mono_class(_tags(DT_I64, DT_I64)), IKM_I64)
    assert_equal(ingest_key_mono_class(_tags(DT_I64, DT_DATE64)), IKM_I64)
    assert_equal(ingest_key_mono_class(_tags(DT_I32, DT_I32)), IKM_I32)
    assert_equal(ingest_key_mono_class(_tags(DT_I32, DT_DATE32)), IKM_I32)
    assert_equal(ingest_key_mono_class(_tags(DT_U32, DT_U32)), IKM_U32)


def test_keymono_selector_declines_a_mixed_key() raises:
    """⛔ UNIFORM-OR-NOTHING, and not because mixed keys are rare.

    Mojo cannot spell a comptime LIST of per-key classes, so an N-key
    specialisation would be an N-deep comptime cascade re-entered per key — the
    very thing this lever removes. `probe_mono_class` declines a MIXED-CLASS
    combine for the identical reason. The decline is a routing fact: the caller
    runs the incumbent arm and the answer is unchanged (§3).

    ⚠ THAT SENTENCE READ *"declines a MULTI-KEY combine"* UNTIL KEYCOUNT
    (2026-09-18) AND WOULD NOW BE FALSE. The combine side kept the CLASS and the
    PROBEVEC-VT validity bit comptime and made the COUNT a runtime loop bound, so
    it admits `nk` keys that agree on BOTH axes and declines only a mixture. The
    reason cited here is the one that SURVIVED -- Mojo cannot spell a comptime
    LIST of per-key classes -- and it is why the INGEST side's own `IKM_NONE` on
    a mixed key set is permanent too. Whether the ingest side can take the same
    count-as-loop-bound lift is a separate question this file does not answer."""
    assert_equal(ingest_key_mono_class(_tags(DT_I64, DT_I32)), IKM_NONE)
    assert_equal(ingest_key_mono_class(_tags(DT_I32, DT_U32)), IKM_NONE)
    assert_equal(ingest_key_mono_class(List[UInt8]()), IKM_NONE)


def test_keymono_selector_declines_u64_which_would_be_a_WRONG_answer() raises:
    """⛔⛔ THE ONE DECLINE THAT IS NOT ABOUT SPEED.

    `_read_slot_key_i64_w` has NO DT_U64 ARM: I64/DATE64, I32/DATE32, U32, I16,
    U16, I8, and then `# DT_U8` as the fall-through — so a DT_U64 tag reaching
    it reads ONE BYTE. That is not a live defect, because `_vec_key_dtype_ok`
    keeps DT_U64 out of the vec envelope entirely (its own docstring names the
    raw-u64 hash special case as the reason). It IS the reason an `IKM_U64`
    class must not be added on the grounds that the type system can express it:
    an 8-byte U64 class would be a DIFFERENT ANSWER from the incumbent, not a
    faster one. That is the MINMAXFOLD rule — a specialisation set is bounded by
    what the generic path can already READ."""
    assert_equal(ingest_key_mono_class(_tags(DT_U64, DT_U64)), IKM_NONE)


def test_keymono_selector_declines_narrow_ints() raises:
    """Narrow keys are INSIDE `_vec_key_dtype_ok` and are declined anyway: no
    census cell uses one, and every class costs an instantiation of every
    dispatching row loop. A later slice adds `IKM_I16` with the
    SIGNED-NARROW arithmetic reconstruction copied verbatim; until then this
    assertion pins that the cascade still owns them."""
    assert_equal(ingest_key_mono_class(_tags(DT_I16, DT_I16)), IKM_NONE)


# -----------------------------------------------------------------------------
# 5 — the window arithmetic, as a pure function
# -----------------------------------------------------------------------------


def test_chunk_rows_returns_n_rows_verbatim_when_off() raises:
    assert_equal(
        agg_kbuf_chunk_rows(0, 6, 122_880),
        122_880,
        (
            "the KILL SWITCH (`kib == 0`) must return the batch row count"
            " VERBATIM — the driver's off arm is 'the window loop runs exactly"
            " once', and that identity is what makes an A/B price the lever."
            " Since 2026-09-09 this arm is reached only by an explicit"
            " `AGG_KBUF_CHUNK=0`, never by an unset environment"
        ),
    )
    assert_equal(
        agg_kbuf_chunk_rows(64, 1, 0), 0, "an empty batch stays empty"
    )
    assert_equal(
        agg_kbuf_chunk_rows(64, 0, 512),
        512,
        "a key-less table has nothing to stage and must not be windowed",
    )


def test_chunk_rows_returns_n_rows_when_the_batch_already_fits() raises:
    # 1 key, 512 rows -> 8 KiB of staging; a 1 MiB budget covers it whole.
    assert_equal(
        agg_kbuf_chunk_rows(1024, 1, 512),
        512,
        "a batch inside the budget must run as ONE window, not as a loop",
    )


def test_chunk_rows_divides_by_the_per_row_staging_bytes() raises:
    # (nk + 1) * 8 bytes per row: 6 keys -> 56 B/row. 256 KiB / 56 = 4681.
    assert_equal(
        agg_kbuf_chunk_rows(256, 6, 1_000_000),
        (256 * 1024) // 56,
        (
            "the budget is BYTES, so a 6-key table must get fewer rows per"
            " window than a 1-key one — a row-count budget would stage six"
            " times the bytes here"
        ),
    )
    assert_true(
        agg_kbuf_chunk_rows(256, 1, 1_000_000)
        > agg_kbuf_chunk_rows(256, 6, 1_000_000),
        "more key columns must mean fewer rows per window",
    )


def test_chunk_rows_floors_at_the_prefetch_safe_window() raises:
    assert_equal(
        agg_kbuf_chunk_rows(1, 1, 1_000_000),
        4096,
        (
            "a tiny budget must FLOOR, not produce a window near the software"
            " prefetch lookahead — the lookahead may not cross a window, so a"
            " small window silently disarms the prefetch this route depends on"
        ),
    )
    assert_equal(
        agg_kbuf_chunk_rows(1, 1, _ROWS),
        _WINDOW,
        "the fixture below runs under the floor window",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_combvec_merge_class_widths_are_pinned]()
    suite.test[test_keymono_selector_maps_each_uniform_class]()
    suite.test[test_keymono_selector_declines_a_mixed_key]()
    suite.test[test_keymono_selector_declines_u64_which_would_be_a_WRONG_answer]()
    suite.test[test_keymono_selector_declines_narrow_ints]()
    suite.test[test_chunk_rows_returns_n_rows_verbatim_when_off]()
    suite.test[test_chunk_rows_returns_n_rows_when_the_batch_already_fits]()
    suite.test[test_chunk_rows_divides_by_the_per_row_staging_bytes]()
    suite.test[test_chunk_rows_floors_at_the_prefetch_safe_window]()
    suite^.run()
