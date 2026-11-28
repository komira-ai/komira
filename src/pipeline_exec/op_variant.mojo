# =============================================================================
# OpVariant -- a closed set of operators behind one runtime tag
# =============================================================================
#
# The operator counterpart of `SourceVariant`: one of five operator types,
# fixed where the variant is named, and a tag saying which. `execute` and
# `metrics_snapshot` test the tag and call the member. The fourth and fifth slots are
# `NoOperator` unless the name fills them.

from exec_types.exec_result import ExecResult
from metrics.metrics_set import MetricsSnapshot
from morsel.morsel import Morsel
from morsel.morsel_operator import MorselOperatorImpl

from .unused_members import NoOperator

comptime OP_TAG_FIRST: UInt8 = 0
comptime OP_TAG_SECOND: UInt8 = 1
comptime OP_TAG_THIRD: UInt8 = 2
comptime OP_TAG_FOURTH: UInt8 = 3
comptime OP_TAG_FIFTH: UInt8 = 4


struct OpVariant[
    A: MorselOperatorImpl,
    B: MorselOperatorImpl,
    C: MorselOperatorImpl,
    D: MorselOperatorImpl = NoOperator,
    E: MorselOperatorImpl = NoOperator,
](MorselOperatorImpl):
    """One operator out of the closed list `A`, `B`, `C`, `D`, `E`. Fill unused
    slots with `NoOperator`."""

    var _tag: UInt8
    var _a: Optional[Self.A]
    var _b: Optional[Self.B]
    var _c: Optional[Self.C]
    var _d: Optional[Self.D]
    var _e: Optional[Self.E]

    def __init__(out self, tag: UInt8):
        self._tag = tag
        self._a = Optional[Self.A]()
        self._b = Optional[Self.B]()
        self._c = Optional[Self.C]()
        self._d = Optional[Self.D]()
        self._e = Optional[Self.E]()

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

    @staticmethod
    def fourth(var member: Self.D) -> Self:
        """A variant holding `member` in the fourth slot."""
        var v = Self(OP_TAG_FOURTH)
        v._d = Optional[Self.D](member^)
        return v^

    @staticmethod
    def fifth(var member: Self.E) -> Self:
        """A variant holding `member` in the fifth slot."""
        var v = Self(OP_TAG_FIFTH)
        v._e = Optional[Self.E](member^)
        return v^

    def tag(self) -> UInt8:
        """Which slot holds the member."""
        return self._tag

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        if self._tag == OP_TAG_FIRST:
            return self._a.value().execute(morsel)
        if self._tag == OP_TAG_SECOND:
            return self._b.value().execute(morsel)
        if self._tag == OP_TAG_THIRD:
            return self._c.value().execute(morsel)
        if self._tag == OP_TAG_FOURTH:
            return self._d.value().execute(morsel)
        return self._e.value().execute(morsel)

    def metrics_snapshot(self) -> MetricsSnapshot:
        if self._tag == OP_TAG_FIRST:
            return self._a.value().metrics_snapshot()
        if self._tag == OP_TAG_SECOND:
            return self._b.value().metrics_snapshot()
        if self._tag == OP_TAG_THIRD:
            return self._c.value().metrics_snapshot()
        if self._tag == OP_TAG_FOURTH:
            return self._d.value().metrics_snapshot()
        return self._e.value().metrics_snapshot()
