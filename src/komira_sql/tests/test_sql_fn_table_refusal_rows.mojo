# =============================================================================
# Row pins: every REFUSAL row of sql_scalar_fn_spec, grouped by its reason
# =============================================================================
#
# What it proves: each of the 538 refused names resolves to an FNK_REFUSED
# row that carries exactly its family's `_R_*` reason (77 families), lowers
# to no node (so a UDF may take the name) and has op 0 and the open arity
# sentinels. Every refused name is called, so every one of those rows is
# taken once.
# Mutants it catches: a row wired to a sibling family's reason, a refused
# name dropped (it then reads FNK_NONE), a refusal constructor that derives
# `lowers_to_a_node` from the kind, a reason constant edited to empty.
# The name lists were generated from the rows.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_sql.sql_fn_table import (
    FNK_REFUSED,
    FN_ARITY_OWN,
    FN_ARITY_UNBOUNDED,
    sql_scalar_fn_spec,
    _R_AGGARGEXTREME,
    _R_AGGCOMPENSATED,
    _R_AGGMACRO,
    _R_AGGMONOID,
    _R_AGGNESTED,
    _R_AGGQUANTILE,
    _R_AGGR,
    _R_AGGRETAIN,
    _R_AGGSKETCH,
    _R_AGGSTATE,
    _R_AGGSTRCAT,
    _R_AGGWINVALUE,
    _R_BINCODEC,
    _R_BITFN,
    _R_BITS,
    _R_BLOBLEN,
    _R_BUILD,
    _R_CATALOG,
    _R_CLOCK,
    _R_CODEPOINT,
    _R_DATEMINT,
    _R_DATENAME,
    _R_DUCKINTERNAL,
    _R_ENUMT,
    _R_EPOCHCONV,
    _R_FMTSTR,
    _R_GEOM,
    _R_GRAPHEME,
    _R_ICUCOLL,
    _R_INT128,
    _R_INTERVAL,
    _R_INTERVALCTOR,
    _R_INTPAIR,
    _R_JSONBUILD,
    _R_JSONDOC,
    _R_JSONLEAFMODE,
    _R_JSONMAP,
    _R_JSONMINIFY,
    _R_LAMBDA,
    _R_LIKEESC,
    _R_LISTCELL,
    _R_LISTCTOR,
    _R_LISTORDER,
    _R_LISTREDUCE,
    _R_LISTSEARCH,
    _R_LISTSETOP,
    _R_MAPTYPE,
    _R_MATH2,
    _R_MATHGAP,
    _R_NESTEDDOOR,
    _R_NONDET,
    _R_NULLC,
    _R_NUMFMT,
    _R_PATHSPLIT,
    _R_PGCASE,
    _R_POSITION,
    _R_ROUNDN,
    _R_SESSION,
    _R_SHORTCIRCUIT,
    _R_SIDEEFFECT,
    _R_SIZE,
    _R_SLEEP,
    _R_SLICE,
    _R_SQLSERDE,
    _R_STRUCTTYPE,
    _R_TABLEFN,
    _R_TAGGED,
    _R_TSFORMAT,
    _R_TSMINT,
    _R_TYPEOF,
    _R_TYPEVAL,
    _R_TZFN,
    _R_UKEY,
    _R_UNORM,
    _R_UUIDT,
    _R_VECDIST,
    _R_WALLCLOCK,
)


def _refused(reason: String, names: List[String]) raises:
    assert_true(reason.startswith("SQL not supported: "), names[0])
    for i in range(len(names)):
        var s = sql_scalar_fn_spec(names[i])
        assert_equal(Int(s.kind), Int(FNK_REFUSED), names[i])
        assert_equal(s.reason, reason, names[i])
        assert_false(s.lowers_to_a_node, names[i])
        assert_equal(Int(s.op), 0, names[i])
        assert_equal(s.min_args, FN_ARITY_OWN, names[i])
        assert_equal(s.max_args, FN_ARITY_UNBOUNDED, names[i])


