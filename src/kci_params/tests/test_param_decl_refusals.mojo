# =============================================================================
# src/kci_params/tests/test_param_decl_refusals.mojo
#   Every refusal of a malformed declaration, a malformed supplied set and a
#   malformed argv, each asserted by the text that names what is wrong.
# =============================================================================
#
# The names tests walk both edges of each accepted byte range (`a`/`z`,
# `0`/`9`, `-`) and the byte just outside each edge, so a comparison that is
# off by one at either end refuses a good name or accepts a bad one. The
# duplicate tests put the repeat both adjacent and at a distance, and at the
# last position, so an inner loop that starts or stops one row early misses
# one of them.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from kci_params.app_params import (
    PARAM_KIND_LITERAL,
    PARAM_KIND_REFERENCE,
    PARAM_KIND_SECRET_REFERENCE,
    PARAM_OPTIONAL,
    PARAM_REQUIRED,
    PARAM_RUNNER_INJECTED,
    AppParamBinding,
    AppParamDecl,
    AppParamValue,
    find_param_decl,
    literal_param,
    param_kind_is_reference,
    param_kind_label,
    param_obligation_is_required,
    param_obligation_label,
    parse_app_params,
    reference_param,
    render_app_params,
    secret_reference_param,
    validate_param_decls,
    validate_param_name,
)

comptime _APP = "example-app"
comptime _SECRET = "projects/example-project/secrets/signing-key/versions/latest"


def _decl(name: String, obligation: String, kind: Int) -> AppParamDecl:
    return AppParamDecl(name, obligation, kind, String(""), String("A doc."))


