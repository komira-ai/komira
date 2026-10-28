# =============================================================================
# SourceVariant -- a closed set of sources behind one runtime tag
# =============================================================================
#
# A plan chooses its source at run time, so the driver cannot name the concrete
# source type. `SourceVariant[A, B, C]` holds exactly one of three source types,
# fixed where the variant is named, and a tag saying which; each trait method
# tests the tag and calls the member. There is no function pointer, no erased
# box and no pointer in a signature.
#
# The hooks that take a pointer in the trait (`set_cancel_flag`,
# `set_expr_pool`, `set_dynamic_filter`) keep the trait's no-op defaults here;
# the members that need them are driven through the safe hooks below and the
# builder that constructs them.

from komira_arrow.schema import Schema
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from komira_plan_expr.expr_id import ExprId
from komira_plan_stats.source_statistics import SourceStatistics

comptime SOURCE_TAG_FIRST: UInt8 = 0
comptime SOURCE_TAG_SECOND: UInt8 = 1
comptime SOURCE_TAG_THIRD: UInt8 = 2


struct SourceVariant[
    A: MorselSourceImpl, B: MorselSourceImpl, C: MorselSourceImpl
](MorselSourceImpl):
    """One source out of the closed list `A`, `B`, `C`. Fill unused slots with
    `NoSource`."""

    var _tag: UInt8
    var _a: Optional[Self.A]
    var _b: Optional[Self.B]
    var _c: Optional[Self.C]

    def __init__(out self, tag: UInt8):
        self._tag = tag
        self._a = Optional[Self.A]()
        self._b = Optional[Self.B]()
        self._c = Optional[Self.C]()

    @staticmethod
    def first(var member: Self.A) -> Self:
        """A variant holding `member` in the first slot."""
        var v = Self(SOURCE_TAG_FIRST)
        v._a = Optional[Self.A](member^)
        return v^

    @staticmethod
    def second(var member: Self.B) -> Self:
        """A variant holding `member` in the second slot."""
        var v = Self(SOURCE_TAG_SECOND)
        v._b = Optional[Self.B](member^)
        return v^

    @staticmethod
    def third(var member: Self.C) -> Self:
        """A variant holding `member` in the third slot."""
        var v = Self(SOURCE_TAG_THIRD)
        v._c = Optional[Self.C](member^)
        return v^

    def tag(self) -> UInt8:
        """Which slot holds the member."""
        return self._tag

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().next_morsel(worker_id)
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().next_morsel(worker_id)
        return self._c.value().next_morsel(worker_id)

    def output_schema(self) -> Schema:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().output_schema()
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().output_schema()
        return self._c.value().output_schema()

    def partition_hint(self) -> Int:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().partition_hint()
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().partition_hint()
        return self._c.value().partition_hint()

    def row_count_hint(self) -> Int:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().row_count_hint()
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().row_count_hint()
        return self._c.value().row_count_hint()

    def capabilities(self) -> SourceCapabilities:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().capabilities()
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().capabilities()
        return self._c.value().capabilities()

    def statistics(self) -> SourceStatistics:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().statistics()
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().statistics()
        return self._c.value().statistics()

    def has_decode_filter(self) -> Bool:
        if self._tag == SOURCE_TAG_FIRST:
            return self._a.value().has_decode_filter()
        if self._tag == SOURCE_TAG_SECOND:
            return self._b.value().has_decode_filter()
        return self._c.value().has_decode_filter()

    def set_projection(mut self, cols: List[Int]) -> None:
        if self._tag == SOURCE_TAG_FIRST:
            self._a.value().set_projection(cols)
        elif self._tag == SOURCE_TAG_SECOND:
            self._b.value().set_projection(cols)
        else:
            self._c.value().set_projection(cols)

    def set_decode_filter(mut self, stages: List[ExprId]) -> None:
        if self._tag == SOURCE_TAG_FIRST:
            self._a.value().set_decode_filter(stages)
        elif self._tag == SOURCE_TAG_SECOND:
            self._b.value().set_decode_filter(stages)
        else:
            self._c.value().set_decode_filter(stages)

    def set_pushed_predicate(mut self, expr: ExprId) -> None:
        if self._tag == SOURCE_TAG_FIRST:
            self._a.value().set_pushed_predicate(expr)
        elif self._tag == SOURCE_TAG_SECOND:
            self._b.value().set_pushed_predicate(expr)
        else:
            self._c.value().set_pushed_predicate(expr)

    def set_morsel_rows(mut self, rows: Int) -> None:
        if self._tag == SOURCE_TAG_FIRST:
            self._a.value().set_morsel_rows(rows)
        elif self._tag == SOURCE_TAG_SECOND:
            self._b.value().set_morsel_rows(rows)
        else:
            self._c.value().set_morsel_rows(rows)
