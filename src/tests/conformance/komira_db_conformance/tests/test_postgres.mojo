# =============================================================================
# test_postgres.mojo -- komira_db_postgres's PgDatabase: the suites wired, the
#   server-free part run.
# =============================================================================
#
# RUN HERE: the dialect check (dialect() is "pg", placeholder(i) is `$<i+1>`,
# now_expr() is an expression), which needs no server.
#
# NOT RUN HERE: both live suites. PgDatabase speaks to a Postgres server over
# TCP, with TLS 1.3 required and SCRAM-SHA-256 authentication. A build action
# has no network and no Postgres: third_party/ pins no Postgres source, the
# toolchain has no server binary, and no service runs beside the farm. To run
# them, a build action needs a Postgres it starts itself (a pinned server
# built from source, an initdb in the action's scratch directory, a server
# certificate, a listener on a loopback port the action chooses), and the
# test needs that server's PgConfig. `_run_live` below is the call site: it
# is compiled with this file, so the targets keep conforming, and it is the
# only thing left to call once a server exists.
#
# `fresh()` on a server cannot open a new database per check the way the
# in-memory targets do; it drops the conformance tables and recreates the
# neutral ones, so the checks stay isolated as long as one run owns the
# database.
# =============================================================================

from komira_db import DbValue
from komira_db.blocking import db_blocking_execute
from komira_db_postgres import PgDatabase
from komira_db_postgres.wire.connection import PgConfig

from komira_db_conformance import (
    ERR_NO_TABLE,
    ERR_NOT_NULL,
    ERR_SYNTAX,
    ERR_UNIQUE,
    ITEMS,
    KnownGap,
    NeutralTarget,
    PAIRS,
    SQL_TABLE,
    SQL_TABLE_NN,
    SqlTarget,
    TYPES,
    check_dialect_tokens,
    run_neutral_suite,
    run_sql_suite,
)


def _exec(mut db: PgDatabase, sql: String) raises:
    _ = db_blocking_execute(db, sql, List[DbValue]())


def _connect_clean(config: PgConfig) raises -> PgDatabase:
    """A connection with none of the conformance tables."""
    var db = PgDatabase.connect_blocking(config.copy())
    var tables = List[String]()
    tables.append(String(ITEMS))
    tables.append(String(TYPES))
    tables.append(String(PAIRS))
    tables.append(String(SQL_TABLE))
    tables.append(String(SQL_TABLE_NN))
    for i in range(len(tables)):
        _exec(db, String("DROP TABLE IF EXISTS ") + tables[i])
    return db^


struct PgNeutral(NeutralTarget):
    comptime DB = PgDatabase
    var config: PgConfig

    def __init__(out self, var config: PgConfig):
        self.config = config^

    def name(self) -> String:
        return String("komira_db_postgres")

    def fresh(mut self) raises -> PgDatabase:
        var db = _connect_clean(self.config)
        _exec(
            db,
            String(
                "CREATE TABLE conf_items (id TEXT PRIMARY KEY, owner TEXT NOT"
                " NULL, phase TEXT NOT NULL, version BIGINT NOT NULL, note"
                " TEXT, created_at BIGINT NOT NULL, updated_at BIGINT)"
            ),
        )
        _exec(
            db,
            String(
                "CREATE TABLE conf_types (id TEXT PRIMARY KEY, t_text TEXT,"
                " t_int4 INTEGER, t_int8 BIGINT, t_float8 DOUBLE PRECISION,"
                " t_float4 REAL, t_bool BOOLEAN, t_bytes BYTEA, t_uuid UUID,"
                " t_ts TIMESTAMPTZ, t_jsonb JSONB, t_text_array TEXT[])"
            ),
        )
        _exec(
            db,
            String(
                "CREATE TABLE conf_pairs (a TEXT NOT NULL, b TEXT NOT NULL,"
                " v BIGINT, UNIQUE (a, b))"
            ),
        )
        return db^


struct PgSql(SqlTarget):
    comptime DB = PgDatabase
    var config: PgConfig

    def __init__(out self, var config: PgConfig):
        self.config = config^

    def name(self) -> String:
        return String("komira_db_postgres")

    def fresh(mut self) raises -> PgDatabase:
        return _connect_clean(self.config)

    def error_text(self, kind: Int) -> String:
        # Postgres's own message texts (its error message catalogue).
        if kind == ERR_SYNTAX:
            return String("syntax error at or near")
        if kind == ERR_UNIQUE:
            return String("duplicate key value violates unique constraint")
        if kind == ERR_NOT_NULL:
            return String("violates not-null constraint")
        if kind == ERR_NO_TABLE:
            return String("does not exist")
        return String("<unknown error kind>")


def _run_live(config: PgConfig) raises:
    """Both suites against the server `config` names. Not called: see the
    header for what a build action needs before it can be."""
    var neutral = PgNeutral(config.copy())
    run_neutral_suite(neutral, List[KnownGap]())
    var sql = PgSql(config.copy())
    run_sql_suite(sql, List[KnownGap]())


def main() raises:
    check_dialect_tokens[PgSql]()
    print(
        "PASS komira_db_conformance komira_db_postgres: dialect tokens only;"
        " the live suites did NOT run (no Postgres server in a build action)"
    )
