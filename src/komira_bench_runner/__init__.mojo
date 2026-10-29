"""The benchmark runner: for a query, it registers the dataset, runs the DuckDB
arm and the komira arm, checks the komira answer against DuckDB's before
anything is timed, times warm and cold runs, and fills a `BenchResult`
(`komira_bench_report`). See README.md.

| name | what it is |
|---|---|
| `EngineArm`, `ArmAnswer`, `RefusalArm`, `ARM_ROWS`, `ARM_REFUSED`, `ARM_BIND_FAIL`, `ARM_EXEC_FAIL` | the komira side as the runner drives it: prepare, run (rows, a named refusal or a failure), close; and the arm that refuses every query |
| `QuerySpec` | one query: suite, id, dataset, text, ORDER BY keys, and the sha256 of the text |
| `TableBinding`, `Scale`, `tables_of`, `scale_of`, `table_name_of` | a dataset manifest as named tables and a stated scale |
| `CacheDropper`, `NoCacheDropper`, `ProcDropCaches` | the file-cache drop before a cold run |
| `RunSettings`, `HostFacts`, `RunInputs` | what a run is told |
| `run_queries`, `RunOutput`, `QueryOutcome`, `register_duckdb` | the run itself |
| `measure`, `Sweeps`, `time_komira`, `time_duckdb` | timing one query on both engines |
| `format_run`, `write_run`, `queries_listing`, `queries_file_text` | the console report and the files of a run |
| `RunFlags`, `parse_flags`, `run_entrypoint` | the program |
"""

from .arm import (
    ARM_BIND_FAIL,
    ARM_EXEC_FAIL,
    ARM_REFUSED,
    ARM_ROWS,
    ArmAnswer,
    EngineArm,
    REFUSAL_NO_ARM,
    RefusalArm,
)
from .cache import CacheDropper, NoCacheDropper, ProcDropCaches
from .entrypoint import lock_fingerprint, run_entrypoint
from .flags import RunFlags, parse_flags, parse_order_key, usage
from .measure import Sweeps, measure, time_duckdb, time_komira
from .output import QUERIES_FILE, format_run, queries_file_text, queries_listing, write_run
from .query import QuerySpec
from .runner import (
    CAUSE_NOT_RUN,
    CAUSE_WRONG_ANSWER,
    CAUSE_WRONG_ORDER,
    QueryOutcome,
    RunOutput,
    register_duckdb,
    run_queries,
)
from .settings import HostFacts, RunInputs, RunSettings
from .tables import Scale, TableBinding, scale_of, table_name_of, tables_of
