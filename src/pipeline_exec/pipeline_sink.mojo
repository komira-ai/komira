# =============================================================================
# PipelineSink -- a closed set of sinks behind one runtime tag
# =============================================================================
#
# The sink counterpart of `SourceVariant`: one of five sink types, fixed where
# the variant is named, and a tag saying which. Every method of the sink trait
# tests the tag and calls the member. `consume` takes `self`, as the trait
# does, so workers call it through one shared borrow; a member keeps its
# per-worker state in slots indexed by worker id. The fourth and fifth slots
# are `NoSink` unless the name fills them.

from arrow.schema import RecordBatch
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution

from .unused_members import NoSink

comptime SINK_TAG_FIRST: UInt8 = 0
comptime SINK_TAG_SECOND: UInt8 = 1
comptime SINK_TAG_THIRD: UInt8 = 2
comptime SINK_TAG_FOURTH: UInt8 = 3
comptime SINK_TAG_FIFTH: UInt8 = 4


struct PipelineSink[
    A: MorselSinkImpl,
    B: MorselSinkImpl,
    C: MorselSinkImpl,
    D: MorselSinkImpl = NoSink,
    E: MorselSinkImpl = NoSink,
](MorselSinkImpl):
    """One sink out of the closed list `A`, `B`, `C`, `D`, `E`. Fill unused
    slots with `NoSink`."""

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
        var v = Self(SINK_TAG_FIRST)
        v._a = Optional[Self.A](member^)
        return v^

    @staticmethod
    def second(var member: Self.B) -> Self:
        """A variant holding `member` in the second slot."""
        var v = Self(SINK_TAG_SECOND)
        v._b = Optional[Self.B](member^)
        return v^

    @staticmethod
    def third(var member: Self.C) -> Self:
        """A variant holding `member` in the third slot."""
        var v = Self(SINK_TAG_THIRD)
        v._c = Optional[Self.C](member^)
        return v^

    @staticmethod
    def fourth(var member: Self.D) -> Self:
        """A variant holding `member` in the fourth slot."""
        var v = Self(SINK_TAG_FOURTH)
        v._d = Optional[Self.D](member^)
        return v^

    @staticmethod
    def fifth(var member: Self.E) -> Self:
        """A variant holding `member` in the fifth slot."""
        var v = Self(SINK_TAG_FIFTH)
        v._e = Optional[Self.E](member^)
        return v^

    def tag(self) -> UInt8:
        """Which slot holds the member."""
        return self._tag

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if self._tag == SINK_TAG_FIRST:
            self._a.value().consume(worker_id, morsel^)
        elif self._tag == SINK_TAG_SECOND:
            self._b.value().consume(worker_id, morsel^)
        elif self._tag == SINK_TAG_THIRD:
            self._c.value().consume(worker_id, morsel^)
        elif self._tag == SINK_TAG_FOURTH:
            self._d.value().consume(worker_id, morsel^)
        else:
            self._e.value().consume(worker_id, morsel^)

    def finalize(mut self) raises:
        if self._tag == SINK_TAG_FIRST:
            self._a.value().finalize()
        elif self._tag == SINK_TAG_SECOND:
            self._b.value().finalize()
        elif self._tag == SINK_TAG_THIRD:
            self._c.value().finalize()
        elif self._tag == SINK_TAG_FOURTH:
            self._d.value().finalize()
        else:
            self._e.value().finalize()

    def resize_worker_state(mut self, num_workers: Int) -> None:
        if self._tag == SINK_TAG_FIRST:
            self._a.value().resize_worker_state(num_workers)
        elif self._tag == SINK_TAG_SECOND:
            self._b.value().resize_worker_state(num_workers)
        elif self._tag == SINK_TAG_THIRD:
            self._c.value().resize_worker_state(num_workers)
        elif self._tag == SINK_TAG_FOURTH:
            self._d.value().resize_worker_state(num_workers)
        else:
            self._e.value().resize_worker_state(num_workers)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        if self._tag == SINK_TAG_FIRST:
            self._a.value().combine(pipeline)
        elif self._tag == SINK_TAG_SECOND:
            self._b.value().combine(pipeline)
        elif self._tag == SINK_TAG_THIRD:
            self._c.value().combine(pipeline)
        elif self._tag == SINK_TAG_FOURTH:
            self._d.value().combine(pipeline)
        else:
            self._e.value().combine(pipeline)

    def take_output(mut self) raises -> RecordBatch:
        if self._tag == SINK_TAG_FIRST:
            return self._a.value().take_output()
        if self._tag == SINK_TAG_SECOND:
            return self._b.value().take_output()
        if self._tag == SINK_TAG_THIRD:
            return self._c.value().take_output()
        if self._tag == SINK_TAG_FOURTH:
            return self._d.value().take_output()
        return self._e.value().take_output()
