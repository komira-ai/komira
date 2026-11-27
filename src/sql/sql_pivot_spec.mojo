# =============================================================================
# sql/sql_pivot_spec.mojo
#   What the parser read of a `FROM <relation> PIVOT (...)` or
#   `FROM <relation> UNPIVOT (...)` clause, for the binder to lower.
# =============================================================================
#
# A PIVOT or UNPIVOT is parked in the statement's subquery side-table as a
# `SubqueryDef` of kind `SUBQ_PIVOT` or `SUBQ_UNPIVOT` (sql_ast). Its body is
# `SELECT <aggregate> [AS <alias>] FROM <relation>` for a PIVOT and
# `SELECT * FROM <relation>` for an UNPIVOT; this struct holds the rest of the
# clause. `sql_bind_pivot` reads the relation's columns and lowers the clause
# onto a GROUP BY over one `agg(CASE WHEN ...)` per listed value (PIVOT) or a
# UNION ALL of one SELECT per listed column (UNPIVOT).
#
# This module imports nothing from the SQL front end, so sql_ast can hold it
# without a cycle.
# =============================================================================


struct PivotSpec(Copyable, Movable):
    """The parts of a PIVOT or UNPIVOT clause other than its relation and its
    aggregate.

    PIVOT (agg(x) [AS a] FOR col IN (v1 [AS n1], v2, ...)):
      - `name_col` is `col`, the column whose values become columns;
      - `values` holds each listed literal's text as written (a string's
        contents, an integer's digits), and `value_is_string` whether it was
        a string literal;
      - `labels` holds each value's output name: its `AS` name, else its text.

    UNPIVOT [INCLUDE NULLS] (v FOR n IN (c1 [AS l1], c2, ...)):
      - `value_col` is `v` and `name_col` is `n`, the two columns it adds;
      - `values` holds the listed column names;
      - `labels` holds what each one writes into `n`: its `AS` label, else its
        column name;
      - `include_nulls` keeps the rows whose value is NULL.
    """

    var name_col: String
    var value_col: String
    var values: List[String]
    var value_is_string: List[Bool]
    var labels: List[String]
    var include_nulls: Bool

    def __init__(out self):
        self.name_col = String("")
        self.value_col = String("")
        self.values = List[String]()
        self.value_is_string = List[Bool]()
        self.labels = List[String]()
        self.include_nulls = False
