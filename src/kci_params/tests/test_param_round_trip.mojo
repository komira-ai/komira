# =============================================================================
# src/kci_params/tests/test_param_round_trip.mojo
#   A parameter declaration renders to command-line arguments, and the app's
#   one parse site reads exactly those arguments back.
# =============================================================================
#
# Both ends of the wire take the SAME declaration: the deploy renders argv
# from it (`render_app_params`, or `render_app_param_argv` from a stored map)
# and the app parses argv against it at startup (`parse_app_params`). The
# round-trip tests hand the rendered tokens to the parser unchanged. The
# refusal tests assert on the message, not merely that something raised: a
# required parameter that is missing, an unknown parameter at either end, a
# secret parameter given a literal, and an empty value.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_params.app_params import (
    PARAM_KIND_LITERAL,
    PARAM_KIND_REFERENCE,
    PARAM_KIND_SECRET_REFERENCE,
    PARAM_OPTIONAL,
    PARAM_REQUIRED,
    PARAM_RUNNER_INJECTED,
    AppParamDecl,
    AppParamValue,
    literal_param,
    parse_app_params,
    reference_param,
    render_app_param_argv,
    render_app_params,
    secret_reference_param,
    validate_param_decls,
)

comptime _APP = "example-app"
comptime _SECRET = "projects/example-project/secrets/signing-key/versions/latest"


def _decls() -> List[AppParamDecl]:
    """One parameter of each obligation and kind the example app takes."""
    var d = List[AppParamDecl]()
    d.append(
        AppParamDecl(
            String("listen-address"), PARAM_REQUIRED, PARAM_KIND_LITERAL,
            String(""), String("Address the server binds."),
        )
    )
    d.append(
        AppParamDecl(
            String("max-batch"), PARAM_OPTIONAL, PARAM_KIND_LITERAL,
            String("1000"), String("Rows per flush."),
        )
    )
    d.append(
        AppParamDecl(
            String("store-url"), PARAM_REQUIRED, PARAM_KIND_REFERENCE,
            String(""), String("The object store this app writes to."),
        )
    )
    d.append(
        AppParamDecl(
            String("signing-key"), PARAM_RUNNER_INJECTED,
            PARAM_KIND_SECRET_REFERENCE, String(""),
            String("The secret that signs responses."),
        )
    )
    d.append(
        AppParamDecl(
            String("label"), PARAM_OPTIONAL, PARAM_KIND_LITERAL,
            String(""), String("An optional display label."),
        )
    )
    return d^


def _values() -> List[AppParamValue]:
    """Values for every required parameter, and none for the optional ones."""
    var v = List[AppParamValue]()
    v.append(literal_param(String("listen-address"), String("0.0.0.0:8080")))
    v.append(
        reference_param(String("store-url"), String("s3://example-bucket/app"))
    )
    v.append(secret_reference_param(String("signing-key"), String(_SECRET)))
    return v^


def _with_program(tokens: List[String]) -> List[String]:
    """`tokens` behind an argv[0], as a process receives them."""
    var argv = List[String]()
    argv.append(String("/app/example-app"))
    for i in range(len(tokens)):
        argv.append(tokens[i].copy())
    return argv^


def _assert_contains(msg: String, want: String) raises:
    assert_true(
        msg.find(want) >= 0,
        String("expected a refusal containing '") + want + String("', got: ")
        + msg,
    )


# ── Round trips ───────────────────────────────────────────────────────────────


def test_declared_render_is_one_token_per_parameter_in_declaration_order() raises:
    var argv = render_app_params(String(_APP), _decls(), _values())
    assert_equal(len(argv), 4)
    assert_equal(argv[0], String("--listen-address=0.0.0.0:8080"))
    # An unsupplied optional with a default is rendered, so the running
    # revision's command line shows its effective configuration.
    assert_equal(argv[1], String("--max-batch=1000"))
    assert_equal(argv[2], String("--store-url=s3://example-bucket/app"))
    # A secret renders its reference, never secret material.
    assert_equal(argv[3], String("--signing-key=") + _SECRET)
    # An unsupplied optional with no default is omitted, not rendered empty.
    for i in range(len(argv)):
        assert_false(argv[i].startswith("--label"))


def test_declared_render_parses_back_to_the_same_values() raises:
    var decls = _decls()
    var argv = render_app_params(String(_APP), decls, _values())
    var bound = parse_app_params(String(_APP), decls, _with_program(argv))
    assert_equal(bound.get(String("listen-address")), String("0.0.0.0:8080"))
    assert_equal(bound.get(String("max-batch")), String("1000"))
    assert_equal(bound.get(String("store-url")), String("s3://example-bucket/app"))
    assert_equal(bound.get(String("signing-key")), String(_SECRET))
    # Absent, not empty: an unsupplied optional with no default is not bound.
    assert_false(bound.has(String("label")))
    assert_equal(bound.count(), 4)


