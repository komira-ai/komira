# =============================================================================
# komira_deploy_bundle/tests/test_parser_roundtrip.mojo
#   — the AppBundle textproto parser <-> canonical-emitter ROUND-TRIP gate.
# =============================================================================
#
# The byte-exact round-trip gate. The orders-api worked example — written in the
# LOCKED canonical form (fully-prefixed enum values) — is
# parsed into the GENERATED AppBundle, re-emitted by the canonical emitter, and
# asserted BYTE-FOR-BYTE identical. Parse and emit are INDEPENDENT code paths, so
# a byte-exact round-trip is a genuine correctness signal. A second parse of the
# re-emission asserts field-level identity (kind / name / builds / spec oneof arms
# / waves / the DEPLOY_URL wave-output ref) survives the trip.
#
# Encapsulation: pure parse/emit/value asserts — no store, no dispatcher, no
# UnsafePointer. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.emit import emit_bundle
from komira_deploy_bundle.validate import validate_bundle
from komira_rpc_bundle.app_bundle import (
    AppKind,
    ValueFrom,
    GateOn,
    SourceKind,
    RegistryKind,
)
from komira_rpc_bundle.deploy_model import ComputeIntent, DatastoreNeed

# The `TriggerSource.on` ARM indices — the 1-BASED arm index in declaration order,
# NOT the proto field number (6/7/8). The ARM IS the event, so the assertions
# read `_oneof0_case` here.
comptime ARM_GIT_PUSH: Int = 1
comptime ARM_SCHEDULE: Int = 2
comptime ARM_PACKAGE_PUBLISHED: Int = 3


# The orders-api worked example in LOCKED CANONICAL form — exactly what
# `emit_bundle` produces (2-space indent, proto-field order, blank line between
# top-level sections, fully-prefixed enum values). Comments are NOT included
# because the canonical emitter does not emit them (comment preservation is the
# PATCHER's job, tested separately).
comptime _CANONICAL: String = (
    'kind: APP_KIND_API\n'
    'name: "orders-api"\n'
    "\n"
    "build {\n"
    '  name: "service"\n'
    '  dockerfile: "Dockerfile"\n'
    "}\n"
    "\n"
    "build {\n"
    '  name: "integ_tests"\n'
    '  dockerfile: "Dockerfile.integ"\n'
    "}\n"
    "\n"
    "spec {\n"
    "  image {\n"
    '    from_build: "service"\n'
    "  }\n"
    "  port: 8080\n"
    "  env {\n"
    '    name: "LOG_LEVEL"\n'
    '    value: "info"\n'
    "  }\n"
    "  scaling {\n"
    "    min: 0\n"
    "    max: 10\n"
    "  }\n"
    "  compute: COMPUTE_INTENT_SERVERLESS\n"
    "  datastore: DATASTORE_NEED_NONE\n"
    "  secret_bindings {\n"
    '    handle: "db-url"\n'
    '    capability_node: "cap.db"\n'
    "  }\n"
    "}\n"
    "\n"
    "waves {\n"
    '  env: "dev"\n'
    "  validate {\n"
    '    name: "up"\n'
    "    http_check {\n"
    '      path: "/healthz"\n'
    "      expect_status: 200\n"
    "    }\n"
    "  }\n"
    "}\n"
    "\n"
    "waves {\n"
    '  env: "gamma"\n'
    "  validate {\n"
    '    name: "integ"\n'
    "    run_container {\n"
    "      image {\n"
    '        from_build: "integ_tests"\n'
    "      }\n"
    "      gate_on: GATE_ON_EXIT_CODE\n"
    "      env {\n"
    '        name: "TARGET_URL"\n'
    "        value_from: VALUE_FROM_DEPLOY_URL\n"
    "      }\n"
    "    }\n"
    "  }\n"
    "}\n"
    "\n"
    "waves {\n"
    '  env: "prod"\n'
    "}\n"
)


