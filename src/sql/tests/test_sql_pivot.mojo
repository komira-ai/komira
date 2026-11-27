# =============================================================================
# sql: `FROM <relation> PIVOT (...)` and `FROM <relation> UNPIVOT (...)`
# =============================================================================
#
# Every query binds through `plan_from_sql` against a catalog of parquet tables
# registered with a given schema (no file is opened). A result schema is
# written `name:type`, a DECIMAL128 with `(precision,scale)`, and `?` when
# nullable; the names and types are DuckDB's for the same SQL (DuckDB's
# HUGEINT sum is DECIMAL(38,0) here, as for any sum of integers). The rows
# these plans give are held to DuckDB's by the conformance corpus
# `pivot_unpivot` (src/tests/conformance/komira_sql_conformance). What each
# test proves:
#   * test_pivot_gives_one_column_per_listed_value: the group columns in the
#     relation's order, then one column per IN value, in the list's order,
#     named by the value.
#   * test_pivot_names_follow_the_value_and_aggregate_aliases: `'pen' AS p`
#     names a column `p`; an aggregate alias `total` names it `<value>_total`;
#     an integer value names its column by its digits.
#   * test_pivot_groups_by_every_column_it_does_not_name: count(*) names no
#     column, so `amount` is a group column; an aggregate over an arithmetic,
#     a function call or a CASE names the columns inside it; a relation with
#     no other column gives the whole-relation aggregate.
#   * test_pivot_aggregates_keep_their_types: avg is DOUBLE, max of a DOUBLE
#     DOUBLE, count a BIGINT that is never NULL, count(x) over a string
#     served, count(DISTINCT x) over a BIGINT served.
#   * test_pivot_relation_answers_to_its_alias: an aliased PIVOT is qualified
#     by its alias, an unaliased one by `__unnamed_pivot`, and it joins.
#   * test_pivot_cells_are_conditional_aggregates: the plan is one aggregate
#     over the relation, each cell a CASE on the FOR column.
#   * test_unpivot_keeps_other_columns_then_name_then_value: the columns not
#     listed in the relation's order, then the name column (VARCHAR), then the
#     value column of the listed columns' type; `AS` labels serve.
#   * test_unpivot_leaves_out_nulls_unless_include_nulls: one branch per
#     listed column, each filtered on its column IS NOT NULL, none with
#     INCLUDE NULLS, as with the default EXCLUDE NULLS.
#   * test_pivot_and_unpivot_chain_and_read_derived_tables: a PIVOT of a
#     derived table, an UNPIVOT of a PIVOT.
#   * test_wrong_columns_are_refused_by_name: an unknown FOR column, value
#     column and UNPIVOT column, and a qualified column inside the aggregate.
#   * test_a_text_or_narrow_pivot_value_is_refused_by_name: max over a
#     VARCHAR, sum over a DECIMAL and an INTEGER, count(DISTINCT) over a
#     VARCHAR.
#   * test_pivot_value_forms_outside_the_served_set_are_refused: a value that
#     is not an aggregate, a statistical aggregate, two aggregates, a FOR list,
#     two FOR columns, a non-literal IN entry, an empty IN list, a repeated
#     value, an output column named twice.
#   * test_unpivot_forms_outside_the_served_set_are_refused: columns of two
#     types, two value columns, a literal IN entry, an output column named
#     twice, INCLUDE without NULLS.
#   * test_pivot_statement_and_misplaced_clauses_are_refused_by_name: the
#     `PIVOT t ON c USING ...` and `UNPIVOT t ON ...` statements (and
#     `pivot_wider` / `pivot_longer`), a PIVOT after a WHERE, a missing name
#     after AS.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_ir.schema_propagation import infer_schema

from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_catalog import SqlCatalog
from sql.sql_frontend import plan_from_sql


