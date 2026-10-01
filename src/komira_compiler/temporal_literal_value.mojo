# =============================================================================
# temporal_literal_value.mojo — shared temporal-literal -> comparable-i64 helper
# =============================================================================
#
# TEMPORAL LOGICAL-vs-PHYSICAL convergence point. A
# temporal `ScalarValue` carries its value in a DEDICATED field, NOT `int_val`:
#   * `ScalarValue.date32(D)`          -> `date32_val` (Int32); `int_val == 0`.
#   * `ScalarValue.timestamp_micros(u)`-> `ts_micros`  (Int64); `int_val == 0`.
#   * `ScalarValue.time_of_day(v,unit)`/ `duration(v,unit)` -> `int_val` (+unit).
# A reader that blindly takes `int_val` on a date32 / timestamp literal reads
# ZERO -> a Q16-class SILENT-WRONG (all-false comparison / empty IN-list match).
#
# This module is the ONE place the "temporal literal -> comparable Int64" mapping
# table lives, so the DATE32 predicate fix (`_eval_predicate`), the IN-list
# evaluator (`_eval_in_list`), and any future value-field reader share it instead
# of each re-deriving (and re-getting-wrong) the field routing. It is its own
# module so `compiler_eval_in_list` — which `compiler_eval_predicate` imports —
# can reuse it without a cycle.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.scalar_value import ScalarValue


def _ticks_per_day(col_at: ArrowType) -> Int64:
    """One day in a TIMESTAMP_<unit> (legacy TIMESTAMP is microseconds) or a
    DATE64 (milliseconds) column's own ticks."""
    comptime _S_PER_DAY: Int64 = 86_400
    if col_at == ArrowType.TIMESTAMP_S:
        return _S_PER_DAY
    if col_at == ArrowType.TIMESTAMP_MS or col_at == ArrowType.DATE64:
        return _S_PER_DAY * 1_000
    if col_at == ArrowType.TIMESTAMP_NS:
        return _S_PER_DAY * 1_000_000_000
    return _S_PER_DAY * 1_000_000


