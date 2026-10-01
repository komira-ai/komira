"""`komira_db` — backend-generic, schema-driven database abstraction.

The runtime types and traits that generated DbStorable code compiles against,
plus the sqlite and Postgres drivers.

Public surface (what a generated `*_db.mojo` imports):
  DbStorable           — the generated row-type contract
  DbSchema             — the generated DDL-only schema contract (schema_only)
  Database             — the backend-NEUTRAL tx + 9-structured-op trait (any backend)
  SqlDatabase          — the SQL-specific sub-trait (execute/query + dialect + claim)
  Pred/Filter/Order/DbColVal/PodNameMinter — the neutral structured-op value types
  sql_op_*/render_*    — the shared byte-identical SQL impl of the 9 neutral ops
  Store                — the typed store over a `SqlDatabase` backend
  DbValue / DbColumn   — the backend-neutral logical value + column descriptor
  DbRow / DbRows       — the untyped result row / set (re-surfaced PgRow shape)
  Uuid / Timestamptz   — the UUID + TIMESTAMPTZ logical field types
  LOGICAL_*            — the backend-neutral logical-type tags
  to_proto_json / from_proto_json — the nested-field native-JSON serde

It depends on komira_uuid (Uuid), komira_serde (JSON scanner), komira_pg (the
Postgres wire client) and komira_async (the reactor seam), and modifies no
other package.

Encapsulation: no UnsafePointer crosses any public boundary; no wildcard
origins; no unsafe_from_address. The value carriers each hold a single heap
field, so no stale pointer survives a destroy-and-recreate (see the
db_value.mojo / db_row.mojo banners).
"""

from komira_db.db_value import (
    DbValue,
    DbColumn,
    logical_type_name,
    LOGICAL_UUID,
    LOGICAL_TEXT,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_FLOAT8,
    LOGICAL_FLOAT4,
    LOGICAL_BOOL,
    LOGICAL_BYTES,
    LOGICAL_TIMESTAMPTZ,
    LOGICAL_JSONB,
    LOGICAL_TEXT_ARRAY,
)
from komira_db.db_row import DbRow, DbRows
from komira_db.database import Database, SqlDatabase
from komira_db.neutral_ops import (
    Pred,
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
    # The ONE definition of a placement name. A pure
    # function of the job id — see its header for why no producer may add a
    # term it cannot recompute.
    derive_pod_name,
    POD_NAME_ID_TAIL_LEN,
    PRED_EQ,
    PRED_LT,
    PRED_LE,
    PRED_GTE,
    PRED_IS_NULL,
    PRED_IS_NOT_NULL,
    PRED_JSON_KEY_EQ,
    PRED_IN,
    PRED_ARRAY_CONTAINS,
    PRED_NE,
    COMBINE_AND,
    COMBINE_OR,
    COLVAL_BIND,
    COLVAL_RAW_EXPR,
    # The RAW_EXPR classifier every DOCUMENT backend reads.
    # A `col = <literal SQL>` term has to be UNDERSTOOD by a store with no
    # SQL evaluator; one vocabulary here is what stops one backend from
    # honouring a shape the other silently drops.
    RawExprTerm,
    classify_raw_expr,
    raw_expr_refusal,
    RAWEXPR_UNEVALUABLE,
    RAWEXPR_INCREMENT,
    RAWEXPR_LITERAL,
)
from komira_db.sql_neutral_ops import (
    sql_op_get_by_key,
    sql_op_put,
    sql_op_delete_by_key,
    sql_op_query_rows,
    sql_op_query_rows_locked,
    sql_op_conditional_update,
    sql_op_delete_where,
    sql_op_create_if_absent,
    sql_op_create_if_absent_composite,
    sql_op_claim_rows,
    render_get_by_key,
    render_put,
    render_delete_by_key,
    render_query_rows,
    render_query_rows_locked,
    render_conditional_update,
    render_delete_where,
    render_create_if_absent_composite,
    render_where,
    render_order,
)
from komira_db.sqlite_driver import SqliteDatabase
from komira_db.pg_driver import PgDatabase, pg_rows_to_db_rows, to_pg_params
from komira_db.pool import Pool, PooledResource
from komira_db.pg_pool import PgPool
from komira_db.db_storable import (
    DbStorable,
    Store,
    identity_col_index,
    col_index_for,
)
from komira_db.db_schema import DbSchema
from komira_db.migration import Migration, MigrationRunner
from komira_db.db_uuid import Uuid, generate_uuidv7, from_hyphenated
from komira_db.timestamptz import Timestamptz
from komira_db.proto_json import (
    ProtoJsonable,
    to_proto_json,
    from_proto_json,
    json_escape,
)
