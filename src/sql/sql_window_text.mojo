# =============================================================================
# sql/sql_window_text.mojo
#   The printed form of a window function `f(...) OVER (...)`: the name
#   DuckDB gives an unaliased SELECT item holding one, and the hidden column a
#   window nested in an expression is computed under.
# =============================================================================
#
# DuckDB v1.5.5 prints a window the way it was written, lower-cased, with the
# OVER clause after it (measured):
#
#   sum(n) OVER (PARTITION BY g)
#   row_number() OVER (PARTITION BY g ORDER BY k DESC)
#   count() OVER ()                          COUNT(*) prints no argument
#   lag(n, 2, 0) OVER (ORDER BY k)           offset and DEFAULT as written
#   avg(t.n) OVER (PARTITION BY t.g)         qualifiers kept
#   sum(n) OVER (ORDER BY k DESC NULLS FIRST, g)
#   sum(n) OVER (ORDER BY k ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
#   sum(n) OVER (ORDER BY k)                 a written `RANGE BETWEEN UNBOUNDED
#                                            PRECEDING AND CURRENT ROW`, the
#                                            default frame, is not printed
#
# Not byte-exact with DuckDB, because the parsed window does not record the
# spelling: a written `ASC` is not printed, a written LAG / LEAD offset of 1
# with no DEFAULT is not printed (`lag(n, 1)` prints `lag(n)`), a NULL DEFAULT
# is not printed, and `mean` prints `avg`. Each of these spells the same
# window, so the name still says what the column holds.

from sql.sql_ast import (
    SXFRAME_CURRENT_ROW, SXFRAME_FOLLOWING, SXFRAME_PRECEDING, SXFRAME_RANGE,
    SXFRAME_UNBOUNDED_FOLLOWING, SXFRAME_UNBOUNDED_PRECEDING,
    SXWIN_AVG, SXWIN_COUNT, SXWIN_CUME_DIST, SXWIN_DENSE_RANK, SXWIN_FIRST_VALUE,
    SXWIN_LAG, SXWIN_LAST_VALUE, SXWIN_LEAD, SXWIN_MAX, SXWIN_MIN, SXWIN_NTH_VALUE,
    SXWIN_NTILE, SXWIN_PERCENT_RANK, SXWIN_RANK, SXWIN_ROW_NUMBER, SXWIN_SUM,
    SX_DATE, SX_FLOAT, SX_STRING, SqlExpr, SqlWindowData,
)


# The prefix of the hidden column a nested window is computed under. No
# column the binder or a table names starts with it and a space.
comptime WINDOW_HIDDEN_PREFIX = "__window "


def _win_func_name(func: UInt8) -> String:
    """The lower-case name DuckDB prints for a SXWIN_* function."""
    if func == SXWIN_ROW_NUMBER:
        return String("row_number")
    if func == SXWIN_RANK:
        return String("rank")
    if func == SXWIN_DENSE_RANK:
        return String("dense_rank")
    if func == SXWIN_SUM:
        return String("sum")
    if func == SXWIN_COUNT:
        return String("count")
    if func == SXWIN_MIN:
        return String("min")
    if func == SXWIN_MAX:
        return String("max")
    if func == SXWIN_AVG:
        return String("avg")
    if func == SXWIN_LAG:
        return String("lag")
    if func == SXWIN_LEAD:
        return String("lead")
    if func == SXWIN_FIRST_VALUE:
        return String("first_value")
    if func == SXWIN_LAST_VALUE:
        return String("last_value")
    if func == SXWIN_NTH_VALUE:
        return String("nth_value")
    if func == SXWIN_PERCENT_RANK:
        return String("percent_rank")
    if func == SXWIN_CUME_DIST:
        return String("cume_dist")
    # SXWIN_NTILE, the last code the parser builds.
    return String("ntile")


def _qualified(qual: String, name: String) -> String:
    if qual != "":
        return qual + "." + name
    return String(name)


