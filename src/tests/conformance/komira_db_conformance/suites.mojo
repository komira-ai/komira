# =============================================================================
# komira_db_conformance/suites.mojo -- the two suites: every check, run in a
#   fixed order against one target, then gated on the target's known gaps.
# =============================================================================
#
# A check that raises is recorded as failed with its message, and the run goes
# on, so one report names every failure (report.mojo). Check names are the
# function names without `check_`; type round trips are `type_<type>` and SQL
# checks `sql_<name>`.
# =============================================================================

from komira_db_conformance.report import ConformanceReport, KnownGap
from komira_db_conformance.targets import NeutralTarget, SqlTarget
from komira_db_conformance.neutral_checks import (
    check_put_get_by_key,
    check_put_duplicate_key_raises,
    check_delete_by_key,
    check_query_rows_filter_order_limit,
    check_query_rows_ranges,
    check_query_rows_null_preds,
    check_query_rows_in,
    check_query_rows_ne,
    check_query_rows_locked,
    check_conditional_update_cas,
    check_conditional_update_coalesce,
    check_conditional_update_coalesce_multi_row,
    check_conditional_update_multi_row,
    check_delete_where,
    check_create_if_absent,
    check_create_if_absent_composite,
    check_claim_rows,
    check_tx_rollback_undoes_create,
    check_tx_commit_keeps,
)
from komira_db_conformance.type_checks import (
    check_text,
    check_int4,
    check_int8,
    check_float8,
    check_float4,
    check_bool,
    check_bytes,
    check_bytes_len16,
    check_uuid,
    check_timestamptz,
    check_jsonb,
    check_text_array,
    check_nulls,
)
from komira_db_conformance.sql_checks import (
    check_dialect_tokens,
    check_now_expr_evaluates,
    check_execute_rows_affected,
    check_query_shape,
    check_query_one_and_opt,
    check_params_never_interpolated,
    check_params_typed,
    check_params_null,
    check_tx_commit_visible,
    check_tx_rollback_undoes,
    check_tx_rollback_after_error,
    check_error_syntax,
    check_error_unique,
    check_error_not_null,
    check_error_missing_table,
    check_getter_type_mismatch,
)


def run_neutral_suite[T: NeutralTarget](mut t: T, gaps: List[KnownGap]) raises:
    """Every `Database` check against `t`, gated on `gaps`."""
    var r = ConformanceReport(t.name() + String(" [Database]"))
    try:
        check_text[T](t)
        r.ok(String("type_text"))
    except e:
        r.fail(String("type_text"), String(e))
    try:
        check_int4[T](t)
        r.ok(String("type_int4"))
    except e:
        r.fail(String("type_int4"), String(e))
    try:
        check_int8[T](t)
        r.ok(String("type_int8"))
    except e:
        r.fail(String("type_int8"), String(e))
    try:
        check_float8[T](t)
        r.ok(String("type_float8"))
    except e:
        r.fail(String("type_float8"), String(e))
    try:
        check_float4[T](t)
        r.ok(String("type_float4"))
    except e:
        r.fail(String("type_float4"), String(e))
    try:
        check_bool[T](t)
        r.ok(String("type_bool"))
    except e:
        r.fail(String("type_bool"), String(e))
    try:
        check_bytes[T](t)
        r.ok(String("type_bytes"))
    except e:
        r.fail(String("type_bytes"), String(e))
    try:
        check_bytes_len16[T](t)
        r.ok(String("type_bytes_len16"))
    except e:
        r.fail(String("type_bytes_len16"), String(e))
    try:
        check_uuid[T](t)
        r.ok(String("type_uuid"))
    except e:
        r.fail(String("type_uuid"), String(e))
    try:
        check_timestamptz[T](t)
        r.ok(String("type_timestamptz"))
    except e:
        r.fail(String("type_timestamptz"), String(e))
    try:
        check_jsonb[T](t)
        r.ok(String("type_jsonb"))
    except e:
        r.fail(String("type_jsonb"), String(e))
    try:
        check_text_array[T](t)
        r.ok(String("type_text_array"))
    except e:
        r.fail(String("type_text_array"), String(e))
    try:
        check_nulls[T](t)
        r.ok(String("type_nulls"))
    except e:
        r.fail(String("type_nulls"), String(e))
    try:
        check_put_get_by_key[T](t)
        r.ok(String("put_get_by_key"))
    except e:
        r.fail(String("put_get_by_key"), String(e))
    try:
        check_put_duplicate_key_raises[T](t)
        r.ok(String("put_duplicate_key_raises"))
    except e:
        r.fail(String("put_duplicate_key_raises"), String(e))
    try:
        check_delete_by_key[T](t)
        r.ok(String("delete_by_key"))
    except e:
        r.fail(String("delete_by_key"), String(e))
    try:
        check_query_rows_filter_order_limit[T](t)
        r.ok(String("query_rows_filter_order_limit"))
    except e:
        r.fail(String("query_rows_filter_order_limit"), String(e))
    try:
        check_query_rows_ranges[T](t)
        r.ok(String("query_rows_ranges"))
    except e:
        r.fail(String("query_rows_ranges"), String(e))
    try:
        check_query_rows_null_preds[T](t)
        r.ok(String("query_rows_null_preds"))
    except e:
        r.fail(String("query_rows_null_preds"), String(e))
    try:
        check_query_rows_in[T](t)
        r.ok(String("query_rows_in"))
    except e:
        r.fail(String("query_rows_in"), String(e))
    try:
        check_query_rows_ne[T](t)
        r.ok(String("query_rows_ne"))
    except e:
        r.fail(String("query_rows_ne"), String(e))
    try:
        check_query_rows_locked[T](t)
        r.ok(String("query_rows_locked"))
    except e:
        r.fail(String("query_rows_locked"), String(e))
    try:
        check_conditional_update_cas[T](t)
        r.ok(String("conditional_update_cas"))
    except e:
        r.fail(String("conditional_update_cas"), String(e))
    try:
        check_conditional_update_coalesce[T](t)
        r.ok(String("conditional_update_coalesce"))
    except e:
        r.fail(String("conditional_update_coalesce"), String(e))
    try:
        check_conditional_update_coalesce_multi_row[T](t)
        r.ok(String("conditional_update_coalesce_multi_row"))
    except e:
        r.fail(String("conditional_update_coalesce_multi_row"), String(e))
    try:
        check_conditional_update_multi_row[T](t)
        r.ok(String("conditional_update_multi_row"))
    except e:
        r.fail(String("conditional_update_multi_row"), String(e))
    try:
        check_delete_where[T](t)
        r.ok(String("delete_where"))
    except e:
        r.fail(String("delete_where"), String(e))
    try:
        check_create_if_absent[T](t)
        r.ok(String("create_if_absent"))
    except e:
        r.fail(String("create_if_absent"), String(e))
    try:
        check_create_if_absent_composite[T](t)
        r.ok(String("create_if_absent_composite"))
    except e:
        r.fail(String("create_if_absent_composite"), String(e))
    try:
        check_claim_rows[T](t)
        r.ok(String("claim_rows"))
    except e:
        r.fail(String("claim_rows"), String(e))
    try:
        check_tx_rollback_undoes_create[T](t)
        r.ok(String("tx_rollback_undoes_create"))
    except e:
        r.fail(String("tx_rollback_undoes_create"), String(e))
    try:
        check_tx_commit_keeps[T](t)
        r.ok(String("tx_commit_keeps"))
    except e:
        r.fail(String("tx_commit_keeps"), String(e))
    print(String("komira_db conformance: ") + r.target + String(": ") + String(r.count()) + String(" checks run"))
    r.gate(gaps)