def _add(mut cat: SqlCatalog, name: String, var fields: List[Field]):
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i])
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """sales(region, product VARCHAR, amount BIGINT);
    wide(region, product VARCHAR, price DOUBLE, qty INTEGER,
    cost DECIMAL(12,2), note VARCHAR, amount BIGINT);
    qs(y INTEGER, q BIGINT, v BIGINT);
    scores(name VARCHAR, q1, q2, q3 BIGINT, note VARCHAR, f DOUBLE)."""
    var cat = SqlCatalog()
    _add(cat, "sales", [
        Field(String("region"), ArrowType.STRING, True),
        Field(String("product"), ArrowType.STRING, True),
        Field(String("amount"), ArrowType.INT64, True),
    ])
    _add(cat, "wide", [
        Field(String("region"), ArrowType.STRING, True),
        Field(String("product"), ArrowType.STRING, True),
        Field(String("price"), ArrowType.FLOAT64, True),
        Field(String("qty"), ArrowType.INT32, True),
        Field.decimal128(String("cost"), 12, 2, True),
        Field(String("note"), ArrowType.STRING, True),
        Field(String("amount"), ArrowType.INT64, True),
    ])
    _add(cat, "qs", [
        Field(String("y"), ArrowType.INT32, True),
        Field(String("q"), ArrowType.INT64, True),
        Field(String("v"), ArrowType.INT64, True),
    ])
    _add(cat, "scores", [
        Field(String("name"), ArrowType.STRING, True),
        Field(String("q1"), ArrowType.INT64, True),
        Field(String("q2"), ArrowType.INT64, True),
        Field(String("q3"), ArrowType.INT64, True),
        Field(String("note"), ArrowType.STRING, True),
        Field(String("f"), ArrowType.FLOAT64, True),
    ])
    return cat^


def _render(schema: Schema) -> String:
    """`name:type[(p,s)][?]` per column, joined by `, `."""
    var out = String("")
    for c in range(schema.num_columns()):
        if c > 0:
            out += ", "
        out += schema.field_name(c) + ":" + String(schema.field_arrow_type(c))
        if schema.field_arrow_type(c) == ArrowType.DECIMAL128:
            out += (
                "("
                + String(schema.field_decimal_precision(c))
                + ","
                + String(schema.field_decimal_scale(c))
                + ")"
            )
        if schema.field_nullable(c):
            out += "?"
    return out


def _schema_of(sql: String) raises -> String:
    """The rendered result schema of `sql`, after checking that
    `infer_schema` re-derives the same one from the plan."""
    var cat = _catalog()
    var plan = plan_from_sql(sql, cat, NoParquetFooters())
    var carried = _render(plan.output_schema)
    assert_equal(_render(infer_schema(plan)), carried, sql)
    return carried


def _plan_text(sql: String) raises -> String:
    var cat = _catalog()
    return String(plan_from_sql(sql, cat, NoParquetFooters()))


def _count(text: String, sub: String) -> Int:
    """How many times `sub` occurs in `text`, not overlapping."""
    var n = 0
    var at = text.find(sub)
    while at >= 0:
        n += 1
        at = text.find(sub, at + sub.byte_length())
    return n


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = plan_from_sql(sql, cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def _refused(sql: String, want: String) raises:
    """`sql` is refused with a message that holds `want`."""
    var got = _err(sql)
    assert_true(want in got, sql + "\n  got: " + got + "\n  want: " + want)


comptime _SUM = ":decimal128(38,0)?"


def test_pivot_gives_one_column_per_listed_value() raises:
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))"
        ),
        "region:string?, pen" + _SUM + ", ink" + _SUM,
    )
    # The list's order, not the data's or the alphabet's.
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink', 'cap'))"
        ),
        "region:string?, pen" + _SUM + ", ink" + _SUM + ", cap" + _SUM,
    )