def test_a_supplied_optional_overrides_its_default_end_to_end() raises:
    var decls = _decls()
    var values = _values()
    values.append(literal_param(String("max-batch"), String("5000")))
    values.append(literal_param(String("label"), String("acme")))
    var argv = render_app_params(String(_APP), decls, values)
    var bound = parse_app_params(String(_APP), decls, _with_program(argv))
    assert_equal(bound.get(String("max-batch")), String("5000"))
    assert_equal(bound.get(String("label")), String("acme"))


def test_the_map_render_parses_back_against_the_declaration() raises:
    """The deployment store renders from the stored map alone, with no
    declaration; the app still parses it against its own."""
    var argv = render_app_param_argv(_values())
    assert_equal(len(argv), 3)
    assert_equal(argv[0], String("--listen-address=0.0.0.0:8080"))
    var bound = parse_app_params(String(_APP), _decls(), _with_program(argv))
    assert_equal(bound.get(String("listen-address")), String("0.0.0.0:8080"))
    assert_equal(bound.get(String("store-url")), String("s3://example-bucket/app"))
    assert_equal(bound.get(String("signing-key")), String(_SECRET))
    # The parser fills the default the map render did not carry.
    assert_equal(bound.get(String("max-batch")), String("1000"))


def test_a_value_holding_equals_or_a_leading_dash_round_trips() raises:
    """One `--name=value` token splits at the FIRST `=`, so a value may hold
    `=` or begin with `-`."""
    var values = _values()
    values.append(literal_param(String("label"), String("k=v=w")))
    values.append(literal_param(String("max-batch"), String("-5")))
    var decls = _decls()
    var argv = render_app_params(String(_APP), decls, values)
    var bound = parse_app_params(String(_APP), decls, _with_program(argv))
    assert_equal(bound.get(String("label")), String("k=v=w"))
    assert_equal(bound.get(String("max-batch")), String("-5"))


def test_the_two_token_spelling_parses_too() raises:
    var tokens = List[String]()
    tokens.append(String("--listen-address"))
    tokens.append(String("127.0.0.1:9000"))
    tokens.append(String("--store-url=s3://b/p"))
    tokens.append(String("--signing-key=") + _SECRET)
    var bound = parse_app_params(String(_APP), _decls(), _with_program(tokens))
    assert_equal(bound.get(String("listen-address")), String("127.0.0.1:9000"))


# ── Required ─────────────────────────────────────────────────────────────────


def test_render_refuses_a_missing_required_parameter_by_name() raises:
    var values = List[AppParamValue]()
    values.append(
        reference_param(String("store-url"), String("s3://example-bucket/app"))
    )
    values.append(secret_reference_param(String("signing-key"), String(_SECRET)))
    var msg = String("")
    try:
        _ = render_app_params(String(_APP), _decls(), values)
    except e:
        msg = String(e)
    _assert_contains(msg, String("NO GAP VIOLATED"))
    _assert_contains(msg, String("'listen-address'"))
    _assert_contains(msg, String(_APP))
    # The refusal quotes what the app declares the parameter to mean.
    _assert_contains(msg, String("Address the server binds."))


def test_parse_refuses_a_missing_required_parameter_by_flag() raises:
    var tokens = List[String]()
    tokens.append(String("--store-url=s3://b/p"))
    tokens.append(String("--signing-key=") + _SECRET)
    var msg = String("")
    try:
        _ = parse_app_params(String(_APP), _decls(), _with_program(tokens))
    except e:
        msg = String(e)
    _assert_contains(msg, String("REQUIRED parameter '--listen-address'"))


def test_a_required_parameter_may_not_declare_a_default() raises:
    var decls = List[AppParamDecl]()
    decls.append(
        AppParamDecl(
            String("listen-address"), PARAM_REQUIRED, PARAM_KIND_LITERAL,
            String("0.0.0.0:8080"), String("Address the server binds."),
        )
    )
    var msg = String("")
    try:
        validate_param_decls(decls)
    except e:
        msg = String(e)
    _assert_contains(msg, String("A required parameter may not have one"))
    # And the render refuses the same declaration before rendering anything.
    var msg2 = String("")
    try:
        _ = render_app_params(String(_APP), decls, List[AppParamValue]())
    except e:
        msg2 = String(e)
    _assert_contains(msg2, String("A required parameter may not have one"))


