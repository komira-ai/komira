# =============================================================================
# NoSource, NoOperator, NoSink -- the member of a variant slot nothing uses
# =============================================================================
#
# A closed variant holds one of a fixed list of members. A list shorter than
# the variant's slots fills the rest with these, which refuse to run: a variant
# whose tag names one of them is a driver defect, and the refusal says so.

from komira_arrow.schema import Schema
from komira_exec_types.exec_result import ExecResult
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities


struct NoSource(MorselSourceImpl):
    """A source slot with no member. Every pull raises."""

    def __init__(out self):
        pass

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        raise Error("komira_pipeline_exec: the source slot is unused")

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 0

    def row_count_hint(self) -> Int:
        return 0

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


struct NoOperator(MorselOperatorImpl):
    """An operator slot with no member. Every execute raises."""

    def __init__(out self):
        pass

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        raise Error("komira_pipeline_exec: the operator slot is unused")


struct NoSink(MorselSinkImpl):
    """A sink slot with no member. Every call raises."""

    def __init__(out self):
        pass

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        raise Error("komira_pipeline_exec: the sink slot is unused")

    def finalize(mut self) raises:
        raise Error("komira_pipeline_exec: the sink slot is unused")