def test_pivot_names_follow_the_value_and_aggregate_aliases() raises:
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(amount) AS total FOR product IN"
            " ('pen' AS p, 'ink'))"
        ),
        "region:string?, p_total" + _SUM + ", ink_total" + _SUM,
    )
    assert_equal(
        _schema_of("SELECT * FROM qs PIVOT (sum(v) FOR q IN (1, 2, 3))"),
        "y:int32?, 1" + _SUM + ", 2" + _SUM + ", 3" + _SUM,
    )
    # A string label after AS, as DuckDB takes either spelling.
    assert_equal(
        _schema_of("SELECT * FROM qs PIVOT (sum(v) FOR q IN (1 AS 'One'))"),
        "y:int32?, One" + _SUM,
    )


def test_pivot_groups_by_every_column_it_does_not_name() raises:
    assert_equal(
        _schema_of("SELECT * FROM sales PIVOT (count(*) FOR product IN ('pen', 'ink'))"),
        "region:string?, amount:int64?, pen:int64, ink:int64",
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(amount * 2) FOR product IN ('pen'))"
        ),
        "region:string?, pen" + _SUM,
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(abs(amount)) FOR product IN ('pen'))"
        ),
        "region:string?, pen" + _SUM,
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(CASE WHEN amount IS NOT NULL THEN"
            " amount ELSE 0 END) FOR product IN ('pen'))"
        ),
        "region:string?, pen" + _SUM,
    )
    # Every column named: one row over the whole relation.
    assert_equal(
        _schema_of(
            "SELECT * FROM (SELECT product, amount FROM sales) PIVOT (sum(amount)"
            " FOR product IN ('pen', 'ink'))"
        ),
        "pen" + _SUM + ", ink" + _SUM,
    )
    assert_true(
        "group_by=[]" in _plan_text(
            "SELECT * FROM (SELECT product, amount FROM sales) PIVOT"
            " (sum(amount) FOR product IN ('pen'))"
        )
    )


def test_pivot_aggregates_keep_their_types() raises:
    assert_equal(
        _schema_of("SELECT * FROM sales PIVOT (avg(amount) FOR product IN ('pen'))"),
        "region:string?, pen:float64?",
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM (SELECT region, product, price FROM wide) PIVOT"
            " (max(price) FOR product IN ('pen'))"
        ),
        "region:string?, pen:float64?",
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM (SELECT region, product, amount FROM wide) PIVOT"
            " (min(amount) FOR product IN ('pen'))"
        ),
        "region:string?, pen:int64?",
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM (SELECT region, product, note FROM wide) PIVOT"
            " (count(note) FOR product IN ('pen'))"
        ),
        "region:string?, pen:int64",
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (count(DISTINCT amount) FOR product IN ('pen'))"
        ),
        "region:string?, pen:int64",
    )


def test_pivot_relation_answers_to_its_alias() raises:
    assert_equal(
        _schema_of(
            "SELECT p.pen FROM sales PIVOT (sum(amount) FOR product IN ('pen')) AS p"
        ),
        "pen" + _SUM,
    )
    assert_equal(
        _schema_of(
            "SELECT p.pen FROM sales PIVOT (sum(amount) FOR product IN ('pen')) p"
        ),
        "pen" + _SUM,
    )
    assert_equal(
        _schema_of(
            "SELECT __unnamed_pivot.ink FROM sales PIVOT (sum(amount) FOR"
            " product IN ('ink'))"
        ),
        "ink" + _SUM,
    )
    assert_equal(
        _schema_of(
            "SELECT p.region, p.pen, s.amount FROM sales PIVOT (sum(amount) FOR"
            " product IN ('pen')) p JOIN sales s ON p.region = s.region"
        ),
        "region:string?, pen" + _SUM + ", amount:int64?",
    )


def test_pivot_cells_are_conditional_aggregates() raises:
    var text = _plan_text(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))"
    )
    assert_equal(_count(text, "Aggregate("), 1, text)
    assert_equal(_count(text, "Scan("), 1, text)
    assert_equal(_count(text, "Union("), 0, text)
    # One CASE per listed value, each on the FOR column.
    assert_equal(_count(text, "When("), 2, text)


