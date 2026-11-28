"""The vocabularies the node tree accepts, as frozen sets of lower-case names.

The operator, function, unit, cast, aggregate, window, join, side and format
sets use the names of the plan wire's enumeration members with the prefix
removed and lower-cased. The grouping sets (keyless and left-only joins,
ranking and offset window functions, predicate operators) and the numeric and
string constants are this package's own.
"""

from __future__ import annotations

COL_SIDES = frozenset({"left", "right"})

COMPARE_OPS = frozenset({"eq", "ne", "lt", "le", "gt", "ge"})
ARITH_OPS = frozenset({"add", "sub", "mul", "div", "mod"})
BOOL_OPS = frozenset({"and", "or"})
UNARY_OPS = frozenset(
    {
        "not",
        "negate",
        "is_null",
        "is_not_null",
        "abs",
        "sign",
        "trunc",
        "round",
        "bit_count",
    }
)
PREDICATE_UNARY_OPS = frozenset({"not", "is_null", "is_not_null"})

STRING_OPS = frozenset({"contains", "starts_with", "ends_with"})
STRING_FNS = frozenset(
    {
        "upper",
        "lower",
        "trim",
        "ltrim",
        "rtrim",
        "length",
        "reverse",
        "ascii",
        "unicode",
        "strlen",
        "bit_length",
        "hex",
        "bin",
        "url_encode",
        "url_decode",
        "regexp_escape",
        "md5",
        "sha1",
        "sha256",
    }
)
STRING_FNS_N = frozenset(
    {
        "concat",
        "concat_ws",
        "replace",
        "lpad",
        "rpad",
        "repeat",
        "strpos",
        "levenshtein",
        "damerau_levenshtein",
        "hamming",
        "translate",
        "jaro",
        "jaro_winkler",
        "jaccard",
    }
)
REGEXP_OPS = frozenset(
    {
        "like",
        "match",
        "replace",
        "extract",
        "split_to_array",
        "extract_all",
        "count",
        "instr",
        "substr",
        "full_match",
    }
)
PREDICATE_REGEXP_OPS = frozenset({"like", "full_match"})

MATH_FNS = frozenset(
    {
        "sin",
        "cos",
        "sqrt",
        "asin",
        "radians",
        "ceil",
        "floor",
        "ln",
        "exp",
        "log10",
        "log2",
        "tan",
        "atan",
        "acos",
        "cot",
        "degrees",
        "cbrt",
        "sinh",
        "cosh",
        "tanh",
        "acosh",
        "asinh",
        "atanh",
        "gamma",
    }
)
MATH_FNS_2 = frozenset({"atan2", "pow"})

EXTRACT_UNITS = frozenset(
    {
        "year",
        "quarter",
        "month",
        "day",
        "hour",
        "minute",
        "second",
        "dayofweek",
        "isodow",
        "dayofyear",
        "week",
        "isoyear",
        "yearweek",
        "millisecond",
        "microsecond",
        "trunc_year",
        "trunc_quarter",
        "trunc_month",
        "trunc_week",
        "trunc_day",
        "trunc_hour",
        "trunc_minute",
        "trunc_second",
        "trunc_millisecond",
        "trunc_microsecond",
    }
)

CAST_TARGETS = frozenset(
    {
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "float16",
        "float32",
        "float64",
    }
)

ARROW_TYPES = frozenset(
    {
        "null",
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "float16",
        "float32",
        "float64",
        "string",
        "binary",
        "date32",
        "date64",
        "timestamp",
        "decimal128",
        "dictionary",
        "list",
        "struct",
        "timestamp_s",
        "timestamp_ms",
        "timestamp_us",
        "timestamp_ns",
        "large_string",
        "large_binary",
        "map",
        "decimal256",
        "time32_s",
        "time32_ms",
        "time64_us",
        "time64_ns",
        "duration_s",
        "duration_ms",
        "duration_us",
        "duration_ns",
        "interval_year_month",
        "interval_day_time",
        "interval_month_day_nano",
        "union_sparse",
        "union_dense",
        "large_list",
        "fixed_size_binary",
        "fixed_size_list",
        "binary_view",
        "utf8_view",
        "list_view",
        "large_list_view",
    }
)

