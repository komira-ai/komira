# =============================================================================
# sql/sql_frontend.mojo
#   SQL text to a bound statement or a query plan, without running anything.
# =============================================================================
#
# The front end's entry points: tokenize, parse and bind in one call.
#
#   var catalog = SqlCatalog()
#   catalog.add_parquet("t", "t.parquet", schema^)
#   var plan = plan_from_sql("SELECT k, sum(v) FROM t GROUP BY k", catalog,
#                            NoParquetFooters())
#   # plan.output_schema is the result's schema; nothing has been read.
#
# `statement_from_sql` serves every statement kind (a query, `COPY ... TO`,
# `CREATE TABLE ... AS`) and returns the `BoundStatement` that says which.
# `plan_from_sql` serves a query only and refuses a write statement by name
# (`STATEMENT_NOT_A_QUERY`), through `query_plan`, which `sdk_exec.engine_sql`'s
# `run_sql` calls on its own bound statement too, so both refuse a write in the
# same words.
#
# Every failure raises an `Error` whose text is the failing step's own message,
# unchanged: `SQL syntax error ...` or `SQL not supported ...` from the
# tokenizer and parser, `SQL bind error ...` or `SQL not supported ...` from the
# binder, and `STATEMENT_NOT_A_QUERY: ...` from `plan_from_sql`.

from plan_ir.logical_plan import LogicalPlan
from sql.sql_ast import STMT_QUERY
from sql.sql_bind_parquet import SqlParquetFooters
from sql.sql_binder import BoundStatement, bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize

comptime STATEMENT_NOT_A_QUERY = "STATEMENT_NOT_A_QUERY"
"""Refusal: the statement is a `COPY ... TO` or a `CREATE TABLE ... AS`, which
binds to a write, where a query plan was asked for."""


def statement_from_sql[P: SqlParquetFooters](
    sql: String, catalog: SqlCatalog, footers: P
) raises -> BoundStatement:
    """Tokenize, parse and bind `sql` against `catalog`.

    `footers` reads the schema and null counts of every Parquet file the
    statement names (a `read_parquet` relation); pass `NoParquetFooters()` when
    the catalog's tables carry their schemas and no `read_parquet` is expected.

    Returns the `BoundStatement`: its `kind` is `STMT_QUERY`, `STMT_COPY` or
    `STMT_CREATE_TABLE_AS`, and its plan is the query or the write's source.

    Raises the tokenizer's, parser's or binder's own `Error` unchanged.
    """
    return bind_statement(parse_sql(tokenize(sql)), catalog, footers)


def query_plan(var bound: BoundStatement) raises -> LogicalPlan:
    """The query plan of `bound`, or the `STATEMENT_NOT_A_QUERY` refusal when
    `bound` is a `COPY ... TO` or a `CREATE TABLE ... AS`."""
    if bound.kind != STMT_QUERY:
        raise Error(
            String(STATEMENT_NOT_A_QUERY)
            + ": only a query has a query plan; COPY and CREATE TABLE AS"
            " bind to a write, which is not served yet"
        )
    return bound.take_plan()


def plan_from_sql[P: SqlParquetFooters](
    sql: String, catalog: SqlCatalog, footers: P
) raises -> LogicalPlan:
    """Tokenize, parse and bind the query `sql` against `catalog` and return
    its plan; the plan's `output_schema` is the result's schema.

    Raises what `statement_from_sql` raises, and `STATEMENT_NOT_A_QUERY` when
    `sql` is a `COPY ... TO` or a `CREATE TABLE ... AS`.
    """
    return query_plan(statement_from_sql(sql, catalog, footers))