def test_unpivot_keeps_other_columns_then_name_then_value() raises:
    assert_equal(
        _schema_of(
            "SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1, q2, q3))"
        ),
        "name:string?, note:string?, f:float64?, quarter:string, score:int64?",
    )
    assert_equal(
        _schema_of(
            "SELECT quarter FROM scores UNPIVOT (score FOR quarter IN"
            " (q1 AS 'first', q2 AS second)) AS u WHERE u.score > 6"
        ),
        "quarter:string",
    )
    # A text column unpivots as well as a number does.
    assert_equal(
        _schema_of("SELECT * FROM scores UNPIVOT (txt FOR k IN (name, note))"),
        "q1:int64?, q2:int64?, q3:int64?, f:float64?, k:string, txt:string?",
    )


def test_unpivot_leaves_out_nulls_unless_include_nulls() raises:
    var excluded = _plan_text(
        "SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1, q2, q3))"
    )
    assert_equal(_count(excluded, "Union(branches=3)"), 1, excluded)
    assert_equal(_count(excluded, "Filter("), 3, excluded)
    var included = _plan_text(
        "SELECT * FROM scores UNPIVOT INCLUDE NULLS (score FOR quarter IN"
        " (q1, q2, q3))"
    )
    assert_equal(_count(included, "Union(branches=3)"), 1, included)
    assert_equal(_count(included, "Filter("), 0, included)
    var said = _plan_text(
        "SELECT * FROM scores UNPIVOT EXCLUDE NULLS (score FOR quarter IN (q1, q2))"
    )
    assert_equal(_count(said, "Union(branches=2)"), 1, said)
    assert_equal(_count(said, "Filter("), 2, said)
    # One column: no union, one filter.
    var one = _plan_text(
        "SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1))"
    )
    assert_equal(_count(one, "Union("), 0, one)
    assert_equal(_count(one, "Filter("), 1, one)


def test_pivot_and_unpivot_chain_and_read_derived_tables() raises:
    assert_equal(
        _schema_of(
            "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))"
            " UNPIVOT (v FOR p IN (pen, ink))"
        ),
        "region:string?, p:string, v" + _SUM,
    )
    assert_equal(
        _schema_of(
            "SELECT * FROM (SELECT region AS r, product, amount FROM sales"
            " WHERE amount > 1) d PIVOT (max(amount) FOR product IN ('pen'))"
        ),
        "r:string?, pen:int64?",
    )


def test_wrong_columns_are_refused_by_name() raises:
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR productx IN ('pen'))",
        "SQL bind error: PIVOT names the column `productx`, which the relation"
        " it reshapes does not have (its columns: region, product, amount)",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amountx) FOR product IN ('pen'))",
        "amountx",
    )
    _refused(
        "SELECT * FROM sales PIVOT (count(amountx) FOR product IN ('pen'))",
        "amountx",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1, qx))",
        "SQL bind error: UNPIVOT names the column `qx`, which the relation it"
        " reshapes does not have (its columns: name, q1, q2, q3, note, f)",
    )
    _refused(
        "SELECT * FROM sales s PIVOT (sum(s.amount) FOR product IN ('pen'))",
        "SQL bind error: a PIVOT aggregate names the qualified column"
        " `s.amount`",
    )


def test_a_text_or_narrow_pivot_value_is_refused_by_name() raises:
    comptime want = "SQL not supported: PIVOT over a value that is neither BIGINT nor DOUBLE"
    _refused(
        "SELECT * FROM sales PIVOT (max(region) FOR product IN ('pen'))", want
    )
    _refused(
        "SELECT * FROM (SELECT region, product, cost FROM wide) PIVOT"
        " (sum(cost) FOR product IN ('pen'))",
        want,
    )
    _refused(
        "SELECT * FROM (SELECT region, product, qty FROM wide) PIVOT"
        " (sum(qty) FOR product IN ('pen'))",
        want,
    )
    _refused(
        "SELECT * FROM (SELECT product, note FROM wide) PIVOT"
        " (count(DISTINCT note) FOR product IN ('pen'))",
        want,
    )