def test_refusal_families_1() raises:
    _refused(
        _R_MATH2,
        [
            "nextafter",
        ],
    )
    _refused(
        _R_AGGR,
        [
            "array_to_string", "array_to_string_comma_default", "list_any_value",
            "list_approx_count_distinct", "list_avg", "list_bit_and", "list_bit_or",
            "list_bit_xor", "list_bool_and", "list_bool_or", "list_count",
            "list_entropy", "list_first", "list_histogram", "list_kurtosis",
            "list_kurtosis_pop", "list_last", "list_mad", "list_max", "list_median",
            "list_min", "list_mode", "list_product", "list_sem", "list_skewness",
            "list_stddev_pop", "list_stddev_samp", "list_string_agg", "list_sum",
            "list_var_pop", "list_var_samp",
        ],
    )
    _refused(
        _R_NULLC,
        [
            "col_description", "inet_client_addr", "inet_client_port",
            "inet_server_addr", "inet_server_port", "obj_description",
            "shobj_description",
        ],
    )
    _refused(
        _R_BUILD,
        [
            "array_append", "array_prepend", "array_push_back", "array_push_front",
            "list_append", "list_prepend",
        ],
    )
    _refused(
        _R_SLICE,
        [
            "array_pop_back", "array_pop_front", "array_reverse", "list_reverse",
            "split_part",
        ],
    )
    _refused(
        _R_CATALOG,
        [
            "current_catalog", "current_database", "current_query", "current_schema",
            "current_schemas", "format_type", "get_block_size", "pg_get_constraintdef",
            "pg_get_expr", "pg_get_viewdef",
        ],
    )
    _refused(
        _R_AGGMACRO,
        [
            "geomean", "geometric_mean", "wavg", "weighted_avg",
        ],
    )
    _refused(
        _R_AGGARGEXTREME,
        [
            "arg_max", "arg_max_null", "arg_max_nulls_last", "arg_min", "arg_min_null",
            "arg_min_nulls_last", "argmax", "argmin", "max_by", "min_by",
        ],
    )
    _refused(
        _R_AGGWINVALUE,
        [
            "cume_dist", "fill", "first_value", "lag", "last_value", "lead",
            "nth_value", "ntile", "percent_rank",
        ],
    )
    _refused(
        _R_AGGNESTED,
        [
            "array_agg", "bitstring_agg", "histogram", "histogram_exact", "list",
        ],
    )
    _refused(
        _R_AGGSTRCAT,
        [
            "group_concat", "listagg", "string_agg",
        ],
    )
    _refused(
        _R_AGGQUANTILE,
        [
            "quantile", "quantile_cont", "quantile_disc",
        ],
    )


def test_refusal_families_2() raises:
    _refused(
        _R_AGGRETAIN,
        [
            "entropy", "mad", "mode",
        ],
    )
    _refused(
        _R_AGGSKETCH,
        [
            "approx_count_distinct", "approx_quantile", "approx_top_k",
            "reservoir_quantile",
        ],
    )
    _refused(
        _R_AGGCOMPENSATED,
        [
            "sum_no_overflow",
        ],
    )
    _refused(
        _R_AGGMONOID,
        [
            "bit_and", "bit_or", "bit_xor",
        ],
    )
    _refused(
        _R_JSONMINIFY,
        [
            "json",
        ],
    )
    _refused(
        _R_JSONMAP,
        [
            "json_group_array", "json_group_object", "json_group_structure",
            "map_contains_entry", "map_contains_value",
        ],
    )
    _refused(
        _R_INTERVAL,
        [
            "ago", "date_add",
        ],
    )
    _refused(
        _R_ROUNDN,
        [
            "round_even", "roundbankers",
        ],
    )
    _refused(
        _R_TABLEFN,
        [
            "generate_subscripts", "regexp_split_to_table",
        ],
    )
    _refused(
        _R_BITS,
        [
            "md5_number_lower", "md5_number_upper",
        ],
    )
    _refused(
        _R_INT128,
        [
            "md5_number", "factorial",
        ],
    )
    _refused(
        _R_CLOCK,
        [
            "pg_conf_load_time", "pg_postmaster_start_time",
        ],
    )


