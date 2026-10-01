# =============================================================================
# kci_bundle/tests/test_validate.mojo
#   — the semantic validation pass (field-precise, self-correctable).
# =============================================================================
#
# The semantic pass catches the convergence-breaking authoring bugs a purely
# structural parse cannot: missing per-kind
# required fields, empty wave `env` symbols, oneof arms with zero arms set, and a
# missing required gate. These tests pin each rule fires (and that a clean bundle
# produces ZERO errors). Coverage complements test_parse_errors.mojo (which owns
# the dangling-from_build + parse-time goldens).
#
# Encapsulation: pure parse + validate + list asserts. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_bundle.parser import parse_bundle
from kci_bundle.validate import validate_bundle


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _any_contains(errs: List[String], needle: String) -> Bool:
    for ref e in errs:
        if e.find(needle) >= 0:
            return True
    return False


def test_clean_bundle_has_no_errors() raises:
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        'waves { env: "dev" }\n'
    )
    assert_equal(len(_errs(text)), 0, "a valid bundle produces no errors")
    print("  test_clean_bundle_has_no_errors: PASS")


def test_missing_top_level_required_fields() raises:
    """No kind, no name, no spec, no wave -> four required-field errors."""
    var text = String('build { name: "service" dockerfile: "Dockerfile" }\n')
    var errs = _errs(text)
    assert_true(_any_contains(errs, String("'kind' is required")), "kind req")
    assert_true(_any_contains(errs, String("'name' is required")), "name req")
    assert_true(_any_contains(errs, String("'spec' is required")), "spec req")
    assert_true(
        _any_contains(errs, String("at least one wave is required")), "wave req"
    )
    print("  test_missing_top_level_required_fields: PASS")


def test_empty_wave_env_symbol() raises:
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves { }\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("waves[0]: 'env' is required")),
        "empty wave env flagged",
    )
    print("  test_empty_wave_env_symbol: PASS")


