# =============================================================================
# sql/sql_copy_partition.mojo
#   The PARTITION_BY option of COPY ... TO: its column list as the parser
#   reads it, and the result columns it names as the binder resolves them.
# =============================================================================
#
#   COPY (SELECT ...) TO 'out' (FORMAT parquet, PARTITION_BY (year, month))
#
# writes one Hive-style directory per distinct (year, month) of the result,
# as DuckDB does (sdk_exec/engine_write_partitioned.mojo writes them). What is
# accepted, each as the pinned DuckDB (v1.5.6) answers it:
#
#   PARTITION_BY (a, b)     a parenthesised list of one or more names
#   PARTITION_BY a          one name without parentheses
#   PARTITION_BY ('a')      a name may be a quoted string
#
# Refused here, by name, at parse:
#   * an empty list `()` and anything that is not a name (`(a + 1)`): DuckDB
#     raises a parser or binder error for both;
#   * a name listed twice, `(a, a)`: DuckDB v1.5.6 stops with an INTERNAL
#     error, so there is no answer to copy;
#   * the option given twice: DuckDB's `Unexpected duplicate option`.
#
# At bind (`partition_columns_of`), each name must be a column of the query's
# result, matched without regard to case (DuckDB's `Binder Error: "partition_by"
# expected to find c, but it was not found in the table`), and at least one
# result column must be left to write (DuckDB: `No column to write as all
# columns are specified as partition columns`). The directory name takes the
# result column's own spelling: `PARTITION_BY (year)` over a column `Year`
# writes `Year=...`.

from arrow.schema import Schema

from .sql_token import TK_COMMA, TK_IDENT, TK_LPAREN, TK_RPAREN, TK_STRING, Token

comptime COPY_PARTITION_BIND_PREFIX = "SQL bind error: COPY ... PARTITION_BY"
"""The start of every bind refusal of a PARTITION_BY column list."""


def _partition_name(tokens: List[Token], pos: Int) raises -> String:
    """The column name at `tokens[pos]`: an identifier (lower-folded by the
    tokenizer) or a quoted string, as written."""
    ref t = tokens[pos]
    if t.kind != TK_IDENT and t.kind != TK_STRING:
        raise Error(
            "SQL syntax error: COPY option PARTITION_BY expects a column name"
            " or a parenthesised list of column names"
        )
    return t.text


def parse_partition_by(
    tokens: List[Token], mut pos: Int, mut names: List[String]
) raises:
    """Read the value of a PARTITION_BY option starting at `tokens[pos]` into
    `names` and leave `pos` on the token after it: one name, or `(` one or
    more names separated by `,` `)`.

    Raises:
        `SQL syntax error: ...` for an empty list, a token that is not a name,
        or a missing `)`; `SQL not supported: ...` for a name listed twice
        (compared without regard to case). `pos` is left on the token that
        was refused.
    """
    if tokens[pos].kind != TK_LPAREN:
        names.append(_partition_name(tokens, pos))
        pos += 1
        return
    pos += 1
    while True:
        var name = _partition_name(tokens, pos)
        for i in range(len(names)):
            if names[i].lower() == name.lower():
                raise Error(
                    "SQL not supported: COPY ... PARTITION_BY names the column '"
                    + name + "' twice"
                )
        names.append(name^)
        pos += 1
        if tokens[pos].kind == TK_COMMA:
            pos += 1
            continue
        break
    if tokens[pos].kind != TK_RPAREN:
        raise Error("SQL syntax error: expected ')' to close the PARTITION_BY column list")
    pos += 1


def partition_columns_of(names: List[String], schema: Schema) raises -> List[String]:
    """The result columns `names` (a PARTITION_BY list) name in `schema` (the
    COPY query's output), in list order, each spelled as the result spells it:
    the column whose name equals the listed name, else the first whose name
    equals it without regard to case.

    Raises:
        `SQL bind error: COPY ... PARTITION_BY names column '<n>', which is not
        a column of the query's result (<columns>)`; or `SQL bind error: COPY
        ... PARTITION_BY names every column of the result (<columns>): no
        column is left to write in the files` when the list covers them all.
    """
    var out = List[String]()
    var columns = String("")
    for c in range(schema.num_columns()):
        if c > 0:
            columns += ", "
        columns += schema.field_name(c)
    for i in range(len(names)):
        var found = -1
        for c in range(schema.num_columns()):
            if schema.field_name(c) == names[i]:
                found = c
                break
        if found < 0:
            for c in range(schema.num_columns()):
                if schema.field_name(c).lower() == names[i].lower():
                    found = c
                    break
        if found < 0:
            raise Error(
                String(COPY_PARTITION_BIND_PREFIX) + " names column '" + names[i]
                + "', which is not a column of the query's result (" + columns + ")"
            )
        out.append(schema.field_name(found))
    if len(out) >= schema.num_columns():
        raise Error(
            String(COPY_PARTITION_BIND_PREFIX) + " names every column of the result ("
            + columns + "): no column is left to write in the files"
        )
    return out^