def test_pivot_value_forms_outside_the_served_set_are_refused() raises:
    _refused(
        "SELECT * FROM sales PIVOT (amount FOR product IN ('pen'))",
        "SQL bind error: a PIVOT value must be one aggregate call",
    )
    _refused(
        "SELECT * FROM sales PIVOT (median(amount) FOR product IN ('pen'))",
        "SQL not supported: PIVOT over the aggregate `median`",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount), max(amount) FOR product IN ('pen'))",
        "SQL not supported: PIVOT with more than one aggregate",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR (product, region) IN (('pen', 'east')))",
        "SQL not supported: PIVOT FOR a list of columns",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen') region IN ('east'))",
        "SQL not supported: PIVOT over more than one FOR column",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN (1.5))",
        "SQL not supported: a PIVOT IN list entry that is not a string or an"
        " unsigned integer literal",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ())",
        "SQL syntax error: the PIVOT IN list is empty",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'pen'))",
        "SQL bind error: the value 'pen' is listed more than once in the PIVOT"
        " IN list",
    )
    _refused(
        "SELECT * FROM qs PIVOT (sum(v) FOR q IN (1, 1))",
        "SQL bind error: the value 1 is listed more than once in the PIVOT IN"
        " list",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('region'))",
        "SQL not supported: PIVOT gives two output columns named `region`",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen' AS x, 'ink' AS x))",
        "SQL not supported: PIVOT gives two output columns named `x`",
    )


def test_unpivot_forms_outside_the_served_set_are_refused() raises:
    _refused(
        "SELECT * FROM scores UNPIVOT (v FOR k IN (q1, note))",
        "SQL not supported: UNPIVOT over columns of different types (`q1`"
        " int64, `note` string)",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT (v FOR k IN (q1, f))",
        "SQL not supported: UNPIVOT over columns of different types",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT ((a, b) FOR k IN ((q1, q2)))",
        "SQL not supported: UNPIVOT into more than one value column",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT (v FOR k IN ('q1'))",
        "SQL not supported: an UNPIVOT IN list entry that is not a column name",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT (v FOR name IN (q1))",
        "SQL not supported: UNPIVOT gives two output columns named `name`",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT INCLUDE (v FOR k IN (q1))",
        "SQL syntax error: expected keyword 'nulls'",
    )
    _refused(
        "SELECT * FROM scores UNPIVOT (1 FOR k IN (q1))",
        "SQL syntax error: expected the UNPIVOT value column name",
    )


def test_pivot_statement_and_misplaced_clauses_are_refused_by_name() raises:
    _refused(
        "PIVOT sales ON product USING sum(amount)",
        "SQL not supported: the PIVOT statement (`PIVOT t ON c USING agg(x)`)",
    )
    _refused(
        "PIVOT_WIDER sales ON product USING sum(amount)",
        "SQL not supported: the PIVOT statement",
    )
    _refused(
        "UNPIVOT scores ON q1, q2 INTO NAME quarter VALUE score",
        "SQL not supported: the UNPIVOT statement",
    )
    _refused(
        "PIVOT_LONGER scores ON q1, q2 INTO NAME quarter VALUE score",
        "SQL not supported: the UNPIVOT statement",
    )
    _refused(
        "SELECT * FROM sales WHERE amount > 1 PIVOT (sum(amount) FOR product IN ('pen'))",
        "SQL not supported: PIVOT here. It is served directly after one FROM"
        " relation",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) AS FOR product IN ('pen'))",
        "SQL syntax error: expected alias after AS",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen' AS 1))",
        "SQL syntax error: expected a name after AS in an IN list",
    )
    _refused(
        "SELECT * FROM sales PIVOT (sum(amount) FOR 1 IN ('pen'))",
        "SQL syntax error: expected a column name after FOR",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