def test_image_with_zero_oneof_arms() raises:
    """An `image { }` block with no arm is an exactly-one-oneof-arm error."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec { image { } port: 8080 }\n"
        'waves { env: "dev" }\n'
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(
            errs, String("spec.image: set exactly one of {digest, from_build}")
        ),
        "zero-arm image flagged",
    )
    print("  test_image_with_zero_oneof_arms: PASS")


def test_api_requires_positive_port() raises:
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } }\n'
        'waves { env: "dev" }\n'
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("'port' is required (> 0) for an APP_KIND_API")),
        "API port required",
    )
    print("  test_api_requires_positive_port: PASS")


def test_run_container_requires_gate_on() raises:
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "integ" dockerfile: "Dockerfile.integ" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "integ"\n'
        '    run_container { image { from_build: "integ" } }\n'
        "  }\n"
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("'gate_on' is required (GATE_ON_EXIT_CODE)")),
        "gate_on required",
    )
    print("  test_run_container_requires_gate_on: PASS")


# ═══════════════════════════════════════════════════════════════════════════
#  ★ A `service_ref` ENV ON A VALIDATE STEP — THE SILENT DROP
# ═══════════════════════════════════════════════════════════════════════════
#
# `BundleEnvVar` carries three arms, and the THIRD one means something different
# depending on WHERE it is authored:
#
#   * on `spec.env` (a SERVED container) `service_ref` is live and load-bearing.
#     The compose pass turns it into an INVOKE_SERVICE grant node and the
#     peer-name marker, and the runtime URL comes from the ServiceRegistry
#     (registry-first, env-fallback).
#
#   * on a `waves{} validate{} run_container{}` env it resolves to EMPTY and is
#     DROPPED WITHOUT A WORD: the validate driver resolves arm 3 to `""` and
#     drops every empty resolution.
#
# ⚠ WHY THAT IS THE DANGEROUS DIRECTION. The step's container starts, and the
# variable is simply ABSENT. For a key the validator requires that is a loud
# first-line exit. For a key it reads with a DEFAULT it is silent, and the
# validator dials the default — a probe defaulting a peer URL to
# `http://127.0.0.1:<port>` would report green about LOCALHOST while the operator
# reads a bundle that says it points at a sibling service.
#
# ⚠ AND IT IS THE CONSTRUCT PEOPLE WILL REACH FOR FIRST. "Endpoints are
# REFERENCES that resolve at deploy time, not literals stamped into a bundle" —
# and `service_ref` is, syntactically, exactly that. Authoring it on a validate
# step is the obvious move and it fails quiet. A comment cannot converge; this
# is that comment given a wire.
#
# ⛔ WHEN THE RESOLUTION LANDS, INVERT THIS — DO NOT DELETE IT. Once a validate
# step CAN resolve a sibling endpoint, this assertion becomes "the
# ref RESOLVES", asserted against the resolved value. Deleting it would return
# the silent drop to the exact construct the new shape encourages.


def _service_ref_bundle(where_env: String, where_validate: String) -> String:
    """One bundle, with the `service_ref` env authored either on the SERVED spec
    or on a validate step — the NARROW difference the refusal must key on."""
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "integ" dockerfile: "Dockerfile.integ" }\n'
        "spec {\n"
        '  image { from_build: "service" }\n'
        "  port: 8080\n"
        + where_env
        + "}\n"
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "integ"\n'
        "    run_container {\n"
        '      image { from_build: "integ" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
        + where_validate
        + "    }\n"
        "  }\n"
        "}\n"
    )


comptime _SVC_REF_ENV: String = (
    '  env { name: "API_GATEWAY_URL" service_ref { service: "orders-api" } }\n'
)


def test_a_service_ref_env_on_a_validate_step_is_refused() raises:
    """FAILS ON PRE-FIX CODE: `_check_run_container` walked `rc.env` and called
    `_check_env`, which handles arm 0 (no arm) and arm 2 (`value_from`) and lets
    arm 3 (`service_ref`) fall through unremarked — because on `spec.env`, the
    other caller of that same helper, arm 3 is CORRECT. So this bundle produced
    ZERO errors, composed, deployed, and reached the container with
    `API_GATEWAY_URL` absent.

    The pre-fix run of this test asserts on an error list of length 0."""
    var errs = _errs(_service_ref_bundle(String(""), _SVC_REF_ENV))
    assert_true(
        _any_contains(errs, String("'service_ref' resolves to NOTHING")),
        "a service_ref env on a validate step is refused by name",
    )
    # The refusal must name the KEY, not just the step: a step may carry a dozen
    # envs and "one of them is wrong" is not an actionable 3am message.
    assert_true(
        _any_contains(errs, String("API_GATEWAY_URL")),
        "the refusal names the offending env key",
    )
    print("  test_a_service_ref_env_on_a_validate_step_is_refused: PASS")


def test_a_service_ref_env_on_the_served_spec_is_still_accepted() raises:
    """★ THE POSITIVE CONTROL, AND IT IS THE HALF THAT MAKES THE REFUSAL SAFE.

    The SAME `service_ref` env, moved to `spec.env`, must still validate CLEAN.
    Served bundles depend on it: compose turns each into an INVOKE_SERVICE
    grant, so a refusal that keyed on the ARM rather than on the
    ARM-AND-THE-CONTEXT would stop every such deploy.

    This is the narrow difference the fix must key on, exhibited rather than
    argued."""
    var errs = _errs(_service_ref_bundle(_SVC_REF_ENV, String("")))
    assert_equal(
        len(errs),
        0,
        "a service_ref env on the SERVED spec is legal and must stay legal —"
        " it is how control-plane bundles compose their run.invoker grants",
    )
    print("  test_a_service_ref_env_on_the_served_spec_is_still_accepted: PASS")


def test_http_check_bad_status() raises:
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves {\n"
        '  env: "dev"\n'
        '  validate { name: "up" http_check { path: "/healthz" expect_status: 7 } }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("is not a valid HTTP status")),
        "bad http status flagged",
    )
    print("  test_http_check_bad_status: PASS")


def test_http_check_max_latency_ms_opt_in_and_negative_refused() raises:
    """★ `HttpCheck.max_latency_ms` (field 3) — the validator's
    two obligations for the latency budget.

    (1) OMITTED IS LEGAL, AND SILENT. The budget is OPT-IN: a step that does
        not author one is latency-UNCHECKED, exactly as every `http_check` in
        the tree behaved before the field existed. `validate_bundle` must not
        warn, must not require it, and must not acquire a default — retrofitting
        a budget onto every authored step at once means guessing a number per
        route with no measurement behind it.
    (2) A NEGATIVE VALUE IS REFUSED BY NAME. "Do not check latency" already has
        exactly ONE spelling (omit the field, leaving the proto3 zero), so a
        negative number cannot express it — it is a typo (`-1` reaching for
        "unset", a mis-signed generator), and flooring it to zero would
        reproduce this field's own founding defect one level up: an assertion
        the author believes they wrote, which asserts nothing.

    FAILS ON PRE-FIX CODE: leg (2) has no check at all — a negative budget
    parses (once the parser knows the field) and validates clean, so
    `len(errs) == 0` and the `is negative` assertion below fails."""
    # (1) the OPT-IN default — no budget authored, no error.
    var omitted = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves {\n"
        '  env: "dev"\n'
        '  validate { name: "up" http_check { path: "/readyz" expect_status: 200 } }\n'
        "}\n"
    )
    assert_equal(
        len(_errs(omitted)),
        0,
        "an http_check with NO max_latency_ms is legal — the budget is OPT-IN",
    )
    # A POSITIVE budget is equally legal (the whole point of the field).
    var budgeted = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves {\n"
        '  env: "dev"\n'
        '  validate { name: "up" http_check { path: "/readyz" expect_status: 200'
        " max_latency_ms: 2000 } }\n"
        "}\n"
    )
    assert_equal(
        len(_errs(budgeted)), 0, "a POSITIVE max_latency_ms is legal"
    )
    # (2) NEGATIVE is refused, and the message says what to do instead.
    var negative = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves {\n"
        '  env: "dev"\n'
        '  validate { name: "up" http_check { path: "/readyz" expect_status: 200'
        " max_latency_ms: -1 } }\n"
        "}\n"
    )
    var errs = _errs(negative)
    assert_true(
        _any_contains(errs, String("'max_latency_ms' -1 is negative")),
        "a negative latency budget is refused, quoting the value",
    )
    assert_true(
        _any_contains(errs, String("Omit the field to leave latency UNCHECKED")),
        "the refusal names the correct spelling of 'do not check latency'",
    )
    print("  test_http_check_max_latency_ms_opt_in_and_negative_refused: PASS")


def test_static_frontend_image_optional() raises:
    """A STATIC_FRONTEND deploys NO container (the SPA content is PUBLISHED to
    the front door's bucket) — its spec.image is OPTIONAL. Every other kind
    keeps the image-required rule (the API case below still flags it)."""
    var text = String(
        "kind: APP_KIND_STATIC_FRONTEND\n"
        'name: "orders-web"\n'
        "spec {\n"
        '  web_slug: "orders-prod"\n'
        '  web_domain: "example.com"\n'
        "}\n"
        'waves { env: "prod" }\n'
    )
    assert_equal(
        len(_errs(text)),
        0,
        "a STATIC_FRONTEND bundle without an image is valid",
    )
    # The image-required rule still fires for an API bundle.
    var api_text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec { port: 8080 }\n"
        'waves { env: "dev" }\n'
    )
    assert_true(
        _any_contains(_errs(api_text), String("'image' is required")),
        "an API bundle without an image is still flagged",
    )
    print("  test_static_frontend_image_optional: PASS")


# =============================================================================
# ★ SECURED INBOUND ROUTES (AppSpec field 26; federated callers). EVERY rule
#   here fails CLOSED, and the reason is a property of
#   the target rather than a taste: ESPv2 ACCEPTS a document whose operation
#   names a `security` requirement no `securityDefinitions` entry defines, and it
#   leaves that route OPEN. So an under-specified secured route must be REFUSED,
#   never rendered as something weaker — for a webhook app the weaker thing is a
#   public POST into it.
# =============================================================================

comptime _SECURED_HEAD: String = (
    "kind: APP_KIND_API\n"
    'name: "svc"\n'
    'build { name: "service" dockerfile: "Dockerfile" }\n'
)


def _secured_spec(body: String) -> String:
    """A minimal WEBHOOK bundle whose spec carries `body` verbatim."""
    return (
        _SECURED_HEAD
        + String("spec {\n")
        + String('  image { from_build: "service" }\n')
        + String("  port: 8080\n")
        + String("  inbound: INBOUND_NEED_WEBHOOK\n")
        + String('  inbound_route_path: "/mail/inbound"\n')
        + body
        + String("}\n")
        + String('waves { env: "dev" }\n')
    )


comptime _GOOD_SECURED: String = (
    "  secured_inbound_routes {\n"
    '    route_path: "/mail/ses-inbound"\n'
    "    policy: EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT\n"
    '    sa_email: "router@p.iam.gserviceaccount.com"\n'
    "  }\n"
)


def test_a_well_formed_secured_route_validates() raises:
    """THE POSITIVE CONTROL. Without it every refusal below could be a validator
    that refuses everything, which passes the same assertions."""
    assert_equal(
        len(_errs(_secured_spec(_GOOD_SECURED))),
        0,
        "a well-formed secured route produces no errors",
    )
    print("  test_a_well_formed_secured_route_validates: PASS")


def test_secured_route_requires_a_webhook_inbound_need() raises:
    """A secured route is an ADDITIONAL route on the SINGLE_PATH inbound edge.
    Without that edge there is nothing to attach it to and compose would DROP it
    silently — the author would read a declaration and get no route."""
    var text = (
        _SECURED_HEAD
        + String("spec {\n")
        + String('  image { from_build: "service" }\n')
        + String("  port: 8080\n")
        + _GOOD_SECURED
        + String("}\n")
        + String('waves { env: "dev" }\n')
    )
    assert_true(
        _any_contains(
            _errs(text), String("requires 'inbound: INBOUND_NEED_WEBHOOK'")
        ),
        "a secured route with no WEBHOOK inbound need is refused",
    )
    print("  test_secured_route_requires_a_webhook_inbound_need: PASS")


def test_an_unspecified_policy_is_refused() raises:
    """★ THE ZERO VALUE MUST REFUSE. `policy` unset is UNSPECIFIED, and the
    failure mode of defaulting it to anything permissive is a route the author
    called secured that the gateway serves open."""
    var text = _secured_spec(
        String(
            "  secured_inbound_routes {\n"
            '    route_path: "/mail/ses-inbound"\n'
            '    sa_email: "router@p.iam.gserviceaccount.com"\n'
                    "  }\n"
        )
    )
    assert_true(
        _any_contains(
            _errs(text),
            String("'policy' must be EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT"),
        ),
        "an UNSPECIFIED policy is refused",
    )
    print("  test_an_unspecified_policy_is_refused: PASS")


def test_an_explicitly_non_federated_policy_is_refused() raises:
    """The SAME refusal spelled explicitly rather than by omission — the two are
    different authoring mistakes and only one of them is a typo."""
    var text = _secured_spec(
        String(
            "  secured_inbound_routes {\n"
            '    route_path: "/mail/ses-inbound"\n'
            "    policy: EDGE_AUTH_POLICY_KIND_UNSPECIFIED\n"
            '    sa_email: "router@p.iam.gserviceaccount.com"\n'
                    "  }\n"
        )
    )
    assert_true(
        _any_contains(
            _errs(text),
            String("'policy' must be EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT"),
        ),
        "an explicitly non-federated policy is refused",
    )
    print("  test_an_explicitly_non_federated_policy_is_refused: PASS")


def test_a_secured_route_colliding_with_the_pass_through_is_refused() raises:
    """Two `paths:` keys with one value: the LAST wins in the rendered document,
    so one of the two policies vanishes with nothing to observe it. If the
    survivor is the pass-through, the SES route is public; if it is the secured
    one, Postmark 401s and mail stops arriving."""
    var text = _secured_spec(
        String(
            "  secured_inbound_routes {\n"
            '    route_path: "/mail/inbound"\n'
            "    policy: EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT\n"
            '    sa_email: "router@p.iam.gserviceaccount.com"\n'
                    "  }\n"
        )
    )
    assert_true(
        _any_contains(
            _errs(text), String("collides with 'inbound_route_path'")
        ),
        "a secured route colliding with the pass-through route is refused",
    )
    print("  test_a_secured_route_colliding_with_the_pass_through_is_refused: PASS")


def test_two_secured_routes_with_different_service_accounts_are_refused() raises:
    """★ THE RENDER EMITS ONE SECURITY DEFINITION FOR THE WHOLE EDGE. Two callers
    would collapse into it and one principal would silently replace the other —
    and the pin would still read as configured."""
    var text = _secured_spec(
        _GOOD_SECURED
        + String(
            "  secured_inbound_routes {\n"
            '    route_path: "/mail/other-inbound"\n'
            "    policy: EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT\n"
            '    sa_email: "other@p.iam.gserviceaccount.com"\n'
                    "  }\n"
        )
    )
    assert_true(
        _any_contains(_errs(text), String("differs from an earlier secured route")),
        "two secured routes naming different service accounts are refused",
    )
    print(
        "  test_two_secured_routes_with_different_service_accounts_are_refused:"
        " PASS"
    )


def test_secured_route_audience_is_not_authorable() raises:
    """★★ A BUNDLE THAT SPELLS `audience:` IS REFUSED, BY NAME, WITH THE REASON.

    A "non-empty" check would be a check on the SHAPE of a value nothing offline
    can check the CONTENT of: a bundle authoring `https://stage.example.com` (a
    mail domain, not a gateway origin) satisfies "non-empty" perfectly while
    being wrong for every deployment.

    The accepted `aud` must equal the ORIGIN OF THE GATEWAY THAT SERVES THE
    ROUTE, and a gateway hostname is generated by the cloud at Gateway CREATE —
    strictly after the ApiConfig whose document carries it. Nothing authorable
    can be right except by luck, so there is no field and the spelling is
    REFUSED rather than ignored: an ignored field keeps looking like the thing in
    control.

    ⚠️ THE REFUSAL IS A PARSE ERROR, NOT A VALIDATE ERROR, and that is deliberate
    — `validate` never sees a field the parser will not build. So this drives
    `parse_bundle` directly and asserts the RAISE."""
    var text = _secured_spec(
        String(
            "  secured_inbound_routes {\n"
            '    route_path: "/mail/ses-inbound"\n'
            "    policy: EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT\n"
            '    sa_email: "router@p.iam.gserviceaccount.com"\n'
            '    audience: "https://stage.example.com"\n'
            "  }\n"
        )
    )
    var raised = False
    var msg = String("")
    try:
        _ = parse_bundle(text)
    except e:
        msg = String(e)
        raised = True
    assert_true(
        raised,
        "★ a bundle authoring `audience:` was ACCEPTED. Every value it can hold"
        " is a guess at a hostname the cloud has not chosen yet, and a wrong"
        " guess fails CLOSED and SILENT (a bare 401, no body, mail stops).",
    )
    # ⛔ AND THE REFUSAL MUST BE ATTRIBUTABLE. "unknown field" would send the
    # author looking for a typo instead of telling them the value is derived now.
    assert_true(
        String("no longer an authorable field") in msg,
        String(
            "the refusal does not explain itself — an author who is told only"
            " 'unknown field' will re-add it under another name. Got: "
        )
        + msg,
    )
    assert_true(
        String("Gateway CREATE") in msg,
        String("the refusal does not say WHY it cannot be authored. Got: ") + msg,
    )
    # POSITIVE CONTROL — the same bundle WITHOUT the line parses and validates.
    assert_equal(
        len(_errs(_secured_spec(_GOOD_SECURED))),
        0,
        "control: the refusal is the `audience:` line, not the block",
    )
    print("  test_secured_route_audience_is_not_authorable: PASS")


def test_an_empty_sa_email_is_refused() raises:
    """`sa_email` is BOTH the issuer and the account whose keys the edge fetches.
    An empty one renders a definition no token can satisfy — every request 401s,
    which reads as a broken deploy rather than as this."""
    var text = _secured_spec(
        String(
            "  secured_inbound_routes {\n"
            '    route_path: "/mail/ses-inbound"\n'
            "    policy: EDGE_AUTH_POLICY_KIND_FEDERATED_SA_JWT\n"
                    "  }\n"
        )
    )
    assert_true(
        _any_contains(_errs(text), String("'sa_email' is required")),
        "an empty sa_email is refused",
    )
    print("  test_an_empty_sa_email_is_refused: PASS")


# ═══════════════════════════════════════════════════════════════════════════
# ★ `RunContainer.vpc_egress` (field 7) — the DIRECT VPC EGRESS
# attachment a validate step's JOB carries.
#
# ⛔ WHY A HALF-FILLED BLOCK MUST BE A LOAD-TIME REFUSAL AND NOT A QUIET DROP.
# Cloud Run rejects a `networkInterfaces` entry missing either half, so the render
# deliberately emits NOTHING for one — which means a bundle authoring
# `vpc_egress { network: "default" }` and nothing else would READ as attached to
# the VPC while the placed job egressed over the PUBLIC INTERNET. That is exactly
# the prose-says-one-thing / wire-says-another failure this field exists to end,
# and reproducing it inside the field's own implementation would be the worst
# available outcome. So it is refused offline, where it costs nothing.
# ═══════════════════════════════════════════════════════════════════════════
def _vpc_egress_bundle(block: String) -> String:
    """One bundle whose single validate step carries `block` inside its
    `run_container` — the vpc_egress arm under test, or nothing at all."""
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "integ" dockerfile: "Dockerfile.integ" }\n'
        "spec {\n"
        '  image { from_build: "service" }\n'
        "  port: 8080\n"
        "}\n"
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "integ"\n'
        "    run_container {\n"
        '      image { from_build: "integ" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n" + block + "    }\n"
        "  }\n"
        "}\n"
    )


def test_no_vpc_egress_block_is_legal_and_is_the_default() raises:
    """★ THE CONTROL, AND THE ROW THAT MATTERS MOST. A step authoring NO
    `vpc_egress` validates CLEAN — because that is the ordinary step, and a
    refusal keying on absence would stop every deploy.

    It also states what absence MEANS: no block => no `vpcAccess` on the CreateJob
    wire => the job egresses over the PUBLIC INTERNET and cannot reach a service
    whose ingress is `internal-and-cloud-load-balancing`. Legal, unchanged, and
    not neutral."""
    var errs = _errs(_vpc_egress_bundle(String("")))
    assert_equal(
        len(errs),
        0,
        "a step with no vpc_egress block is legal — it is the ordinary"
        " validate step, and it means the job is on the public"
        " internet",
    )
    print("  test_no_vpc_egress_block_is_legal_and_is_the_default: PASS")


def test_a_well_formed_vpc_egress_block_validates() raises:
    """The positive control: both halves named => clean."""
    var errs = _errs(
        _vpc_egress_bundle(
            String(
                "      vpc_egress {\n"
                '        network: "default"\n'
                '        subnetwork: "default"\n'
                "      }\n"
            )
        )
    )
    assert_equal(
        len(errs), 0, "a network + subnetwork is the shape Cloud Run accepts"
    )
    print("  test_a_well_formed_vpc_egress_block_validates: PASS")


def test_a_vpc_egress_without_a_subnetwork_is_refused() raises:
    """FALSIFIER: `vpc_egress { network: "default" }` — no subnetwork — is
    REFUSED, naming the missing field.

    Without this the bundle composes, deploys, and places a job with NO attachment
    at all (the render drops a half-filled interface rather than emit one Cloud
    Run rejects). The deploy would read as VPC-attached and behave as
    public-internet — silently."""
    var errs = _errs(
        _vpc_egress_bundle(
            String(
                "      vpc_egress {\n" '        network: "default"\n' "      }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("'vpc_egress' declares no 'subnetwork'")),
        "a vpc_egress without a subnetwork is refused by name",
    )
    # ⚠ AND THE MESSAGE MUST STATE THE CONSEQUENCE, not merely that a field is
    # missing. "subnetwork is required" leaves the reader to guess whether the
    # deploy FAILS or quietly degrades. It quietly degrades, and that is the
    # sentence worth reading at 3am.
    assert_true(
        _any_contains(errs, String("public internet")),
        "the refusal states the CONSEQUENCE — the job would egress over the"
        " public internet while the bundle read as attached",
    )
    print("  test_a_vpc_egress_without_a_subnetwork_is_refused: PASS")


def test_a_vpc_egress_without_a_network_is_refused() raises:
    """The mirror half — a subnetwork with no network. Asserted separately
    because a check written as one `if` over both fields would emit ONE error and
    an author fixing it would be told about only half their problem."""
    var errs = _errs(
        _vpc_egress_bundle(
            String(
                "      vpc_egress {\n"
                '        subnetwork: "default"\n'
                "      }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("'vpc_egress' declares no 'network'")),
        "a vpc_egress without a network is refused by name",
    )
    print("  test_a_vpc_egress_without_a_network_is_refused: PASS")


# =============================================================================
# `RunContainer.reads_telemetry` (field 8) — the read-only
# observability planes a validate step's container queries for itself. Each entry
# composes ONE PROJECT-SCOPED IAM read grant for the identity the job runs as, so
# a malformed entry is a privilege declaration, and it is refused at the line that
# wrote it rather than at a conformer an hour later.
# =============================================================================
def test_no_reads_telemetry_is_legal_and_is_the_default() raises:
    """★ THE CONTROL. A step declaring NO telemetry read is the ordinary
    validate step, so it must be clean — otherwise the refusals below
    would be measuring the fixture rather than the rule."""
    var errs = _errs(_vpc_egress_bundle(String("")))
    assert_equal(len(errs), 0, "no reads_telemetry is the default and is legal")
    print("  test_no_reads_telemetry_is_legal_and_is_the_default: PASS")


def test_both_telemetry_planes_validate() raises:
    """The positive control: the two distinct planes together are clean — the
    shape `cp-observability` authors."""
    var errs = _errs(
        _vpc_egress_bundle(
            String(
                "      reads_telemetry: TELEMETRY_READ_LOGS\n"
                "      reads_telemetry: TELEMETRY_READ_METRICS\n"
            )
        )
    )
    assert_equal(len(errs), 0, "logs + metrics is the authored observability set")
    print("  test_both_telemetry_planes_validate: PASS")


def test_an_unspecified_telemetry_plane_is_refused() raises:
    """FALSIFIER: `TELEMETRY_READ_UNSPECIFIED` — the proto3 zero — is REFUSED.

    Without this it composes a Grant node carrying `CAPABILITY_UNSPECIFIED`, and
    `_role_for_capability` fail-fasts on it at APPLY time, an hour into a deploy,
    naming an ordinal rather than the bundle line that wrote it. A privilege
    declaration that means nothing should not reach a cloud call."""
    var errs = _errs(
        _vpc_egress_bundle(
            String("      reads_telemetry: TELEMETRY_READ_UNSPECIFIED\n")
        )
    )
    assert_true(
        _any_contains(errs, String("TELEMETRY_READ_UNSPECIFIED")),
        "the unset plane must be refused, NAMING the value",
    )
    print("  test_an_unspecified_telemetry_plane_is_refused: PASS")


def test_a_duplicate_telemetry_plane_is_refused() raises:
    """FALSIFIER: the same plane twice is REFUSED, naming it.

    Two entries compose two grant nodes binding the SAME
    `(projects/<P>, member, role)` triple, and a project's IAM policy is ONE
    resource under read-modify-write SetIamPolicy — so the two race and one
    binding is lost. Deduping silently would hide the author's mistake; the
    duplicate says nothing the single entry did not."""
    var errs = _errs(
        _vpc_egress_bundle(
            String(
                "      reads_telemetry: TELEMETRY_READ_LOGS\n"
                "      reads_telemetry: TELEMETRY_READ_LOGS\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("DUPLICATED")),
        "a repeated plane must be refused",
    )
    assert_true(
        _any_contains(errs, String("TELEMETRY_READ_LOGS")),
        "the refusal must NAME the duplicated plane, not merely count",
    )
    print("  test_a_duplicate_telemetry_plane_is_refused: PASS")


def test_an_unknown_telemetry_token_is_refused_at_parse() raises:
    """★ THE CEILING. `telemetry_read_values()` is a CLOSED set, so a token that
    is not one of the three is refused by the PARSER — a bundle author cannot
    invent a plane, and therefore cannot ask the deploy to grant a capability this
    enum does not name. That closure is what keeps a validate-step declaration
    from being a general 'grant me any role' channel."""
    var raised = False
    try:
        _ = _errs(
            _vpc_egress_bundle(
                String("      reads_telemetry: TELEMETRY_READ_EVERYTHING\n")
            )
        )
    except e:
        raised = True
        assert_true(
            String(e).find(String("TelemetryRead")) >= 0,
            "the parse refusal must name the enum it checked against",
        )
    assert_true(raised, "an unknown telemetry token must not parse")
    print("  test_an_unknown_telemetry_token_is_refused_at_parse: PASS")


# =============================================================================
# ★ THE PLACEMENT RULE — a managed app's database lives in the CUSTOMER's
#   project.
# =============================================================================
#
# ⛔ WHY THESE ARE HERE AND NOT ONLY IN A TEST OVER A LIST OF BUNDLES. A gate
# asserted over a hand-written list of bundle paths covers only that list: a
# bundle that is compliant today but missing from the list keeps the gate green
# on the day it grows a database.
#
# These tests pin the rule in the VALIDATOR, where it applies to every bundle
# that is ever parsed, including the ones nobody has written yet.
#
# Each rule is falsified in BOTH directions, because the rule is DELIBERATELY
# ASYMMETRIC: the control plane owning `control-plane` is correct and intended,
# and a suite that only proved the refusals would pass just as well against a
# validator that refused everything.
# =============================================================================


def _customer_bundle(datastore_lines: String) -> String:
    """A minimal, otherwise-VALID managed-app bundle. Every placement test below
    differs from this by its datastore block alone, so a failure names the rule
    rather than some unrelated missing field."""
    return (
        String(
            "kind: APP_KIND_API\n"
            "tenancy: TENANCY_CUSTOMER\n"
            'name: "orders-widget"\n'
            'build { name: "service" dockerfile: "Dockerfile" }\n'
            'spec { image { from_build: "service" } port: 8080\n'
        )
        + datastore_lines
        + String("}\n" 'waves { env: "gamma-test" }\n')
    )


def test_a_managed_app_owning_its_own_database_validates() raises:
    """THE POSITIVE CONTROL. The correct arrangement — a customer-tenancy bundle
    owning a database named after what it holds — must produce ZERO errors, or the
    three refusals below prove nothing."""
    var errs = _errs(
        _customer_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
            )
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "a managed app that OWNS a database named after its contents is the"
            " CORRECT arrangement and must validate cleanly"
        ),
    )
    print("  test_a_managed_app_owning_its_own_database_validates: PASS")


def test_a_managed_app_may_not_name_the_control_plane_database() raises:
    """R2 — the NAMED violation: a managed app's database must not be in the
    control-plane project."""
    var errs = _errs(
        _customer_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "control-plane"\n'
            )
        )
    )
    assert_true(
        _any_contains(errs, String("may not name the database `control-plane`")),
        String(
            "a TENANCY_CUSTOMER bundle naming `control-plane` must be REFUSED at"
            " validate — offline, before any cloud call, which is the only place"
            " this mistake is cheap"
        ),
    )
    print("  test_a_managed_app_may_not_name_the_control_plane_database: PASS")


def test_a_control_plane_bundle_may_name_the_control_plane_database() raises:
    """R2, THE OTHER DIRECTION — the asymmetry. The control plane owning
    `control-plane` is the correct and intended arrangement, and a rule that
    refused it would refuse a shared-infrastructure bundle, whose entire job is to
    own that database."""
    var text = String(
        "kind: APP_KIND_API\n"
        "tenancy: TENANCY_CONTROL_PLANE\n"
        'name: "orders-api"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080\n'
        "  datastore: DATASTORE_NEED_SERVERLESS\n"
        '  datastore_database: "control-plane"\n'
        "}\n"
        'waves { env: "gamma" }\n'
    )
    assert_equal(
        len(_errs(text)),
        0,
        String(
            "a CONTROL_PLANE bundle owning `control-plane` is correct — the rule"
            " is asymmetric on purpose"
        ),
    )
    print("  test_a_control_plane_bundle_may_name_the_control_plane_database: PASS")


def test_a_managed_app_may_not_reference_a_database() raises:
    """R1 — a managed app runs in a CUSTOMER's account, where there is exactly one
    tenant and no shared infrastructure to reference. A reference there can only
    resolve to the OPERATOR's database."""
    var errs = _errs(
        _customer_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database_ref: "widgets"\n'
            )
        )
    )
    assert_true(
        _any_contains(errs, String("may not `datastore_database_ref:")),
        String(
            "a TENANCY_CUSTOMER bundle that REFERENCES a database must be refused"
            " — there is no other release machine in a customer's account to own"
            " it"
        ),
    )
    print("  test_a_managed_app_may_not_reference_a_database: PASS")


