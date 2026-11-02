# The komira side of a comparison, as the runner sees it. An arm is prepared
# once with the tables and the two settings both engines share, then asked to
# run queries. Each run ends in one of four ways, which are the stages the
# result records: rows (or a row count), a named refusal, a bind failure, an
# execution failure.
#
# Three things plug in here, none of which the runner knows about:
#   * `RefusalArm`, below: refuses every query by name; the arm of today.
#   * a hand-built-plan arm: `run` looks the query up by `query.key()` or
#     `query.sha256()`, runs the plan it has for it and refuses the rest.
#   * `run_sql`, once it exists: `run` hands `query.text` to the engine.

from komira_bench_duckdb import FaultCount, ResultSet

from .query import QuerySpec
from .tables import TableBinding

comptime ARM_ROWS: Int = 0
comptime ARM_REFUSED: Int = 1
comptime ARM_BIND_FAIL: Int = 2
comptime ARM_EXEC_FAIL: Int = 3

comptime REFUSAL_NO_ARM: String = "no_engine_arm"
"""The construct `RefusalArm` names by default."""


struct ArmAnswer(Copyable, Movable):
    """How one run of the arm ended. `kind` is `ARM_ROWS` (the run completed:
    `rows` holds the typed rows when they were asked for, and `row_count` is
    the number of rows either way), `ARM_REFUSED` (`detail` is the construct
    the engine refuses, a token with no slash: it is written to the result),
    `ARM_BIND_FAIL` or `ARM_EXEC_FAIL` (`detail` is the engine's message,
    shown on the console and never written to the result)."""

    var kind: Int
    var detail: String
    var rows: ResultSet
    var row_count: Int64

    def __init__(out self, kind: Int, var detail: String, var rows: ResultSet, row_count: Int64):
        self.kind = kind
        self.detail = detail^
        self.rows = rows^
        self.row_count = row_count

    @staticmethod
    def with_rows(var rows: ResultSet) -> ArmAnswer:
        var n = Int64(rows.row_count())
        return ArmAnswer(ARM_ROWS, String(""), rows^, n)

    @staticmethod
    def counted(row_count: Int64) -> ArmAnswer:
        """A completed run whose rows were not materialized."""
        return ArmAnswer(ARM_ROWS, String(""), ResultSet(), row_count)

    @staticmethod
    def refused(var construct: String) -> ArmAnswer:
        return ArmAnswer(ARM_REFUSED, construct^, ResultSet(), Int64(0))

    @staticmethod
    def bind_failed(var message: String) -> ArmAnswer:
        return ArmAnswer(ARM_BIND_FAIL, message^, ResultSet(), Int64(0))

    @staticmethod
    def exec_failed(var message: String) -> ArmAnswer:
        return ArmAnswer(ARM_EXEC_FAIL, message^, ResultSet(), Int64(0))

    def completed(self) -> Bool:
        return self.kind == ARM_ROWS


trait EngineArm(Movable, Deinitable):
    """The komira engine as the runner drives it."""

    def label(self) -> String:
        """A short name for the console (`refusal`, `plan`, `run_sql`)."""
        ...

    def prepare(
        mut self,
        tables: List[TableBinding],
        threads: Int,
        memory_limit_bytes: Int,
    ) raises:
        """Make `tables` readable by name and run with `threads` workers and
        `memory_limit_bytes`, the numbers DuckDB was given. Raises when the
        arm cannot be set up: that ends the run. A query the arm cannot serve
        is not a raise here but a refusal from `run`."""
        ...

    def run(mut self, query: QuerySpec, materialize: Bool) raises -> ArmAnswer:
        """Run `query` to completion. With `materialize` the answer carries
        its rows (the value check); without it the engine consumes the result
        as its own sink would and reports only the row count (the timed
        runs). A refusal or failure of the query is an answer; a raise is a
        fault of the arm itself and ends the run."""
        ...

    def close(mut self) raises:
        """Release whatever `prepare` acquired."""
        ...

    def faults(self) -> Optional[FaultCount]:
        """The minor and major page faults of the process the engine runs
        in, so far; the runner reads it before and after each timed run. An
        arm that cannot read them reports none, and the result then says the
        faults of its runs were not measured."""
        return Optional[FaultCount]()


struct RefusalArm(EngineArm):
    """An arm that refuses every query, naming one construct. It is the komira
    arm until an engine exists: a run with it lists every query as unserved."""

    var _construct: String
    var prepared: Bool
    var asked: Int

    def __init__(out self, var construct: String = String(REFUSAL_NO_ARM)):
        self._construct = construct^
        self.prepared = False
        self.asked = 0

    def label(self) -> String:
        return String("refusal")

    def prepare(mut self, tables: List[TableBinding], threads: Int, memory_limit_bytes: Int) raises:
        self.prepared = True

    def run(mut self, query: QuerySpec, materialize: Bool) raises -> ArmAnswer:
        self.asked += 1
        return ArmAnswer.refused(self._construct.copy())

    def close(mut self) raises:
        self.prepared = False
