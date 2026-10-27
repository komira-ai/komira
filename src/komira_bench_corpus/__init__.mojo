"""The SQL of three published benchmark suites, as Mojo data, with a content
hash of every query and every suite. See README.md.

Derived from TPC-H; not a TPC result.

| name | what it is |
|---|---|
| `suites`, `suite_ids`, `suite` | the suites (`tpch`: 22 queries, `clickbench`: 43, `h2o`: 15), their ids, and one by id |
| `Suite` | a suite: `id`, `title`, `notice` (the sentence a report of it must carry), `queries`, `query(id)` and `sha256()` |
| `Query`, `find_query` | one query: `suite`, `id`, `dataset`, `text`, `key()` (`tpch/q1`) and `sha256()`; `find_query` looks one up by key |
| `dataset`, `dataset_names` | the dataset a query expects: the tables and their column types |
| `Dataset`, `Table`, `Column` | the tables of a dataset, with `ddl()` and `sha256()` |
| `tpch_q11_at_scale` | TPC-H query 11 with the fraction of a given scale factor |
| `sha256_hex` | the SHA-256 the hashes above use |
"""

from .catalog import (
    dataset,
    dataset_names,
    find_query,
    suite,
    suite_ids,
    suites,
)
from .datasets import (
    DATASET_CLICKBENCH,
    DATASET_H2O_GROUPBY,
    DATASET_H2O_JOIN,
    DATASET_TPCH,
)
from .clickbench import SUITE_CLICKBENCH
from .h2o import SUITE_H2O
from .query import Query, Suite
from .schema import Column, Dataset, Table
from .sha256 import sha256_hex
from .tpch import SUITE_TPCH, TPCH_NOTICE, tpch_q11_at_scale