def test_refusal_families_3() raises:
    _refused(
        _R_PGCASE,
        [
            "format_pg_type", "map_to_pg_oid",
        ],
    )
    _refused(
        _R_SLEEP,
        [
            "pg_sleep",
        ],
    )
    _refused(
        _R_TYPEOF,
        [
            "pg_typeof",
        ],
    )
    _refused(
        _R_SIZE,
        [
            "pg_size_pretty",
        ],
    )
    _refused(
        _R_ICUCOLL,
        [
            "create_sort_key", "icu_collate_af", "icu_collate_am", "icu_collate_ar",
            "icu_collate_ar_sa", "icu_collate_as", "icu_collate_az", "icu_collate_be",
            "icu_collate_bg", "icu_collate_blo", "icu_collate_bn", "icu_collate_bo",
            "icu_collate_br", "icu_collate_bs", "icu_collate_ca", "icu_collate_ceb",
            "icu_collate_chr", "icu_collate_cs", "icu_collate_cy", "icu_collate_da",
            "icu_collate_de", "icu_collate_de_at", "icu_collate_dsb", "icu_collate_dz",
            "icu_collate_ee", "icu_collate_el", "icu_collate_en", "icu_collate_en_us",
            "icu_collate_eo", "icu_collate_es", "icu_collate_et", "icu_collate_fa",
            "icu_collate_fa_af", "icu_collate_ff", "icu_collate_fi", "icu_collate_fil",
            "icu_collate_fo", "icu_collate_fr", "icu_collate_fr_ca", "icu_collate_fy",
            "icu_collate_ga", "icu_collate_gl", "icu_collate_gu", "icu_collate_ha",
            "icu_collate_haw", "icu_collate_he", "icu_collate_he_il", "icu_collate_hi",
            "icu_collate_hr", "icu_collate_hsb", "icu_collate_hu", "icu_collate_hy",
            "icu_collate_id", "icu_collate_id_id", "icu_collate_ig", "icu_collate_is",
            "icu_collate_it", "icu_collate_ja", "icu_collate_ka", "icu_collate_kk",
            "icu_collate_kl", "icu_collate_km", "icu_collate_kn", "icu_collate_ko",
            "icu_collate_kok", "icu_collate_ku", "icu_collate_ky", "icu_collate_lb",
            "icu_collate_lij", "icu_collate_lkt", "icu_collate_ln", "icu_collate_lo",
            "icu_collate_lt", "icu_collate_lv", "icu_collate_mk", "icu_collate_ml",
            "icu_collate_mn", "icu_collate_mr", "icu_collate_ms", "icu_collate_mt",
            "icu_collate_my", "icu_collate_nb", "icu_collate_nb_no", "icu_collate_ne",
            "icu_collate_nl", "icu_collate_nn", "icu_collate_no",
            "icu_collate_noaccent", "icu_collate_nso", "icu_collate_om",
            "icu_collate_or", "icu_collate_pa", "icu_collate_pa_in", "icu_collate_pl",
            "icu_collate_ps", "icu_collate_pt", "icu_collate_ro", "icu_collate_ru",
            "icu_collate_sa", "icu_collate_se", "icu_collate_si", "icu_collate_sk",
            "icu_collate_sl", "icu_collate_smn", "icu_collate_sq", "icu_collate_sr",
            "icu_collate_sr_ba", "icu_collate_sr_me", "icu_collate_sr_rs",
            "icu_collate_st", "icu_collate_sv", "icu_collate_sw", "icu_collate_ta",
            "icu_collate_te", "icu_collate_th", "icu_collate_tk", "icu_collate_tn",
            "icu_collate_to", "icu_collate_tr", "icu_collate_ug", "icu_collate_uk",
            "icu_collate_ur", "icu_collate_uz", "icu_collate_vi", "icu_collate_wae",
            "icu_collate_wo", "icu_collate_xh", "icu_collate_yi", "icu_collate_yo",
            "icu_collate_zh", "icu_collate_zh_cn", "icu_collate_zh_hk",
            "icu_collate_zh_mo", "icu_collate_zh_sg", "icu_collate_zh_tw",
            "icu_collate_zu", "icu_sort_key",
        ],
    )
    _refused(
        _R_GRAPHEME,
        [
            "left_grapheme", "length_grapheme", "right_grapheme", "substring_grapheme",
        ],
    )
    _refused(
        _R_UNORM,
        [
            "nfc_normalize", "strip_accents",
        ],
    )
    _refused(
        _R_FMTSTR,
        [
            "format", "printf",
        ],
    )
    _refused(
        _R_NUMFMT,
        [
            "bar", "formatreadabledecimalsize", "formatreadablesize", "format_bytes",
            "parse_formatted_bytes", "to_base",
        ],
    )
    _refused(
        _R_BINCODEC,
        [
            "base64", "decode", "encode", "from_base64", "from_binary", "from_hex",
            "to_base64", "unbin", "unhex",
        ],
    )
    _refused(
        _R_LIKEESC,
        [
            "ilike_escape", "like_escape", "not_ilike_escape", "not_like_escape",
        ],
    )
    _refused(
        _R_PATHSPLIT,
        [
            "parse_dirname", "parse_dirpath", "parse_filename", "parse_path",
        ],
    )


