# =============================================================================
# src/kci_params/tests/test_param_config_wire.mojo
#   The store's side: parameters travel as opaque `APP_PARAM:<name>` config
#   entries holding `<kind>|<value>`, come back sorted by name, and render
#   to argv with no declaration.
# =============================================================================
#
# The sort cases hand the entries in reverse order, in an order where a name
# is a prefix of another, and with non-parameter keys mixed in, and check
# that each value stays with its own name. The duplicate cases put the
# repeat at the first two positions after the sort, where a check that
# skips index 1 misses it. The full round trip ends at the app's parser, so
# a store that loses or reorders a value is caught where it would matter.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from kci_params.app_params import (
    APP_PARAM_CONFIG_PREFIX,
    PARAM_KIND_LITERAL,
    PARAM_KIND_REFERENCE,
    PARAM_KIND_SECRET_REFERENCE,
    PARAM_OPTIONAL,
    PARAM_REQUIRED,
    PARAM_RUNNER_INJECTED,
    AppParamDecl,
    AppParamValue,
    app_param_config_key,
    app_param_name_from_config_key,
    collect_app_params_from_config,
    decode_app_param_config_value,
    encode_app_param_config_value,
    find_param_value,
    is_app_param_config_key,
    literal_param,
    param_map_is_storable,
    param_map_names,
    parse_app_params,
    reference_param,
    render_app_param_argv,
    secret_reference_param,
)

comptime _SECRET = "projects/example-project/secrets/signing-key/versions/latest"


# ── Keys ────────────────────────────────────────────────────────────────────


def test_a_config_key_is_the_prefix_and_the_name() raises:
    assert_equal(APP_PARAM_CONFIG_PREFIX, "APP_PARAM:")
    assert_equal(app_param_config_key("store-url"), "APP_PARAM:store-url")
    assert_true(is_app_param_config_key("APP_PARAM:store-url"))
    assert_true(is_app_param_config_key("APP_PARAM:"))
    assert_false(is_app_param_config_key("app_param:store-url"))
    assert_false(is_app_param_config_key("APP_PARAM"))
    assert_false(is_app_param_config_key("X_APP_PARAM:a"))
    assert_false(is_app_param_config_key(""))


def test_the_name_comes_back_from_its_key() raises:
    assert_equal(
        app_param_name_from_config_key(app_param_config_key("store-url")),
        "store-url",
    )
    assert_equal(app_param_name_from_config_key("APP_PARAM:a"), "a")
    assert_equal(app_param_name_from_config_key("APP_PARAM:"), "")
    with assert_raises(
        contains="'OTHER:a' is not a parameter config key (no 'APP_PARAM:'"
        " prefix)"
    ):
        _ = app_param_name_from_config_key("OTHER:a")


# ── Values ──────────────────────────────────────────────────────────────────


def test_a_value_is_encoded_as_its_kind_ordinal_a_bar_and_the_value() raises:
    assert_equal(encode_app_param_config_value(PARAM_KIND_LITERAL, "8080"), "0|8080")
    assert_equal(
        encode_app_param_config_value(PARAM_KIND_REFERENCE, "s3://b/p:x"),
        "1|s3://b/p:x",
    )
    assert_equal(
        encode_app_param_config_value(PARAM_KIND_SECRET_REFERENCE, _SECRET),
        String("2|") + _SECRET,
    )


def test_a_value_holding_the_separator_is_refused_at_any_position() raises:
    var bad = List[String]()
    bad.append("|lead")
    bad.append("mid|dle")
    bad.append("trail|")
    for i in range(len(bad)):
        var msg = String("")
        try:
            _ = encode_app_param_config_value(PARAM_KIND_LITERAL, bad[i])
        except e:
            msg = String(e)
        assert_true(
            msg.find(
                String("a parameter value may not contain '|'")
            )
            >= 0
            and msg.find(String(": '") + bad[i] + "'") >= 0,
            String("value ") + bad[i] + " got: " + msg,
        )


def test_each_kind_decodes_back_to_its_own_value() raises:
    var kinds = List[Int]()
    kinds.append(PARAM_KIND_LITERAL)
    kinds.append(PARAM_KIND_REFERENCE)
    kinds.append(PARAM_KIND_SECRET_REFERENCE)
    for i in range(len(kinds)):
        var raw = encode_app_param_config_value(kinds[i], "v:/x")
        var v = decode_app_param_config_value("p", raw)
        assert_equal(v.name, "p")
        assert_equal(v.kind, kinds[i])
        assert_equal(v.value, "v:/x")


