# =============================================================================
# multi_column_builder.mojo — the variadic multi-output column builder
# =============================================================================
#
# `MultiColumnBuilder` is the variadic-parametric output-accumulation
# primitive the unified Stage substrate writes into: "one `ColumnBuilder[DT]`
# per output slot, exposed via `append_at[k: Int, DT: DType]`". The
# variadic-parametric `RowTransform` (in the eval layer)
# calls `write_one[bo, MCB]` with
# `MCB = MultiColumnBuilder`; the Stage's per-row loop fans out over the
# output pack and lands one value per slot via `append_at`.
#
# -----------------------------------------------------------------------------
# WHY A TYPE PACK, NOT A VALUE PACK (Mojo 1.0.0b1 capability)
# -----------------------------------------------------------------------------
# One might expect `MultiColumnBuilder` to be parametric on a
# comptime VALUE pack of DTypes — `MultiColumnBuilder[DType.int64,
# DType.float64, ...]`. That is NOT expressible in Mojo 1.0.0b1: there is no
# comptime map from a value pack `[*DTs: DType]` to a dependent Tuple element
# list `Tuple[ColumnBuilder[DTs[0]], ColumnBuilder[DTs[1]], ...]`. The
# `Tuple[*Self.Ts]` storage shape works ONLY
# over a TYPE pack.
#
# Resolution: `MultiColumnBuilder` is parametric on a TYPE pack of
# `ColumnSink` conformers — `MultiColumnBuilder[ColumnSlot[DType.int64],
# ColumnSlot[DType.float64], ...]`. The `ColumnSlot[dt]` factory
# (`column_slot[dt]()`) and the `MultiColumnBuilder.make_*` factories below
# give callers the same ergonomics. The `append_at[k, DT]` API surface is
# preserved exactly — `DT` is a comptime caller-asserted dtype tag,
# `constrained` to equal slot `k`'s column dtype.
#
# Per-DType type families are the production shape in Mojo 1.0; a single
# value-parametric surface over DType is not witness-resolvable. The per-slot
# `ColumnSlot[dt]` type family is the same idiom the `ExprXI64` / `ExprXF64`
# split uses.
#
# -----------------------------------------------------------------------------
# THE CANONICAL VARIADIC SHAPE
# -----------------------------------------------------------------------------
# `MultiColumnBuilder` is the first in-tree consumer of the canonical
# `Tuple[*Self.Ts]` variadic-storage primitive (see `variadic_pack.mojo`):
#   - field `var _slots: Tuple[*Self.Bs]`,
#   - ctor `Tuple(*slots^)`,
#   - per-slot fan-out by `@parameter for k in range(arity())`.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any signature.
#   - NO wildcard origins.
#   - NO byte-erased fn-ptr dispatch — `@parameter for` is comptime-unrolled
#     direct dispatch.
#   - NO additive parallel API.
#   - NO partial-move-via-`take_pointee` — `ColumnSlot.finalize_column`
#     extracts its inner builder via `Optional.take()`, the canonical
#     partial-move-free shape.
#
# Cross-references:
#   - variadic_pack.mojo — the canonical `Tuple[*Self.Ts]` primitive.
#   - column_builder.mojo — `ColumnBuilder[dt]`, the per-slot backing builder.
#   - `RowTransform.write_one[bo, MCB]` (eval layer) — the trait method that
#     writes into a `MultiColumnBuilder`.
# =============================================================================

from std.collections import Optional

from komira_arrow.column import Column
from komira_arrow.offset_overflow import (
    ARROW_INT32_OFFSET_MAX,
    wrap_to_int32,
)
from komira_arrow.string_builder import ArrowStringBuilder
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column_builder import ColumnBuilder
from komira_collections.slab import Slab


