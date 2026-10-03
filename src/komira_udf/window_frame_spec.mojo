# =============================================================================
# window_frame_spec.mojo — the comptime ROWS-frame spec for custom WindowFn
# =============================================================================
#
# A `WindowFn` declares a `comptime frame: WindowFrameSpec` describing the
# `ROWS BETWEEN <start> AND <end>` window the engine slides over each sorted
# partition. The spec is COMPTIME — part of the UDF's identity — and the window
# operator comptime-asserts `frame.units == FRAME_UNITS_ROWS` at build time
# (ROWS-only fence; RANGE/GROUPS conformers fail at compile time with a
# clear diagnostic).
#
# # Why a NEW comptime spec instead of reusing `PartitionFrame`
#
# The built-in window track carries `PartitionFrame`
# (`komira_core.plan.partition_expr`), but that struct uses `def __init__`
# + `Int64` offset fields and is plumbed as a RUNTIME plan-IR payload. A
# `WindowFn` needs its frame as a COMPTIME trait member (the engine reads
# `F.frame.start_tag` / `.start_offset` at comptime to pick the bound decode +
# the ROWS-only fence). This spec is the comptime-friendly mirror: it REUSES the
# existing `FRAME_UNITS_*` / `FRAME_BOUND_*` tag VALUES verbatim (imported from
# `partition_expr`, so the two stay in lockstep — the frame-bound decoders in
# the custom window kernel are the direct analog of `partition_sliding_frame`'s
# `_decode_start_off` / `_decode_end_off`), with a plain `@fieldwise_init`
# comptime-constructible shape (`Int` offsets, `fn` ctor) so it can ride as a
# `comptime` member.
#
# # Encapsulation invariants
#   - Pure POD value type (UInt8 tags + Int offsets). NO UnsafePointer, NO
#     wildcard origin, NO heap. Comptime-constructible.
# =============================================================================

from komira_core.plan.partition_expr import (
    FRAME_UNITS_ROWS,
    FRAME_UNITS_RANGE,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
)


@fieldwise_init
struct WindowFrameSpec(ImplicitlyCopyable, Copyable, Movable):
    """A comptime ROWS-frame spec for a custom `WindowFn`.

    Mirrors `PartitionFrame` (`partition_expr.mojo`) but is comptime-friendly
    (plain `fn` ctor + `Int` offsets) so it rides as a `comptime` trait member.
    The tag values are the SAME `FRAME_UNITS_*` / `FRAME_BOUND_*` constants the
    built-in window track uses — the custom window frame-bound decoder is the direct analog
    of `partition_sliding_frame`'s `_decode_start_off` / `_decode_end_off`.

    Fields:
        units : `FRAME_UNITS_ROWS` (the only core value; RANGE is
                      fenced out at operator build time).
        start_tag   : one of `FRAME_BOUND_*` for the frame START bound.
        start_offset: the PRECEDING / FOLLOWING row offset for `start_tag`
                      (ignored for UNBOUNDED / CURRENT_ROW).
        end_tag     : one of `FRAME_BOUND_*` for the frame END bound.
        end_offset  : the PRECEDING / FOLLOWING row offset for `end_tag`.
    """

    var units: UInt8
    var start_tag: UInt8
    var start_offset: Int
    var end_tag: UInt8
    var end_offset: Int

    @staticmethod
    def rows(
        start_tag: UInt8, start_offset: Int, end_tag: UInt8, end_offset: Int
    ) -> Self:
        """A ROWS frame from explicit start/end bound tags + offsets."""
        return Self(
            FRAME_UNITS_ROWS, start_tag, start_offset, end_tag, end_offset
        )

    @staticmethod
    def rows_between_preceding_and_current(n: Int) -> Self:
        """`ROWS BETWEEN n PRECEDING AND CURRENT ROW` — the trailing window
        (e.g. a trailing moving-average / trailing-sum)."""
        return Self(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_PRECEDING,
            n,
            FRAME_BOUND_CURRENT_ROW,
            0,
        )

    @staticmethod
    def rows_running() -> Self:
        """`ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (running)."""
        return Self(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_UNBOUNDED_PRECEDING,
            0,
            FRAME_BOUND_CURRENT_ROW,
            0,
        )

    @staticmethod
    def rows_full_partition() -> Self:
        """`ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`."""
        return Self(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_UNBOUNDED_PRECEDING,
            0,
            FRAME_BOUND_UNBOUNDED_FOLLOWING,
            0,
        )

    # -------------------------------------------------------------------------
    # RANGE constructors.
    #
    # A RANGE frame slides the per-row bounds by ORDER-KEY VALUE arithmetic, not
    # row position: the frame is `{rows whose order-key value is in
    # [k - preceding, k + following]}` for the current row's order key `k`, with
    # SQL PEER semantics (rows with equal order-key share one frame). The tag
    # values + offsets are reused verbatim from the ROWS spec — only `units`
    # flips to `FRAME_UNITS_RANGE`, and the offsets are reinterpreted as VALUE
    # offsets in the order key's dtype units.
    # -------------------------------------------------------------------------

    @staticmethod
    def range(
        start_tag: UInt8, start_offset: Int, end_tag: UInt8, end_offset: Int
    ) -> Self:
        """A RANGE frame from explicit start/end bound tags + VALUE offsets
        (interpreted in the order key's dtype units)."""
        return Self(
            FRAME_UNITS_RANGE, start_tag, start_offset, end_tag, end_offset
        )

    @staticmethod
    def range_between_preceding_and_current(n: Int) -> Self:
        """`RANGE BETWEEN n PRECEDING AND CURRENT ROW` — the trailing VALUE
        window (rows whose order key is in `[k - n, k]`, all peers of `k`
        included). Differs from the ROWS analog whenever the order key has
        value-gaps or peer groups."""
        return Self(
            FRAME_UNITS_RANGE,
            FRAME_BOUND_PRECEDING,
            n,
            FRAME_BOUND_CURRENT_ROW,
            0,
        )

    @staticmethod
    def range_running() -> Self:
        """`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — the running
        aggregate with SQL peer semantics (rows whose order key is `<= k`, i.e.
        up to and INCLUDING the current row's whole peer group)."""
        return Self(
            FRAME_UNITS_RANGE,
            FRAME_BOUND_UNBOUNDED_PRECEDING,
            0,
            FRAME_BOUND_CURRENT_ROW,
            0,
        )

    @staticmethod
    def range_full_partition() -> Self:
        """`RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` — the
        whole partition (value-independent; identical to the ROWS form)."""
        return Self(
            FRAME_UNITS_RANGE,
            FRAME_BOUND_UNBOUNDED_PRECEDING,
            0,
            FRAME_BOUND_UNBOUNDED_FOLLOWING,
            0,
        )