def test_a_malformed_transported_value_is_refused() raises:
    with assert_raises(
        contains="parameter 'p' has a malformed transported value (no '|'"
        " separating the kind ordinal from the value): '0'"
    ):
        _ = decode_app_param_config_value("p", "0")
    var kinds = List[String]()
    kinds.append("")
    kinds.append("3")
    kinds.append("-1")
    kinds.append("01")
    kinds.append(" 0")
    kinds.append("LITERAL")
    for i in range(len(kinds)):
        var msg = String("")
        try:
            _ = decode_app_param_config_value("p", kinds[i] + "|x")
        except e:
            msg = String(e)
        assert_true(
            msg.find(
                String(
                    "parameter 'p' was transported with an unknown kind ordinal '"
                )
                + kinds[i]
                + "'"
            )
            >= 0,
            String("kind '") + kinds[i] + "' got: " + msg,
        )


# ── Collect ─────────────────────────────────────────────────────────────────


def _kv(
    mut keys: List[String], mut raws: List[String], name: String, raw: String
):
    keys.append(app_param_config_key(name))
    raws.append(raw.copy())


def test_collect_sorts_by_name_and_keeps_each_value_with_its_name() raises:
    var keys = List[String]()
    var raws = List[String]()
    _kv(keys, raws, "zeta", "0|z")
    keys.append("image")
    raws.append("not a parameter")
    _kv(keys, raws, "mid", "1|m")
    _kv(keys, raws, "ab", "0|ab")
    _kv(keys, raws, "a-b", "0|a-b")
    _kv(keys, raws, "a", String("2|") + _SECRET)
    keys.append("APP_PARAM")
    raws.append("no colon, not a parameter")
    var got = collect_app_params_from_config(keys, raws)
    assert_equal(len(got), 5)
    assert_equal(got[0].name, "a")
    assert_equal(got[0].kind, PARAM_KIND_SECRET_REFERENCE)
    assert_equal(got[0].value, _SECRET)
    assert_equal(got[1].name, "a-b")
    assert_equal(got[1].value, "a-b")
    assert_equal(got[2].name, "ab")
    assert_equal(got[2].value, "ab")
    assert_equal(got[3].name, "mid")
    assert_equal(got[3].kind, PARAM_KIND_REFERENCE)
    assert_equal(got[3].value, "m")
    assert_equal(got[4].name, "zeta")
    assert_equal(got[4].value, "z")


def test_collect_of_an_already_sorted_map_and_of_nothing() raises:
    var keys = List[String]()
    var raws = List[String]()
    _kv(keys, raws, "a", "0|1")
    _kv(keys, raws, "b", "0|2")
    _kv(keys, raws, "c", "0|3")
    var got = collect_app_params_from_config(keys, raws)
    assert_equal(len(got), 3)
    assert_equal(got[0].value, "1")
    assert_equal(got[1].value, "2")
    assert_equal(got[2].value, "3")
    var none = collect_app_params_from_config(List[String](), List[String]())
    assert_equal(len(none), 0)


def test_collect_refuses_lists_of_different_lengths() raises:
    var keys = List[String]()
    keys.append(app_param_config_key("a"))
    keys.append(app_param_config_key("b"))
    var raws = List[String]()
    raws.append("0|x")
    with assert_raises(
        contains="config key/value lists differ in length (2 vs 1)"
    ):
        _ = collect_app_params_from_config(keys, raws)
    # The reverse direction: more values than keys must also refuse, not drop
    # the extra value silently.
    var one_key = List[String]()
    one_key.append(app_param_config_key("a"))
    var two_raws = List[String]()
    two_raws.append("0|x")
    two_raws.append("0|y")
    with assert_raises(
        contains="config key/value lists differ in length (1 vs 2)"
    ):
        _ = collect_app_params_from_config(one_key, two_raws)


def test_collect_refuses_a_name_carried_twice() raises:
    # The two rows sort to positions 0 and 1.
    var first = List[String]()
    var first_raws = List[String]()
    _kv(first, first_raws, "a", "0|x")
    _kv(first, first_raws, "a", "0|y")
    with assert_raises(contains="parameter 'a' appears TWICE"):
        _ = collect_app_params_from_config(first, first_raws)
    # Apart in the input, adjacent once sorted.
    var apart = List[String]()
    var apart_raws = List[String]()
    _kv(apart, apart_raws, "m", "0|x")
    _kv(apart, apart_raws, "c", "0|x")
    _kv(apart, apart_raws, "a", "0|x")
    _kv(apart, apart_raws, "m", "0|y")
    with assert_raises(contains="parameter 'm' appears TWICE"):
        _ = collect_app_params_from_config(apart, apart_raws)


def test_collect_refuses_a_malformed_row_by_name() raises:
    var keys = List[String]()
    var raws = List[String]()
    _kv(keys, raws, "a", "0|x")
    _kv(keys, raws, "b", "9|x")
    with assert_raises(
        contains="parameter 'b' was transported with an unknown kind ordinal '9'"
    ):
        _ = collect_app_params_from_config(keys, raws)


# ── The stored map ──────────────────────────────────────────────────────────