# =============================================================================
# §0 — SinkKind — WHICH value channel a slot accepts
# =============================================================================
#
# `ColumnSlot[dt]` lands a value through exactly one method,
# `append_value(v: Scalar[Self.DT])`. No `DType` holds a String, so a
# String-producing transform needs a second value channel.
#
# WHY A KIND TAG AND NOT A SECOND TRAIT. `MultiColumnBuilder[*Bs]`'s pack is
# bounded on ONE trait; a sibling `StringColumnSink` trait could not appear
# in the same pack as a numeric slot, so a two-output project of
# `(Int64, String)` would be inexpressible — which is the common case, not an
# edge case. One trait with a comptime KIND discriminator keeps the pack
# homogeneous while making the value channel a compile-time fact.
#
# ⚠ A SECOND VALUE CHANNEL IS A TRAIT-SHAPE CHANGE, NOT JUST A NEW
# CONFORMER. A value channel is a trait method by construction, so a String
# conformer cannot be added without touching the trait.
#
# WHAT THIS DOES **NOT** CONSTRAIN — an untyped-UDF ABI. Putting a
# function behind a runtime pointer is cheap, while making the boundary
# MATERIALIZE AN INTERMEDIATE is expensive, so the thing to avoid is a
# sink shape that forces a copy-through-scratch. This design does not:
#
#   * It adds NO fn-ptr and NO erasure, so
#     `untyped_multi_column_sink.mojo`'s "NO byte-erased fn-ptr dispatch"
#     invariant is untouched.
#   * It adds NO intermediate. A `StringColumnSlot` append writes straight
#     into `ArrowStringBuilder`'s `(offsets, data)`; the value crosses once.
#   * The STRING channel is STRICTLY LESS comptime-dependent than the
#     numeric one it mirrors: `append_at[k, DT](Scalar[DT])` parameterises
#     on the VALUE TYPE, `append_string_at[k](String)` does not. So the
#     name-resolving twin an untyped path would want
#     (`append_string_at_name(name, value)`) needs no comptime DType at
#     all, where `append_at_name[DT]` does.
#
# A BULK CHANNEL IS AN ADDITION, NOT A REDESIGN: the STRING channel is
# per-VALUE and `raises` (the offset-ceiling guard, §2a). A batch-at-a-time
# handoff would want a BULK push instead — and the primitive underneath
# already has exactly that shape (`ArrowStringBuilder.push_contiguous_block`,
# one memcpy + a prefix-sum for a whole run). So a bulk channel can be
# added to this trait later without redesigning it.
#
# WHY `KIND` IS CHECKED BEFORE `DT`. A STRING slot has no value-channel
# DType and Mojo 1.0.0 removed `DType.invalid`, so its `DT` is a documented
# placeholder. `MultiColumnBuilder.append_at` therefore asserts KIND FIRST:
# the placeholder is unreachable by construction, and a numeric append aimed
# at a string slot fails with a message naming `append_string_at` rather than
# with a DType mismatch against a value nobody chose.
# =============================================================================


struct SinkKind(ImplicitlyCopyable, Movable, Copyable, Deinitable):
    """Which value channel a `ColumnSink` slot accepts.

    Canonical enum shape for this tree (`var _tag: UInt8` + named `comptime`
    constants) — the same shape as `Purity` / `NullHandling`. No heap
    fields, so it is legal as a `comptime` trait member.

        NUMERIC : `append_value(Scalar[DT])`. `ColumnSlot[dt]`.
        STRING  : `append_string_value(String)`. `StringColumnSlot`.
    """

    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    def __init__(out self, tag: Int):
        self._tag = UInt8(tag)

    comptime NUMERIC = SinkKind(0)
    comptime STRING = SinkKind(1)

    def __eq__(self, other: SinkKind) -> Bool:
        return self._tag == other._tag

    def __ne__(self, other: SinkKind) -> Bool:
        return self._tag != other._tag

    def tag(self) -> UInt8:
        """The raw discriminator."""
        return self._tag


# =============================================================================
# §1 — ColumnSink — the per-slot element trait
# =============================================================================