def test_a_managed_app_may_not_leave_its_datastore_unspecified() raises:
    """★ R3 — THE ROOT CAUSE, and the one that is not obvious.

    `DatastoreNeed`'s zero value is `DATASTORE_NEED_UNSPECIFIED` and the proto says
    it MEANS `NONE`. So an author who never thought about the datastore produces
    bytes IDENTICAL to one who decided the app is stateless — and that bundle
    stamps no `*_FIRESTORE_DATABASE` env, leaving the deployed binary to fall back
    to its own compiled-in default. Those defaults can DISAGREE across binaries:
    `(default)`, the app's own name, or `control-plane` — the OPERATOR's
    database.

    `Tenancy`'s own proto comment says it has no default DELIBERATELY, for exactly
    this reason. This rule applies the same discipline to `DatastoreNeed` without a
    proto change: silence is refused, and `NONE` must be said out loud."""
    var errs = _errs(_customer_bundle(String("")))
    assert_true(
        _any_contains(errs, String("must STATE its `datastore` intent")),
        String(
            "a TENANCY_CUSTOMER bundle that says NOTHING about its datastore must"
            " be refused — silence and 'stateless' must stop being the same bytes"
        ),
    )
    print("  test_a_managed_app_may_not_leave_its_datastore_unspecified: PASS")