def test_map_names_are_the_supplied_names_in_supplied_order() raises:
    var values = List[AppParamValue]()
    values.append(literal_param("zeta", "1"))
    values.append(reference_param("alpha", "2"))
    values.append(secret_reference_param("mid", _SECRET))
    var names = param_map_names(values)
    assert_equal(len(names), 3)
    assert_equal(names[0], "zeta")
    assert_equal(names[1], "alpha")
    assert_equal(names[2], "mid")
    assert_equal(len(param_map_names(List[AppParamValue]())), 0)


def test_find_param_value_finds_any_row_or_answers_absent() raises:
    var values = List[AppParamValue]()
    values.append(literal_param("a", "1"))
    values.append(reference_param("b", "2"))
    var b = find_param_value(values, "b")
    assert_true(Bool(b))
    assert_equal(b.value().value, "2")
    assert_equal(b.value().kind, PARAM_KIND_REFERENCE)
    assert_false(Bool(find_param_value(values, "c")))
    assert_false(Bool(find_param_value(List[AppParamValue](), "a")))


def test_only_a_secret_row_must_hold_a_resource_name() raises:
    var ok = List[AppParamValue]()
    ok.append(literal_param("a", "raw text"))
    ok.append(reference_param("b", "s3://bucket"))
    ok.append(secret_reference_param("c", _SECRET))
    param_map_is_storable(ok)
    var bad = List[String]()
    bad.append("Projects/p/secrets/s")
    bad.append("xprojects/p")
    bad.append("projects")
    bad.append("")
    for i in range(len(bad)):
        var rows = List[AppParamValue]()
        rows.append(literal_param("a", "raw text"))
        rows.append(secret_reference_param("c", _SECRET))
        rows.append(secret_reference_param("key", bad[i]))
        var msg = String("")
        try:
            param_map_is_storable(rows)
        except e:
            msg = String(e)
        assert_true(
            msg.find("refusing to persist parameter 'key'") >= 0,
            String("value '") + bad[i] + "' got: " + msg,
        )


def test_the_map_render_refuses_a_row_whose_name_is_not_kebab() raises:
    var values = List[AppParamValue]()
    values.append(literal_param("ok", "1"))
    values.append(literal_param("Bad", "2"))
    with assert_raises(contains="parameter name 'Bad' contains a byte"):
        _ = render_app_param_argv(values)


def test_the_map_render_keeps_supplied_order() raises:
    var values = List[AppParamValue]()
    values.append(literal_param("zeta", "1"))
    values.append(reference_param("alpha", "s3://b"))
    values.append(secret_reference_param("mid", _SECRET))
    var argv = render_app_param_argv(values)
    assert_equal(len(argv), 3)
    assert_equal(argv[0], "--zeta=1")
    assert_equal(argv[1], "--alpha=s3://b")
    assert_equal(argv[2], String("--mid=") + _SECRET)


def test_the_store_wire_round_trips_to_the_apps_parser() raises:
    """Supplied values -> config entries -> collected map -> argv -> parsed."""
    var supplied = List[AppParamValue]()
    supplied.append(secret_reference_param("signing-key", _SECRET))
    supplied.append(literal_param("listen-address", "0.0.0.0:8080"))
    supplied.append(reference_param("store-url", "s3://bucket/app"))
    var keys = List[String]()
    var raws = List[String]()
    keys.append("unrelated")
    raws.append("ignored")
    for i in range(len(supplied)):
        keys.append(app_param_config_key(supplied[i].name))
        raws.append(
            encode_app_param_config_value(supplied[i].kind, supplied[i].value)
        )
    var stored = collect_app_params_from_config(keys, raws)
    var argv = render_app_param_argv(stored)
    assert_equal(len(argv), 3)
    assert_equal(argv[0], "--listen-address=0.0.0.0:8080")
    assert_equal(argv[1], String("--signing-key=") + _SECRET)
    assert_equal(argv[2], "--store-url=s3://bucket/app")

    var decls = List[AppParamDecl]()
    decls.append(
        AppParamDecl(
            "listen-address", PARAM_REQUIRED, PARAM_KIND_LITERAL, "", "Addr."
        )
    )
    decls.append(
        AppParamDecl(
            "store-url", PARAM_REQUIRED, PARAM_KIND_REFERENCE, "", "Store."
        )
    )
    decls.append(
        AppParamDecl(
            "signing-key", PARAM_RUNNER_INJECTED, PARAM_KIND_SECRET_REFERENCE,
            "", "Key.",
        )
    )
    decls.append(
        AppParamDecl("batch", PARAM_OPTIONAL, PARAM_KIND_LITERAL, "7", "Rows.")
    )
    var process = List[String]()
    process.append("/app/example-app")
    for i in range(len(argv)):
        process.append(argv[i].copy())
    var bound = parse_app_params("example-app", decls, process)
    assert_equal(bound.get("listen-address"), "0.0.0.0:8080")
    assert_equal(bound.get("store-url"), "s3://bucket/app")
    assert_equal(bound.get("signing-key"), _SECRET)
    assert_equal(bound.get("batch"), "7")
    assert_equal(bound.count(), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