trait ColumnSink(Movable, Deinitable):
    """A typed, append-only column sink — the per-slot element type of a
    `MultiColumnBuilder` pack.

    A `MultiColumnBuilder` stores a `Tuple` of `ColumnSink` conformers, one
    per output column. Conformers expose their column DType via the comptime
    `DT` member so the `MultiColumnBuilder.append_at[k, DT]` API can
    `constrained`-assert the caller's DType against the slot's DType.

    The two in-tree conformers are `ColumnSlot[dt]` (numeric, a thin wrapper
    over `ColumnBuilder[dt]`) and `StringColumnSlot` (a thin wrapper over
    `ArrowStringBuilder`). Both wrap their inner builder in an `Optional` so
    `finalize_column` can be a `mut self` one-shot consume (extracting via
    `Optional.take()`) rather than a `var self` whole-struct consume — the
    `MultiColumnBuilder.finalize` fan-out borrows each tuple slot mutably,
    it does not move slots out of the `Tuple` field.

    `Deinitable` is load-bearing for `Tuple[*Self.Bs]` storage.

    THE TWO VALUE CHANNELS. `append_value` takes a `Scalar[Self.DT]` and
    `append_string_value` takes a `String`; a conformer implements exactly
    ONE and inherits a `comptime assert False` refusal for the other, so
    reaching the wrong channel is a named COMPILE error and never a wrong
    byte. `KIND` says which one is live, and every dispatcher must consult
    it before `DT` (see §0).
    """

    comptime KIND: SinkKind = SinkKind.NUMERIC
    """Which value channel this slot accepts. Defaults to NUMERIC so every
    numeric conformer keeps conforming with no edit."""

    comptime DT: DType

    def append_value(mut self, v: Scalar[Self.DT]):
        """Append one value at the current logical end. Always VALID.

        NUMERIC channel. A non-NUMERIC conformer overrides this with a
        `comptime assert False` refusal rather than leaving it callable.
        """
        ...

    def append_string_value(mut self, v: String) raises:
        """Append one String value at the current logical end. Always VALID.

        STRING channel. The default body REFUSES at compile time, so the
        numeric conformers need no edit and a numeric slot cannot be handed
        a String.

        `raises` because the STRING conformer enforces the Arrow 32-bit
        offset ceiling here — see `StringColumnSlot.append_string_value`.
        The declaration is `raises` on the TRAIT so the numeric conformers
        and the string one share one signature; a non-raising body
        satisfies a `raises` requirement, so this costs the numeric slots
        nothing.
        """
        comptime assert False, (
            "ColumnSink.append_string_value: this slot's value channel is"
            " not STRING (its `KIND` is not `SinkKind.STRING`). A numeric"
            " `ColumnSlot[dt]` stores `Scalar[dt]` and has nowhere to put"
            " a String. Use a `StringColumnSlot` for that output column."
        )

    def append_null_value(mut self):
        """Append one null slot (lazy-allocates the validity bitmap).

        Kind-agnostic: a null row is a cleared validity bit in BOTH
        channels. For the STRING channel it is additionally a zero-length
        value, which is what distinguishes it from an empty string only via
        the validity bitmap — the values are byte-identical.
        """
        ...

    def current_length(self) -> Int:
        """Current logical row count."""
        ...

    def finalize_column(mut self) raises -> Column[HeapRegion]:
        """One-shot consume: emit the accumulated `Column[HeapRegion]`. Raises if
        called twice."""
        ...


# =============================================================================
# §2 — ColumnSlot[dt] — the in-tree ColumnSink conformer
# =============================================================================


struct ColumnSlot[dt: DType](ColumnSink):
    """A `ColumnSink` over a `ColumnBuilder[dt]` — one output column slot.

    Wraps the builder in an `Optional` so `finalize_column` can extract it
    via `Optional.take()` (the canonical partial-move-free extraction)
    without consuming the whole `ColumnSlot` — the
    `MultiColumnBuilder.finalize` fan-out only mutably borrows each slot.

    Parameters:
        dt: The Arrow primitive DType this slot's column carries.
    """

    comptime DT: DType = Self.dt
    var _builder: Optional[ColumnBuilder[Self.dt]]

    def __init__(out self, var builder: ColumnBuilder[Self.dt]):
        """Wrap an existing `ColumnBuilder`. Prefer `with_capacity`."""
        self._builder = Optional[ColumnBuilder[Self.dt]](builder^)

    @staticmethod
    def with_capacity(capacity: Int) -> ColumnSlot[Self.dt]:
        """Allocate an empty slot with `capacity` rows of headroom."""
        return ColumnSlot[Self.dt](
            ColumnBuilder[Self.dt].with_capacity(capacity)
        )

    def append_value(mut self, v: Scalar[Self.DT]):
        """Append one VALID value at the current logical end."""
        self._builder.value().append(v)

    def append_null_value(mut self):
        """Append one null slot."""
        self._builder.value().append_null()

    def current_length(self) -> Int:
        """Current logical row count of the underlying builder."""
        return self._builder.value().length()

    def is_finalized(self) -> Bool:
        """True once `finalize_column` has consumed the inner builder."""
        return not self._builder

    def finalize_column(mut self) raises -> Column[HeapRegion]:
        """One-shot consume: emit the accumulated `Column[HeapRegion]`.

        Extracts the inner builder via `Optional.take()` — the `ColumnSlot`
        stays valid (its only field becomes `None`) and is safe to drop.
        Raises if called a second time.
        """
        if not self._builder:
            raise Error(
                "ColumnSlot.finalize_column: column already finalized"
            )
        var builder = self._builder.take()
        return builder^.materialize()