def _temporal_literal_i64(lit: ScalarValue, col_at: ArrowType) raises -> Int64:
    """The comparable integer threshold for a TEMPORAL or int literal, read from
    the literal's correct storage field.

    Raises on a literal that is neither temporal nor int (e.g. a string / bool /
    decimal literal reaching a temporal-or-int comparison) — a loud, visible
    failure rather than a silent int_val==0 miss. Callers that must also accept
    the narrow / unsigned integer widths (which are NOT `is_int`) should use
    `_comparable_literal_i64` instead."""
    if lit.is_date32():
        # days since epoch (int32) — the value lives in `date32_val`, not int_val.
        var days = Int64(Int(lit.date32_val))
        # ⛔ A DATE LITERAL AGAINST A TIMESTAMP / DATE64 COLUMN. The
        # threshold is compared against the
        # column's RAW TICKS, so returning the DAY COUNT here compared days with
        # microseconds: `n > DATE '2024-02-29'` over a timestamp[us] column kept
        # every row after 1970-01-01T00:00:00.019790 -- 7 rows where DuckDB
        # 1.5.3 keeps 6, silently. DuckDB compares a DATE against a TIMESTAMP
        # by casting the DATE to that day's MIDNIGHT, which is a multiplication
        # into the column's unit: EXACT, so every operator carries over.
        if col_at.is_timestamp() or col_at == ArrowType.DATE64:
            var per_day = _ticks_per_day(col_at)
            if days > Int64.MAX // per_day or days < Int64.MIN // per_day:
                raise Error(
                    "temporal literal: DATE literal (day "
                    + String(days)
                    + ") is outside the range of a "
                    + String(col_at)
                    + " column"
                )
            return days * per_day
        return days
    elif lit.is_timestamp() and col_at == ArrowType.DATE32:
        # ⛔ A TIMESTAMP LITERAL AGAINST A DATE COLUMN. Without this arm the
        # pair falls to the `else` below and returns the
        # literal's MICROSECONDS as a threshold over DAYS, so
        # `d > TIMESTAMP '2024-12-30 06:07:08'` kept 0 rows where DuckDB keeps
        # 4. DuckDB casts the DATE column to MIDNIGHT, so a literal that IS a
        # midnight is an exact day count and every operator carries over.
        # ⛔ OFF MIDNIGHT IT STILL REFUSES: the threshold is then operator-
        # dependent (`d > <02-29 06:00>` is `d >= 03-01`, and `d = <06:00>` is
        # false for every row), and this function returns a value with no
        # operator -- the same residual as the sub-tick arm below.
        comptime _US_PER_DAY: Int64 = 86_400_000_000
        if lit.ts_micros % _US_PER_DAY == 0:
            return lit.ts_micros // _US_PER_DAY
        raise Error(
            "temporal literal: a TIMESTAMP literal vs a DATE column is served"
            " only where the literal is a MIDNIGHT (this one is not: "
            + String(Int(lit.ts_micros % _US_PER_DAY))
            + " leftover microseconds). DuckDB compares the DATE at midnight,"
            " and an off-midnight threshold needs the COMPARISON OPERATOR"
            " adjusted as well as the value -- `d > <day 06:00>` is"
            " `d >= <the next day>` -- which this threshold cannot carry."
            " Compare against a DATE literal instead (`d > <day> 06:00` is"
            " `d > DATE '<day>'`); CAST(d AS TIMESTAMP) is not a remedy, the"
            " SQL door refuses CAST to TIMESTAMP."
        )
    elif lit.is_timestamp():
        # Canonical micros. Compare only where the unit is exact vs the column:
        #   TIMESTAMP_US / legacy TIMESTAMP / an int64-physical column -> raw us.
        #   TIMESTAMP_NS -> us * 1000 (exact widen).
        #   TIMESTAMP_S / TIMESTAMP_MS -> lossy narrow; RAISE (follow-up).
        if col_at == ArrowType.TIMESTAMP_NS:
            return lit.ts_micros * 1000
        elif (
            col_at == ArrowType.TIMESTAMP_MS
            or col_at == ArrowType.TIMESTAMP_S
            or col_at == ArrowType.DATE64
        ):
            # ⭐ DATE64
            # rides the MILLISECOND arm: it used to fall to the `else` and
            # compare the literal's MICROSECONDS with its milliseconds.
            # ★ A NARROWING UNIT, SERVED **ONLY WHERE IT IS EXACT**.
            #
            # The threshold this function returns is compared against the
            # column's RAW PHYSICAL integers, so a micros literal has to be
            # expressed in the column's own unit. Where the literal lands
            # exactly on one of the column's ticks that is a division and
            # nothing else: `TIMESTAMP '03:30:15.123000'` is
            # 1767238215123000 us = 1767238215123 ms, and every comparison
            # operator carries over unchanged.
            #
            # ⛔ AND WHERE IT DOES **NOT** LAND EXACTLY, THIS STILL REFUSES —
            # which is the half that matters. A literal strictly between two
            # ticks needs the OPERATOR adjusted as well as the value
            # (`col > 1.5ms` is `col >= 2ms`, and `col = 1.5ms` is FALSE for
            # every row), and this function's signature returns a value and no
            # operator. Rounding the value and keeping the operator would move
            # the boundary by up to one tick: a row set wrong at the edge, with
            # no error anywhere. ⇒ Closing the residual means changing this
            # SIGNATURE, not this arithmetic.
            var per_tick = (
                Int64(1000000) if col_at == ArrowType.TIMESTAMP_S else Int64(1000)
            )
            # ⚠ `%` ON A NEGATIVE MICROS VALUE. Mojo's `%` follows its FLOORING
            # `//`, so `-1500 % 1000 == 500` (not -500) and the zero test is
            # still exactly "lands on a tick" for pre-epoch instants. The
            # accompanying `//` therefore also floors, which is the correct
            # pairing: -2000 us is -2 ms, and -2000 // 1000 == -2.
            if lit.ts_micros % per_tick == 0:
                return lit.ts_micros // per_tick
            raise Error(
                "temporal literal: a MICROSECOND timestamp literal vs a "
                + String(col_at)
                + " column is served only where the literal lands exactly on"
                " one of the column's ticks (this one does not: "
                + String(Int(lit.ts_micros % per_tick))
                + " leftover microseconds). An inexact one needs the COMPARISON"
                " OPERATOR adjusted as well as the value — `col > <half a tick>`"
                " is `col >= <the next tick>`, and `col = <half a tick>` is"
                " false for every row — and this threshold carries a value"
                " only. Round the literal to the column's unit, or compare"
                " against a TIMESTAMP_US column."
            )
        else:
            return lit.ts_micros
    elif lit.is_int() or lit.is_time() or lit.is_duration():
        # Time-of-day / duration / plain-int literals carry the value in int_val.
        return lit.int_val
    else:
        raise Error(
            "temporal literal: unsupported literal type for a temporal/int"
            " column (expected date32 / timestamp / time / duration / int)"
        )


def _comparable_literal_i64(lit: ScalarValue, col_at: ArrowType) raises -> Int64:
    """Broad temporal-aware `ScalarValue -> Int64` value read for a NUMERIC
    comparison / membership context.

    Same temporal field routing as `_temporal_literal_i64`, but the non-temporal
    fallback is `int_val` for EVERY integer width (int8/16/32/64 + uint8/16/32/64).
    ⚠ THAT IS NOT A CORRECT READ OF EVERY INTEGER: a uint64-tagged literal at or
    above 2**63 carries its TWO'S-COMPLEMENT bit pattern in `int_val`, so it
    reads NEGATIVE here (`2**64-1` -> -1). An INTEGER literal must be read by
    its TAG first (`integer_literal_value.integer_literal_value`), which is what
    both `_eval_in_list` value-table builds (int32 / int64) do before they fall
    back to this function for a non-integer (date32 / timestamp / time /
    duration) member."""
    if lit.is_date32() or lit.is_timestamp() or lit.is_time() or lit.is_duration():
        return _temporal_literal_i64(lit, col_at)
    return lit.int_val
