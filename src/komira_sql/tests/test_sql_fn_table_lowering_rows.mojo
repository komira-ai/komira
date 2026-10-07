# =============================================================================
# Row pins: every LOWERING row of sql_scalar_fn_spec, one call per spelling
# =============================================================================
#
# What it proves: each of the 191 spellings on the table's 160 lowering rows
# (every kind except FNK_REFUSED) resolves to its row's kind, op and
# inclusive arity, claims the name (`lowers_to_a_node` True) and carries no
# reason. Every alias of a row is called, so every `name == ...` operand of
# every `or` chain is taken once (and every earlier operand is seen False).
# Mutants it catches: a row moved to another kind or op (for example
# `strlen` read as STRFN_LENGTH, or DSG_COALESCE and DSG_IFNULL swapped), an
# arity widened or narrowed, an alias dropped from a row or moved to another
# row, a lowering constructor that stops setting `lowers_to_a_node`.
# The expectations were generated from the rows; a
# deliberate row change edits its line here in the same commit.

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_DIV,
    BIN_MOD,
    BIN_MUL,
    BIN_SUB,
    EXTRACT_DAY,
    EXTRACT_DAYOFWEEK,
    EXTRACT_DAYOFYEAR,
    EXTRACT_HOUR,
    EXTRACT_ISODOW,
    EXTRACT_ISOYEAR,
    EXTRACT_MICROSECOND,
    EXTRACT_MILLISECOND,
    EXTRACT_MINUTE,
    EXTRACT_MONTH,
    EXTRACT_QUARTER,
    EXTRACT_SECOND,
    EXTRACT_WEEK,
    EXTRACT_YEAR,
    EXTRACT_YEARWEEK,
    MATH2_ATAN2,
    MATH2_POW,
    MATH_ACOS,
    MATH_ACOSH,
    MATH_ASIN,
    MATH_ASINH,
    MATH_ATAN,
    MATH_ATANH,
    MATH_CBRT,
    MATH_CEIL,
    MATH_COS,
    MATH_COSH,
    MATH_COT,
    MATH_DEGREES,
    MATH_EXP,
    MATH_FLOOR,
    MATH_GAMMA,
    MATH_LN,
    MATH_LOG10,
    MATH_LOG2,
    MATH_RADIANS,
    MATH_SIN,
    MATH_SINH,
    MATH_SQRT,
    MATH_TAN,
    MATH_TANH,
    REGEXP_EXTRACT,
    REGEXP_EXTRACT_ALL,
    REGEXP_FULL_MATCH,
    REGEXP_LIKE,
    REGEXP_REPLACE,
    REGEXP_SPLIT_TO_ARRAY,
    STRFNN_CONCAT,
    STRFNN_CONCAT_WS,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
    STRFNN_JACCARD,
    STRFNN_JARO,
    STRFNN_JARO_WINKLER,
    STRFNN_LEVENSHTEIN,
    STRFNN_LPAD,
    STRFNN_REPEAT,
    STRFNN_REPLACE,
    STRFNN_RPAD,
    STRFNN_STRPOS,
    STRFNN_TRANSLATE,
    STRFN_ASCII,
    STRFN_BIN,
    STRFN_BIT_LENGTH,
    STRFN_HEX,
    STRFN_LENGTH,
    STRFN_LOWER,
    STRFN_LTRIM,
    STRFN_MD5,
    STRFN_REGEXP_ESCAPE,
    STRFN_REVERSE,
    STRFN_RTRIM,
    STRFN_SHA1,
    STRFN_SHA256,
    STRFN_STRLEN,
    STRFN_TRIM,
    STRFN_UNICODE,
    STRFN_UPPER,
    STRFN_URL_DECODE,
    STRFN_URL_ENCODE,
    STR_CONTAINS,
    STR_ENDS_WITH,
    STR_STARTS_WITH,
    UN_ABS,
    UN_BIT_COUNT,
    UN_ROUND,
    UN_SIGN,
    UN_TRUNC,
)
from komira_sql.sql_fn_table import (
    CAST_DESUGAR_NAME,
    CONST_FALSE,
    CONST_INT_ZERO,
    CONST_TRUE,
    CONST_USER,
    DSG_CAST,
    DSG_CENTURY,
    DSG_COALESCE,
    DSG_DATE_DIFF,
    DSG_DATE_PART,
    DSG_DATE_SUB,
    DSG_DATE_TRUNC,
    DSG_DAYS_IN_MONTH,
    DSG_DECADE,
    DSG_ERA,
    DSG_EVEN,
    DSG_FDIV,
    DSG_FMOD,
    DSG_GREATEST,
    DSG_IFNULL,
    DSG_ISFINITE,
    DSG_ISINF,
    DSG_ISNAN,
    DSG_JSON_EXTRACT,
    DSG_JSON_EXTRACT_TEXT,
    DSG_LEAST,
    DSG_LEFT,
    DSG_MAKE_TS_MS,
    DSG_MAKE_TS_NS,
    DSG_MAKE_TS_US,
    DSG_MAP_EXTRACT_VALUE,
    DSG_MILLENNIUM,
    DSG_NANOSECOND,
    DSG_NULLIF,
    DSG_PI,
    DSG_RIGHT,
    DSG_STRING_SPLIT,
    DSG_STRUCT_EXTRACT,
    DSG_STRUCT_EXTRACT_AT,
    DSG_SUBSTRING,
    DSG_TRY_CAST,
    FNK_BINARY_OP,
    FNK_CONST,
    FNK_DESUGAR,
    FNK_EXTRACT_FIELD,
    FNK_MATH_FN,
    FNK_MATH_FN2,
    FNK_REGEXP,
    FNK_STRING_FN,
    FNK_STRING_FN_N,
    FNK_STRING_PRED,
    FNK_UNARY_NUM,
    FN_ARITY_OWN,
    FN_ARITY_UNBOUNDED,
    POSITION_IN_DESUGAR_NAME,
    TRY_CAST_DESUGAR_NAME,
    sql_scalar_fn_spec,
)