@always_inline
def column_slot[dt: DType](capacity: Int = 0) -> ColumnSlot[dt]:
    """Factory for one `ColumnSlot[dt]` with `capacity` rows of headroom.

    Use to construct the per-slot arguments of `MultiColumnBuilder`:

        var mcb = MultiColumnBuilder[
            ColumnSlot[DType.int64], ColumnSlot[DType.float64]
        ](column_slot[DType.int64](64), column_slot[DType.float64](64))
    """
    return ColumnSlot[dt].with_capacity(capacity)


# =============================================================================
# §2a — StringColumnSlot — the STRING ColumnSink conformer
# =============================================================================
#
# This is a THIN WRAPPER, not a new builder. `ArrowStringBuilder`
# (`arrow/string_builder.mojo`) already streams straight into Arrow's
# `(offsets, data)` layout with no per-value `String` allocation and no
# re-serialize pass; all this slot adds is the `ColumnSink` shape — the
# `Optional` wrap that makes `finalize_column` a `mut self` one-shot consume,
# and the offset-ceiling guard.
#
# -----------------------------------------------------------------------------
# THE INT32 OFFSET CEILING: THIS SLOT REFUSES. IT DOES NOT PROMOTE.
# -----------------------------------------------------------------------------
# Arrow `STRING` carries Int32 offsets, so `offsets[N]` — the total data-buffer
# length — must fit in a signed 32-bit int (2,147,483,647 bytes). Past that,
# `ArrowStringBuilder._append_offset`'s bare `Int32(len(self.data))` wraps
# NEGATIVE while `data` stays correctly large: `get_length(i)` goes negative,
# `get_span(i)` slices at a negative start, and the row COUNT stays exactly
# right. `LARGE_STRING` is the 64-bit answer and this tree has it.
#
# So the choice is REFUSE or PROMOTE, and this slot refuses. Three reasons,
# in order of weight:
#
#   1. THE OUTPUT TYPE IS STAMPED BEFORE THE FIRST ROW IS APPENDED. Every
#      caller of this slot (`ProjectList.emit_projected`,
#      `EvaluatorAdapterFor_Map.emit_projected`) builds its output `Schema`
#      FIRST and appends rows after. A slot that promoted itself to
#      LARGE_STRING mid-build would emit a Column whose type disagreed with
#      the `Field` already published for it — a schema/data mismatch, which
#      is precisely the class `varlen_width_guard.mojo` guards against.
#      Promotion needs a schema renegotiation this
#      layer does not have.
#
#   2. PROMOTION HERE WOULD MAKE THE OUTPUT TYPE DEPEND ON THE ROW COUNT.
#      One slot is built per MORSEL, so morsel A (under 2 GiB) would emit
#      STRING and morsel B (over it) LARGE_STRING for the SAME output
#      column, and the concat that reassembles them would see two types for
#      one column. A wrong answer that depends on how the input happened to
#      be chunked is worse than a refusal.
#
#   3. `arrow/offset_overflow.mojo`'s contract: "this
#      module's only job is to convert a silent wrong answer into a named
#      error"; offset widening is a separate, tracked step, and the two
#      producers that DO promote (`compiler_helpers`,
#      `compiler_join_assembly`) own their output type end-to-end, which
#      this slot does not. The refusal raises the same `ArrowOffsetOverflow`
#      name and states the same four facts that module's shared builder
#      states — plus the ROW INDEX, which the finalize-time check in
#      `StringArray.from_buffers` structurally cannot know because by then
#      every offset has already been narrowed.
#
# WHY THE CHECK IS PER-APPEND AND NOT ONCE PER COLUMN. `offset_overflow.mojo`
# says to check the TOTAL once, before pass 2, because its callers are
# TWO-PASS and know the total up front. A `ColumnSink` is a ONE-PASS
# streaming accumulator: it does not know its total until the last row, and
# `ArrowStringBuilder` has already narrowed every offset by then. So the only
# COMPLETE placement is the append itself. The cost is one `Int` compare
# against a constant per row, next to a `List.extend` that already does a
# grow check and a memcpy.
#
# `StringArray.from_buffers` performs the same check at finalize; that one is
# kept as the backstop for anything that reaches the builder directly. This
# one is what makes the failure land on the ROW that crossed, before ~2 GiB
# of RSS has been committed — `offset_overflow.mojo`'s own "fail BEFORE
# allocating" principle.
# =============================================================================


