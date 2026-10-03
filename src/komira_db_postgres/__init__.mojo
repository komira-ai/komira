"""`komira_db_postgres` — the Postgres driver for `komira_db`.

`PgDatabase` conforms to the backend-generic `SqlDatabase` trait over the
`komira_pg` wire client; `PgPool` is the `Pool[PgDatabase]` specialization.

Public surface:
  PgDatabase         — the Postgres `SqlDatabase` conformer
  pg_rows_to_db_rows — PgRow set -> DbRows
  to_pg_params       — DbValue list -> Postgres bind parameters
  PgPool             — the pooled Postgres connections

Encapsulation: no UnsafePointer crosses any public boundary; no wildcard
origins; no unsafe_from_address.
"""

from komira_db_postgres.pg_driver import (
    PgDatabase,
    pg_rows_to_db_rows,
    to_pg_params,
)
from komira_db_postgres.pg_pool import PgPool