def _lowers(name: String, kind: UInt8, op: UInt8, lo: Int, hi: Int) raises:
    var s = sql_scalar_fn_spec(name)
    assert_equal(Int(s.kind), Int(kind), name)
    assert_equal(Int(s.op), Int(op), name)
    assert_equal(s.min_args, lo, name)
    assert_equal(s.max_args, hi, name)
    assert_true(s.lowers_to_a_node, name)
    assert_equal(s.reason, String(""), name)


def test_lowering_rows_1() raises:
    _lowers("upper", FNK_STRING_FN, STRFN_UPPER, 1, 1)
    _lowers("ucase", FNK_STRING_FN, STRFN_UPPER, 1, 1)
    _lowers("lower", FNK_STRING_FN, STRFN_LOWER, 1, 1)
    _lowers("lcase", FNK_STRING_FN, STRFN_LOWER, 1, 1)
    _lowers("trim", FNK_STRING_FN, STRFN_TRIM, 1, 1)
    _lowers("ltrim", FNK_STRING_FN, STRFN_LTRIM, 1, 1)
    _lowers("rtrim", FNK_STRING_FN, STRFN_RTRIM, 1, 1)
    _lowers("length", FNK_STRING_FN, STRFN_LENGTH, 1, 1)
    _lowers("len", FNK_STRING_FN, STRFN_LENGTH, 1, 1)
    _lowers("char_length", FNK_STRING_FN, STRFN_LENGTH, 1, 1)
    _lowers("character_length", FNK_STRING_FN, STRFN_LENGTH, 1, 1)
    _lowers("reverse", FNK_STRING_FN, STRFN_REVERSE, 1, 1)
    _lowers("ascii", FNK_STRING_FN, STRFN_ASCII, 1, 1)
    _lowers("unicode", FNK_STRING_FN, STRFN_UNICODE, 1, 1)
    _lowers("ord", FNK_STRING_FN, STRFN_UNICODE, 1, 1)
    _lowers("strlen", FNK_STRING_FN, STRFN_STRLEN, 1, 1)
    _lowers("bit_length", FNK_STRING_FN, STRFN_BIT_LENGTH, 1, 1)
    _lowers("hex", FNK_STRING_FN, STRFN_HEX, 1, 1)
    _lowers("to_hex", FNK_STRING_FN, STRFN_HEX, 1, 1)
    _lowers("bin", FNK_STRING_FN, STRFN_BIN, 1, 1)
    _lowers("to_binary", FNK_STRING_FN, STRFN_BIN, 1, 1)
    _lowers("url_encode", FNK_STRING_FN, STRFN_URL_ENCODE, 1, 1)
    _lowers("url_decode", FNK_STRING_FN, STRFN_URL_DECODE, 1, 1)
    _lowers("regexp_escape", FNK_STRING_FN, STRFN_REGEXP_ESCAPE, 1, 1)
    _lowers("md5", FNK_STRING_FN, STRFN_MD5, 1, 1)
    _lowers("sha1", FNK_STRING_FN, STRFN_SHA1, 1, 1)
    _lowers("sha256", FNK_STRING_FN, STRFN_SHA256, 1, 1)
    _lowers("sin", FNK_MATH_FN, MATH_SIN, 1, 1)
    _lowers("cos", FNK_MATH_FN, MATH_COS, 1, 1)
    _lowers("sqrt", FNK_MATH_FN, MATH_SQRT, 1, 1)
    _lowers("asin", FNK_MATH_FN, MATH_ASIN, 1, 1)
    _lowers("radians", FNK_MATH_FN, MATH_RADIANS, 1, 1)
    _lowers("ceil", FNK_MATH_FN, MATH_CEIL, 1, 1)
    _lowers("ceiling", FNK_MATH_FN, MATH_CEIL, 1, 1)
    _lowers("floor", FNK_MATH_FN, MATH_FLOOR, 1, 1)
    _lowers("ln", FNK_MATH_FN, MATH_LN, 1, 1)
    _lowers("exp", FNK_MATH_FN, MATH_EXP, 1, 1)
    _lowers("log10", FNK_MATH_FN, MATH_LOG10, 1, 1)
    _lowers("log", FNK_MATH_FN, MATH_LOG10, 1, 1)
    _lowers("log2", FNK_MATH_FN, MATH_LOG2, 1, 1)
    _lowers("tan", FNK_MATH_FN, MATH_TAN, 1, 1)
    _lowers("atan", FNK_MATH_FN, MATH_ATAN, 1, 1)
    _lowers("acos", FNK_MATH_FN, MATH_ACOS, 1, 1)
    _lowers("cot", FNK_MATH_FN, MATH_COT, 1, 1)
    _lowers("degrees", FNK_MATH_FN, MATH_DEGREES, 1, 1)
    _lowers("cbrt", FNK_MATH_FN, MATH_CBRT, 1, 1)
    _lowers("sinh", FNK_MATH_FN, MATH_SINH, 1, 1)
    _lowers("cosh", FNK_MATH_FN, MATH_COSH, 1, 1)
    _lowers("tanh", FNK_MATH_FN, MATH_TANH, 1, 1)
    _lowers("acosh", FNK_MATH_FN, MATH_ACOSH, 1, 1)


