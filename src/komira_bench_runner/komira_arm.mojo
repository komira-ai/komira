# The komira engine as the runner's arm: SQL text in, record batches out, over
# an `EngineContext` (komira_sdk_exec).
#
#   prepare  builds one context with the run's thread count and memory limit
#            (`EngineOptions.worker_count` and `memory_budget_bytes`) and
#            registers every table as a Parquet table. A table the engine cannot
#            register ends the run (a raise naming the table): the arm cannot be
#            set up.
#   run      hands `query.text` to `run_sql`. Batches become the answer: the
#            typed rows (convert.mojo) when `materialize`, the row count alone
#            otherwise. A refusal becomes `ArmAnswer.refused(token)`.
#   close    drops the context (its workers and its tables). A cold rep closes
#            and prepares again, so nothing the engine cached in its process
#            survives.
#
# THE REFUSAL TOKEN. The result records a refusal as `UNSUPPORTED:<token>` and
# refuses a token that holds a slash, a backslash or a control character (a
# detail is text about a query, never a place on a machine), while an engine's
# message may name a file. The token is therefore `<step>.<CODE>`: the step
# that refused (`parse`, `bind`, `optimize`, `lower`, `execute`) and the leading
# upper-case code (letters, digits, `_`) that starts the engine's message and
# is followed by a colon, when it has one (`LOWERING_UNCUTTABLE_NODE: ...`), else the step alone. The engine's whole message
# is kept in `last_refusal` for the console, never in the result.

from std.collections import Optional

from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql

from .arm import ArmAnswer, EngineArm
from .convert import RESULT_TYPE_UNSUPPORTED, result_set_of
from .query import QuerySpec
from .tables import TableBinding

comptime REFUSAL_RESULT_TYPE: String = "result_type_unsupported"
"""The construct of a run whose result has a column type the conversion lacks."""


def _is_code_byte(c: UInt8) -> Bool:
    return (c >= 0x41 and c <= 0x5A) or (c >= 0x30 and c <= 0x39) or c == 0x5F


def refusal_token(step: String, reason: String) -> String:
    """`<step>.<CODE>` for an engine refusal at `step` whose message starts with
    an upper-case code of at least three characters followed by `:`; `step` alone
    otherwise (`SQL syntax error` has no code). Never holds a slash or a control
    character."""
    var b = reason.as_bytes()
    var n = 0
    while n < len(b) and _is_code_byte(b[n]):
        n += 1
    if n >= 3 and n < len(b) and b[n] == 0x3A:
        return step + String(".") + String(reason[byte=0:n])
    return step.copy()


struct KomiraArm(EngineArm):
    """The komira engine, driven through `run_sql`."""

    var _ctx: Optional[EngineContext]
    var last_refusal: String
    """The engine's whole message of the most recent refusal, `<step>: <reason>`."""
    var prepares: Int
    """How many contexts `prepare` has built (a cold rep builds a new one)."""
    var closes: Int
    """How many contexts `close` has dropped."""

    def __init__(out self):
        self._ctx = None
        self.last_refusal = String("")
        self.prepares = 0
        self.closes = 0

    def label(self) -> String:
        return String("run_sql")

    def is_prepared(self) -> Bool:
        return Bool(self._ctx)

    def prepare(mut self, tables: List[TableBinding], threads: Int, memory_limit_bytes: Int) raises:
        if self._ctx:
            self.close()
        var ctx = EngineContext(EngineOptions(worker_count=threads, memory_budget_bytes=memory_limit_bytes))
        for i in range(len(tables)):
            try:
                register_parquet(ctx, tables[i].name, tables[i].path)
            except e:
                raise Error(
                    "the komira engine cannot register table " + tables[i].name + " (" + tables[i].path + "): " + String(e)
                )
        self._ctx = Optional[EngineContext](ctx^)
        self.prepares += 1

    def run(mut self, query: QuerySpec, materialize: Bool) raises -> ArmAnswer:
        if not self._ctx:
            raise Error("the komira arm is not prepared")
        var outcome = run_sql(self._ctx.value(), query.text)
        if outcome.refusal:
            ref refusal = outcome.refusal.value()
            self.last_refusal = refusal.step + String(": ") + refusal.reason
            return ArmAnswer.refused(refusal_token(refusal.step, refusal.reason))
        if not materialize:
            var n = 0
            for i in range(len(outcome.batches)):
                n += outcome.batches[i].num_rows()
            return ArmAnswer.counted(Int64(n))
        try:
            return ArmAnswer.with_rows(result_set_of(outcome.batches))
        except e:
            var message = String(e)
            if message.startswith(RESULT_TYPE_UNSUPPORTED):
                self.last_refusal = String("result: ") + message
                return ArmAnswer.refused(String(REFUSAL_RESULT_TYPE))
            return ArmAnswer.exec_failed(message^)

    def close(mut self) raises:
        if self._ctx:
            self._ctx = None
            self.closes += 1
