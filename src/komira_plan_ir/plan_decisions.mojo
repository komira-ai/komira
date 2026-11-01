# =============================================================================
# plan_decisions — the optimizer's recorded decisions, as plan node fields
# =============================================================================
#
# A decision the lowering must obey is a typed field on the node it governs
# (docs/design/optimized_plan.md §5.1): a join's build side and whether the
# host may switch its distribution at run time, an aggregate's mode, a scan's
# boundedness, and an exchange's kind. This file holds their value spaces and
# the writers that name them. It imports nothing, so `logical_plan.mojo`,
# `logical_plan_variants.mojo` and `plan_display.mojo` can all read it without
# widening any import cycle; `logical_plan.mojo` re-exports every name.
#
# THE UNSET VALUES. `JOIN_BUILD_SIDE_UNSET` and `AGG_MODE_UNSET` are what a
# node carries until an optimizer records a decision. They are not a third
# decision: an unoptimized (RAW) plan states no build side and no mode, and an
# optimized one states both. Without the sentinel, "the optimizer kept the
# build on the right" and "nothing decided" would be one byte, and an encoder
# could not refuse the first in a RAW plan or require it in an OPTIMIZED one.
# 255 follows `SOURCE_KIND_UNSET`. What an UNSET node means at execution is
# the convention every plan had before these fields: probe = left,
# build = right, and a single-phase aggregate.
#
# Scan boundedness has no unset value: a RAW plan reads an unstated
# boundedness as BOUNDED (§5.2), which is what every plan meant before the
# field existed, so BOUNDED is the default.
#
# The values are engine values. A wire encoding adds 1, as every
# `plan_vocabulary.proto` space does, so that an absent proto3 enum field
# (wire 0) is never read as a real value.
# =============================================================================


# -----------------------------------------------------------------------------
# Join build side (`JoinData.build_side`)
# -----------------------------------------------------------------------------
#
# The side the host builds its hash table on. Child order still fixes the
# output schema (left columns, then right columns with the `_right` collision
# rename); `build_side` chooses only which input is materialized.

comptime JOIN_BUILD_SIDE_LEFT: UInt8 = 0
comptime JOIN_BUILD_SIDE_RIGHT: UInt8 = 1
comptime JOIN_BUILD_SIDE_UNSET: UInt8 = 255


# -----------------------------------------------------------------------------
# Aggregate mode (`AggregateData.mode`)
# -----------------------------------------------------------------------------
#
# SINGLE aggregates its whole input to final values. PARTIAL emits per-group
# partial states; FINAL merges partial states into final values. The producer
# records the mode only; the host derives the partial-state layout from the
# aggregate expressions.

comptime AGG_MODE_SINGLE: UInt8 = 0
comptime AGG_MODE_PARTIAL: UInt8 = 1
comptime AGG_MODE_FINAL: UInt8 = 2
comptime AGG_MODE_UNSET: UInt8 = 255


# -----------------------------------------------------------------------------
# Scan boundedness (`ScanData.boundedness`)
# -----------------------------------------------------------------------------
#
# UNBOUNDED marks a source with no end (a message stream, a table read as it
# grows). A plan with at least one UNBOUNDED scan is a streaming plan.

comptime SCAN_BOUNDED: UInt8 = 0
comptime SCAN_UNBOUNDED: UInt8 = 1


# -----------------------------------------------------------------------------
# Exchange kind (`ExchangeData.kind`)
# -----------------------------------------------------------------------------
#
# GATHER sends every partition to one consumer; BROADCAST sends every row to
# every consumer; HASH partitions by `keys`; RANGE partitions by `ordering`.

comptime EXCHANGE_KIND_GATHER: UInt8 = 0
comptime EXCHANGE_KIND_BROADCAST: UInt8 = 1
comptime EXCHANGE_KIND_HASH: UInt8 = 2
comptime EXCHANGE_KIND_RANGE: UInt8 = 3

# The design names a `key_encoding` field and no values for it. Until it
# does, the only value is "not stated", and a HASH or RANGE exchange carries
# it. It is a field now so that the node's shape, its copy and its render do
# not change when the values arrive.
comptime EXCHANGE_KEY_ENCODING_UNSET: UInt8 = 255


# -----------------------------------------------------------------------------
# Writers. ⚠ THESE WRITE; THEY DO NOT RETURN — see the banner over the
# vocabulary helpers in `plan_display.mojo` for why a literal-returning ladder
# is not used anywhere in a render.
# -----------------------------------------------------------------------------


def write_join_build_side[W: Writer](mut writer: W, side: UInt8):
    """Write `left`, `right`, `unset`, or `build_side#<n>` for a value no
    constant names."""
    if side == JOIN_BUILD_SIDE_LEFT:
        writer.write("left")
        return
    if side == JOIN_BUILD_SIDE_RIGHT:
        writer.write("right")
        return
    if side == JOIN_BUILD_SIDE_UNSET:
        writer.write("unset")
        return
    writer.write("build_side#", Int(side))


def write_agg_mode[W: Writer](mut writer: W, mode: UInt8):
    """Write `single`, `partial`, `final`, `unset`, or `agg_mode#<n>`."""
    if mode == AGG_MODE_SINGLE:
        writer.write("single")
        return
    if mode == AGG_MODE_PARTIAL:
        writer.write("partial")
        return
    if mode == AGG_MODE_FINAL:
        writer.write("final")
        return
    if mode == AGG_MODE_UNSET:
        writer.write("unset")
        return
    writer.write("agg_mode#", Int(mode))


def write_scan_boundedness[W: Writer](mut writer: W, b: UInt8):
    """Write `bounded`, `unbounded`, or `boundedness#<n>`."""
    if b == SCAN_BOUNDED:
        writer.write("bounded")
        return
    if b == SCAN_UNBOUNDED:
        writer.write("unbounded")
        return
    writer.write("boundedness#", Int(b))


def write_exchange_kind[W: Writer](mut writer: W, kind: UInt8):
    """Write `GATHER`, `BROADCAST`, `HASH`, `RANGE`, or `exchange_kind#<n>`."""
    if kind == EXCHANGE_KIND_GATHER:
        writer.write("GATHER")
        return
    if kind == EXCHANGE_KIND_BROADCAST:
        writer.write("BROADCAST")
        return
    if kind == EXCHANGE_KIND_HASH:
        writer.write("HASH")
        return
    if kind == EXCHANGE_KIND_RANGE:
        writer.write("RANGE")
        return
    writer.write("exchange_kind#", Int(kind))


def join_build_side_is_valid(side: UInt8) -> Bool:
    """A value a `JoinData.build_side` may hold: LEFT, RIGHT or UNSET."""
    return (
        side == JOIN_BUILD_SIDE_LEFT
        or side == JOIN_BUILD_SIDE_RIGHT
        or side == JOIN_BUILD_SIDE_UNSET
    )


def agg_mode_is_valid(mode: UInt8) -> Bool:
    """A value an `AggregateData.mode` may hold: SINGLE, PARTIAL, FINAL or
    UNSET."""
    return (
        mode == AGG_MODE_SINGLE
        or mode == AGG_MODE_PARTIAL
        or mode == AGG_MODE_FINAL
        or mode == AGG_MODE_UNSET
    )


def scan_boundedness_is_valid(b: UInt8) -> Bool:
    """A value a `ScanData.boundedness` may hold: BOUNDED or UNBOUNDED."""
    return b == SCAN_BOUNDED or b == SCAN_UNBOUNDED


def exchange_kind_is_valid(kind: UInt8) -> Bool:
    """A value an `ExchangeData.kind` may hold."""
    return kind <= EXCHANGE_KIND_RANGE
