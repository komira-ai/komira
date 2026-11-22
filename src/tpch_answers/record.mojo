# The answers DuckDB gives to the TPC-H corpus queries, as recorded references
# (bench_duckdb's reference text): per query the row count, the ORDER BY keys
# and the order-independent signature of every column, with its declared type.

from bench_corpus import TPCH_NOTICE, Suite
from bench_duckdb import (
    DuckDbSession,
    DuckDbTransport,
    ReferenceAnswer,
    check_order,
    format_reference,
    signature_of,
)

from .keys import tpch_order_keys


def _double_quoted(text: String) -> String:
    return String('"') + text.replace(String('"'), String('""')) + String('"')


def _single_quoted(text: String) -> String:
    return String("'") + text.replace(String("'"), String("''")) + String("'")


def register_tables[T: DuckDbTransport](
    mut session: DuckDbSession[T], names: List[String], paths: List[String]
) raises:
    """One view per table, named as the queries name it, over its Parquet
    file. `names` and `paths` are parallel lists."""
    if len(names) != len(paths):
        raise Error("register_tables: one path per table name")
    for i in range(len(names)):
        var sql = (
            String("CREATE OR REPLACE VIEW ")
            + _double_quoted(names[i])
            + String(" AS SELECT * FROM read_parquet(")
            + _single_quoted(paths[i])
            + String(")")
        )
        var t = session.run_timed(sql)
        if not t.ok():
            raise Error(String("duckdb cannot register ") + names[i] + String(": ") + t.error)


def record_answers[T: DuckDbTransport](
    mut session: DuckDbSession[T], suite: Suite, header: String
) raises -> String:
    """The recorded answers of every query of `suite`, in the suite's order,
    after `header` (comment lines, each starting with `#`, which the reader of
    a recorded text skips).

    Each query is run once and its rows are checked against the query's ORDER
    BY keys before they are summarised, so a key table that does not match the
    query text fails here, not in a consumer.

    Raises:
        Error: a query DuckDB refuses (the message names the query and carries
            DuckDB's text), a query that returns no rows, a result whose rows are not in the
            order of the query's keys, a column with no recordable form, or a query id the
            key table does not know.
    """
    var out = header.copy()
    if out.byte_length() > 0 and not out.endswith(String("\n")):
        out += String("\n")
    for i in range(len(suite.queries)):
        ref q = suite.queries[i]
        var fetched = session.fetch(q.text)
        if not fetched.ok():
            raise Error(String("duckdb refused ") + q.key() + String(": ") + fetched.error)
        if fetched.rows.row_count() == 0:
            raise Error(
                q.key() + String(" returned no rows: an answer with no rows records no columns, so it would check nothing;")
                + String(" the staged data is not the data these queries are for")
            )
        var keys = tpch_order_keys(q.id)
        var verdict = check_order(fetched.rows, keys)
        if not verdict.ok:
            raise Error(q.key() + String(" came back from duckdb out of its order: ") + verdict.label())
        var answer = ReferenceAnswer(q.key())
        answer.signature = signature_of(fetched.rows)
        answer.order = keys^
        out += format_reference(answer)
    return out^


def tpch_header(suite: Suite, duckdb_version: String, lock_fingerprint: String) -> String:
    """The comment lines at the top of the answers file: the fair-use notice,
    the digest of the query texts, the DuckDB release that answered and the
    fingerprint of the data lock whose files it answered over."""
    return (
        String("# ") + String(TPCH_NOTICE) + String("\n")
        + String("# suite ") + suite.id + String(" sha256 ") + suite.sha256() + String("\n")
        + String("# duckdb ") + duckdb_version + String("\n")
        + String("# data lock fingerprint ") + lock_fingerprint + String("\n")
    )