def test_lowering_rows_2() raises:
    _lowers("asinh", FNK_MATH_FN, MATH_ASINH, 1, 1)
    _lowers("atanh", FNK_MATH_FN, MATH_ATANH, 1, 1)
    _lowers("gamma", FNK_MATH_FN, MATH_GAMMA, 1, 1)
    _lowers("atan2", FNK_MATH_FN2, MATH2_ATAN2, 2, 2)
    _lowers("pow", FNK_MATH_FN2, MATH2_POW, 2, 2)
    _lowers("power", FNK_MATH_FN2, MATH2_POW, 2, 2)
    _lowers("abs", FNK_UNARY_NUM, UN_ABS, 1, 1)
    _lowers("sign", FNK_UNARY_NUM, UN_SIGN, 1, 1)
    _lowers("trunc", FNK_UNARY_NUM, UN_TRUNC, 1, 1)
    _lowers("round", FNK_UNARY_NUM, UN_ROUND, 1, 1)
    _lowers("bit_count", FNK_UNARY_NUM, UN_BIT_COUNT, 1, 1)
    _lowers("add", FNK_BINARY_OP, BIN_ADD, 1, 2)
    _lowers("subtract", FNK_BINARY_OP, BIN_SUB, 1, 2)
    _lowers("multiply", FNK_BINARY_OP, BIN_MUL, 2, 2)
    _lowers("divide", FNK_BINARY_OP, BIN_DIV, 2, 2)
    _lowers("mod", FNK_BINARY_OP, BIN_MOD, 2, 2)
    _lowers("century", FNK_DESUGAR, DSG_CENTURY, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("decade", FNK_DESUGAR, DSG_DECADE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("millennium", FNK_DESUGAR, DSG_MILLENNIUM, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("era", FNK_DESUGAR, DSG_ERA, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("nanosecond", FNK_DESUGAR, DSG_NANOSECOND, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("isfinite", FNK_DESUGAR, DSG_ISFINITE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("isinf", FNK_DESUGAR, DSG_ISINF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("isnan", FNK_DESUGAR, DSG_ISNAN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("string_split", FNK_DESUGAR, DSG_STRING_SPLIT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("str_split", FNK_DESUGAR, DSG_STRING_SPLIT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("string_to_array", FNK_DESUGAR, DSG_STRING_SPLIT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("split", FNK_DESUGAR, DSG_STRING_SPLIT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("json_extract", FNK_DESUGAR, DSG_JSON_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("json_extract_path", FNK_DESUGAR, DSG_JSON_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("json_extract_string", FNK_DESUGAR, DSG_JSON_EXTRACT_TEXT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("json_extract_path_text", FNK_DESUGAR, DSG_JSON_EXTRACT_TEXT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("struct_extract", FNK_DESUGAR, DSG_STRUCT_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("struct_extract_at", FNK_DESUGAR, DSG_STRUCT_EXTRACT_AT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("map_extract_value", FNK_DESUGAR, DSG_MAP_EXTRACT_VALUE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("date_sub", FNK_DESUGAR, DSG_DATE_SUB, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("datesub", FNK_DESUGAR, DSG_DATE_SUB, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("even", FNK_DESUGAR, DSG_EVEN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("fdiv", FNK_DESUGAR, DSG_FDIV, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("fmod", FNK_DESUGAR, DSG_FMOD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("nullif", FNK_DESUGAR, DSG_NULLIF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("days_in_month", FNK_DESUGAR, DSG_DAYS_IN_MONTH, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers(CAST_DESUGAR_NAME, FNK_DESUGAR, DSG_CAST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers(TRY_CAST_DESUGAR_NAME, FNK_DESUGAR, DSG_TRY_CAST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers(POSITION_IN_DESUGAR_NAME, FNK_STRING_FN_N, STRFNN_STRPOS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("contains", FNK_STRING_PRED, STR_CONTAINS, 2, 2)
    _lowers("starts_with", FNK_STRING_PRED, STR_STARTS_WITH, 2, 2)
    _lowers("prefix", FNK_STRING_PRED, STR_STARTS_WITH, 2, 2)
    _lowers("ends_with", FNK_STRING_PRED, STR_ENDS_WITH, 2, 2)
    _lowers("suffix", FNK_STRING_PRED, STR_ENDS_WITH, 2, 2)


def test_lowering_rows_3() raises:
    _lowers("concat", FNK_STRING_FN_N, STRFNN_CONCAT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("concat_ws", FNK_STRING_FN_N, STRFNN_CONCAT_WS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("replace", FNK_STRING_FN_N, STRFNN_REPLACE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("lpad", FNK_STRING_FN_N, STRFNN_LPAD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("rpad", FNK_STRING_FN_N, STRFNN_RPAD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("repeat", FNK_STRING_FN_N, STRFNN_REPEAT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("strpos", FNK_STRING_FN_N, STRFNN_STRPOS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("instr", FNK_STRING_FN_N, STRFNN_STRPOS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("levenshtein", FNK_STRING_FN_N, STRFNN_LEVENSHTEIN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("editdist3", FNK_STRING_FN_N, STRFNN_LEVENSHTEIN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("damerau_levenshtein", FNK_STRING_FN_N, STRFNN_DAMERAU_LEVENSHTEIN, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("hamming", FNK_STRING_FN_N, STRFNN_HAMMING, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("mismatches", FNK_STRING_FN_N, STRFNN_HAMMING, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("translate", FNK_STRING_FN_N, STRFNN_TRANSLATE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("jaro_similarity", FNK_STRING_FN_N, STRFNN_JARO, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("jaro_winkler_similarity", FNK_STRING_FN_N, STRFNN_JARO_WINKLER, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("jaccard", FNK_STRING_FN_N, STRFNN_JACCARD, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("regexp_matches", FNK_REGEXP, REGEXP_LIKE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("regexp_full_match", FNK_REGEXP, REGEXP_FULL_MATCH, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("regexp_replace", FNK_REGEXP, REGEXP_REPLACE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("regexp_extract", FNK_REGEXP, REGEXP_EXTRACT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("regexp_extract_all", FNK_REGEXP, REGEXP_EXTRACT_ALL, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("regexp_split_to_array", FNK_REGEXP, REGEXP_SPLIT_TO_ARRAY, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("str_split_regex", FNK_REGEXP, REGEXP_SPLIT_TO_ARRAY, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("string_split_regex", FNK_REGEXP, REGEXP_SPLIT_TO_ARRAY, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("year", FNK_EXTRACT_FIELD, EXTRACT_YEAR, 1, 1)
    _lowers("quarter", FNK_EXTRACT_FIELD, EXTRACT_QUARTER, 1, 1)
    _lowers("month", FNK_EXTRACT_FIELD, EXTRACT_MONTH, 1, 1)
    _lowers("day", FNK_EXTRACT_FIELD, EXTRACT_DAY, 1, 1)
    _lowers("dayofmonth", FNK_EXTRACT_FIELD, EXTRACT_DAY, 1, 1)
    _lowers("hour", FNK_EXTRACT_FIELD, EXTRACT_HOUR, 1, 1)
    _lowers("minute", FNK_EXTRACT_FIELD, EXTRACT_MINUTE, 1, 1)
    _lowers("second", FNK_EXTRACT_FIELD, EXTRACT_SECOND, 1, 1)
    _lowers("dayofweek", FNK_EXTRACT_FIELD, EXTRACT_DAYOFWEEK, 1, 1)
    _lowers("weekday", FNK_EXTRACT_FIELD, EXTRACT_DAYOFWEEK, 1, 1)
    _lowers("isodow", FNK_EXTRACT_FIELD, EXTRACT_ISODOW, 1, 1)
    _lowers("dayofyear", FNK_EXTRACT_FIELD, EXTRACT_DAYOFYEAR, 1, 1)
    _lowers("week", FNK_EXTRACT_FIELD, EXTRACT_WEEK, 1, 1)
    _lowers("weekofyear", FNK_EXTRACT_FIELD, EXTRACT_WEEK, 1, 1)
    _lowers("isoyear", FNK_EXTRACT_FIELD, EXTRACT_ISOYEAR, 1, 1)
    _lowers("yearweek", FNK_EXTRACT_FIELD, EXTRACT_YEARWEEK, 1, 1)
    _lowers("millisecond", FNK_EXTRACT_FIELD, EXTRACT_MILLISECOND, 1, 1)
    _lowers("microsecond", FNK_EXTRACT_FIELD, EXTRACT_MICROSECOND, 1, 1)
    _lowers("date_diff", FNK_DESUGAR, DSG_DATE_DIFF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("datediff", FNK_DESUGAR, DSG_DATE_DIFF, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("coalesce", FNK_DESUGAR, DSG_COALESCE, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("ifnull", FNK_DESUGAR, DSG_IFNULL, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("greatest", FNK_DESUGAR, DSG_GREATEST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("least", FNK_DESUGAR, DSG_LEAST, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("date_part", FNK_DESUGAR, DSG_DATE_PART, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)


def test_lowering_rows_4() raises:
    _lowers("datepart", FNK_DESUGAR, DSG_DATE_PART, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("date_trunc", FNK_DESUGAR, DSG_DATE_TRUNC, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("datetrunc", FNK_DESUGAR, DSG_DATE_TRUNC, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("left", FNK_DESUGAR, DSG_LEFT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("right", FNK_DESUGAR, DSG_RIGHT, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("substring", FNK_DESUGAR, DSG_SUBSTRING, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("substr", FNK_DESUGAR, DSG_SUBSTRING, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("pi", FNK_DESUGAR, DSG_PI, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("pg_collation_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_conversion_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_function_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_opclass_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_operator_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_opfamily_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_table_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_ts_config_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_ts_dict_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_ts_parser_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_ts_template_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_type_is_visible", FNK_CONST, CONST_TRUE, 1, 1)
    _lowers("pg_is_other_temp_schema", FNK_CONST, CONST_FALSE, 1, 1)
    _lowers("has_any_column_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_database_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_foreign_data_wrapper_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_function_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_language_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_schema_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_sequence_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_server_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_table_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_tablespace_privilege", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("pg_has_role", FNK_CONST, CONST_TRUE, 2, 3)
    _lowers("has_column_privilege", FNK_CONST, CONST_TRUE, 3, 4)
    _lowers("current_user", FNK_CONST, CONST_USER, 0, 0)
    _lowers("session_user", FNK_CONST, CONST_USER, 0, 0)
    _lowers("current_role", FNK_CONST, CONST_USER, 0, 0)
    _lowers("user", FNK_CONST, CONST_USER, 0, 0)
    _lowers("pg_my_temp_schema", FNK_CONST, CONST_INT_ZERO, 0, 0)
    _lowers("make_timestamp", FNK_DESUGAR, DSG_MAKE_TS_US, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("make_timestamp_ms", FNK_DESUGAR, DSG_MAKE_TS_MS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)
    _lowers("make_timestamp_ns", FNK_DESUGAR, DSG_MAKE_TS_NS, FN_ARITY_OWN, FN_ARITY_UNBOUNDED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
