# =============================================================================
# null_order_policy.mojo — THE ENGINE'S DEFAULT NULL PLACEMENT, STATED ONCE
# =============================================================================
#
# ⭐⭐ ONE FUNCTION, ONE LINE OF POLICY, AND THAT IS THE ENTIRE REASON THIS FILE
# EXISTS. A default-placement rule spelled EXECUTABLY at many sites across
# packages — the plan resolver, EXPLAIN, and every sort kernel — looks like:
#
#   PLAN     `logical_plan_variants._resolve_nulls_first`     the derived list
#   PLAN     `physical_plan.is_explicit_nulls_first_request`  what counts as a REQUEST
#   PLAN     `plan_display._write_sort_nulls`                 whether EXPLAIN renders it
#   KERNEL   `sort_topn_sink._sort_batch_single_key`          numeric single key
#   KERNEL   `sort_string.sort_indices_string`                string/binary single key
#   KERNEL   `sort_multi.sort_batch_by_keys`                  the K-pass ladder
#   KERNEL   `unified/parallel_dictrank_sort`   ⛔ no placement argument
#   KERNEL   `unified/parallel_column_sort` string merge cmp  ⛔ no placement argument
#   KERNEL   `unified/parallel_column_sort` prefix-radix      ⛔ no placement argument
#   GATE     `komira_sdk_exec/subquery_executor`              the bounded-route decline
#   FRONTEND `komira_sdk/sql_binder`                          ⭐ THE TWELFTH — see below
#   SKIN     `python/komira/_ops.py:engine_nulls_first`       the python-side mirror
#
# Spelled inline (`not descending[i]`, `not desc`), each site is a separate,
# silent opportunity to disagree with the others; and three take NO placement
# argument at all, so nothing above them could correct a disagreement — a
# policy change that edited only the plan resolver would leave those three
# answering the OLD default, i.e. THE SAME QUERY ANSWERING DIFFERENTLY
# DEPENDING ON ROW COUNT AND WORKER COUNT.
#
# ⛔⛔ A GREP CANNOT FIND EVERY COPY. `sql_binder` fills in the placement for an
# ORDER BY key that carries no clause when a SIBLING key does, and a third
# spelling (`not ok.descending`) escapes a grep for the other two. ⇒ THE LAST
# COPY OF A DUPLICATED POLICY IS THE ONE THAT SPELLS IT DIFFERENTLY. That is
# the argument for this file.
#
# ⛔ SO DO NOT RE-SPELL `not descending[i]` ANYWHERE. Call this. The whole
# argument for the file is that the policy has exactly one definition, and the
# cost of that being false is a wrong `ORDER BY` that no single test can see.
#
# ============================= THE POLICY ====================================
#
# ★ NULLS LAST IN BOTH DIRECTIONS, matching DuckDB and Arrow. MEASURED, not
#   recalled:
#
#     duckdb 1.5.3    SELECT current_setting('default_null_order') -> NULLS_LAST
#                     ORDER BY v      over [30,NULL,10,NULL,50,20]
#                       -> 10, 20, 30, 50, NULL, NULL
#                     ORDER BY v DESC -> 50, 30, 20, 10, NULL, NULL
#     pyarrow 24.0.0  pc.array_sort_indices(a, order="ascending")  -> nulls END
#                     pc.array_sort_indices(a, order="descending") -> nulls END
#
#   The alternative rule *"a NULL compares SMALLEST"* — SQLite's and MySQL's
#   convention, and the opposite of PostgreSQL's *"a NULL compares LARGEST"* —
#   agrees with DuckDB and Arrow on DESC and disagrees on ASC, so HALF of every
#   ORDER BY would match, which makes the divergence easy to miss.
#
# ⚠ THE ARGUMENT TAKES THE `descending` FLAG EVEN THOUGH IT IGNORES IT, AND THAT
#   IS DELIBERATE. The placement is ALLOWED to depend on the direction —
#   PostgreSQL's does (NULLS LAST on ASC, FIRST on DESC). Keeping the parameter
#   means a future policy change is a change to THIS FUNCTION and not a
#   re-plumbing of every call site, and it keeps every call site honest
#   about which direction it is asking about.
#
# ⛔ THIS IS THE **DEFAULT**, NOT THE ANSWER. An explicit per-key request (SQL
#   `NULLS FIRST` / `NULLS LAST`) is carried on
#   `SortData.nulls_first` / `TopNData.nulls_first` and used VERBATIM; this
#   function is consulted only where nobody asked. `physical_plan.
#   is_explicit_nulls_first_request` is the predicate that tells the two apart,
#   and it is written against THIS function rather than against a literal — which
#   is why no decline gate in the engine depends on the default.
#
# ⛔ NOT NaN. NaN placement is a DIFFERENT question and
#   this function says nothing about it. A NaN is a VALUE with a validity bit of
#   1; a NULL has no value at all.
# =============================================================================


# ⚠ `def`, NOT `fn` — Mojo 1.0.0 REMOVED `fn` ('error: \'fn\' has been removed;
# use \'def\' instead'). `@always_inline` still applies, which is what keeps a
# constant-returning policy call free at the per-comparison sites.
@always_inline
def derived_nulls_first(descending: Bool) -> Bool:
    """Where the engine puts NULLs for `descending` when NOBODY ASKED.

    Args:
        descending: The sort direction of the key in question. Ignored TODAY —
            the policy is NULLS LAST in both directions — and taken anyway
            because the policy is allowed to depend on it (see the file header).

    Returns:
        True to place this key's NULLs BEFORE every valid value, False to place
        them AFTER. Currently always False.
    """
    return False