def _decls() -> List[AppParamDecl]:
    var d = List[AppParamDecl]()
    d.append(_decl("listen-address", PARAM_REQUIRED, PARAM_KIND_LITERAL))
    d.append(
        AppParamDecl(
            String("max-batch"), PARAM_OPTIONAL, PARAM_KIND_LITERAL,
            String("1000"), String("Rows per flush."),
        )
    )
    d.append(_decl("store-url", PARAM_REQUIRED, PARAM_KIND_REFERENCE))
    d.append(
        _decl("signing-key", PARAM_RUNNER_INJECTED, PARAM_KIND_SECRET_REFERENCE)
    )
    d.append(_decl("label", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    return d^


def _values() -> List[AppParamValue]:
    var v = List[AppParamValue]()
    v.append(literal_param(String("listen-address"), String("0.0.0.0:8080")))
    v.append(reference_param(String("store-url"), String("s3://bucket/app")))
    v.append(secret_reference_param(String("signing-key"), String(_SECRET)))
    return v^


def _with_program(tokens: List[String]) -> List[String]:
    var argv = List[String]()
    argv.append(String("/app/example-app"))
    for i in range(len(tokens)):
        argv.append(tokens[i].copy())
    return argv^


# ── Labels and predicates ───────────────────────────────────────────────────


def test_obligation_labels_and_the_required_predicate() raises:
    assert_equal(param_obligation_label(PARAM_REQUIRED), "REQUIRED")
    assert_equal(
        param_obligation_label(PARAM_RUNNER_INJECTED),
        "REQUIRED (reference-only)",
    )
    assert_equal(param_obligation_label(PARAM_OPTIONAL), "OPTIONAL")
    assert_equal(param_obligation_label("X"), "UNKNOWN('X')")
    assert_equal(param_obligation_label(""), "UNKNOWN('')")
    assert_true(param_obligation_is_required(PARAM_REQUIRED))
    assert_true(param_obligation_is_required(PARAM_RUNNER_INJECTED))
    assert_false(param_obligation_is_required(PARAM_OPTIONAL))
    assert_false(param_obligation_is_required("r"))


def test_kind_labels_and_the_reference_predicate() raises:
    assert_equal(param_kind_label(PARAM_KIND_LITERAL), "LITERAL")
    assert_equal(param_kind_label(PARAM_KIND_REFERENCE), "REFERENCE")
    assert_equal(
        param_kind_label(PARAM_KIND_SECRET_REFERENCE), "SECRET_REFERENCE"
    )
    assert_equal(param_kind_label(3), "UNKNOWN(3)")
    assert_equal(param_kind_label(-1), "UNKNOWN(-1)")
    assert_false(param_kind_is_reference(PARAM_KIND_LITERAL))
    assert_true(param_kind_is_reference(PARAM_KIND_REFERENCE))
    assert_true(param_kind_is_reference(PARAM_KIND_SECRET_REFERENCE))
    assert_false(param_kind_is_reference(3))


# ── Names ───────────────────────────────────────────────────────────────────


def test_a_name_at_every_edge_of_the_kebab_set_is_accepted() raises:
    # `a` and `z` (97, 122), `0` and `9` (48, 57), and an inner `-` (45).
    validate_param_name("az-09")
    validate_param_name("z")
    validate_param_name("9")
    validate_param_name("a--b")
    var d = List[AppParamDecl]()
    d.append(_decl("a0", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    d.append(_decl("z9-x", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    validate_param_decls(d)


def test_an_empty_name_is_refused() raises:
    with assert_raises(contains="a parameter with an EMPTY name"):
        validate_param_name("")


def test_a_leading_dash_is_refused_with_the_bare_name_advice() raises:
    with assert_raises(contains="parameter name '-a' starts with '-'"):
        validate_param_name("-a")
    with assert_raises(contains="parameter name '--a' starts with '-'"):
        validate_param_name("--a")
    with assert_raises(contains="parameter name '-' starts with '-'"):
        validate_param_name("-")


def test_a_trailing_dash_is_refused() raises:
    with assert_raises(contains="parameter name 'a-' ends with '-'"):
        validate_param_name("a-")
    with assert_raises(contains="parameter name 'ab-c-' ends with '-'"):
        validate_param_name("ab-c-")


def test_a_byte_just_outside_each_kebab_range_is_refused() raises:
    # `/` 47 and `:` 58 flank the digits; a backquote 96 and `{` 123 flank
    # the lowercase letters; `,` 44 and `.` 46 flank `-`.
    var bad = List[String]()
    bad.append("a/")
    bad.append("a:b")
    bad.append("x`")
    bad.append("x{")
    bad.append("a,b")
    bad.append("a.b")
    bad.append("Ab")
    bad.append("a_b")
    bad.append("a=b")
    bad.append("a b")
    bad.append("aé")
    for i in range(len(bad)):
        var msg = String("")
        try:
            validate_param_name(bad[i])
        except e:
            msg = String(e)
        assert_true(
            msg.find(
                String("parameter name '")
                + bad[i]
                + "' contains a byte outside lowercase-kebab"
            )
            >= 0,
            String("name ") + bad[i] + " got: " + msg,
        )


def test_a_decl_set_refuses_a_bad_name_in_any_row() raises:
    var d = List[AppParamDecl]()
    d.append(_decl("ok", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    d.append(_decl("Bad", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    with assert_raises(contains="parameter name 'Bad' contains a byte"):
        validate_param_decls(d)


# ── Obligation and kind codes ───────────────────────────────────────────────


def test_an_unknown_obligation_code_is_refused() raises:
    var codes = List[String]()
    codes.append("X")
    codes.append("")
    codes.append("r")
    codes.append("RO")
    for i in range(len(codes)):
        var d = List[AppParamDecl]()
        d.append(_decl("ok", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
        d.append(_decl("p", codes[i], PARAM_KIND_LITERAL))
        var msg = String("")
        try:
            validate_param_decls(d)
        except e:
            msg = String(e)
        assert_true(
            msg.find(
                String("parameter 'p' has unknown obligation code '")
                + codes[i]
                + "' (expected 'R', 'I' or 'O')"
            )
            >= 0,
            String("code '") + codes[i] + "' got: " + msg,
        )


def test_an_unknown_kind_ordinal_is_refused() raises:
    var kinds = List[Int]()
    kinds.append(3)
    kinds.append(-1)
    kinds.append(99)
    for i in range(len(kinds)):
        var d = List[AppParamDecl]()
        d.append(_decl("p", PARAM_OPTIONAL, kinds[i]))
        var msg = String("")
        try:
            validate_param_decls(d)
        except e:
            msg = String(e)
        assert_true(
            msg.find(
                String("parameter 'p' has unknown kind ordinal ")
                + String(kinds[i])
            )
            >= 0,
            String("kind ") + String(kinds[i]) + " got: " + msg,
        )


def test_every_obligation_with_every_allowed_kind_is_accepted() raises:
    var d = List[AppParamDecl]()
    d.append(_decl("r0", PARAM_REQUIRED, PARAM_KIND_LITERAL))
    d.append(_decl("r1", PARAM_REQUIRED, PARAM_KIND_REFERENCE))
    d.append(_decl("r2", PARAM_REQUIRED, PARAM_KIND_SECRET_REFERENCE))
    d.append(_decl("i1", PARAM_RUNNER_INJECTED, PARAM_KIND_REFERENCE))
    d.append(_decl("i2", PARAM_RUNNER_INJECTED, PARAM_KIND_SECRET_REFERENCE))
    d.append(_decl("o0", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    d.append(_decl("o1", PARAM_OPTIONAL, PARAM_KIND_REFERENCE))
    d.append(_decl("o2", PARAM_OPTIONAL, PARAM_KIND_SECRET_REFERENCE))
    validate_param_decls(d)


def test_a_runner_injected_default_names_the_reference_only_label() raises:
    var d = List[AppParamDecl]()
    d.append(
        AppParamDecl(
            String("token"), PARAM_RUNNER_INJECTED, PARAM_KIND_REFERENCE,
            String("projects/p/secrets/s"), String("A doc."),
        )
    )
    with assert_raises(
        contains="'token' is REQUIRED (reference-only) and also declares a"
        " default ('projects/p/secrets/s')"
    ):
        validate_param_decls(d)


def test_an_optional_may_carry_a_default() raises:
    var d = List[AppParamDecl]()
    d.append(
        AppParamDecl(
            String("o"), PARAM_OPTIONAL, PARAM_KIND_REFERENCE,
            String("x"), String("A doc."),
        )
    )
    validate_param_decls(d)


# ── Duplicate declarations ──────────────────────────────────────────────────


def test_a_name_declared_twice_is_refused_adjacent_and_at_a_distance() raises:
    var adjacent = List[AppParamDecl]()
    adjacent.append(_decl("x", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    adjacent.append(_decl("a", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    adjacent.append(_decl("a", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    with assert_raises(contains="parameter 'a' is declared TWICE"):
        validate_param_decls(adjacent)
    var apart = List[AppParamDecl]()
    apart.append(_decl("a", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    apart.append(_decl("x", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    apart.append(_decl("y", PARAM_OPTIONAL, PARAM_KIND_LITERAL))
    apart.append(_decl("a", PARAM_REQUIRED, PARAM_KIND_LITERAL))
    with assert_raises(contains="parameter 'a' is declared TWICE"):
        validate_param_decls(apart)
    # The render and the parse refuse the same set before using it.
    with assert_raises(contains="parameter 'a' is declared TWICE"):
        _ = render_app_params(_APP, apart, List[AppParamValue]())
    with assert_raises(contains="parameter 'a' is declared TWICE"):
        _ = parse_app_params(_APP, apart, _with_program(List[String]()))


# ── Lookup ──────────────────────────────────────────────────────────────────


def test_find_param_decl_returns_the_named_row_or_lists_the_set() raises:
    var decls = _decls()
    var d = find_param_decl(decls, "max-batch")
    assert_equal(d.name, "max-batch")
    assert_equal(d.obligation, PARAM_OPTIONAL)
    assert_equal(d.kind, PARAM_KIND_LITERAL)
    assert_equal(d.default_value, "1000")
    assert_equal(d.doc, "Rows per flush.")
    var last = find_param_decl(decls, "label")
    assert_equal(last.name, "label")
    with assert_raises(
        contains="no parameter named 'nope' is declared. Declared parameters:"
        " [listen-address, max-batch, store-url, signing-key, label]"
    ):
        _ = find_param_decl(decls, "nope")
    with assert_raises(contains="Declared parameters: []"):
        _ = find_param_decl(List[AppParamDecl](), "nope")


# ── Supplied values ─────────────────────────────────────────────────────────


def test_render_refuses_a_value_supplied_twice() raises:
    var values = _values()
    values.append(literal_param("listen-address", "127.0.0.1:1"))
    with assert_raises(
        contains="the deploy of 'example-app' supplies 'listen-address' TWICE"
    ):
        _ = render_app_params(_APP, _decls(), values)
    # The repeat as the last two rows: the inner scan must reach the end.
    var tail = _values()
    tail.append(literal_param("label", "a"))
    tail.append(literal_param("label", "b"))
    with assert_raises(contains="supplies 'label' TWICE"):
        _ = render_app_params(_APP, _decls(), tail)


def test_a_phantom_names_every_declared_parameter() raises:
    var values = _values()
    values.append(literal_param("bind-addr", "x"))
    with assert_raises(
        contains="Declared parameters: [listen-address, max-batch, store-url,"
        " signing-key, label]"
    ):
        _ = render_app_params(_APP, _decls(), values)


def test_render_refuses_a_reference_for_a_literal_parameter() raises:
    var values = _values()
    values[0] = reference_param("listen-address", "s3://bucket/addr")
    with assert_raises(
        contains="the deploy of 'example-app' supplies a REFERENCE for"
        " 'listen-address', which the app declares LITERAL"
    ):
        _ = render_app_params(_APP, _decls(), values)
    var secret = _values()
    secret[0] = secret_reference_param("listen-address", _SECRET)
    with assert_raises(
        contains="supplies a SECRET_REFERENCE for 'listen-address'"
    ):
        _ = render_app_params(_APP, _decls(), secret)


def test_render_refuses_a_literal_for_a_plain_reference_parameter() raises:
    var values = _values()
    values[1] = literal_param("store-url", "s3://bucket/app")
    with assert_raises(
        contains="NO LEAK VIOLATED — the deploy of 'example-app' supplies a"
        " LITERAL for 'store-url', which the app declares REFERENCE"
    ):
        _ = render_app_params(_APP, _decls(), values)


def test_a_missing_runner_injected_parameter_is_refused_at_both_ends() raises:
    var values = _values()
    _ = values.pop()
    with assert_raises(
        contains="supplies no value for 'signing-key' (REQUIRED"
        " (reference-only))"
    ):
        _ = render_app_params(_APP, _decls(), values)
    var tokens = List[String]()
    tokens.append("--listen-address=a")
    tokens.append("--store-url=b")
    with assert_raises(
        contains="REQUIRED parameter '--signing-key' was not supplied (REQUIRED"
        " (reference-only))"
    ):
        _ = parse_app_params(_APP, _decls(), _with_program(tokens))


# ── Parse ───────────────────────────────────────────────────────────────────


def test_a_flag_with_no_following_value_is_refused() raises:
    var tokens = render_app_params(_APP, _decls(), _values())
    tokens.append("--label")
    with assert_raises(
        contains="example-app: flag '--label' requires a value"
    ):
        _ = parse_app_params(_APP, _decls(), _with_program(tokens))


def test_the_two_token_spelling_as_the_last_pair_parses() raises:
    var tokens = render_app_params(_APP, _decls(), _values())
    tokens.append("--label")
    tokens.append("shown")
    var bound = parse_app_params(_APP, _decls(), _with_program(tokens))
    assert_equal(bound.get("label"), "shown")
    assert_equal(bound.count(), 5)


def test_argv_zero_is_the_program_and_is_never_parsed() raises:
    # argv[0] looks like a flag here; it is skipped, not refused as unknown.
    var argv = List[String]()
    argv.append("--not-a-param")
    argv.append("--listen-address=a")
    argv.append("--store-url=b")
    argv.append("--signing-key=" + _SECRET)
    var bound = parse_app_params(_APP, _decls(), argv)
    assert_equal(bound.get("listen-address"), "a")
    assert_false(bound.has("not-a-param"))


def test_an_unbound_read_is_refused_naming_what_is_bound() raises:
    var tokens = render_app_params(_APP, _decls(), _values())
    var bound = parse_app_params(_APP, _decls(), _with_program(tokens))
    with assert_raises(
        contains="no parameter 'label' is bound. Bound parameters:"
        " [listen-address, max-batch, store-url, signing-key]"
    ):
        _ = bound.get("label")
    var empty = AppParamBinding()
    assert_equal(empty.count(), 0)
    assert_false(empty.has("x"))
    with assert_raises(contains="no parameter 'x' is bound. Bound parameters: []"):
        _ = empty.get("x")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