def test_canonical_round_trips_byte_exact() raises:
    """Parse(canonical) -> emit == canonical, byte-for-byte."""
    var bundle = parse_bundle(_CANONICAL)
    var re_emitted = emit_bundle(bundle)
    assert_equal(re_emitted, _CANONICAL, "canonical re-emit is byte-exact")
    print("  test_canonical_round_trips_byte_exact: PASS")


def test_round_trip_is_idempotent() raises:
    """A SECOND parse+emit of the re-emission is still byte-identical (idempotent
    canonical form)."""
    var b1 = parse_bundle(_CANONICAL)
    var e1 = emit_bundle(b1)
    var b2 = parse_bundle(e1)
    var e2 = emit_bundle(b2)
    assert_equal(e2, e1, "second round-trip is idempotent")
    print("  test_round_trip_is_idempotent: PASS")


def test_parsed_fields_match() raises:
    """The parsed AppBundle carries the exact worked-example values (a genuine
    parse, not just a re-serialize)."""
    var b = parse_bundle(_CANONICAL)
    assert_equal(b.kind.value, AppKind.APP_KIND_API, "kind API")
    assert_equal(b.name, String("orders-api"), "name")
    assert_equal(len(b.build), 2, "two build targets")
    assert_equal(b.build[0].name, String("service"), "build[0] name")
    assert_equal(
        b.build[1].dockerfile, String("Dockerfile.integ"), "build[1] dockerfile"
    )

    var sp = b.spec.value().copy()
    assert_equal(sp.image.value()._oneof0_case, 2, "spec image from_build arm")
    assert_equal(
        sp.image.value().from_build.value(), String("service"), "spec image target"
    )
    assert_equal(sp.port, Int32(8080), "spec port")
    assert_equal(len(sp.env), 1, "spec one env")
    assert_equal(sp.env[0].value.value(), String("info"), "spec env literal value")
    assert_equal(sp.scaling.value().min, Int32(0), "scale-to-zero min")
    assert_equal(sp.scaling.value().max, Int32(10), "scaling max")
    assert_equal(
        sp.compute.value, ComputeIntent.COMPUTE_INTENT_SERVERLESS, "compute serverless"
    )
    assert_equal(
        sp.datastore.value, DatastoreNeed.DATASTORE_NEED_NONE, "datastore none"
    )
    assert_equal(len(sp.secret_bindings), 1, "one secret binding")
    assert_equal(
        sp.secret_bindings[0].handle, String("db-url"), "secret handle"
    )
    # runtime_identity UNSET in the canonical bundle -> parses to empty (the
    # derive-`<name>-role` default; no self-provision).
    assert_equal(
        sp.runtime_identity, String(""), "runtime_identity unset -> empty default"
    )

    assert_equal(len(b.waves), 3, "three waves")
    assert_equal(b.waves[0].env, String("dev"), "wave0 dev")
    assert_equal(
        b.waves[0].validate[0].http_check.value().path,
        String("/healthz"),
        "dev probe path",
    )
    var integ = b.waves[1].validate[0].run_container.value().copy()
    assert_equal(integ.gate_on.value, GateOn.GATE_ON_EXIT_CODE, "gamma gate EXIT_CODE")
    assert_equal(
        integ.image.value().from_build.value(),
        String("integ_tests"),
        "gamma integ image",
    )
    assert_equal(
        integ.env[0].value_from.value().value,
        ValueFrom.VALUE_FROM_DEPLOY_URL,
        "gamma TARGET_URL <- DEPLOY_URL",
    )
    assert_equal(b.waves[2].env, String("prod"), "wave2 prod")
    assert_equal(
        len(b.waves[2].validate), 0, "prod has no gate (promotion-only)"
    )
    print("  test_parsed_fields_match: PASS")