def _frame_bound(tag: UInt8, offset: Int64) -> String:
    if tag == SXFRAME_UNBOUNDED_PRECEDING:
        return String("UNBOUNDED PRECEDING")
    if tag == SXFRAME_PRECEDING:
        return String(offset) + " PRECEDING"
    if tag == SXFRAME_CURRENT_ROW:
        return String("CURRENT ROW")
    if tag == SXFRAME_FOLLOWING:
        return String(offset) + " FOLLOWING"
    return String("UNBOUNDED FOLLOWING")


def _hex_bytes(text: String) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("x'")
    for b in text.as_bytes():
        var v = Int(b)
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out + "'"


def _default_text(w: SqlWindowData, exact: Bool) -> String:
    """The LAG / LEAD DEFAULT literal as DuckDB prints it. With `exact` a
    string is spelled by its bytes: column names compare case-insensitively,
    and `'A'` and `'a'` are two different defaults."""
    if w.default_kind == SX_FLOAT:
        return String(w.default_float)
    if w.default_kind == SX_STRING:
        if exact:
            return _hex_bytes(w.default_text)
        return "'" + w.default_text + "'"
    if w.default_kind == SX_DATE:
        return "CAST('" + w.default_text + "' AS \"DATE\")"
    return String(w.default_int)


def _window_spelling(w: SqlWindowData, exact: Bool) -> String:
    """`f(args) OVER (...)`. With `exact`, every field the parse recorded is
    printed, the default frame and a LAG / LEAD offset of 1 included, so two
    windows print alike only when they are the same window."""
    var out = _win_func_name(w.func) + "("
    var is_lag_lead = w.func == SXWIN_LAG or w.func == SXWIN_LEAD
    if w.arg_col != "":
        out += _qualified(w.arg_qual, w.arg_col)
        if is_lag_lead:
            if exact or w.has_default or w.value_offset != 1:
                out += ", " + String(w.value_offset)
            if w.has_default:
                out += ", " + _default_text(w, exact)
        elif w.func == SXWIN_NTH_VALUE:
            out += ", " + String(w.value_offset)
    elif w.func == SXWIN_NTILE:
        out += String(w.value_offset)
    out += ") OVER ("
    var parts = List[String]()
    if len(w.partition_by) > 0:
        var p = String("PARTITION BY ")
        for i in range(len(w.partition_by)):
            if i > 0:
                p += ", "
            p += _qualified(w.partition_qual[i], w.partition_by[i])
        parts.append(p^)
    if len(w.order_by) > 0:
        var o = String("ORDER BY ")
        for i in range(len(w.order_by)):
            if i > 0:
                o += ", "
            o += _qualified(w.order_qual[i], w.order_by[i])
            if w.descending[i]:
                o += " DESC"
            if w.nulls_first[i]:
                o += " NULLS FIRST" if w.nulls_first[i].value() else " NULLS LAST"
        parts.append(o^)
    var default_frame = (
        w.frame_units == SXFRAME_RANGE
        and w.frame_start_tag == SXFRAME_UNBOUNDED_PRECEDING
        and w.frame_end_tag == SXFRAME_CURRENT_ROW
    )
    if w.has_frame and (exact or not default_frame):
        var f = String("RANGE") if w.frame_units == SXFRAME_RANGE else String("ROWS")
        f += " BETWEEN " + _frame_bound(w.frame_start_tag, w.frame_start_offset)
        f += " AND " + _frame_bound(w.frame_end_tag, w.frame_end_offset)
        parts.append(f^)
    for i in range(len(parts)):
        if i > 0:
            out += " "
        out += parts[i]
    out += ")"
    return out^


def window_duckdb_text(sx: SqlExpr) -> String:
    """The name DuckDB gives a window function `sx` (an SX_WINDOW node)."""
    return _window_spelling(sx._window.value(), False)


def window_hidden_name(sx: SqlExpr) -> String:
    """The hidden column a window nested in an expression is computed under:
    the prefix and the window's exact spelling, so one window written twice in
    a SELECT is computed once and two different windows never share a
    column."""
    return String(WINDOW_HIDDEN_PREFIX) + _window_spelling(sx._window.value(), True)
