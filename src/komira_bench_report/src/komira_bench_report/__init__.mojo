"""The result model and report of a benchmark run: the cells of a run and how
each ended, the environment fingerprint, the `result.json` writer and strict
reader (schema `komira-bench-result/1`), the aggregates (counts, geomean) and
the human table. See README.md.

| name | what it is |
|---|---|
| `median`, `minimum`, `maximum`, `drop_first_rep`, `sweep_median`, `sweep_medians`, `min_of_sweep_medians`, `spread_pct`, `geomean`, `ratio_of` | the statistics: rep 0 dropped, a median per sweep, the least of the sweeps, the geomean of the ratios |
| `Side`, `Cell`, `derive_ratio` | what an engine measured for a cell, and the cell with its derived ratio and verdict |
| `StageOutcome`, `ValueVerdict`, `cell_verdict` | how komira's run ended, whether the values matched, PASS / FAIL / NO_RATIO |
| `RunInfo`, `Environment`, `DuckDbPin`, `BenchResult`, `validate_result` | the run, its fingerprint, the DuckDB pin and the whole result |
| `write_result_json`, `result_json`, `summary_json`, `parse_result_json` | the writer and the strict reader of result.json |
| `summarize`, `Summary`, `SuiteSummary`, `summary_line`, `exit_code` | the aggregates and the line that states them |
| `render_table` | the human table |
"""

from .format import format_fixed, pad_left, pad_right
from .json_read import parse_result_json
from .json_write import result_json, summary_json, write_result_json
from .model import (
    BenchResult,
    Cell,
    DuckDbPin,
    Environment,
    RESULT_SCHEMA,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
    Side,
    derive_ratio,
    validate_cell,
    validate_result,
)
from .stats import (
    drop_first_rep,
    geomean,
    maximum,
    median,
    min_of_sweep_medians,
    minimum,
    ratio_of,
    spread_pct,
    sweep_median,
    sweep_medians,
)
from .summary import Summary, SuiteSummary, exit_code, summarize, summary_line
from .table import render_table
from .verdict import (
    CELL_FAIL,
    CELL_NO_RATIO,
    CELL_PASS,
    StageOutcome,
    ValueVerdict,
    cell_verdict,
)