def test_a_managed_app_may_declare_itself_stateless_out_loud() raises:
    """R3, THE OTHER DIRECTION. A genuinely stateless managed app is legitimate —
    the rule demands a STATEMENT, not a database. An app that stores only
    objects (no Firestore handle) is exactly this shape, and refusing `NONE`
    outright would force it to invent a database it never opens."""
    var errs = _errs(_customer_bundle(String("  datastore: DATASTORE_NEED_NONE\n")))
    assert_equal(
        len(errs),
        0,
        String(
            "an app that declares DATASTORE_NEED_NONE has SAID it stores nothing,"
            " and that is a legal statement — the rule refuses silence, not"
            " statelessness"
        ),
    )
    print("  test_a_managed_app_may_declare_itself_stateless_out_loud: PASS")


# =============================================================================
# ★ R2 IS A NAMESPACE RULE, NOT A LIST OF ONE — an operator may own more than
#   one database, and managed apps never reference any of them.
# =============================================================================
# An equality `sp.datastore_database == "control-plane"` misses an operator's
# second database (for example a regional `control-plane-us-central1`), which a
# managed app could then name with the validator saying nothing. These tests
# falsify `is_control_plane_database_id`, the rule that replaces the equality.
#
# Each is falsified in BOTH directions, for the same reason as its neighbours: a
# suite of refusals alone passes against a validator that refuses everything.
# =============================================================================


def test_a_managed_app_may_not_name_a_REGIONAL_control_plane_database() raises:
    """★ THE FALSIFIER FOR THE EQUALITY HOLE. `control-plane-us-central1` is an
    operator database name. An equality with the single literal `control-plane`
    does not match it: revert R2 to `sp.datastore_database ==
    String(CONTROL_PLANE_DATABASE_ID)` and this is the test that goes RED."""
    var errs = _errs(
        _customer_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "control-plane-us-central1"\n'
            )
        )
    )
    assert_true(
        _any_contains(
            errs, String("may not name the database `control-plane-us-central1`")
        ),
        String(
            "a TENANCY_CUSTOMER bundle naming `control-plane-us-central1` — an"
            " operator database — must be REFUSED. R2's single-literal equality did not see it, which is the"
            " whole reason the check is now a rule over the namespace"
        ),
    )
    print(
        "  test_a_managed_app_may_not_name_a_REGIONAL_control_plane_database: PASS"
    )


def test_a_managed_app_may_not_author_indexes_against_a_cp_database() raises:
    """★ A managed app's index cannot be AUTHORED against a control-plane
    database.

    `index_tables` is legal ONLY on a bundle that OWNS its database (app_bundle
    .proto — a bundle that merely REFERENCES one is refused if it authors index
    shapes). So the ONLY way a managed app's index shape can name an operator
    database is for the managed app to OWN one, and this is that bundle: a
    complete, otherwise-valid `index_tables` block on a customer-tenancy bundle
    whose `datastore_database` is the operator's.

    The refusal is what makes the rule STRUCTURAL rather than a convention: there
    is no ordering, no reviewer and no lint in the path. It fires inside
    `validate_bundle`, which every release-CLI verb that parses a bundle calls
    BEFORE any resource graph is built and before any cloud call — so the index
    shapes have nowhere to go."""
    var errs = _errs(
        _customer_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "control-plane-us-central1"\n'
                "  index_tables {\n"
                '    table: "widget"\n'
                "    indexes {\n"
                '      name: "ix_widget_org_created"\n'
                '      fields { col: "org_id" }\n'
                '      fields { col: "created_at" desc: true }\n'
                "      scope: SCOPE_COLLECTION\n"
                "    }\n"
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("OPERATOR's namespace")),
        String(
            "a managed app authoring `index_tables` against an OPERATOR database"
            " must be REFUSED — this is the exact shape that puts a managed app's"
            " composite indexes in the control plane's own database"
        ),
    )
    print("  test_a_managed_app_may_not_author_indexes_against_a_cp_database: PASS")


def test_a_managed_app_may_own_a_name_that_merely_LOOKS_operator_ish() raises:
    """THE OTHER DIRECTION FOR THE RULE'S SHAPE — and the reason the stem carries
    its separator. The predicate is `control-plane` exactly, or anything under
    `control-plane-`; it is NOT a bare stem test. A bare stem would also claim
    `control-planet` for the operator, and a gate that refuses a managed app a name
    it is entitled to teaches authors to route around the gate rather than obey
    it."""
    var errs = _errs(
        _customer_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "control-planet"\n'
            )
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "`control-planet` is not in the operator's namespace (`control-plane`,"
            " or anything under `control-plane-`) and a managed app may own it —"
            " the rule must be exact, not a bare stem"
        ),
    )
    print("  test_a_managed_app_may_own_a_name_that_merely_LOOKS_operator_ish: PASS")


def test_an_operator_bundle_may_not_own_an_app_shaped_database() raises:
    """★ THE OTHER HALF OF THE PARTITION —
    `control_plane_database_namespace_error`.

    R2 stops a managed app reaching INTO the operator's namespace. This stops an
    operator bundle reaching OUT of it — an operator project holding app-named
    databases.

    Both halves are required for the id namespace to be a DECISION PROCEDURE. While
    it overlaps, a deployed-topology check cannot tell an operator database from an
    app database by its name, and a live `databases.list` gives it no other
    signal."""
    var text = String(
        "kind: APP_KIND_API\n"
        "tenancy: TENANCY_CONTROL_PLANE\n"
        'name: "orders-api"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080\n'
        "  datastore: DATASTORE_NEED_SERVERLESS\n"
        '  datastore_database: "widgets"\n'
        "}\n"
        'waves { env: "gamma" }\n'
    )
    assert_true(
        _any_contains(_errs(text), String("may not OWN the database `widgets`")),
        String(
            "an OPERATOR bundle owning an app-shaped database name must be REFUSED"
            " — that is how the operator's own project comes to hold a managed"
            " app's database"
        ),
    )
    print("  test_an_operator_bundle_may_not_own_an_app_shaped_database: PASS")


# ═══════════════════════════════════════════════════════════════════════════
#  ★ EPHEMERAL LIFECYCLE ⇒ AN AUTHORED DEADLINE THAT FITS
# ═══════════════════════════════════════════════════════════════════════════
#
# ⛔ THE FAILURE THE REFUSAL PREVENTS IS A LEAKED CUSTOMER DEPLOYMENT, not a flake.
# A validate step declaring `<APP>_LIFECYCLE_MODE: "ephemeral"` CREATES a real
# managed app in a real customer project and then deletes it. Its guaranteed
# bounded-poll wall is `LIFECYCLE_GUARANTEED_POLL_FLOOR_S`; a Cloud Run Job with no
# authored `taskTemplate.timeout` gets Google's 600s default. The task is therefore
# SIGKILLed mid-lifecycle — necessarily AFTER the deploy POST, which is issued in
# the first minute, and BEFORE the delete — and a SIGKILL runs NO in-process reap.
#
# The only recovery is a later run's stale-orphan sweep. So an unpaired
# authoring is a durable customer-project leak that nothing is guaranteed to
# clear.
#
# ★ WHY A REFUSAL AND NOT A RAISED NUMBER. Pairing ephemeral with a deadline by
# hand is exactly what an author forgets; these arms make an unpaired bundle
# unloadable the moment someone sets the mode. A `_check_run_container` with no
# lifecycle check makes arms 1-3 produce zero errors and their asserts trip.


def _ephemeral_step(deadline_env: String) -> String:
    """A minimal bundle whose ONE validate step declares an ephemeral lifecycle.
    `deadline_env` is spliced verbatim so an arm can author no key, a good key, a
    too-small key, or a malformed one — the whole matrix off one fixture."""
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "lifecycle" dockerfile: "Dockerfile.lc" }\n'
        "spec { image { from_build: \"service\" } port: 8080 }\n"
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "app-lifecycle"\n'
        "    run_container {\n"
        '      image { from_build: "lifecycle" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
        '      env { name: "HELLO_LIFECYCLE_MODE" value: "ephemeral" }\n'
    ) + deadline_env + String(
        "    }\n"
        "  }\n"
        "}\n"
    )


def test_an_ephemeral_lifecycle_without_a_deadline_is_refused() raises:
    """ARM 1 — the shape that leaks. No `KOMIRA_VALIDATE_TASK_TIMEOUT_S` at all.

    FAILS ON PRE-FIX CODE: the validator had no lifecycle check, so this bundle
    validated clean and a deploy would have placed a Job under the 600s wall."""
    var errs = _errs(_ephemeral_step(String("")))
    assert_true(
        _any_contains(errs, String("HELLO_LIFECYCLE_MODE")),
        "the refusal NAMES the key that declared the ephemeral mode",
    )
    assert_true(
        _any_contains(errs, String("LEAVES THE DEPLOYED APP BEHIND")),
        "…and states the consequence — a leaked deployment in a customer project,"
        " not a slow test",
    )
    assert_true(
        _any_contains(errs, String("KOMIRA_VALIDATE_TASK_TIMEOUT_S")),
        "…and names the key to author, so the message is actionable",
    )
    print("  test_an_ephemeral_lifecycle_without_a_deadline_is_refused: PASS")


def test_an_ephemeral_lifecycle_below_the_polling_floor_is_refused() raises:
    """ARM 2 — authored, positive, and STILL too small. 600 is the exact value an
    author who believes the Cloud Run default is adequate would write down."""
    var errs = _errs(
        _ephemeral_step(
            String(
                '      env { name: "KOMIRA_VALIDATE_TASK_TIMEOUT_S" value:'
                ' "600" }\n'
            )
        )
    )
    assert_true(
        _any_contains(errs, String("BELOW the lifecycle's guaranteed polling")),
        "an authored deadline under the 2100s floor is refused, not accepted"
        " because it is non-empty",
    )
    assert_true(
        _any_contains(errs, String("do NOT shrink the budgets")),
        "…and the message forecloses the wrong fix (trimming budgets moves the"
        " kill earlier in the matrix rather than removing it)",
    )
    print("  test_an_ephemeral_lifecycle_below_the_polling_floor_is_refused: PASS")


def test_a_duration_shaped_deadline_is_refused_not_truncated() raises:
    """ARM 3 — ★ THE ARM THAT MAKES THE OTHERS NON-VACUOUS. `"3600s"` is the
    likeliest authoring typo (every other duration in the deploy surface is
    Duration-shaped) and it LOOKS correct. The RENDERER rejects it strictly and
    authors no timeout at all, so a gate that truncated it to 3600 and passed
    would certify precisely the bundle that runs under the 600s wall."""
    var errs = _errs(
        _ephemeral_step(
            String(
                '      env { name: "KOMIRA_VALIDATE_TASK_TIMEOUT_S" value:'
                ' "3600s" }\n'
            )
        )
    )
    assert_true(
        _any_contains(errs, String("not a positive whole number of SECONDS")),
        "a Duration-shaped value is refused HERE because the renderer refuses it"
        " THERE — a value this gate accepts but the renderer drops is worse than"
        " no gate",
    )
    assert_true(
        _any_contains(errs, String("3600s")),
        "…and the message quotes what was actually authored",
    )
    print("  test_a_duration_shaped_deadline_is_refused_not_truncated: PASS")


