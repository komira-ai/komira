"""`komira_plan_conformance`: the logical-plan conformance corpus.

Test-only; nothing depends on it. Each case is a plan built with
komira_plan_ir's factories plus an expected answer derived by hand from the
query-semantics document (or, later, by an independent oracle). Nothing here
executes a plan yet; test_corpus checks every case through the plan wire and
against its expectation's schema. Modules:
  - plan_case.mojo: `Case`, `Dataset`, the expectation kinds, the .err format;
  - datasets.mojo : the JSON Lines inputs and their schemas, and the
    registered files under inputs/ (the upstream Avro files);
  - cases_<shard>.mojo : one shard's plans;
  - registry.mojo : the shards and what each registers;
  - corpus.mojo   : the checks, gathered by `check_corpus`;
  - oracle_checks.mojo : expected rows tied to an oracle file, and the
    Avro header schema.
"""

from .plan_case import (
    DATASET_DIR,
    EXPECT_DIR,
    EXPECT_ERROR,
    EXPECT_HAND,
    EXPECT_ORACLE,
    INPUT_DIR,
    BuildFn,
    Case,
    Dataset,
    ErrExpectation,
    expect_extension,
    expect_kind_name,
    parse_err,
)
from .corpus import (
    check_cells,
    check_corpus,
    check_dataset,
    check_dataset_files,
    check_expectation,
    check_files,
    check_input_files,
    check_partition,
    check_schema,
    check_wire,
    list_expect_files,
    list_input_files,
    require_corpus,
    schema_entries,
)
from .datasets import all_datasets, all_inputs
from .oracle_checks import RowsFrom, check_avro_schema, check_rows_from
from .registry import Registered, registered_cases, shard_cases, shard_names