def test_comments_and_optional_colon_are_ignored() raises:
    """`#` comments and the optional `:` before `{` (both `spec {` and `spec: {`)
    parse identically to the canonical form."""
    var with_comments = String(
        "# a header comment\n"
        "kind: APP_KIND_API   # inline comment\n"
        'name: "svc"\n'
        "build { name: \"service\" dockerfile: \"Dockerfile\" }\n"
        "spec: {\n"  # optional colon before the block
        "  image { from_build: \"service\" }\n"
        "  port: 9090\n"
        "}\n"
        'waves { env: "dev" }\n'
    )
    var b = parse_bundle(with_comments)
    assert_equal(b.name, String("svc"), "name past comments")
    assert_equal(b.spec.value().port, Int32(9090), "port with optional colon")
    assert_equal(b.waves[0].env, String("dev"), "wave env")
    print("  test_comments_and_optional_colon_are_ignored: PASS")


def test_zero_triggers_parses_to_empty_one_shot() raises:
    """A bundle with NO `triggers` blocks (the orders-api worked example) parses to
    an EMPTY `triggers` list — the one-shot identifier is preserved."""
    var b = parse_bundle(_CANONICAL)
    assert_equal(len(b.triggers), 0, "zero authored triggers -> empty list (one-shot)")
    print("  test_zero_triggers_parses_to_empty_one_shot: PASS")