def test_a_paired_ephemeral_step_validates() raises:
    """ARM 4 — ⛔ THE NON-VACUITY CONTROL. The deadline the live waves actually
    author must validate CLEAN. Without this arm, arms 1-3 would be satisfied by
    a check that refuses every ephemeral step unconditionally. The deadline
    used here is one that clears the floor with headroom (5400s); a control that
    certifies a value nobody would author is certifying nothing."""
    var errs = _errs(
        _ephemeral_step(
            String(
                '      env { name: "KOMIRA_VALIDATE_TASK_TIMEOUT_S" value:'
                ' "5400" }\n'
            )
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "an ephemeral step paired with a 5400s deadline"
            " author validates CLEAN — the gate refuses the unpaired shape, not"
            " the feature"
        ),
    )
    print("  test_a_paired_ephemeral_step_validates: PASS")


def test_a_non_ephemeral_lifecycle_step_needs_no_deadline() raises:
    """ARM 5 — ⛔ THE SECOND NON-VACUITY CONTROL. `standing` mode reuses an app it
    did not create and deletes nothing, so it cannot leak one; refusing it would be
    a gate that fires on the wrong property. A standing wave (standing, no
    timeout) must keep loading."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "lifecycle" dockerfile: "Dockerfile.lc" }\n'
        "spec { image { from_build: \"service\" } port: 8080 }\n"
        "waves {\n"
        '  env: "gamma-lt"\n'
        "  validate {\n"
        '    name: "app-lifecycle"\n'
        "    run_container {\n"
        '      image { from_build: "lifecycle" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
        '      env { name: "HELLO_LIFECYCLE_MODE" value: "standing" }\n'
        "    }\n"
        "  }\n"
        "}\n"
    )
    assert_equal(
        len(_errs(text)), 0, "a STANDING lifecycle step needs no deadline"
    )
    print("  test_a_non_ephemeral_lifecycle_step_needs_no_deadline: PASS")


# ═══════════════════════════════════════════════════════════════════════════
#  ★★ THE SAME GUARD, KEYED ON THE `args` CHANNEL
# ═══════════════════════════════════════════════════════════════════════════
#
# ⛔ THIS IS THE HALF A NAIVE env->argv MOVE STRANDS, AND IT STRANDS IT SILENTLY.
# A binary's configuration belongs on argv, and the lifecycle mode is
# configuration — but a refusal that scans `rc.env` ONLY matches NOTHING once
# the mode moves to `args`: every ephemeral step becomes unpaired, each one able to be SIGKILLed at Cloud Run's 600s default after the
# deploy POST and before the DELETE, and the test suite goes GREENER rather than
# redder because the step-scanning readers then iterate an empty list.
#
# ★ THE TRIGGER HAS TWO CHANNELS; THE ASSERTION HAS ONE. Below the trigger in
# `validate.mojo` there is one path — the same `KOMIRA_VALIDATE_TASK_TIMEOUT_S` lookup
# in `rc.env` (it configures the POD, not the binary, so it stays on env), the same `parse_positive_decimal`, the same floor,
# the same two refusal texts. Only the question "did this step declare an
# ephemeral lifecycle?" gains a second channel to look in.
#
# ⚠ THE ARG PREDICATE IS KEYED ON THE RENDERED FLAG, NOT THE ARG NAME. An author
# may state `flag:` explicitly, so comparing `prm.name` to a literal would miss
# `args { name: "MODE" flag: "lifecycle-mode" }` — two spellings of "which arg is
# the mode" is precisely how a predicate gets a hole nobody can see.


def _mode_arg(name: String, value_line: String) -> String:
    """One `args { … }` block carrying a validate-step parameter. `value_line` is
    spliced verbatim so an arm can author a literal `value`, a `value_from`, or
    no source arm at all — the whole matrix off one fixture."""
    return String(
        "      args {\n"
        '        name: "'
    ) + name + String(
        '"\n'
        "        type: PARAM_TYPE_ENUM\n"
        '        allowed_values: "off"\n'
        '        allowed_values: "ephemeral"\n'
        '        allowed_values: "standing"\n'
        "        required: true\n"
        '        description: "Whether this run DEPLOYS the app itself and'
        ' DELETES it, or dials one someone else deployed."\n'
    ) + value_line + String(
        "      }\n"
    )


def _ephemeral_args_step(arg_block: String, deadline_env: String) -> String:
    """A minimal bundle whose ONE validate step declares its lifecycle mode on the
    ARGS channel rather than on env. Mirrors `_ephemeral_step` exactly apart from
    that one move, so a divergence between the two names the channel and nothing
    else."""
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "lifecycle" dockerfile: "Dockerfile.lc" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "app-lifecycle"\n'
        "    run_container {\n"
        '      image { from_build: "lifecycle" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
    ) + arg_block + deadline_env + String(
        "    }\n"
        "  }\n"
        "}\n"
    )


def test_the_ephemeral_gate_sees_an_ARGS_declared_mode() raises:
    """(a) ⛔ THE DEFECT. An ephemeral lifecycle declared on `args` with NO
    `KOMIRA_VALIDATE_TASK_TIMEOUT_S` must be REFUSED, exactly as the env spelling
    is.

    RED BEFORE THE FIX: `_check_run_container` scanned `rc.env` alone, so this
    bundle validated CLEAN — the deploy would place a Cloud Run Job under
    Google's 600s default against a 4600s guaranteed polling wall, the task would
    be SIGKILLed after the deploy POST and before the DELETE, and a SIGKILL runs
    no reap. That is a real managed app left standing in a real customer project,
    reported as a green validation.

    WHAT IT CATCHES: the whole leak guard being silently disarmed by the argv
    migration. It is the one failure mode here that fails OPEN."""
    var errs = _errs(
        _ephemeral_args_step(
            _mode_arg(
                String("LIFECYCLE_MODE"), String('        value: "ephemeral"\n')
            ),
            String(""),
        )
    )
    assert_true(
        _any_contains(errs, String("LIFECYCLE_MODE")),
        (
            "⛔ an ephemeral lifecycle declared on the ARGS channel must arm the"
            " deadline refusal, and the refusal must NAME the arg that declared"
            " it. A gate that scans only `env` is disarmed when configuration"
            " moves to argv flags"
        ),
    )
    assert_true(
        _any_contains(errs, String("LEAVES THE DEPLOYED APP BEHIND")),
        (
            "…and states the same consequence the env arm states — this is one"
            " assertion reached through two channels, not two gates"
        ),
    )
    assert_true(
        _any_contains(errs, String("KOMIRA_VALIDATE_TASK_TIMEOUT_S")),
        "…and names the key to author, so the message is actionable",
    )
    print("  test_the_ephemeral_gate_sees_an_ARGS_declared_mode: PASS")


def test_an_args_declared_ephemeral_below_the_floor_is_refused() raises:
    """(b) Authored, positive, and STILL too small — 600 is the value an author
    who believes the Cloud Run default is adequate would write down.

    WHAT IT CATCHES: an args-channel move that re-arms the "is there a key" half
    of the gate but drops the "does it clear the floor" half."""
    var errs = _errs(
        _ephemeral_args_step(
            _mode_arg(
                String("LIFECYCLE_MODE"), String('        value: "ephemeral"\n')
            ),
            String(
                '      env { name: "KOMIRA_VALIDATE_TASK_TIMEOUT_S" value:'
                ' "600" }\n'
            ),
        )
    )
    assert_true(
        _any_contains(errs, String("BELOW the lifecycle's guaranteed polling")),
        (
            "an args-declared ephemeral step under the floor is refused, not"
            " accepted because a deadline key is merely present"
        ),
    )
    print("  test_an_args_declared_ephemeral_below_the_floor_is_refused: PASS")


def test_a_paired_args_declared_ephemeral_step_validates() raises:
    """(c) ⛔ THE NON-VACUITY CONTROL. Without it, (a) and (b) are satisfied by a
    check that refuses every args-declared step unconditionally, which would make
    every converted bundle unloadable.

    WHAT IT CATCHES: a gate that fires on the wrong property — presence of an arg
    rather than the unpaired ephemeral shape."""
    var errs = _errs(
        _ephemeral_args_step(
            _mode_arg(
                String("LIFECYCLE_MODE"), String('        value: "ephemeral"\n')
            ),
            String(
                '      env { name: "KOMIRA_VALIDATE_TASK_TIMEOUT_S" value:'
                ' "5400" }\n'
            ),
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "an args-declared ephemeral step paired with 5400 validates CLEAN —"
            " the gate refuses the unpaired shape, not the argv channel"
        ),
    )
    print("  test_a_paired_args_declared_ephemeral_step_validates: PASS")


def test_the_args_mode_predicate_does_not_match_unrelated_args() raises:
    """(d) ⛔ THE NEGATIVE ARM, AND IT IS NOT OPTIONAL. "Make it match
    LIFECYCLE_MODE" is satisfiable by returning True unconditionally, which would
    arm the deadline refusal on EVERY arg — every validate step carrying an arg
    would then demand a 4600s deadline it has no reason
    to have.

    WHAT EACH CATCHES:
      * `MODE`            — a fragment matching, i.e. a substring/suffix predicate
      * `LIFECYCLE_MODEL` — an INFIX or prefix match; the flag `lifecycle-model`
        is not `lifecycle-mode`, and a `startswith` would accept it
      * `LOG_LEVEL` valued `"ephemeral"` — the gate keying on the VALUE rather
        than on which arg carries it"""
    var names = List[String]()
    names.append(String("MODE"))
    names.append(String("LIFECYCLE_MODEL"))
    for i in range(len(names)):
        var errs = _errs(
            _ephemeral_args_step(
                _mode_arg(names[i], String('        value: "ephemeral"\n')),
                String(""),
            )
        )
        assert_equal(
            len(errs),
            0,
            String("arg '")
            + names[i]
            + String(
                "' is not the lifecycle mode and must not arm the deadline"
                " refusal — the predicate is the RENDERED FLAG, matched whole,"
                " not a fragment and not an infix"
            ),
        )
    # …and the value-keyed confusion, stated separately because it is a different
    # wrong predicate from a name-shape one.
    var errs2 = _errs(
        _ephemeral_args_step(
            String(
                "      args {\n"
                '        name: "LOG_LEVEL"\n'
                "        type: PARAM_TYPE_STRING\n"
                '        value: "ephemeral"\n'
                "      }\n"
            ),
            String(""),
        )
    )
    assert_equal(
        len(errs2),
        0,
        String(
            "an unrelated arg that merely HOLDS the string 'ephemeral' must not"
            " arm the refusal — the gate keys on WHICH arg carries the mode, not"
            " on any arg holding that value"
        ),
    )
    print("  test_the_args_mode_predicate_does_not_match_unrelated_args: PASS")


def test_args_declared_off_and_standing_need_no_deadline() raises:
    """(e) Neither `off` nor `standing` creates-then-deletes on a wall, so neither
    can leak an app and neither needs a deadline. The env arm already states this
    for `standing`; the args arm must agree or a converted standing wave stops
    loading.

    WHAT IT CATCHES: a gate that fires on the mode ARG's presence rather than on
    its `ephemeral` VALUE."""
    var modes = List[String]()
    modes.append(String("off"))
    modes.append(String("standing"))
    for i in range(len(modes)):
        var errs = _errs(
            _ephemeral_args_step(
                _mode_arg(
                    String("LIFECYCLE_MODE"),
                    String('        value: "') + modes[i] + String('"\n'),
                ),
                String(""),
            )
        )
        assert_equal(
            len(errs),
            0,
            String("an args-declared `LIFECYCLE_MODE: ")
            + modes[i]
            + String(
                "` deletes nothing on a wall, so it needs no deadline — refusing"
                " it would be a gate firing on the wrong property"
            ),
        )
    print("  test_args_declared_off_and_standing_need_no_deadline: PASS")


def test_an_args_value_from_mode_is_out_of_scope_like_the_env_arm() raises:
    """(f) ★ THE STATED NARROWNESS, MIRRORED. Only the LITERAL-`value` arm is
    checkable: a `value_from` resolves at DEPLOY time and carries no authored mode
    this validator can read. The env half says so in its own comment; the args
    half must have the same scope or the two channels disagree about what the gate
    promises.

    WHAT IT CATCHES: an args predicate that ignores the source arm and treats a
    `value_from` reference as if it declared a literal mode — refusing a bundle on
    a value nobody authored."""
    var errs = _errs(
        _ephemeral_args_step(
            _mode_arg(
                String("LIFECYCLE_MODE"),
                String("        value_from: VALUE_FROM_DEPLOY_URL\n"),
            ),
            String(""),
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "a `value_from` mode resolves at deploy time and cannot be read here,"
            " so it is out of scope — exactly as it is on the env arm. This gate"
            " refuses only what it can actually prove"
        ),
    )
    print("  test_an_args_value_from_mode_is_out_of_scope_like_the_env_arm: PASS")


# =============================================================================
# ★ THE COLLECTION SHAPES (`AppSpec.datastore_collections`, field 35)
# =============================================================================
#
# The field is the AUTHORING half of a channel whose IR half the compose pass
# carries into each kind-4 (datastore) node.
#
# ⛔ EVERY REFUSAL BELOW IS ABOUT ONE PROPERTY: on the arm that materializes an
# access path the result is a KEY SCHEMA, and a key schema is IMMUTABLE. There
# is no update form that changes a partition key, a sort key or an attribute
# type; the only path between two designs is destroy-and-recreate, which loses
# every row. So a validator that supplied a missing half would make the answer
# PERMANENT as well as wrong, and the fail-quiet ones (a collection beside no
# datastore need; an empty name) are worse than an error because the deploy is
# green and the storage is simply never shaped.


def _collections_bundle(spec_lines: String) -> String:
    """A minimal, otherwise-VALID bundle. Every collection test below differs
    from this by its spec lines alone, so a failure names the rule rather than
    some unrelated missing field.

    ⚠ `TENANCY_CUSTOMER` IS LOAD-BEARING AND IS NOT DECORATION — it is the same
    choice `_customer_bundle` above makes, for the same reason. An OPERATOR
    bundle owning a database named `widgets` is refused by
    `control_plane_database_namespace_error` (an operator bundle may not own an
    app-shaped database), so an operator-tenancy fixture would make the positive
    control below fail for a reason that has nothing to do with collections."""
    return (
        String(
            "kind: APP_KIND_API\n"
            "tenancy: TENANCY_CUSTOMER\n"
            'name: "orders-widget"\n'
            'build { name: "service" dockerfile: "Dockerfile" }\n'
            'spec { image { from_build: "service" } port: 8080\n'
        )
        + spec_lines
        + String("}\n" 'waves { env: "dev" }\n')
    )


comptime _GOOD_COLLECTION: String = (
    "  datastore: DATASTORE_NEED_SERVERLESS\n"
    '  datastore_database: "widgets"\n'
    "  datastore_collections {\n"
    '    name: "widget"\n'
    "    primary_access_path {\n"
    '      partition_field: "widget_id"\n'
    '      partition_field_type: "string"\n'
    '      ordered_field: "revision"\n'
    '      ordered_field_type: "number"\n'
    "    }\n"
    "    secondary_access_paths {\n"
    '      name: "by_owner"\n'
    '      partition_field: "owner"\n'
    '      partition_field_type: "string"\n'
    "    }\n"
    '    expiry_field: "expires_at"\n'
    "  }\n"
)


def test_a_well_formed_collection_validates() raises:
    """THE POSITIVE CONTROL. A complete collection — a name, a full primary key,
    a named secondary path and an expiry field, beside a real datastore need —
    must produce ZERO errors, or the refusals below prove nothing."""
    var errs = _errs(_collections_bundle(String(_GOOD_COLLECTION)))
    assert_equal(
        len(errs),
        0,
        String(
            "a fully-authored collection beside a SERVERLESS datastore need is"
            " the CORRECT arrangement and must validate cleanly"
        ),
    )
    print("  test_a_well_formed_collection_validates: PASS")


def test_no_collections_is_legal_and_is_the_state_of_every_bundle() raises:
    """THE OTHER CONTROL, and the one that makes the field additive-safe. A
    bundle that authors no collection is the ordinary shape; if the absence were
    an error every such bundle would be red."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
            )
        )
    )
    assert_equal(len(errs), 0, "authoring no collection is legal")
    print("  test_no_collections_is_legal_and_is_the_state_of_every_bundle: PASS")