def run_sql_suite[T: SqlTarget](mut t: T, gaps: List[KnownGap]) raises:
    """Every `SqlDatabase` string-surface check against `t`, gated on `gaps`."""
    var r = ConformanceReport(t.name() + String(" [SqlDatabase]"))
    try:
        check_dialect_tokens[T]()
        r.ok(String("sql_dialect_tokens"))
    except e:
        r.fail(String("sql_dialect_tokens"), String(e))
    try:
        check_now_expr_evaluates[T](t)
        r.ok(String("sql_now_expr_evaluates"))
    except e:
        r.fail(String("sql_now_expr_evaluates"), String(e))
    try:
        check_execute_rows_affected[T](t)
        r.ok(String("sql_execute_rows_affected"))
    except e:
        r.fail(String("sql_execute_rows_affected"), String(e))
    try:
        check_query_shape[T](t)
        r.ok(String("sql_query_shape"))
    except e:
        r.fail(String("sql_query_shape"), String(e))
    try:
        check_query_one_and_opt[T](t)
        r.ok(String("sql_query_one_and_opt"))
    except e:
        r.fail(String("sql_query_one_and_opt"), String(e))
    try:
        check_params_never_interpolated[T](t)
        r.ok(String("sql_params_never_interpolated"))
    except e:
        r.fail(String("sql_params_never_interpolated"), String(e))
    try:
        check_params_typed[T](t)
        r.ok(String("sql_params_typed"))
    except e:
        r.fail(String("sql_params_typed"), String(e))
    try:
        check_params_null[T](t)
        r.ok(String("sql_params_null"))
    except e:
        r.fail(String("sql_params_null"), String(e))
    try:
        check_tx_commit_visible[T](t)
        r.ok(String("sql_tx_commit_visible"))
    except e:
        r.fail(String("sql_tx_commit_visible"), String(e))
    try:
        check_tx_rollback_undoes[T](t)
        r.ok(String("sql_tx_rollback_undoes"))
    except e:
        r.fail(String("sql_tx_rollback_undoes"), String(e))
    try:
        check_tx_rollback_after_error[T](t)
        r.ok(String("sql_tx_rollback_after_error"))
    except e:
        r.fail(String("sql_tx_rollback_after_error"), String(e))
    try:
        check_error_syntax[T](t)
        r.ok(String("sql_error_syntax"))
    except e:
        r.fail(String("sql_error_syntax"), String(e))
    try:
        check_error_unique[T](t)
        r.ok(String("sql_error_unique"))
    except e:
        r.fail(String("sql_error_unique"), String(e))
    try:
        check_error_not_null[T](t)
        r.ok(String("sql_error_not_null"))
    except e:
        r.fail(String("sql_error_not_null"), String(e))
    try:
        check_error_missing_table[T](t)
        r.ok(String("sql_error_missing_table"))
    except e:
        r.fail(String("sql_error_missing_table"), String(e))
    try:
        check_getter_type_mismatch[T](t)
        r.ok(String("sql_getter_type_mismatch"))
    except e:
        r.fail(String("sql_getter_type_mismatch"), String(e))
    print(String("komira_db conformance: ") + r.target + String(": ") + String(r.count()) + String(" checks run"))
    r.gate(gaps)