@always_inline
def _clamp_ceiling(ceiling: Int) -> Int:
    """FAIL-CLOSED clamp for `StringColumnSlot`'s refusal threshold.

    A non-positive value, or one ABOVE the real Arrow Int32 limit, collapses
    to `ARROW_INT32_OFFSET_MAX` — so a bad seam value can only ever make the
    slot STRICTER, never re-arm the silent wrap. Mirrors
    `offset_overflow.clamp_offset_promote_at`.
    """
    if ceiling <= 0 or ceiling > ARROW_INT32_OFFSET_MAX:
        return ARROW_INT32_OFFSET_MAX
    return ceiling


def _string_slot_offset_overflow(
    row: Int, have: Int, add: Int, ceiling: Int
) -> Error:
    """Build the `ArrowOffsetOverflow` error for a refused String append.

    COLD path only. Says the same four things
    `offset_overflow.arrow_int32_offset_overflow` says — what the total
    would have been, what the ceiling is, what the silent narrowing would
    have produced, and what to do instead — plus the ROW INDEX, which the
    finalize-time check in `StringArray.from_buffers` structurally cannot
    know because by then every offset has already been narrowed.

    It quotes `ceiling`, the value actually in force, rather than the
    constant — so under a lowered test seam the message is still true.
    """
    return Error(
        String("ArrowOffsetOverflow: StringColumnSlot.append_string_value")
        + String(" refused row ")
        + String(row)
        + String(": the column holds ")
        + String(have)
        + String(" data bytes and this value adds ")
        + String(add)
        + String(", for a total of ")
        + String(have + add)
        + String(", which exceeds the Arrow 32-bit string offset ceiling in")
        + String(" force (")
        + String(ceiling)
        + String("). offsets[N] must fit in Int32; narrowing would have")
        + String(" wrapped to ")
        + String(wrap_to_int32(have + add))
        + String(", leaving every row past that byte unaddressable while the")
        + String(" row COUNT stayed correct. This slot REFUSES rather than")
        + String(" promoting to LARGE_STRING because its output ArrowType is")
        + String(" already published in the emitted Schema (see the module")
        + String(" section above). Emit this column in smaller batches, or")
        + String(" build it with a 64-bit-offset producer.")
    )