def test_refusal_families_4() raises:
    _refused(
        _R_POSITION,
        [
            "position",
        ],
    )
    _refused(
        _R_WALLCLOCK,
        [
            "current_date", "current_localtime", "current_localtimestamp",
            "get_current_time", "get_current_timestamp", "now", "today",
            "transaction_timestamp",
        ],
    )
    _refused(
        _R_TSFORMAT,
        [
            "strftime", "strptime", "try_strptime",
        ],
    )
    _refused(
        _R_TSMINT,
        [
            "make_date", "make_time", "make_timestamptz", "to_timestamp",
        ],
    )
    _refused(
        _R_EPOCHCONV,
        [
            "epoch", "epoch_ms", "epoch_ns", "epoch_us",
        ],
    )
    _refused(
        _R_TZFN,
        [
            "timezone", "timezone_hour", "timezone_minute",
        ],
    )
    _refused(
        _R_DATENAME,
        [
            "dayname", "monthname",
        ],
    )
    _refused(
        _R_INTERVALCTOR,
        [
            "age", "normalized_interval", "time_bucket", "to_centuries", "to_days",
            "to_decades", "to_hours", "to_microseconds", "to_millennia",
            "to_milliseconds", "to_minutes", "to_months", "to_quarters", "to_seconds",
            "to_weeks", "to_years",
        ],
    )
    _refused(
        _R_DATEMINT,
        [
            "julian", "last_day",
        ],
    )
    _refused(
        _R_BITFN,
        [
            "bit_position", "bitstring", "get_bit", "set_bit", "xor",
        ],
    )
    _refused(
        _R_INTPAIR,
        [
            "gcd", "greatest_common_divisor", "lcm", "least_common_multiple",
        ],
    )
    _refused(
        _R_NONDET,
        [
            "random", "setseed",
        ],
    )


def test_refusal_families_5() raises:
    _refused(
        _R_MATHGAP,
        [
            "lgamma", "signbit",
        ],
    )
    _refused(
        _R_NESTEDDOOR,
        [
            "element_at", "map_extract",
        ],
    )
    _refused(
        _R_JSONLEAFMODE,
        [
            "json_value",
        ],
    )
    _refused(
        _R_LISTCELL,
        [
            "array_extract", "list_extract", "list_element", "list_slice",
            "array_slice", "list_select", "array_select", "list_where", "array_where",
            "array_length",
        ],
    )
    _refused(
        _R_LISTCTOR,
        [
            "list_value", "list_pack", "array_value", "list_concat", "list_cat",
            "array_cat", "array_concat", "list_resize", "array_resize", "flatten",
            "unpivot_list", "list_zip", "array_zip", "generate_series", "range",
            "equi_width_bins",
        ],
    )
    _refused(
        _R_LISTSEARCH,
        [
            "list_contains", "list_has", "array_contains", "array_has", "list_has_all",
            "list_has_any", "array_has_all", "array_has_any", "list_position",
            "list_indexof", "array_position", "array_indexof",
        ],
    )
    _refused(
        _R_LISTSETOP,
        [
            "list_distinct", "array_distinct", "list_intersect", "array_intersect",
            "list_unique", "array_unique",
        ],
    )
    _refused(
        _R_LISTORDER,
        [
            "list_sort", "array_sort", "list_reverse_sort", "array_reverse_sort",
            "list_grade_up", "array_grade_up", "grade_up",
        ],
    )
    _refused(
        _R_LAMBDA,
        [
            "apply", "array_apply", "list_apply", "list_transform", "array_transform",
            "filter", "list_filter", "array_filter", "reduce", "list_reduce",
            "array_reduce",
        ],
    )
    _refused(
        _R_LISTREDUCE,
        [
            "aggregate", "array_aggr", "array_aggregate", "list_aggr",
            "list_aggregate",
        ],
    )
    _refused(
        _R_VECDIST,
        [
            "array_cosine_distance", "array_cosine_similarity", "array_cross_product",
            "array_distance", "array_dot_product", "array_inner_product",
            "array_negative_dot_product", "array_negative_inner_product",
            "list_cosine_distance", "list_cosine_similarity", "list_distance",
            "list_dot_product", "list_inner_product", "list_negative_dot_product",
            "list_negative_inner_product",
        ],
    )
    _refused(
        _R_MAPTYPE,
        [
            "map", "map_concat", "map_contains", "map_entries", "map_from_entries",
            "map_keys", "map_values", "cardinality", "switch",
        ],
    )