AGG_FUNCS = frozenset(
    {
        "sum",
        "count",
        "min",
        "max",
        "mean",
        "count_distinct",
        "first",
        "last",
        "stddev_samp",
        "corr",
        "median",
        "largest_k",
        "var_samp",
        "covar_pop",
        "covar_samp",
        "regr_avgx",
        "regr_avgy",
        "regr_count",
        "regr_sxx",
        "regr_sxy",
        "regr_syy",
        "regr_slope",
        "regr_intercept",
        "regr_r2",
        "var_pop",
        "stddev_pop",
        "sem",
        "count_if",
        "bool_and",
        "bool_or",
        "product",
        "any_value",
        "kahan_sum",
        "kahan_avg",
        "skewness",
        "kurtosis",
        "kurtosis_pop",
        "quantile_cont",
    }
)
AGG_TWO_ARG = frozenset(
    {
        "quantile_cont",
        "corr",
        "covar_pop",
        "covar_samp",
        "regr_avgx",
        "regr_avgy",
        "regr_count",
        "regr_sxx",
        "regr_sxy",
        "regr_syy",
        "regr_slope",
        "regr_intercept",
        "regr_r2",
    }
)
AGG_ZERO_OR_ONE_ARG = frozenset({"count"})
AGG_K_ARG = frozenset({"largest_k"})

WINDOW_FUNCS = frozenset(
    {
        "row_number",
        "rank",
        "dense_rank",
        "percent_rank",
        "cume_dist",
        "ntile",
        "lag",
        "lead",
        "first_value",
        "last_value",
        "nth_value",
        "sum",
        "avg",
        "count",
        "min",
        "max",
    }
)
WINDOW_RANKING = frozenset(
    {"row_number", "rank", "dense_rank", "percent_rank", "cume_dist", "ntile"}
)
WINDOW_OFFSET = frozenset({"lag", "lead", "nth_value"})
WINDOW_AGGREGATE = frozenset({"sum", "avg", "min", "max"})

FRAME_UNITS = frozenset({"rows", "range"})
FRAME_BOUNDS = frozenset(
    {
        "unbounded_preceding",
        "preceding",
        "current_row",
        "following",
        "unbounded_following",
    }
)

JOIN_HOWS = frozenset({"inner", "left", "right", "full", "semi", "anti", "cross"})
KEYLESS_HOWS = frozenset({"cross"})
LEFT_ONLY_HOWS = frozenset({"semi", "anti"})

SOURCE_FORMATS = frozenset({"parquet", "csv", "ndjson", "json", "orc", "avro", "arrow"})
WRITE_FORMATS = frozenset({"parquet", "csv", "jsonl"})
# The compressions a write target names; the formats that write each are in
# komira/_ops/_rel.py (`WriteTarget`).
WRITE_CODECS = frozenset({"snappy", "uncompressed", "zstd", "gzip", "lz4"})

RIGHT_SUFFIX = "_right"
IN_LIST_MAX = 64

# User functions (komira/python, docs/design/optimized_plan_udfs.md §10.2):
# the call shapes this package captures and encodes, how the code is reached,
# the determinism and null declarations, and the batch format the function is
# called with. The types a column may have are those of
# _dtype.py.
UDF_KINDS = frozenset({"scalar", "map_batches_column", "row", "map_batches_frame"})
UDF_COLUMN_KINDS = frozenset({"scalar", "map_batches_column", "row"})
UDF_READ_SET_KINDS = frozenset({"row", "map_batches_frame"})
UDF_FORMS = frozenset({"package", "bundle"})
UDF_STABILITIES = frozenset({"immutable", "stable", "volatile"})
UDF_NULL_MODES = frozenset({"manual", "propagate"})
UDF_BATCH_FORMATS = frozenset({"values", "arrow"})
