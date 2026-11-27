"""Each corpus's tables as Parquet, written by the pinned DuckDB (README.md, "The tables as Parquet").

`corpus_tables(name, tables_sql, tables)` runs `tables_sql` (a corpus's
tables.sql) and then an export, `<name>_export_sql`, that writes every table
it created as `<table>.parquet`: the `sql_oracle` target `<name>`, one
sub-target `[<table>.parquet]` per table. A runner registers those files, so
no runner executes CREATE TABLE. The export fails the action, naming both
lists, unless the tables tables.sql created are exactly `tables`, so a table
added to a corpus without its line here is never left out.

`CORPUS_TABLES` names the tables of each corpus of cases/, the outputs
sql_oracle must know before it runs.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/sql:defs.bzl", "sql_oracle")

CORPUS_TABLES = {
    "agg_exact_floats": ["T"],
    "agg_float_ungrouped": ["V", "X"],
    "aggregate_modifiers": ["T"],
    "aggregate_names": ["N"],
    "bind_controls": ["T", "U", "D"],
    "cast_boundaries": ["T"],
    "conditional_exprs": ["T"],
    "cross_binary": ["t_full"],
    "cross_bool": ["t_full", "t_single", "t_nulls", "t_allnull", "t_empty"],
    "cross_date32": ["t_full"],
    "cross_decimal128_12_2": ["t_full", "t_single", "t_nulls", "t_allnull", "t_empty"],
    "cross_dictionary_string": ["t_full"],
    "cross_float32": ["t_full"],
    "cross_float64": ["t_full"],
    "cross_int16": ["t_full"],
    "cross_int32": ["t_full"],
    "cross_int64": ["t_full", "t_single", "t_nulls", "t_allnull", "t_empty"],
    "cross_int8": ["t_full"],
    "cross_large_string": ["t_full"],
    "cross_string": ["t_full", "t_single", "t_nulls", "t_allnull", "t_empty"],
    "cross_timestamp_ms": ["t_full"],
    "cross_timestamp_us": ["t_full", "t_single", "t_nulls", "t_allnull", "t_empty"],
    "cross_timestamp_us_utc": ["t_full"],
    "cross_uint64": ["t_full"],
    "cross_uint8": ["t_full"],
    "fn_positions": ["T", "U"],
    "fn_postagg_positions": ["T", "U"],
    "join_shapes": ["L", "R", "K", "M", "E", "F", "G", "S", "S2", "D", "D2", "MK", "MK2"],
    "null_adversarial_n005": ["T"],
    "null_adversarial_n006": ["T"],
    "null_adversarial_n007": ["T"],
    "null_adversarial_n008": ["T"],
    "null_adversarial_n009": ["T"],
    "null_adversarial_n012": ["T"],
    "null_adversarial_n015": ["T"],
    "null_adversarial_n016": ["T"],
    "null_adversarial_n017": ["T"],
    "null_adversarial_n023": ["T"],
    "null_adversarial_n024": ["T"],
    "null_adversarial_n031": ["T"],
    "null_adversarial_n032": ["T"],
    "null_adversarial_n033": ["T"],
    "null_adversarial_n063": ["T"],
    "null_adversarial_n064": ["T"],
    "null_adversarial_n065": ["T"],
    "null_adversarial_n095": ["T"],
    "null_adversarial_n096": ["T"],
    "null_adversarial_n127": ["T"],
    "null_adversarial_n128": ["T"],
    "null_adversarial_n129": ["T"],
    "null_adversarial_n191": ["T"],
    "null_adversarial_n192": ["T"],
    "null_adversarial_n193": ["T"],
    "null_adversarial_n255": ["T"],
    "null_adversarial_n256": ["T"],
    "null_adversarial_n257": ["T"],
    "null_pattern_n005": ["T"],
    "null_pattern_n006": ["T"],
    "null_pattern_n007": ["T"],
    "null_pattern_n008": ["T"],
    "null_pattern_n009": ["T"],
    "null_pattern_n012": ["T"],
    "null_pattern_n013": ["T"],
    "null_pattern_n015": ["T"],
    "null_pattern_n016": ["T"],
    "null_pattern_n017": ["T"],
    "null_pattern_n024": ["T"],
    "null_pattern_n025": ["T"],
    "null_pattern_n063": ["T"],
    "null_pattern_n064": ["T"],
    "null_pattern_n065": ["T"],
    "null_pattern_n127": ["T"],
    "null_pattern_n128": ["T"],
    "null_pattern_n129": ["T"],
    "numeric_domain": ["T"],
    "numeric_envelope": ["t"],
    "ops_controls": ["T", "U", "C", "B"],
    "order_by_limit": ["T", "U"],
    "pivot_unpivot": ["SALES", "P", "Q", "W", "EMPTY"],
    "predicates_three_valued": ["T", "S"],
    "range_frames": ["R", "Q"],
    "scalar_fn": ["T", "E"],
    "set_operations": ["ta", "tb", "te", "tn", "tv", "ab", "ae", "an", "abn"],
    "string_domain": ["T"],
    "subquery_cte": ["T", "U"],
    "surface_limits": ["fx_nulls", "fx_nullvsempty", "fx_empty", "fx_allnull", "fx_boolcol", "fx_weirdstr", "fx_nanfloat", "fx_typed", "fx_bigint", "fx_oddnames", "fx_nation", "fx_lineitem"],
    "temporal_domain": ["T", "N", "DXIN", "PMS", "PUS", "PNS"],
    "union_all": ["A", "B", "EMPTY"],
    "window_frames": ["F", "T"],
}

# A table name: an identifier the export spells unquoted in a file name and
# quoted in SQL, so it can hold no quote.
_TABLE = "^[A-Za-z_][A-Za-z0-9_]*$"

def _sql_list(names):
    return "[" + ", ".join(["'{}'".format(n) for n in names]) + "]"

def _export_sql_impl(ctx):
    where = str(ctx.label.raw_target())
    if not ctx.attrs.tables:
        fail("{}: tables is empty: name the tables tables.sql creates".format(where))
    for t in ctx.attrs.tables:
        if not regex_match(_TABLE, t):
            fail("{}: table {} is not an identifier ({})".format(where, repr(t), _TABLE))
    lines = [
        "-- Written by tables.bzl for {}: every table tables.sql created, as <table>.parquet.".format(where),
        "SELECT error('corpus tables: tables.sql creates ' || coalesce((SELECT string_agg(table_name, ', ' ORDER BY table_name) FROM duckdb_tables()), 'no table') || ', and tables.bzl lists {}')".format(", ".join(sorted(ctx.attrs.tables))),
        "WHERE (SELECT list_sort(list(table_name)) FROM duckdb_tables()) IS DISTINCT FROM list_sort({});".format(_sql_list(ctx.attrs.tables)),
    ] + [
        "COPY \"{t}\" TO '{t}.parquet' (FORMAT parquet);".format(t = t)
        for t in ctx.attrs.tables
    ]
    out = ctx.actions.write("export.sql", "\n".join(lines) + "\n")
    return [DefaultInfo(default_output = out)]

_export_sql = rule(
    impl = _export_sql_impl,
    doc = "The SQL that writes each of `tables` (identifiers) as <table>.parquet, after failing unless the session's tables are exactly those: export.sql, for corpus_tables.",
    attrs = {"tables": attrs.list(attrs.string())},
)

def check_corpora(corpora):
    """Fails analysis unless CORPUS_TABLES names exactly the corpora of cases/ (`corpora`)."""
    other = sorted([c for c in corpora if c not in CORPUS_TABLES] + [c for c in CORPUS_TABLES if c not in corpora])
    if other:
        fail("tables.bzl: CORPUS_TABLES and cases/ differ on the corpora {}: name each corpus's tables in CORPUS_TABLES".format(", ".join(other)))

def _corpus_tables(name, tables_sql, tables, visibility = None):
    _export_sql(name = name + "_export_sql", tables = tables)
    sql_oracle(
        name = name,
        srcs = [tables_sql, ":" + name + "_export_sql"],
        outputs = [t + ".parquet" for t in tables],
        visibility = visibility,
    )

corpus_tables = declares_docs(_corpus_tables)