def test_a_collection_beside_no_datastore_need_is_refused() raises:
    """⛔ THE SILENT DROP, AND THE REASON THIS CHECK EXISTS AT ALL.

    The composer emits a kind-4 node ONLY for a SERVERLESS/DEDICATED need. A
    collection authored beside `datastore: NONE` therefore reaches NO node and
    is provisioned by NOTHING — while the bundle reads as though this app's
    storage were shaped, and the deploy is green. Refusing it at authoring is
    the difference between a stated error and a file that lies."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore_collections {\n"
                '    name: "widget"\n'
                "    primary_access_path {\n"
                '      partition_field: "widget_id"\n'
                '      partition_field_type: "string"\n'
                "    }\n"
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("'datastore' is")),
        String(
            "a collection declared with no datastore need must be REFUSED, not"
            " silently dropped by the composer"
        ),
    )
    print("  test_a_collection_beside_no_datastore_need_is_refused: PASS")


def test_a_collection_with_no_primary_access_path_is_refused() raises:
    """A collection with no primary access path is a table with no key, which is
    not a thing either cloud can hold — and a defaulted key is permanent."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
                "  datastore_collections {\n"
                '    name: "widget"\n'
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("'primary_access_path' is required")),
        "a collection with no identity is refused",
    )
    print("  test_a_collection_with_no_primary_access_path_is_refused: PASS")


def test_a_half_authored_ordered_pair_is_refused_not_half_honoured() raises:
    """★ THE SHARPEST ONE. An ordered field with no type could be "resolved" by
    dropping the name — and the result is a DIFFERENT collection that can never
    become the authored one without destroying every row. Refuse; do not pick a
    half."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
                "  datastore_collections {\n"
                '    name: "widget"\n'
                "    primary_access_path {\n"
                '      partition_field: "widget_id"\n'
                '      partition_field_type: "string"\n'
                '      ordered_field: "revision"\n'
                "    }\n"
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("has no 'ordered_field_type'")),
        "an ordered field with no type is refused",
    )
    print(
        "  test_a_half_authored_ordered_pair_is_refused_not_half_honoured: PASS"
    )


def test_a_vendor_attribute_letter_is_refused() raises:
    """⛔ `S` IS NOT A TYPE HERE. It is one vendor's own attribute letter; this
    field is read by every arm and the vocabulary is `string` / `number` /
    `bytes`. Caught at AUTHORING rather than at map time, because at map time the
    collection may already exist with the wrong key."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
                "  datastore_collections {\n"
                '    name: "widget"\n'
                "    primary_access_path {\n"
                '      partition_field: "widget_id"\n'
                '      partition_field_type: "S"\n'
                "    }\n"
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("neutral tokens")),
        "a vendor attribute letter is refused by name",
    )
    print("  test_a_vendor_attribute_letter_is_refused: PASS")


def test_a_secondary_path_without_a_name_is_refused() raises:
    """The name is the index name on both clouds, and it is how a re-deploy
    recognises the index it already created rather than making a second one."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
                "  datastore_collections {\n"
                '    name: "widget"\n'
                "    primary_access_path {\n"
                '      partition_field: "widget_id"\n'
                '      partition_field_type: "string"\n'
                "    }\n"
                "    secondary_access_paths {\n"
                '      partition_field: "owner"\n'
                '      partition_field_type: "string"\n'
                "    }\n"
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("SECONDARY access path")),
        "an unnamed secondary path is refused",
    )
    print("  test_a_secondary_path_without_a_name_is_refused: PASS")


def test_a_named_primary_path_is_refused() raises:
    """The mirror of the rule above, and it is not symmetry for its own sake: the
    primary path has no name of ITS own on either cloud, so an authored one
    materializes into nothing — a value the author wrote and no arm reads."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
                "  datastore_collections {\n"
                '    name: "widget"\n'
                "    primary_access_path {\n"
                '      name: "pk"\n'
                '      partition_field: "widget_id"\n'
                '      partition_field_type: "string"\n'
                "    }\n"
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("PRIMARY access path")),
        "a named primary path is refused",
    )
    print("  test_a_named_primary_path_is_refused: PASS")


def test_two_collections_with_one_name_are_refused() raises:
    """Two blocks for one collection read as though both applied; whichever is
    second is the only one a name-keyed reader keeps, and on the arm that
    materializes them they are two writers over one address."""
    var errs = _errs(
        _collections_bundle(
            String(
                "  datastore: DATASTORE_NEED_SERVERLESS\n"
                '  datastore_database: "widgets"\n'
                "  datastore_collections {\n"
                '    name: "widget"\n'
                '    primary_access_path { partition_field: "a"'
                ' partition_field_type: "string" }\n'
                "  }\n"
                "  datastore_collections {\n"
                '    name: "widget"\n'
                '    primary_access_path { partition_field: "b"'
                ' partition_field_type: "number" }\n'
                "  }\n"
            )
        )
    )
    assert_true(
        _any_contains(errs, String("duplicate 'name'")),
        "two collections with one name are refused",
    )
    print("  test_two_collections_with_one_name_are_refused: PASS")


