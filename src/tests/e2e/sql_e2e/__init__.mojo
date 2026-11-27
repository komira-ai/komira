# sql_e2e: komira's SQL surface held end to end to the pinned DuckDB.
#
# Each case of cases/ is one SELECT over komira_test_oracle's datasets or the
# package's regression tables (sql/regression_tables.sql). Its answer from
# DuckDB is a sql_oracle build action (BUCK); its answer from
# komira is `so.sql_result`, what libkomira's komira_sql_stream runs. The two
# must be equal by value and in row order (runner.mojo), or komira must refuse
# the case with the text refusals.tsv lists for it (corpus.mojo). One
# capability's cases also run as a test of their own, one per cell of the
# surface capability matrix (capability.mojo). Test-only; nothing ships.
from .capability import check_capability, flag_value, split_cases
from .corpus import (
    REFUSALS_FILE,
    Corpus,
    Refusal,
    SqlCase,
    load_corpus,
    parse_refusals,
    query_text,
    run_sql_steps,
)
from .runner import E2eReport, check_case, check_corpus, compare_answer, has_resident_twin, open_session