struct StringColumnSlot(ColumnSink):
    """A `ColumnSink` over an `ArrowStringBuilder` — one STRING output column.

    The STRING-channel twin of `ColumnSlot[dt]`. Values arrive through
    `append_string_value`; `append_value` is overridden below with a
    `comptime assert False` refusal, so aiming a numeric append at a STRING
    column is a named COMPILE error rather than a lost value.

    NULL vs EMPTY STRING. These are different rows and Arrow distinguishes
    them ONLY via the validity bitmap — both occupy zero data bytes and both
    push an identical offset. `append_null_value()` clears the validity bit;
    `append_string_value("")` leaves it set. A builder that conflated them
    would produce byte-identical `(offsets, data)` buffers and a different
    answer to `is_null(i)`, which no value assertion alone would catch.
    """

    comptime KIND = SinkKind.STRING

    comptime DT = DType.uint8
    # ⚠ PLACEHOLDER, AND UNREACHABLE BY CONSTRUCTION. `DT` is the DType of
    # the NUMERIC value channel and a STRING slot has none. Mojo 1.0.0
    # REMOVED `DType.invalid`, so some concrete DType has to be named;
    # `uint8` is chosen because it is the element type of the byte buffer
    # this slot actually writes, so a misreading is inert rather than
    # plausible. Nothing can observe it: `MultiColumnBuilder.append_at`
    # asserts `KIND == NUMERIC` BEFORE it compares `DT`, and
    # `append_value` below refuses outright.

    var _builder: Optional[ArrowStringBuilder]

    var _ceiling: Int
    """The data-byte total at which `append_string_value` REFUSES.

    In production this is `ARROW_INT32_OFFSET_MAX` and nothing else. It is a
    CONSTRUCTOR PARAMETER rather than a constant for one reason, the same
    one the `promote_at` parameter exists for: reaching
    the refusing arm at the production ceiling costs 2 GiB of accumulated
    payload, so an arm gated only on that is — for practical purposes —
    exercised by nobody, cannot go red on a regression, and its first
    report of a defect is a wrong answer in front of a user.

    ⚠ IT MOVES THE THRESHOLD AND NOTHING ELSE. A lowered ceiling runs
    precisely the same compare, the same raise and the same message a 2 GiB
    append runs; the message quotes THIS field, so it never states a
    ceiling that was not the one in force. `_clamp_ceiling` makes it
    fail CLOSED — non-positive or above the real Int32 limit both collapse
    to `ARROW_INT32_OFFSET_MAX`, so a typo cannot widen a column.
    """

    def __init__(
        out self,
        var builder: ArrowStringBuilder,
        ceiling: Int = ARROW_INT32_OFFSET_MAX,
    ):
        """Wrap an existing `ArrowStringBuilder`. Prefer `with_capacity`."""
        self._builder = Optional[ArrowStringBuilder](builder^)
        self._ceiling = _clamp_ceiling(ceiling)

    @staticmethod
    def with_capacity(
        capacity: Int, ceiling: Int = ARROW_INT32_OFFSET_MAX
    ) -> StringColumnSlot:
        """Allocate an empty STRING slot with `capacity` rows of headroom.

        Only the N+1 `Int32` offsets list is reserved — the byte payload's
        size depends on the average value length, which the caller does not
        know (`ArrowStringBuilder.reserve_rows` documents the same choice).

        `ceiling` is the test seam documented on `_ceiling`; production
        callers omit it.
        """
        var b = ArrowStringBuilder()
        if capacity > 0:
            b.reserve_rows(capacity)
        return StringColumnSlot(b^, ceiling)

    def append_value(mut self, v: Scalar[Self.DT]):
        """REFUSED. A STRING slot has no numeric value channel."""
        comptime assert False, (
            "StringColumnSlot.append_value: a STRING column slot has no"
            " numeric value channel. Use `append_string_value(String)` —"
            " or, through a `MultiColumnBuilder`, `append_string_at[k]`"
            " rather than `append_at[k, DT]`."
        )

    def append_string_value(mut self, v: String) raises:
        """Append one VALID String value at the current logical end.

        Raises `ArrowOffsetOverflow` if this value would push the column's
        total data bytes past what an Arrow Int32 offsets buffer can address.
        See the module section above for why this REFUSES rather than
        promoting to LARGE_STRING, and why the check is per-append.
        """
        ref b = self._builder.value()
        # Overflow-SAFE form (`a > MAX - b`, never `a + b > MAX`) per
        # `offset_overflow.mojo`'s own guidance.
        var have = b.data_len()
        var add = v.byte_length()
        if have > self._ceiling - add:
            raise _string_slot_offset_overflow(
                b.n_values(), have, add, self._ceiling
            )
        b.push_bytes(v.as_bytes())

    def append_null_value(mut self):
        """Append one NULL slot — zero-length value, validity bit CLEARED.

        Distinct from `append_string_value("")`, which pushes the same zero
        bytes with the validity bit SET.
        """
        self._builder.value().push_null()

    def current_length(self) -> Int:
        """Current logical row count of the underlying builder."""
        return self._builder.value().n_values()

    def data_byte_length(self) -> Int:
        """Total accumulated value bytes (the quantity the Int32 offset
        ceiling is measured against). Exposed for tests + diagnostics."""
        return self._builder.value().data_len()

    def is_finalized(self) -> Bool:
        """True once `finalize_column` has consumed the inner builder."""
        return not self._builder

    def finalize_column(mut self) raises -> Column[HeapRegion]:
        """One-shot consume: emit the accumulated STRING `Column`.

        Extracts the inner builder via `Optional.take()` — the slot stays
        valid (its only field becomes `None`) and is safe to drop. Raises if
        called a second time.
        """
        if not self._builder:
            raise Error(
                "StringColumnSlot.finalize_column: column already finalized"
            )
        var builder = self._builder.take()
        return builder^.build()


@always_inline
def string_column_slot(
    capacity: Int = 0, ceiling: Int = ARROW_INT32_OFFSET_MAX
) -> StringColumnSlot:
    """Factory for one `StringColumnSlot` with `capacity` rows of headroom.

    The STRING twin of `column_slot[dt]()`. Use to construct the per-slot
    arguments of `MultiColumnBuilder`:

        var mcb = MultiColumnBuilder[
            ColumnSlot[DType.int64], StringColumnSlot
        ](column_slot[DType.int64](64), string_column_slot(64))
    """
    return StringColumnSlot.with_capacity(capacity, ceiling)