def test_triggers_parse_to_n_trigger_sources() raises:
    """A bundle authoring N `triggers { … }` blocks parses to N `TriggerSource`
    entries, each with its `name` + its payload ARM recovered (the continuous-
    deployment authoring surface). Mixed self-hosted + external git_push sources
    prove both `SourceKind` values; a third `schedule` trigger proves the arm
    dispatch and the multi-source fan-in. The `ref` proto field escapes to the Mojo
    keyword-safe `ref_`.

    The payload is `oneof on { GitPush | Schedule | PackagePublished }` (fields
    1-4 are reserved), so the git fields live one level down inside
    `git_push { … }`. THE ARM IS THE EVENT, so each event assertion is an
    assertion on `_oneof0_case`; the `schedule` arm carries an actual `cron`,
    asserted below. A parser without the `triggers` arm raises
    `unknown field 'triggers'` here."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "orders-api"\n'
        "spec {\n"
        "  image { from_build: \"service\" }\n"
        "  port: 8080\n"
        "}\n"
        "triggers {\n"
        '  name: "selfhosted-mainline"\n'
        "  git_push {\n"
        "    source_kind: SOURCE_KIND_GIT_SELFHOSTED\n"
        '    repo_ref: "acme/orders-api"\n'
        '    ref: "main"\n'
        "  }\n"
        "}\n"
        "triggers {\n"
        '  name: "external-release"\n'
        "  git_push {\n"
        "    source_kind: SOURCE_KIND_GIT_EXTERNAL\n"
        '    repo_ref: "github.com/acme/mirror"\n'
        '    ref: "release"\n'
        "  }\n"
        "}\n"
        "triggers {\n"
        '  name: "weekly-sweep"\n'
        "  schedule {\n"
        '    cron: "0 6 * * 1"\n'
        '    timezone: "America/Chicago"\n'
        "  }\n"
        "}\n"
    )
    var b = parse_bundle(text)
    assert_equal(
        len(b.triggers), 3, "three authored triggers -> three TriggerSource"
    )

    # trigger[0] — self-hosted git_push on main.
    assert_equal(
        b.triggers[0].name, String("selfhosted-mainline"), "trigger0 name"
    )
    assert_equal(
        b.triggers[0]._oneof0_case,
        ARM_GIT_PUSH,
        "trigger0 arm is git_push (the arm IS the event — was TRIGGER_EVENT_PUSH)",
    )
    ref gp0 = b.triggers[0].git_push.value()
    assert_equal(
        gp0.source_kind.value,
        SourceKind.SOURCE_KIND_GIT_SELFHOSTED,
        "trigger0 source_kind GIT_SELFHOSTED",
    )
    assert_equal(gp0.repo_ref, String("acme/orders-api"), "trigger0 repo_ref")
    assert_equal(gp0.ref_, String("main"), "trigger0 ref_ (escaped from `ref`)")

    # trigger[1] — external git_push on release.
    assert_equal(b.triggers[1].name, String("external-release"), "trigger1 name")
    assert_equal(
        b.triggers[1]._oneof0_case, ARM_GIT_PUSH, "trigger1 arm is git_push"
    )
    ref gp1 = b.triggers[1].git_push.value()
    assert_equal(
        gp1.source_kind.value,
        SourceKind.SOURCE_KIND_GIT_EXTERNAL,
        "trigger1 source_kind GIT_EXTERNAL",
    )
    assert_equal(
        gp1.repo_ref, String("github.com/acme/mirror"), "trigger1 repo_ref"
    )
    assert_equal(gp1.ref_, String("release"), "trigger1 ref_")

    # trigger[2] — the SCHEDULE arm. This is what the old
    # `event: TRIGGER_EVENT_SCHEDULE` was trying and failing to say: it sat on a
    # git-shaped payload with a repo_ref and NO field anywhere to name a cadence.
    # The arm carries the cadence, so the assertion has something real to check.
    assert_equal(b.triggers[2].name, String("weekly-sweep"), "trigger2 name")
    assert_equal(
        b.triggers[2]._oneof0_case,
        ARM_SCHEDULE,
        "trigger2 arm is schedule (was TRIGGER_EVENT_SCHEDULE)",
    )
    ref sc2 = b.triggers[2].schedule.value()
    assert_equal(sc2.cron, String("0 6 * * 1"), "trigger2 cron")
    assert_equal(sc2.timezone, String("America/Chicago"), "trigger2 timezone")
    print("  test_triggers_parse_to_n_trigger_sources: PASS")


def test_trigger_enum_short_alias_resolves() raises:
    """The trigger enum fields accept the UNAMBIGUOUS short suffix alias (the same
    LLM-writability rule every other enum field uses): `GIT_SELFHOSTED` resolves to
    `SOURCE_KIND_GIT_SELFHOSTED`, and `GITHUB_PACKAGES` to
    `REGISTRY_KIND_GITHUB_PACKAGES`.

    `source_kind` lives inside `git_push` and the alias rule follows it there. The
    alias rule must hold for EVERY enum reachable under `triggers`, including
    `RegistryKind` on the `package_published` arm, so the second leg asserts it
    there ("the trigger tree's enums take short aliases")."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "triggers {\n"
        '  name: "push-main"\n'
        "  git_push {\n"
        "    source_kind: GIT_SELFHOSTED\n"
        '    repo_ref: "acme/svc"\n'
        '    ref: "main"\n'
        "  }\n"
        "}\n"
        "triggers {\n"
        '  name: "upstream-widget"\n'
        "  package_published {\n"
        "    registry_kind: GITHUB_PACKAGES\n"
        '    package_ref: "acme/widget"\n'
        "  }\n"
        "}\n"
    )
    var b = parse_bundle(text)
    assert_equal(len(b.triggers), 2, "two triggers via short aliases")
    assert_equal(
        b.triggers[0].git_push.value().source_kind.value,
        SourceKind.SOURCE_KIND_GIT_SELFHOSTED,
        "short alias GIT_SELFHOSTED -> SOURCE_KIND_GIT_SELFHOSTED",
    )
    assert_equal(
        b.triggers[1].package_published.value().registry_kind.value,
        RegistryKind.REGISTRY_KIND_GITHUB_PACKAGES,
        "short alias GITHUB_PACKAGES -> REGISTRY_KIND_GITHUB_PACKAGES",
    )
    print("  test_trigger_enum_short_alias_resolves: PASS")


