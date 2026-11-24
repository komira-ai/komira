# =============================================================================
# The deepest nesting the SQL parser follows
# =============================================================================
#
# The parser recurses once per nested construct on the caller's thread, so a
# statement nested without bound would exhaust that thread's stack. The parser
# counts each nested construct as one level and refuses the level past
# `MAX_SQL_NESTING`. One level is one parenthesised expression, one function
# call or CASE, one prefix `NOT`, `+`, `-` or `@`, one `IN ( ... )` list, and
# one subquery or derived table. Chains a loop builds (`a + b + c`, `a AND b`,
# an IN list's items, a UNION chain) are not levels.
#
# Why 100 and not DuckDB's 1000: one level takes about 25 KB of the parser's
# stack for a parenthesised expression and about 35 KB for a subquery, so 1000
# levels do not fit in the 8 MiB a host's query thread has (a Linux main
# thread, the Node addon's session thread). 100 levels take at most about
# 3.5 MiB and leave the rest to the binder, the optimizer and the run.

comptime MAX_SQL_NESTING: Int = 100
"""The most levels of nesting one statement may have."""


def enter_sql_nesting(mut depth: Int) raises:
    """Count one more level of nesting in `depth`; raise when that is past
    `MAX_SQL_NESTING`. The caller subtracts one from `depth` when it leaves the
    level."""
    depth += 1
    if depth > MAX_SQL_NESTING:
        raise Error(
            "SQL syntax error: the statement nests deeper than "
            + String(MAX_SQL_NESTING) + " levels"
        )