# ── Unknown ──────────────────────────────────────────────────────────────────


def test_render_refuses_a_parameter_the_app_does_not_declare() raises:
    var values = _values()
    values.append(literal_param(String("bind-addr"), String("0.0.0.0")))
    var msg = String("")
    try:
        _ = render_app_params(String(_APP), _decls(), values)
    except e:
        msg = String(e)
    _assert_contains(msg, String("PHANTOM PARAMETER"))
    _assert_contains(msg, String("'bind-addr'"))


def test_parse_refuses_an_undeclared_flag() raises:
    var tokens = render_app_params(String(_APP), _decls(), _values())
    tokens.append(String("--bind-addr=0.0.0.0"))
    var msg = String("")
    try:
        _ = parse_app_params(String(_APP), _decls(), _with_program(tokens))
    except e:
        msg = String(e)
    _assert_contains(msg, String("no parameter named 'bind-addr' is declared"))


def test_parse_refuses_a_repeat_and_a_positional() raises:
    var tokens = render_app_params(String(_APP), _decls(), _values())
    tokens.append(String("--listen-address=127.0.0.1:1"))
    var msg = String("")
    try:
        _ = parse_app_params(String(_APP), _decls(), _with_program(tokens))
    except e:
        msg = String(e)
    _assert_contains(msg, String("'listen-address' was passed TWICE"))
    var positional = render_app_params(String(_APP), _decls(), _values())
    positional.append(String("serve"))
    var msg2 = String("")
    try:
        _ = parse_app_params(String(_APP), _decls(), _with_program(positional))
    except e:
        msg2 = String(e)
    _assert_contains(msg2, String("unexpected argument 'serve'"))


# ── Secret references ────────────────────────────────────────────────────────


def test_render_refuses_a_literal_for_a_secret_parameter() raises:
    var values = List[AppParamValue]()
    values.append(literal_param(String("listen-address"), String("0.0.0.0:8080")))
    values.append(
        reference_param(String("store-url"), String("s3://example-bucket/app"))
    )
    values.append(literal_param(String("signing-key"), String("raw-seed-bytes")))
    var msg = String("")
    try:
        _ = render_app_params(String(_APP), _decls(), values)
    except e:
        msg = String(e)
    _assert_contains(msg, String("NO LEAK VIOLATED"))
    _assert_contains(msg, String("'signing-key'"))
    # The refusal does not repeat the literal it refused.
    assert_true(msg.find("raw-seed-bytes") < 0, msg)


def test_a_runner_injected_parameter_may_not_be_declared_literal() raises:
    var decls = List[AppParamDecl]()
    decls.append(
        AppParamDecl(
            String("signing-key"), PARAM_RUNNER_INJECTED, PARAM_KIND_LITERAL,
            String(""), String("The secret that signs responses."),
        )
    )
    var msg = String("")
    try:
        validate_param_decls(decls)
    except e:
        msg = String(e)
    _assert_contains(msg, String("declared reference-only ('I')"))


def test_the_map_render_refuses_secret_material_in_a_secret_row() raises:
    var values = List[AppParamValue]()
    values.append(
        AppParamValue(
            String("signing-key"), String("raw-seed-bytes"),
            PARAM_KIND_SECRET_REFERENCE,
        )
    )
    var msg = String("")
    try:
        _ = render_app_param_argv(values)
    except e:
        msg = String(e)
    _assert_contains(msg, String("refusing to persist parameter 'signing-key'"))


# ── Empty values ─────────────────────────────────────────────────────────────


def test_an_empty_value_is_refused_at_every_end() raises:
    var values = _values()
    values.append(literal_param(String("label"), String("")))
    var msg = String("")
    try:
        _ = render_app_params(String(_APP), _decls(), values)
    except e:
        msg = String(e)
    _assert_contains(msg, String("EMPTY value for 'label'"))

    var empty_map = List[AppParamValue]()
    empty_map.append(literal_param(String("label"), String("")))
    var msg2 = String("")
    try:
        _ = render_app_param_argv(empty_map)
    except e:
        msg2 = String(e)
    _assert_contains(msg2, String("EMPTY transported value"))

    var tokens = render_app_params(String(_APP), _decls(), _values())
    tokens.append(String("--label="))
    var msg3 = String("")
    try:
        _ = parse_app_params(String(_APP), _decls(), _with_program(tokens))
    except e:
        msg3 = String(e)
    _assert_contains(msg3, String("'label' was passed with an EMPTY value"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