def test_runtime_identity_authored_parses_and_round_trips() raises:
    """The AUTHORING `runtime_identity` field: an authored
    `runtime_identity: "orders-api-role"` parses into `AppSpec.runtime_identity`, and
    survives an emit -> re-parse round-trip (the emitter re-emits it, proto-field-order,
    only when non-empty)."""
    var text = String(
        'kind: APP_KIND_API\n'
        'name: "cp-api"\n'
        "\n"
        "spec {\n"
        "  image {\n"
        '    digest: "sha256:abc"\n'
        "  }\n"
        "  port: 8088\n"
        "  compute: COMPUTE_INTENT_SERVERLESS\n"
        "  datastore: DATASTORE_NEED_SERVERLESS\n"
        '  runtime_identity: "orders-api-role"\n'
        "}\n"
    )
    var b = parse_bundle(text)
    assert_equal(
        b.spec.value().runtime_identity,
        String("orders-api-role"),
        "runtime_identity parses from the authored field",
    )
    # emit -> re-parse: the field survives the canonical round-trip.
    var b2 = parse_bundle(emit_bundle(b))
    assert_equal(
        b2.spec.value().runtime_identity,
        String("orders-api-role"),
        "runtime_identity survives emit -> re-parse (emitter re-emits it)",
    )
    print("  test_runtime_identity_authored_parses_and_round_trips: PASS")


def test_validate_depends_on_authored_parses_and_round_trips() raises:
    """The step-DAG `depends_on` on a ValidateStep (proto field #4): authored
    `depends_on: "<step>"` lines parse into `ValidateStep.depends_on` (repeated),
    and survive an emit -> re-parse round-trip (the emitter re-emits each, in
    proto-field order AFTER the check block, only when non-empty). An EMPTY
    depends_on (an independent step) emits nothing — round-trip stable."""
    var text = String(
        'kind: APP_KIND_API\n'
        'name: "dep-api"\n'
        "\n"
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "integ"\n'
        "    run_container {\n"
        "      image {\n"
        '        from_build: "integ_tests"\n'
        "      }\n"
        "      gate_on: GATE_ON_EXIT_CODE\n"
        "    }\n"
        '    depends_on: "up"\n'
        '    depends_on: "smoke"\n'
        "  }\n"
        "  validate {\n"
        '    name: "up"\n'
        "    http_check {\n"
        '      path: "/livez"\n'
        "      expect_status: 200\n"
        "    }\n"
        "  }\n"
        "}\n"
    )
    var b = parse_bundle(text)
    # the dependent step carries BOTH deps, in order.
    assert_equal(
        len(b.waves[0].validate[0].depends_on), 2, "two depends_on parsed"
    )
    assert_equal(b.waves[0].validate[0].depends_on[0], String("up"), "dep 0 == up")
    assert_equal(
        b.waves[0].validate[0].depends_on[1], String("smoke"), "dep 1 == smoke"
    )
    # the independent step ("up") has NO depends_on (empty => eligible for concurrency).
    assert_equal(
        len(b.waves[0].validate[1].depends_on),
        0,
        "an independent step parses to an empty depends_on",
    )
    # emit -> the depends_on lines are re-emitted; re-parse -> identical; idempotent.
    var e = emit_bundle(b)
    assert_true(
        e.find(String('depends_on: "up"')) >= 0, "the emitter re-emits depends_on"
    )
    var b2 = parse_bundle(e)
    assert_equal(
        len(b2.waves[0].validate[0].depends_on),
        2,
        "depends_on survives the emit -> re-parse round-trip",
    )
    assert_equal(
        emit_bundle(b2), e, "the round-trip is idempotent with depends_on set"
    )
    print("  test_validate_depends_on_authored_parses_and_round_trips: PASS")