# =============================================================================
# §2b — MultiColumnSink — the minimal builder-trait bound
# =============================================================================
#
# `MultiColumnSink` is the minimal trait surface a `RowTransform.write_one`
# body needs to drive a multi-output column builder: the comptime-indexed
# `append_at[k, DT]` that lands one value into output slot `k`.
# `RowTransform.write_one` (eval layer) takes a
# method-level type parameter `MCB: MultiColumnSink`.
#
# It lives HERE, in `komira_arrow`, next to `MultiColumnBuilder` — NOT in
# the eval layer where `RowTransform` lives. A struct can only declare
# conformance to a trait importable at its own layer, and the core packages
# cannot import from the eval layer (the layering runs eval ->
# the core packages). `MultiColumnBuilder` (this file) must conform to
# `MultiColumnSink`, so the trait must be reachable here.
#
# The bound is `Movable` only — a builder is moved into the Stage's per-row
# loop and mutated in place; it is never copied.
# =============================================================================


trait MultiColumnSink(Movable):
    """Minimal builder-trait bound for `RowTransform.write_one`.

    A `MultiColumnSink` is an append-only multi-output column builder: the
    comptime-indexed `append_at[k, DT]` lands one NUMERIC value into output
    slot `k`, `append_string_at[k]` lands one STRING value, and
    `append_null_at[k]` lands one null. `MultiColumnBuilder[*Bs]` (below)
    conforms directly.

    Both carry a
    `comptime assert False` DEFAULT body, so every conformer
    (the production `MultiColumnBuilder` overrides both; the in-tree
    `_TestBuilder` stand-ins do not) keeps conforming with NO edit, and a
    stand-in that is handed a String or a null fails with a named compile
    error instead of silently dropping the row.
    """

    def append_at[k: Int, DT: DType](mut self, value: Scalar[DT]):
        """Append `value` to output slot `k` (k in [0, arity())). `DT` is a
        comptime caller-asserted dtype tag — it MUST equal slot `k`'s column
        DType (the conformer `constrained`-asserts this)."""
        ...

    def append_string_at[k: Int](mut self, value: String) raises:
        """Append the String `value` to output slot `k`.

        Slot `k` must be a STRING-kind sink; the conformer asserts that at
        compile time. `raises` because the STRING sink enforces the Arrow
        Int32 offset ceiling on append (see `StringColumnSlot`).
        """
        comptime assert False, (
            "MultiColumnSink.append_string_at: this builder does not"
            " implement the STRING channel. The production"
            " `MultiColumnBuilder[*Bs]` does; a minimal test stand-in must"
            " implement it explicitly if the transform under test emits a"
            " String."
        )

    def append_null_at[k: Int](mut self):
        """Append one NULL row to output slot `k`.

        Kind-agnostic — a null is a cleared validity bit in either channel.
        For a STRING slot this is distinct from appending `""`, which is a
        VALID zero-length value.
        """
        comptime assert False, (
            "MultiColumnSink.append_null_at: this builder does not"
            " implement null appends. The production"
            " `MultiColumnBuilder[*Bs]` does."
        )


# =============================================================================
# §3 — MultiColumnBuilder — the variadic multi-output builder
# =============================================================================