def test_refusal_families_6() raises:
    _refused(
        _R_STRUCTTYPE,
        [
            "struct_concat", "struct_contains", "struct_has", "struct_indexof",
            "struct_insert", "struct_keys", "struct_pack", "struct_position",
            "struct_update", "struct_values", "remap_struct", "row",
        ],
    )
    _refused(
        _R_JSONDOC,
        [
            "json_array_length", "json_contains", "json_exists", "json_keys",
            "json_pretty", "json_structure", "json_transform", "json_transform_strict",
            "json_type", "json_valid", "from_json", "from_json_strict",
            "json_merge_patch",
        ],
    )
    _refused(
        _R_JSONBUILD,
        [
            "json_array", "json_object", "json_quote", "to_json", "array_to_json",
            "row_to_json",
        ],
    )
    _refused(
        _R_SQLSERDE,
        [
            "json_deserialize_sql", "json_serialize_plan", "json_serialize_sql",
        ],
    )
    _refused(
        _R_GEOM,
        [
            "st_asbinary", "st_astext", "st_aswkb", "st_aswkt", "st_crs",
            "st_geomfromwkb", "st_intersects_extent", "st_setcrs",
        ],
    )
    _refused(
        _R_UUIDT,
        [
            "uuid", "uuidv4", "uuidv7", "gen_random_uuid", "uuid_extract_timestamp",
            "uuid_extract_version",
        ],
    )
    _refused(
        _R_TAGGED,
        [
            "union_extract", "union_tag", "union_value", "variant_extract",
            "variant_normalize", "variant_to_parquet_variant", "variant_typeof",
        ],
    )
    _refused(
        _R_ENUMT,
        [
            "enum_code", "enum_first", "enum_last", "enum_range",
            "enum_range_boundary",
        ],
    )
    _refused(
        _R_TYPEVAL,
        [
            "typeof", "get_type", "make_type", "vector_type", "can_cast_implicitly",
            "cast_to_type", "replace_type", "alias",
        ],
    )
    _refused(
        _R_SESSION,
        [
            "current_connection_id", "current_query_id", "current_transaction_id",
            "txid_current", "currval", "nextval", "current_setting", "getvariable",
            "in_search_path", "getenv", "version",
        ],
    )
    _refused(
        _R_SIDEEFFECT,
        [
            "error", "sleep_ms", "write_log",
        ],
    )
    _refused(
        _R_DUCKINTERNAL,
        [
            "parse_duckdb_log_message", "stats", "is_histogram_other_bin",
        ],
    )


def test_refusal_families_7() raises:
    _refused(
        _R_AGGSTATE,
        [
            "combine", "finalize",
        ],
    )
    _refused(
        _R_UKEY,
        [
            "hash", "timetz_byte_comparable",
        ],
    )
    _refused(
        _R_CODEPOINT,
        [
            "chr",
        ],
    )
    _refused(
        _R_BLOBLEN,
        [
            "octet_length",
        ],
    )
    _refused(
        _R_SHORTCIRCUIT,
        [
            "constant_or_null",
        ],
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
