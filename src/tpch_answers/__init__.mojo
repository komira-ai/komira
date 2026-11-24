"""DuckDB's answers to the TPC-H corpus queries over staged scale factor 1, as
recorded signatures. See README.md.

| name | what it is |
|---|---|
| `produce_tpch_sf1_answers`, `ANSWERS_FILE`, `QUERIES_DIR` | verify and lock the staged files, run the 22 queries in DuckDB, write the answers file, the lock and the query texts |
| `record_answers`, `register_tables`, `tpch_header` | the answers text of a suite over a DuckDB session; the views the queries read; the comment lines on top |
| `tpch_order_keys` | the ORDER BY keys of a query as result column positions |
| `parse_answer_args`, `AnswerSettings`, `DEFAULT_MEMORY_GIB` | the flags of the program |
"""

from .cli import AnswerSettings, DEFAULT_MEMORY_GIB, parse_answer_args
from .keys import tpch_order_keys
from .produce import ANSWERS_FILE, QUERIES_DIR, produce_tpch_sf1_answers
from .record import record_answers, register_tables, tpch_header