def test_a_second_primary_access_path_is_refused_at_parse() raises:
    """A SINGULAR field, refused at the PARSER rather than resolved last-wins: a
    collection has exactly one identity, and the second block would silently
    REPLACE the first with a design that is different, permanent and
    uncorrectable. An ADDITIONAL query shape is `secondary_access_paths`."""
    var raised = False
    var msg = String("")
    try:
        _ = parse_bundle(
            _collections_bundle(
                String(
                    "  datastore: DATASTORE_NEED_SERVERLESS\n"
                    '  datastore_database: "widgets"\n'
                    "  datastore_collections {\n"
                    '    name: "widget"\n'
                    '    primary_access_path { partition_field: "a"'
                    ' partition_field_type: "string" }\n'
                    '    primary_access_path { partition_field: "b"'
                    ' partition_field_type: "number" }\n'
                    "  }\n"
                )
            )
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a second primary_access_path must RAISE at parse")
    assert_true(
        msg.find(String("SECOND `primary_access_path`")) >= 0,
        String("the parse error names the field: ") + msg,
    )
    print("  test_a_second_primary_access_path_is_refused_at_parse: PASS")



# =============================================================================
# ★ THE LIFECYCLE COMPUTE ENVIRONMENT — PRODUCER AND CONSUMER MUST NAME THE SAME
#   STRING (`_check_lifecycle_env_pairing`).
#
# ⛔ THE FAILURE, as a run reports it:
#
#     CP-IDENTITY: UNRESOLVED at login+users/me
#       (no compute environment named 'stage-orders-lifecycle' in this org)
#     [FAIL] lifecycle_precondition — UNBOUND: --cp-env-name … NOTHING WAS CREATED
#
# A wave holds two ends of one hand-typed string: a bootstrap step's
# `KOMIRA_BOOTSTRAP_ENV_NAME` (which CREATES the environment) and an e2e step's
# `--cp-env-name` (which LISTS it and refuses when absent, deliberately never
# creating one). Nothing joined them. When they disagree the run is red HAVING
# ALREADY MADE THE CLOUD WRITE, and the created environment is invisible to a
# stale-orphan sweep that reaps managed APPS inside an environment.
#
# Without the pairing check the mismatched bundle validates clean (ARM 1).
#
# ARMS 2-4 ARE THE NON-VACUITY CONTROLS, and arm 3 is the load-bearing one: a
# managed-app bundle may consume `--cp-env-name` with no producer in its wave. A
# guard that refused that shape would refuse such bundles at compose in order to
# enforce a rule about a machine that does not exist yet.
# =============================================================================


def _pairing_bundle(producer: String, consumer_env_name: String) -> String:
    """A wave with an optional bootstrap step (spliced verbatim, so an arm can
    author none, a live one, or an EXCLUDED one) and one e2e step that looks up
    `consumer_env_name`."""
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "bootstrapper" dockerfile: "Dockerfile.bs" }\n'
        'build { name: "e2e" dockerfile: "Dockerfile.e2e" }\n'
        "spec { image { from_build: \"service\" } port: 8080 }\n"
        "waves {\n"
        '  env: "gamma"\n'
    ) + producer + String(
        "  validate {\n"
        '    name: "app-e2e"\n'
        "    run_container {\n"
        '      image { from_build: "e2e" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
        "      args {\n"
        '        name: "CP_ENV_NAME"\n'
        "        type: PARAM_TYPE_STRING\n"
        "        required: true\n"
        '        flag: "cp-env-name"\n'
        '        description: "the compute environment this run deploys into"\n'
        '        value: "'
    ) + consumer_env_name + String(
        '"\n'
        "      }\n"
        "    }\n"
        "  }\n"
        "}\n"
    )


def _bootstrap_step(env_name: String, excluded: String) -> String:
    """A bootstrap step that CREATES `env_name`. `excluded` is spliced verbatim
    so one fixture covers the live and the `excluded_because` arms."""
    return String(
        "  validate {\n"
        '    name: "bootstrap"\n'
    ) + excluded + String(
        "    run_container {\n"
        '      image { from_build: "bootstrapper" }\n'
        "      gate_on: GATE_ON_EXIT_CODE\n"
        '      env { name: "KOMIRA_BOOTSTRAP_ENV_NAME" value: "'
    ) + env_name + String(
        '" }\n'
        "    }\n"
        "  }\n"
    )


def test_a_wave_that_bootstraps_one_env_and_looks_for_another_is_refused() raises:
    """ARM 1 — THE DEFECT. The bootstrap makes `stage-orders-lifecycle` and the
    e2e asks for `stage-oders-lifecycle` (one dropped character, which is exactly
    how this arrives). Without the pairing check this validates clean and the
    defect is found only by a live run that has already created the
    environment."""
    var errs = _errs(
        _pairing_bundle(
            _bootstrap_step(String("stage-orders-lifecycle"), String("")),
            String("stage-oders-lifecycle"),
        )
    )
    assert_true(
        _any_contains(errs, String("stage-oders-lifecycle")),
        "the refusal NAMES the environment the consumer looks for",
    )
    assert_true(
        _any_contains(errs, String("stage-orders-lifecycle")),
        "…and the one the wave actually CREATES, so the fix is visible without"
        " opening another file",
    )
    assert_true(
        _any_contains(errs, String("NOTHING in this repo reaps one")),
        "…and states the consequence: a leaked compute environment, not a retry",
    )
    print(
        "  test_a_wave_that_bootstraps_one_env_and_looks_for_another_is_refused:"
        " PASS"
    )


def test_a_wave_whose_two_ends_agree_validates() raises:
    """ARM 2 — ⛔ NON-VACUITY CONTROL. The shape a correctly authored bundle uses must
    validate CLEAN; without this arm, arm 1 would be satisfied by a check that
    refuses every wave carrying a bootstrap step at all."""
    var errs = _errs(
        _pairing_bundle(
            _bootstrap_step(String("stage-orders-lifecycle"), String("")),
            String("stage-orders-lifecycle"),
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "a wave whose bootstrap creates exactly the environment its e2e step"
            " looks for validates clean — the gate refuses the MISMATCH, not the"
            " pairing"
        ),
    )
    print("  test_a_wave_whose_two_ends_agree_validates: PASS")


def test_a_consumer_with_no_producer_is_not_refused() raises:
    """ARM 3 — ⛔ THE LOAD-BEARING NON-VACUITY CONTROL, and the reason this guard
    states the MISMATCH direction and not the stronger `every consumer needs a
    producer`. A bundle may consume `--cp-env-name` against an environment
    authored elsewhere or standing by hand. Refusing that shape would take
    working release machines down at COMPOSE to enforce a rule about a machine
    that does not exist yet."""
    var errs = _errs(
        _pairing_bundle(String(""), String("stage-orders-lifecycle"))
    )
    assert_equal(
        len(errs),
        0,
        String(
            "a wave that consumes a compute environment it does not create is the"
            " ordinary managed-app shape and must keep"
            " loading"
        ),
    )
    print("  test_a_consumer_with_no_producer_is_not_refused: PASS")


def test_an_excluded_bootstrap_step_is_not_a_producer() raises:
    """ARM 4 — ⛔ NON-VACUITY CONTROL. An EXCLUDED step places no job and creates
    no environment, so it is not one end of the string. Reading it as a producer
    would refuse a bundle whose wave carries an authored-and-excluded bootstrap
    step beside a live consumer."""
    var errs = _errs(
        _pairing_bundle(
            _bootstrap_step(
                String("some-other-env"),
                String('    excluded_because: "measured: no consented refresh'
                       ' secret exists for this account"\n'),
            ),
            String("stage-orders-lifecycle"),
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "an excluded bootstrap step composes no job and creates no compute"
            " environment, so it is neither end of the pairing"
        ),
    )
    print("  test_an_excluded_bootstrap_step_is_not_a_producer: PASS")


# ═══════════════════════════════════════════════════════════════════════════════
# ★★ `Wave.web_override` (field 8) — THE **TOTAL** PER-WAVE FRONT DOOR
# ════════════════════════════════════════════════════════════════════════════
#
# ⛔ THE PROPERTY UNDER TEST IS THAT THE OVERRIDE IS **TOTAL, NOT A MERGE**, AND
# EVERY REFUSAL BELOW EXISTS BECAUSE THE MERGE SEMANTIC FAILS SILENTLY.
#
# Under "a non-empty override field replaces the spec value", a wave CANNOT
# EXPRESS ABSENT — an empty `web_route_rules` reads as *inherit*. A
# pre-production front door often routes MORE paths than production (docs,
# token, webhook routes, a DENY rule), so production's table is not the other's
# with blanks; it is a SHORTER TABLE. Under a merge a consolidated machine could
# not author production at all, and the failure would be production silently
# inheriting the other environment's routes.
#
# THE OTHER HALF — "the spec must then author NOTHING" — is what makes the
# document readable. With both authored, a reviewer looking at
# `spec.web_route_rules` cannot tell whether those rules are live for some wave
# or dead for all of them — the route table quietly shrinking without a
# reviewer noticing.
#
# ⚠ AND EVERY REFUSAL HERE HAS A POSITIVE CONTROL BESIDE IT. A refusal test
# alone passes just as well against a validator that refuses EVERYTHING.


comptime _FRONTEND_GAMMA_OVERRIDE: String = (
    "  web_override {\n"
    '    web_slug: "orders-gamma"\n'
    '    web_domain: "gamma.example.com"\n'
    '    web_additional_domains: "gamma.example.dev"\n'
    '    web_api_service_logical_id: "orders-api-svc"\n'
    "    web_route_rules {\n"
    '      backend_role: "spa"\n'
    '      error_404_path: "/index.html"\n'
    "      error_404_code: 200\n"
    "      disposition: WEB_ROUTE_DISPOSITION_DEFAULT\n"
    "    }\n"
    "    web_route_rules {\n"
    '      paths: "/orgs"\n'
    '      paths: "/orgs/*"\n'
    '      backend_role: "api"\n'
    "    }\n"
    "  }\n"
)

comptime _FRONTEND_PROD_OVERRIDE: String = (
    "  web_override {\n"
    '    web_slug: "orders"\n'
    '    web_domain: "example.com"\n'
    '    web_additional_domains: "www.example.com"\n'
    '    web_api_service_logical_id: "orders-api-svc"\n'
    "    web_route_rules {\n"
    '      backend_role: "spa"\n'
    '      error_404_path: "/index.html"\n'
    "      error_404_code: 200\n"
    "      disposition: WEB_ROUTE_DISPOSITION_DEFAULT\n"
    "    }\n"
    "  }\n"
)


def _frontend_bundle(spec_lines: String, gamma: String, prod: String) -> String:
    """A two-wave `APP_KIND_STATIC_FRONTEND` bundle — the consolidated front-door
    shape. Each test below differs from this by its spec lines or one wave's
    override alone, so a failure names the rule and not some unrelated field."""
    return (
        String("kind: APP_KIND_STATIC_FRONTEND\n")
        + String('name: "orders-frontend"\n')
        + String("spec {\n")
        + spec_lines
        + String("}\n")
        + String('waves {\n  env: "gamma"\n')
        + gamma
        + String("}\n")
        + String('waves {\n  env: "prod"\n')
        + prod
        + String("}\n")
    )


def test_two_waves_each_with_its_own_total_front_door_validate() raises:
    """★ THE POSITIVE CONTROL, AND IT IS THE WHOLE POINT OF THE FIELD: ONE
    bundle carrying gamma's front door AND prod's, with the bundle-level spec
    authoring NO web topology at all.

    Without `Wave.web_override` this document could not be written — a bundle has
    ONE `spec`, so two environments' front doors would need two files. If this
    test ever goes red, the consolidation is not expressible and every refusal below is
    guarding a shape nobody can author."""
    var errs = _errs(
        _frontend_bundle(
            String("  \n"), _FRONTEND_GAMMA_OVERRIDE, _FRONTEND_PROD_OVERRIDE
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "two waves each authoring a TOTAL web_override, over a spec that"
            " authors no web topology, is the consolidated front-door shape and must"
            " validate cleanly; got: "
        )
        + (errs[0] if len(errs) > 0 else String("")),
    )
    print("  test_two_waves_each_with_its_own_total_front_door_validate: PASS")