def test_http_check_max_latency_ms_parses_and_round_trips() raises:
    """★ `HttpCheck.max_latency_ms` (proto field #3) — THE
    LATENCY BUDGET, and its OPT-IN contract.

    THE DEFECT IT EXISTS FOR: a deploy health gate whose GET takes tens of
    seconds on a route that normally answers in milliseconds still logs
    `[PASS]` when an `http_check` asserts only STATUS and has no way to express
    time.

    TWO HALVES, and the second is the one that keeps existing bundles safe:
      (a) AUTHORED — `max_latency_ms: 250` parses into `HttpCheck` and is
          re-emitted, so an emit -> re-parse round-trip preserves it and is
          idempotent.
      (b) UNAUTHORED — a step with no budget parses to 0 and the emitter writes
          NO `max_latency_ms` line at all. That is what makes the field
          non-breaking: every bundle written before it existed re-emits
          BYTE-IDENTICALLY, and `emit -> parse -> emit` cannot silently
          introduce a budget nobody declared.

    Without `max_latency_ms` in `_parse_http_check`'s known-field set, leg (a)
    raises `unknown field 'max_latency_ms' in HttpCheck` at parse."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "lat-api"\n'
        "\n"
        "waves {\n"
        '  env: "gamma"\n'
        "  validate {\n"
        '    name: "livez-budgeted"\n'
        "    http_check {\n"
        '      path: "/livez"\n'
        "      expect_status: 200\n"
        "      max_latency_ms: 250\n"
        "    }\n"
        "  }\n"
        "  validate {\n"
        '    name: "livez-unbudgeted"\n'
        "    http_check {\n"
        '      path: "/readyz"\n'
        "      expect_status: 200\n"
        "    }\n"
        "  }\n"
        "}\n"
    )
    var b = parse_bundle(text)
    assert_equal(
        Int(b.waves[0].validate[0].http_check.value().max_latency_ms),
        250,
        "an authored max_latency_ms parses onto the HttpCheck",
    )
    # (b) the UNAUTHORED step is the proto3 zero == LATENCY NOT CHECKED.
    assert_equal(
        Int(b.waves[0].validate[1].http_check.value().max_latency_ms),
        0,
        "a step with no budget parses to 0 (== latency NOT checked)",
    )
    var e = emit_bundle(b)
    assert_true(
        e.find(String("max_latency_ms: 250")) >= 0,
        "the emitter re-emits an AUTHORED budget",
    )
    # ⛔ EXACTLY ONE occurrence — the unbudgeted step must not acquire a
    # `max_latency_ms: 0` line. A zero-valued line would (1) change the bytes of
    # every bundle this emitter round-trips and (2) STATE a budget
    # where the author declared none, which is how an opt-in field stops being
    # one.
    var budget_lines = 0
    var scan = 0
    while True:
        var at = e.find(String("max_latency_ms"), scan)
        if at < 0:
            break
        budget_lines += 1
        scan = at + 1
    assert_equal(
        budget_lines,
        1,
        "the emitter writes the budget line ONCE — never for the unbudgeted step",
    )
    var b2 = parse_bundle(e)
    assert_equal(
        Int(b2.waves[0].validate[0].http_check.value().max_latency_ms),
        250,
        "max_latency_ms survives the emit -> re-parse round-trip",
    )
    assert_equal(
        Int(b2.waves[0].validate[1].http_check.value().max_latency_ms),
        0,
        "the unbudgeted step is STILL unbudgeted after a round trip",
    )
    assert_equal(
        emit_bundle(b2), e, "the round-trip is idempotent with a budget set"
    )
    print("  test_http_check_max_latency_ms_parses_and_round_trips: PASS")


def test_web_frontend_fields_parse_and_round_trip() raises:
    """The STATIC_FRONTEND authoring fields (AppSpec 13-17): authored `web_slug` / `web_domain` / repeated
    `web_additional_domains` / repeated `web_api_path_prefixes` /
    `web_api_service_logical_id` parse into `AppSpec`, and survive an emit ->
    re-parse round-trip (the emitter re-emits each only when non-empty; the
    repeated fields in the repeated-scalar one-line-per-element form)."""
    var text = String(
        "kind: APP_KIND_STATIC_FRONTEND\n"
        'name: "orders-web"\n'
        "\n"
        "spec {\n"
        '  web_slug: "orders-prod"\n'
        '  web_domain: "example.com"\n'
        '  web_additional_domains: "www.example.com"\n'
        '  web_api_path_prefixes: "/api"\n'
        '  web_api_path_prefixes: "/v1"\n'
        '  web_api_service_logical_id: "orders-api-svc"\n'
        "}\n"
        "\n"
        "waves {\n"
        '  env: "prod"\n'
        "}\n"
    )
    var b = parse_bundle(text)
    ref sp = b.spec.value()
    assert_equal(sp.web_slug, String("orders-prod"), "web_slug parses")
    assert_equal(sp.web_domain, String("example.com"), "web_domain parses")
    assert_equal(
        len(sp.web_additional_domains), 1, "one additional domain parses"
    )
    assert_equal(
        sp.web_additional_domains[0], String("www.example.com"), "www parses"
    )
    assert_equal(len(sp.web_api_path_prefixes), 2, "two api prefixes parse")
    assert_equal(sp.web_api_path_prefixes[0], String("/api"), "prefix 0")
    assert_equal(sp.web_api_path_prefixes[1], String("/v1"), "prefix 1")
    assert_equal(
        sp.web_api_service_logical_id,
        String("orders-api-svc"),
        "api service logical id parses",
    )
    # emit -> re-parse: every field survives; the round-trip is idempotent.
    var e = emit_bundle(b)
    var b2 = parse_bundle(e)
    ref sp2 = b2.spec.value()
    assert_equal(sp2.web_slug, String("orders-prod"), "web_slug round-trips")
    assert_equal(sp2.web_domain, String("example.com"), "web_domain round-trips")
    assert_equal(
        len(sp2.web_additional_domains), 1, "additional domains round-trip"
    )
    assert_equal(
        len(sp2.web_api_path_prefixes), 2, "api prefixes round-trip"
    )
    assert_equal(
        sp2.web_api_service_logical_id,
        String("orders-api-svc"),
        "api service logical id round-trips",
    )
    assert_equal(
        emit_bundle(b2), e, "the round-trip is idempotent with web fields set"
    )
    print("  test_web_frontend_fields_parse_and_round_trip: PASS")


def test_api_edge_fields_parse_and_round_trip() raises:
    """The API-EDGE authoring fields (AppSpec 18-19 + Wave 3): an authored
    `inbound: INBOUND_NEED_CLIENT` + a per-wave `api_edge_enabled: true` parse
    into the bundle and survive an emit -> re-parse round-trip (the emitter
    re-emits each only when non-default, so a plain bundle stays
    byte-identical); a WEBHOOK intent carries its authored
    `inbound_route_path`; the semantic pass enforces the route-path <->
    WEBHOOK pairing both directions."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "orders-api"\n'
        "\n"
        "build {\n"
        '  name: "service"\n'
        '  dockerfile: "Dockerfile"\n'
        "}\n"
        "\n"
        "spec {\n"
        '  image { from_build: "service" }\n'
        "  port: 8088\n"
        "  inbound: INBOUND_NEED_CLIENT\n"
        "}\n"
        "\n"
        "waves {\n"
        '  env: "gamma"\n'
        "  api_edge_enabled: true\n"
        "}\n"
        "\n"
        "waves {\n"
        '  env: "prod"\n'
        "}\n"
    )
    var b = parse_bundle(text)
    ref sp = b.spec.value()
    assert_equal(Int(sp.inbound.value), 3, "inbound CLIENT parses (ordinal 3)")
    assert_equal(sp.inbound_route_path, String(""), "no route path (CLIENT)")
    assert_true(b.waves[0].api_edge_enabled, "gamma wave toggle parses ON")
    assert_true(
        not b.waves[1].api_edge_enabled, "prod wave toggle defaults OFF"
    )
    assert_equal(len(validate_bundle(b)), 0, "the CLIENT bundle is valid")
    # emit -> re-parse: the fields survive; the round-trip is idempotent.
    var e = emit_bundle(b)
    assert_true(
        String("api_edge_enabled: true") in e, "the ON toggle re-emits"
    )
    assert_true(
        String("inbound: INBOUND_NEED_CLIENT") in e, "the intent re-emits"
    )
    var b2 = parse_bundle(e)
    assert_equal(Int(b2.spec.value().inbound.value), 3, "inbound round-trips")
    assert_true(b2.waves[0].api_edge_enabled, "the toggle round-trips")
    assert_equal(emit_bundle(b2), e, "idempotent with the edge fields set")

    # WEBHOOK carries its authored route path (the OD-3 authoring surface).
    var wh = parse_bundle(
        String(
            "kind: APP_KIND_API\n"
            'name: "inbox"\n'
            "\n"
            "build {\n"
            '  name: "service"\n'
            '  dockerfile: "Dockerfile"\n'
            "}\n"
            "\n"
            "spec {\n"
            '  image { from_build: "service" }\n'
            "  port: 8080\n"
            "  inbound: INBOUND_NEED_WEBHOOK\n"
            '  inbound_route_path: "/mail/inbound"\n'
            "}\n"
            "\n"
            "waves {\n"
            '  env: "gamma"\n'
            "}\n"
        )
    )
    assert_equal(
        wh.spec.value().inbound_route_path,
        String("/mail/inbound"),
        "the WEBHOOK route path parses (authored, never defaulted)",
    )
    assert_equal(len(validate_bundle(wh)), 0, "the WEBHOOK bundle is valid")

    # SEMANTIC pass: WEBHOOK without a route path -> error; a route path
    # without WEBHOOK -> error (validated in both directions).
    var missing = parse_bundle(
        String(
            "kind: APP_KIND_API\n"
            'name: "inbox"\n'
            "\n"
            "build {\n"
            '  name: "service"\n'
            '  dockerfile: "Dockerfile"\n'
            "}\n"
            "\n"
            "spec {\n"
            '  image { from_build: "service" }\n'
            "  port: 8080\n"
            "  inbound: INBOUND_NEED_WEBHOOK\n"
            "}\n"
            "\n"
            "waves {\n"
            '  env: "gamma"\n'
            "}\n"
        )
    )
    var errs = validate_bundle(missing)
    assert_equal(len(errs), 1, "WEBHOOK without a route path is ONE error")
    assert_true(
        String("inbound_route_path") in errs[0], "the error names the field"
    )
    var stray = parse_bundle(
        String(
            "kind: APP_KIND_API\n"
            'name: "orders-api"\n'
            "\n"
            "build {\n"
            '  name: "service"\n'
            '  dockerfile: "Dockerfile"\n'
            "}\n"
            "\n"
            "spec {\n"
            '  image { from_build: "service" }\n'
            "  port: 8088\n"
            "  inbound: INBOUND_NEED_CLIENT\n"
            '  inbound_route_path: "/oops"\n'
            "}\n"
            "\n"
            "waves {\n"
            '  env: "gamma"\n'
            "}\n"
        )
    )
    var errs2 = validate_bundle(stray)
    assert_equal(len(errs2), 1, "a stray route path on CLIENT is ONE error")
    print("  test_api_edge_fields_parse_and_round_trip: PASS")


def main() raises:
    test_canonical_round_trips_byte_exact()
    test_round_trip_is_idempotent()
    test_parsed_fields_match()
    test_comments_and_optional_colon_are_ignored()
    test_zero_triggers_parses_to_empty_one_shot()
    test_triggers_parse_to_n_trigger_sources()
    test_trigger_enum_short_alias_resolves()
    test_runtime_identity_authored_parses_and_round_trips()
    test_validate_depends_on_authored_parses_and_round_trips()
    test_http_check_max_latency_ms_parses_and_round_trips()
    test_web_frontend_fields_parse_and_round_trip()
    test_api_edge_fields_parse_and_round_trip()
    print("PASS test_parser_roundtrip")