struct MultiColumnBuilder[*Bs: ColumnSink](Movable, MultiColumnSink):
    """Variadic multi-output column builder — one `ColumnSink` per output
    slot, stored via the canonical `Tuple[*Self.Bs]` shape.

    This is the output-accumulation primitive the unified Stage substrate
    writes into. `RowTransform.write_one[bo, MCB]` instantiates `MCB =
    MultiColumnBuilder` and lands one value per output column via
    `append_at[k, DT]`; the Stage emits the result columns at stage exit via
    `finalize_at[k]` (or the convenience `finalize_columns`).

    Parameters:
        Bs: The comptime type pack of `ColumnSink` conformers — one
            `ColumnSlot[dt]` per output column. Arbitrary arity, with
            no inner-loop dispatch.

    Storage:
        _slots: `Tuple[*Self.Bs]` — the monomorphized SoA record of
            per-column sinks. Compiles to the identical layout a
            hand-written N-field struct would.

    Usage (the shape the Stage mirrors):

        comptime S0 = ColumnSlot[DType.int64]
        comptime S1 = ColumnSlot[DType.float64]
        var mcb = MultiColumnBuilder[S0, S1](
            column_slot[DType.int64](n), column_slot[DType.float64](n)
        )
        # per surviving row: write each output column
        mcb.append_at[0, DType.int64](row_key)
        mcb.append_at[1, DType.float64](row_val)
        # at stage exit:
        var col0 = mcb.finalize_at[0]()
        var col1 = mcb.finalize_at[1]()
    """

    var _slots: Tuple[*Self.Bs]

    def __init__(out self, var *slots: *Self.Bs):
        """Construct from one `ColumnSink` per output slot.

        `Tuple(*slots^)` is the canonical *pack-forwarding shape (the only
        one that type-binds in Mojo 1.0.0b1 — `take=` / `storage=` keyword
        forms fail). `var *slots` (owned) is required.
        """
        self._slots = Tuple(*slots^)

    @staticmethod
    def arity() -> Int:
        """The comptime output-column count."""
        return Self.Bs.__len__()

    @always_inline
    def append_at[k: Int, DT: DType](mut self, value: Scalar[DT]):
        """Append `value` to output slot `k` (k in [0, arity())).

        `DT` is a comptime caller-asserted dtype tag; it MUST equal slot
        `k`'s column DType. The `constrained` check fails the compile if a
        caller passes a value of the wrong DType for a slot — a comptime
        type-safety guard, no runtime cost.

        ⚠ KIND IS ASSERTED BEFORE DT, and the order is load-bearing — a
        non-NUMERIC slot's `DT` is a documented placeholder (§0), so
        comparing against it first would produce a DType-mismatch message
        about a value nobody chose.
        """
        comptime assert Self.Bs[k].KIND == SinkKind.NUMERIC, "MultiColumnBuilder.append_at: output slot `k` is not a NUMERIC" " sink. A STRING slot takes `append_string_at[k](String)`; a null" " row takes `append_null_at[k]()`."
        comptime assert DT == Self.Bs[k].DT, "MultiColumnBuilder.append_at: the value DType `DT` must equal" " output slot `k`'s column DType."
        # `DT == Bs[k].DT` is comptime-proven above, so the rebind is an
        # identity cast that satisfies the type checker.
        self._slots[k].append_value(rebind[Scalar[Self.Bs[k].DT]](value))

    @always_inline
    def append_string_at[k: Int](mut self, value: String) raises:
        """Append the String `value` to output slot `k` (k in [0, arity())).

        The STRING twin of `append_at[k, DT]`. Slot `k` must be a
        STRING-kind sink; a numeric slot is a named compile error rather
        than a lost value.

        Raises `ArrowOffsetOverflow` when the value would push the column
        past the Arrow Int32 offset ceiling — see `StringColumnSlot`.
        """
        comptime assert Self.Bs[k].KIND == SinkKind.STRING, "MultiColumnBuilder.append_string_at: output slot `k` is not a" " STRING sink. Construct that slot with `string_column_slot()`," " or use `append_at[k, DT]` for a numeric column."
        self._slots[k].append_string_value(value)

    @always_inline
    def append_null_at[k: Int](mut self):
        """Append one null slot to output column `k` (k in [0, arity())).

        Kind-agnostic. For a STRING slot this is NOT the same row as
        `append_string_at[k]("")` — both write zero data bytes, and only the
        validity bit tells them apart.
        """
        self._slots[k].append_null_value()

    @always_inline
    def length_at[k: Int](self) -> Int:
        """Current logical row count of output column `k`."""
        return self._slots[k].current_length()

    def finalize_at[k: Int](mut self) raises -> Column[HeapRegion]:
        """One-shot consume of output slot `k`: emit its accumulated
        `Column`.

        Each `ColumnSink.finalize_column` is a `mut self` one-shot consume
        that extracts its inner builder via `Optional.take()` — no slot is
        moved out of the `Tuple` field, so there is no partial-move hazard.
        Calling `finalize_at[k]` twice for the same `k` raises.
        """
        return self._slots[k].finalize_column()

    def finalize_columns(mut self) raises -> Slab[Column[HeapRegion]]:
        """One-shot consume of EVERY output slot: emit all `arity()`
        columns in slot order as a `Slab[Column]`.

        Returns `Slab[Column]` rather than `List[Column]` because `Column`
        is `Movable`-only (not `Copyable`) and `List` requires a `Copyable`
        element. `Slab` is the codebase's `Copyable`-free column container —
        `RecordBatchBuilder` uses the same shape.

        The per-slot fan-out is a `@parameter for` — comptime-unrolled,
        zero indirect dispatch. The caller (the Stage) wires the resulting
        columns into a `RecordBatch` with the output `Schema`.
        """
        var columns = Slab[Column[HeapRegion]].create(Self.Bs.__len__())

        comptime for k in range(Self.Bs.__len__()):
            columns.append(self._slots[k].finalize_column())
        return columns^