def test_a_spec_that_also_authors_topology_beside_an_override_is_refused() raises:
    """⛔ BOTH PLACES AUTHORED ⇒ REFUSED. This is the readability half of TOTAL.

    A `spec.web_route_rules` sitting beside a wave that overrides the table is
    DEAD TEXT that looks live — and the thing a reviewer scans for the table is
    the spec, because that is where a front-door bundle keeps it. Silently
    ignoring it is how a table shrinks without anyone noticing."""
    var errs = _errs(
        _frontend_bundle(
            String(
                '  web_slug: "orders"\n'
                '  web_domain: "example.com"\n'
            ),
            _FRONTEND_GAMMA_OVERRIDE,
            _FRONTEND_PROD_OVERRIDE,
        )
    )
    assert_true(
        _any_contains(errs, String("web_override")),
        String(
            "a bundle authoring web topology on BOTH spec and a wave override"
            " must be refused naming web_override; got "
        )
        + String(len(errs))
        + String(" error(s)"),
    )
    assert_true(
        _any_contains(errs, String("web_slug")),
        "the refusal must NAME the spec field that is authored twice",
    )
    print(
        "  test_a_spec_that_also_authors_topology_beside_an_override_is_refused:"
        " PASS"
    )


def test_a_wave_left_without_an_override_when_a_sibling_has_one_is_refused() raises:
    """⛔ THE ASYMMETRY IS THE DANGEROUS ONE, AND IT IS THE CASE A MERGE
    SEMANTIC WOULD HAVE SWALLOWED.

    One wave overriding and the other not is exactly "prod inherits whatever the
    spec happens to say" — and since the spec must be EMPTY once any wave
    overrides, prod would inherit an empty slug, which falls back to
    `bundle.name`. Both environments would then derive the SAME slug and one
    env's L7 primitives would be stood up in the other env's project. Refused,
    naming the wave."""
    var errs = _errs(
        _frontend_bundle(
            String("  \n"), _FRONTEND_GAMMA_OVERRIDE, String("")
        )
    )
    assert_true(
        _any_contains(errs, String("prod")),
        String(
            "the wave with no override must be refused BY NAME; got "
        )
        + String(len(errs))
        + String(" error(s)"),
    )
    print(
        "  test_a_wave_left_without_an_override_when_a_sibling_has_one_is_refused:"
        " PASS"
    )


def test_an_override_with_no_route_table_is_refused() raises:
    """⛔ AN EMPTY TABLE IS THE MERGE SEMANTIC'S GHOST. Under a merge it would
    read as *inherit*; under TOTAL it is a front door that routes nothing to any
    api backend, which is a whole environment's api surface falling through to
    the SPA bucket and answering plausible statuses with `index.html`. A wave
    that genuinely routes nothing authors the DEFAULT arm and says so."""
    var no_table = String(
        "  web_override {\n"
        '    web_slug: "orders"\n'
        '    web_domain: "example.com"\n'
        "  }\n"
    )
    var errs = _errs(
        _frontend_bundle(String("  \n"), _FRONTEND_GAMMA_OVERRIDE, no_table)
    )
    assert_true(
        _any_contains(errs, String("web_route_rules")),
        String("an override with no route table must be refused; got ")
        + String(len(errs))
        + String(" error(s)"),
    )
    print("  test_an_override_with_no_route_table_is_refused: PASS")


def test_an_override_with_no_slug_or_no_domain_is_refused() raises:
    """⛔ THE TWO FIELDS WHOSE ABSENCE IS SILENT RATHER THAN LOUD.

    An empty SLUG falls back to `bundle.name` on the spec path — harmless with
    one front door per bundle, and a cross-environment collision with two.
    An empty DOMAIN makes `bundle_web_front_door_url(bundle, env)` return `""`,
    which is the exact STATIC_FRONTEND gap that function was written to close:
    every authored validate step of that wave then probes nothing at all."""
    var no_slug = String(
        "  web_override {\n"
        '    web_domain: "example.com"\n'
        "    web_route_rules {\n"
        '      backend_role: "spa"\n'
        "      disposition: WEB_ROUTE_DISPOSITION_DEFAULT\n"
        '      error_404_path: "/index.html"\n'
        "      error_404_code: 200\n"
        "    }\n"
        "  }\n"
    )
    var errs = _errs(
        _frontend_bundle(String("  \n"), _FRONTEND_GAMMA_OVERRIDE, no_slug)
    )
    assert_true(
        _any_contains(errs, String("web_slug")),
        "an override with no slug must be refused naming web_slug",
    )
    var no_domain = String(
        "  web_override {\n"
        '    web_slug: "orders"\n'
        "    web_route_rules {\n"
        '      backend_role: "spa"\n'
        "      disposition: WEB_ROUTE_DISPOSITION_DEFAULT\n"
        '      error_404_path: "/index.html"\n'
        "      error_404_code: 200\n"
        "    }\n"
        "  }\n"
    )
    var errs2 = _errs(
        _frontend_bundle(String("  \n"), _FRONTEND_GAMMA_OVERRIDE, no_domain)
    )
    assert_true(
        _any_contains(errs2, String("web_domain")),
        "an override with no domain must be refused naming web_domain",
    )
    print("  test_an_override_with_no_slug_or_no_domain_is_refused: PASS")


def test_an_override_on_a_non_static_frontend_bundle_is_refused() raises:
    """⛔ A FRONT DOOR ON A BUNDLE THAT COMPOSES NO FRONT DOOR IS AUTHORED-AND-
    IGNORED, which is a costly failure mode: the text
    is there, it reads as configuration, and nothing consumes it.
    `compose_static_frontend` is the ONLY reader, and it runs for exactly one
    kind."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8080 }\n'
        'waves {\n  env: "dev"\n'
    ) + _FRONTEND_PROD_OVERRIDE + String("}\n")
    assert_true(
        _any_contains(_errs(text), String("APP_KIND_STATIC_FRONTEND")),
        "a web_override on a non-STATIC_FRONTEND bundle must be refused",
    )
    print("  test_an_override_on_a_non_static_frontend_bundle_is_refused: PASS")


def test_a_single_wave_bundle_with_no_override_is_untouched() raises:
    """★ THE ADDITIVE-SAFETY CONTROL. A single-environment front-door bundle
    authors its topology on `spec` and no override at all. If THAT shape were
    refused, every such bundle would go red — which is the difference between an
    additive field and a migration."""
    var text = String(
        "kind: APP_KIND_STATIC_FRONTEND\n"
        'name: "orders-web"\n'
        "spec {\n"
        '  web_slug: "orders"\n'
        '  web_domain: "example.com"\n'
        "  web_route_rules {\n"
        '    backend_role: "spa"\n'
        '    error_404_path: "/index.html"\n'
        "    error_404_code: 200\n"
        "    disposition: WEB_ROUTE_DISPOSITION_DEFAULT\n"
        "  }\n"
        "}\n"
        'waves { env: "prod" }\n'
    )
    assert_equal(
        len(_errs(text)),
        0,
        "the pre-override shape (topology on spec, no wave override) must stay"
        " valid — the ordinary single-environment front door is authored that way",
    )
    print("  test_a_single_wave_bundle_with_no_override_is_untouched: PASS")



def main() raises:
    test_clean_bundle_has_no_errors()
    test_a_managed_app_owning_its_own_database_validates()
    test_a_managed_app_may_not_name_a_REGIONAL_control_plane_database()
    test_a_managed_app_may_not_author_indexes_against_a_cp_database()
    test_a_managed_app_may_own_a_name_that_merely_LOOKS_operator_ish()
    test_an_operator_bundle_may_not_own_an_app_shaped_database()
    test_a_managed_app_may_not_name_the_control_plane_database()
    test_a_control_plane_bundle_may_name_the_control_plane_database()
    test_a_managed_app_may_not_reference_a_database()
    test_a_managed_app_may_not_leave_its_datastore_unspecified()
    test_a_managed_app_may_declare_itself_stateless_out_loud()
    test_no_vpc_egress_block_is_legal_and_is_the_default()
    test_a_well_formed_vpc_egress_block_validates()
    test_a_vpc_egress_without_a_subnetwork_is_refused()
    test_a_vpc_egress_without_a_network_is_refused()
    test_missing_top_level_required_fields()
    test_empty_wave_env_symbol()
    test_image_with_zero_oneof_arms()
    test_api_requires_positive_port()
    test_run_container_requires_gate_on()
    test_a_service_ref_env_on_a_validate_step_is_refused()
    test_a_service_ref_env_on_the_served_spec_is_still_accepted()
    test_http_check_bad_status()
    test_http_check_max_latency_ms_opt_in_and_negative_refused()
    test_static_frontend_image_optional()
    test_a_well_formed_secured_route_validates()
    test_secured_route_requires_a_webhook_inbound_need()
    test_an_unspecified_policy_is_refused()
    test_an_explicitly_non_federated_policy_is_refused()
    test_a_secured_route_colliding_with_the_pass_through_is_refused()
    test_two_secured_routes_with_different_service_accounts_are_refused()
    test_secured_route_audience_is_not_authorable()
    test_an_empty_sa_email_is_refused()
    test_no_reads_telemetry_is_legal_and_is_the_default()
    test_both_telemetry_planes_validate()
    test_an_unspecified_telemetry_plane_is_refused()
    test_a_duplicate_telemetry_plane_is_refused()
    test_an_unknown_telemetry_token_is_refused_at_parse()
    test_an_ephemeral_lifecycle_without_a_deadline_is_refused()
    test_an_ephemeral_lifecycle_below_the_polling_floor_is_refused()
    test_a_duration_shaped_deadline_is_refused_not_truncated()
    test_a_paired_ephemeral_step_validates()
    test_a_non_ephemeral_lifecycle_step_needs_no_deadline()
    test_the_ephemeral_gate_sees_an_ARGS_declared_mode()
    test_an_args_declared_ephemeral_below_the_floor_is_refused()
    test_a_paired_args_declared_ephemeral_step_validates()
    test_the_args_mode_predicate_does_not_match_unrelated_args()
    test_args_declared_off_and_standing_need_no_deadline()
    test_an_args_value_from_mode_is_out_of_scope_like_the_env_arm()
    # ★ THE COLLECTION SHAPES (field 35)
    test_a_well_formed_collection_validates()
    test_no_collections_is_legal_and_is_the_state_of_every_bundle()
    test_a_collection_beside_no_datastore_need_is_refused()
    test_a_collection_with_no_primary_access_path_is_refused()
    test_a_half_authored_ordered_pair_is_refused_not_half_honoured()
    test_a_vendor_attribute_letter_is_refused()
    test_a_secondary_path_without_a_name_is_refused()
    test_a_named_primary_path_is_refused()
    test_two_collections_with_one_name_are_refused()
    test_a_second_primary_access_path_is_refused_at_parse()
    test_a_wave_that_bootstraps_one_env_and_looks_for_another_is_refused()
    test_a_wave_whose_two_ends_agree_validates()
    test_a_consumer_with_no_producer_is_not_refused()
    test_an_excluded_bootstrap_step_is_not_a_producer()
    # ★★ `Wave.web_override` — the TOTAL per-wave front door
    test_two_waves_each_with_its_own_total_front_door_validate()
    test_a_spec_that_also_authors_topology_beside_an_override_is_refused()
    test_a_wave_left_without_an_override_when_a_sibling_has_one_is_refused()
    test_an_override_with_no_route_table_is_refused()
    test_an_override_with_no_slug_or_no_domain_is_refused()
    test_an_override_on_a_non_static_frontend_bundle_is_refused()
    test_a_single_wave_bundle_with_no_override_is_untouched()
    print("PASS test_validate")
