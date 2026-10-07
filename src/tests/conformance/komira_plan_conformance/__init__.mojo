"""`komira_plan_conformance`: the logical-plan conformance corpus.

Test-only; nothing depends on it. Each case is a plan built with
komira_plan_ir's factories plus an expected answer derived by hand from the
query-semantics document (or, later, by an independent oracle). Nothing here
executes a plan yet; test_corpus checks every case through the plan wire and
against its expectation's schema. Modules:
  - plan_case.mojo: `Case`, `Dataset`, the expectation kinds, the .err format;
  - datasets.mojo : the hand-written JSON Lines inputs and their schemas;
  - cases_<shard>.mojo : one shard's plans;
  - registry.mojo : the shards and what each registers;
  - corpus.mojo   : the checks, gathered by `check_corpus`.
"""

from .plan_case import (
    DATASET_DIR,
    EXPECT_DIR,
    EXPECT_ERROR,
    EXPECT_HAND,
    EXPECT_ORACLE,
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
    check_partition,
    check_schema,
    check_wire,
    list_expect_files,
    require_corpus,
    schema_entries,
)
from .datasets import all_datasets
from .registry import Registered, registered_cases, shard_cases, shard_names
