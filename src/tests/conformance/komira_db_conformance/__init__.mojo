"""`komira_db_conformance` -- the `komira_db` contract, written once and run
against every implementation.

Two suites, generic over two target traits (targets.mojo):

  run_neutral_suite[T: NeutralTarget]  the backend-neutral `Database`:
      every logical type through put / get_by_key (type_checks.mojo), and
      the transaction verbs and the structured ops (neutral_checks.mojo).
  run_sql_suite[T: SqlTarget]  the `SqlDatabase` string surface: dialect
      tokens, execute / query / query_one / query_opt, parameter binding
      (never interpolated), transactions, errors (sql_checks.mojo).

Each run records every check and is gated on the target's list of known
gaps, each pinned to the text its failure must carry (report.mojo). The
library imports komira_db and komira_async only; the implementations are
imported by the tests that run the suites against them.

The Firestore target runs on `MockFirestore`, so it proves conformance to the
mock's model of Firestore (what mock_firestore.mojo says it models), not to
Firestore itself.
"""

from komira_db_conformance.report import ConformanceReport, KnownGap
from komira_db_conformance.targets import (
    ERR_NO_TABLE,
    ERR_NOT_NULL,
    ERR_SYNTAX,
    ERR_UNIQUE,
    ITEMS,
    PAIRS,
    SQL_TABLE,
    SQL_TABLE_NN,
    TYPES,
    NeutralTarget,
    SqlTarget,
)
from komira_db_conformance.suites import run_neutral_suite, run_sql_suite
from komira_db_conformance.sql_checks import check_dialect_tokens
