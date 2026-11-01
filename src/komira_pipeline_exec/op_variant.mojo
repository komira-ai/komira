# =============================================================================
# OpVariant -- a closed set of operators behind one runtime tag
# =============================================================================
#
# The operator counterpart of `SourceVariant`: one of three operator types,
# fixed where the variant is named, and a tag saying which. `execute` and
# `metrics_snapshot` test the tag and call the member.

from komira_exec_types.exec_result import ExecResult
from komira_metrics.metrics_set import MetricsSnapshot
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl

comptime OP_TAG_FIRST: UInt8 = 0
comptime OP_TAG_SECOND: UInt8 = 1
comptime OP_TAG_THIRD: UInt8 = 2


struct OpVariant[
    A: MorselOperatorImpl, B: MorselOperatorImpl, C: MorselOperatorImpl
](MorselOperatorImpl):
    """One operator out of the closed list `A`, `B`, `C`. Fill unused slots
    with `NoOperator`."""

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
        var v = Self(OP_TAG_FIRST)
        v._a = Optional[Self.A](member^)
        return v^

    @staticmethod
    def second(var member: Self.B) -> Self:
        """A variant holding `member` in the second slot."""
        var v = Self(OP_TAG_SECOND)
        v._b = Optional[Self.B](member^)
        return v^

    @staticmethod
    def third(var member: Self.C) -> Self:
        """A variant holding `member` in the third slot."""
        var v = Self(OP_TAG_THIRD)
        v._c = Optional[Self.C](member^)
        return v^

    def tag(self) -> UInt8:
        """Which slot holds the member."""
        return self._tag

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        if self._tag == OP_TAG_FIRST:
            return self._a.value().execute(morsel)
        if self._tag == OP_TAG_SECOND:
            return self._b.value().execute(morsel)
        return self._c.value().execute(morsel)

    def metrics_snapshot(self) -> MetricsSnapshot:
        if self._tag == OP_TAG_FIRST:
            return self._a.value().metrics_snapshot()
        if self._tag == OP_TAG_SECOND:
            return self._b.value().metrics_snapshot()
        return self._c.value().metrics_snapshot()
