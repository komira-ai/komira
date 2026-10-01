# =============================================================================
# komira_deploy_bundle/tests/test_outputs.mojo
#   — the named DEPLOY OUTPUTS authoring block: parse + emit round-trip + the
#     pure `${ref:...}` symbolic resolver + fail-closed synth-time validation.
# =============================================================================
#
# Scope = SCHEMA + PARSE + EMIT + the SYMBOLIC `${ref:...}` resolver + VALIDATE
# for the SERVED-URL output kind (the only kind built — it reuses the served-URL
# registry write). These tests pin:
#   (1) an `outputs {}` block PARSES + round-trips (parse -> emit -> re-parse) and
#       a no-outputs bundle re-emits BYTE-IDENTICALLY (migration safety);
#   (2) the PURE `${ref:<bundle>.outputs.<name>}` symbolic resolver: parse_output_
#       ref parses; resolve_output_to_served_name -> the `from_served` name; a
#       MALFORMED ref + an UNKNOWN output fail-closed;
#   (3) `validate_bundle` PASSES a well-formed outputs bundle;
#   (4) `validate_bundle` FAILS-CLOSED on
#         (a) a `from_served` naming no served service in the bundle,
#         (b) a duplicate output name,
#         (c) an empty output name,
#         (d) a missing `from_served` (served-URL only).
#
# The registry-backed URL resolution (service/<from_served> -> URL) belongs to
# the caller that owns the registry; this file is pure — no registry /
# object-store dep, mirroring test_matrix.mojo.
#
# Encapsulation: pure parse + emit + validate + resolve asserts. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.emit import emit_bundle
from komira_deploy_bundle.validate import validate_bundle
from komira_deploy_bundle.outputs_ref import (
    is_output_ref,
    parse_output_ref,
    resolve_output_to_served_name,
    lookup_output,
)


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _any_contains(errs: List[String], needle: String) -> Bool:
    for ref e in errs:
        if e.find(needle) >= 0:
            return True
    return False


# A well-formed bundle: an API service named "orders-coordinator" that
# declares one served-URL OUTPUT ("endpoint") sourced from its OWN served node
# (from_served == the bundle's service name), plus a NON-outputs prefix.
def _good_bundle() -> String:
    return String(
        "kind: APP_KIND_API\n"
        'name: "orders-coordinator"\n'
        'build { name: "coord" dockerfile: "Dockerfile.coord" }\n'
        'spec { image { from_build: "coord" } port: 8080 }\n'
        'waves { env: "gamma" }\n'
        "outputs {\n"
        '  name: "endpoint"\n'
        '  from_served: "orders-coordinator"\n'
        "}\n"
    )


# A NO-OUTPUTS bundle (the migration-safety fixture). We do NOT hardcode the
# canonical emit format (brittle); instead we assert the CANONICAL form is a
# stable fixpoint AND carries no `outputs {}` block (below).
def _no_outputs_bundle() -> String:
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "coord" dockerfile: "Dockerfile.coord" }\n'
        'spec { image { from_build: "coord" } port: 8080 }\n'
        'waves { env: "gamma" }\n'
    )


def test_outputs_parses_and_round_trips_fields() raises:
    """The `outputs {}` block parses into the generated struct and round-trips
    every authored field (name + from_served)."""
    var b = parse_bundle(_good_bundle())
    assert_equal(len(b.outputs), 1, "one output parsed")
    ref o = b.outputs[0]
    assert_equal(o.name, String("endpoint"), "output name")
    assert_equal(
        o.from_served, String("orders-coordinator"), "output from_served"
    )
    print("  test_outputs_parses_and_round_trips_fields: PASS")


def test_outputs_emit_round_trip() raises:
    """emit_bundle re-serializes the `outputs {}` block, and re-parsing the
    emitted text recovers the SAME output (parse -> emit -> parse fixpoint)."""
    var b = parse_bundle(_good_bundle())
    var emitted = emit_bundle(b)
    # the emitted canonical form carries the outputs block
    assert_true(emitted.find(String("outputs {")) >= 0, "emit carries outputs {}")
    assert_true(emitted.find(String('name: "endpoint"')) >= 0, "emit carries name")
    assert_true(
        emitted.find(String('from_served: "orders-coordinator"')) >= 0,
        "emit carries from_served",
    )
    # re-parse the emitted text -> the SAME output (a true round-trip).
    var b2 = parse_bundle(emitted)
    assert_equal(len(b2.outputs), 1, "re-parsed one output")
    assert_equal(b2.outputs[0].name, String("endpoint"), "re-parsed name")
    assert_equal(
        b2.outputs[0].from_served,
        String("orders-coordinator"),
        "re-parsed from_served",
    )
    print("  test_outputs_emit_round_trip: PASS")


def test_no_outputs_bundle_re_emits_byte_identically() raises:
    """A bundle with NO `outputs {}` gains NO outputs block on emit and its
    canonical form is a STABLE FIXPOINT (the feature activates only when authored
    — migration safety; byte-identical + behavior-identical to a pre-outputs
    bundle)."""
    var b = parse_bundle(_no_outputs_bundle())
    assert_equal(len(b.outputs), 0, "no outputs parsed")
    var canonical = emit_bundle(b)
    assert_true(
        canonical.find(String("outputs {")) < 0,
        "a no-outputs bundle emits NO outputs block",
    )
    # The canonical form re-emits byte-identically (a pre-outputs bundle is a
    # stable fixpoint of parse->emit — no drift introduced by the new field).
    assert_equal(
        emit_bundle(parse_bundle(canonical)),
        canonical,
        "no-outputs bundle canonical form is a stable parse->emit fixpoint",
    )
    print("  test_no_outputs_bundle_re_emits_byte_identically: PASS")


def test_symbolic_ref_parses_and_resolves() raises:
    """The PURE `${ref:<bundle>.outputs.<name>}` symbolic resolver: is_output_ref
    discriminates, parse_output_ref splits <bundle>/<name>, and resolve_output_to_
    served_name resolves to the output's `from_served` (the served-service name a
    caller then reads the URL for)."""
    var ref_str = String("${ref:orders-coordinator.outputs.endpoint}")
    assert_true(is_output_ref(ref_str), "is a ${ref:...}")
    assert_true(not is_output_ref(String("https://plain.example")), "plain is not a ref")

    var parsed = parse_output_ref(ref_str)
    assert_equal(parsed.app, String("orders-coordinator"), "parsed <bundle>")
    assert_equal(parsed.output, String("endpoint"), "parsed <name>")

    var b = parse_bundle(_good_bundle())
    var served = resolve_output_to_served_name(ref_str, b.outputs)
    assert_equal(
        served, String("orders-coordinator"), "resolved served-service name"
    )

    # lookup_output finds the declared output, None for an unknown one.
    assert_true(lookup_output(b.outputs, String("endpoint")).__bool__(), "found")
    assert_true(not lookup_output(b.outputs, String("ghost")).__bool__(), "not found")
    print("  test_symbolic_ref_parses_and_resolves: PASS")


def test_malformed_ref_fails_closed() raises:
    """A malformed `${ref:...}` (not of the `<bundle>.outputs.<name>` form) is a
    fail-closed raise — never a silent empty resolution."""
    var b = parse_bundle(_good_bundle())
    var raised = False
    try:
        _ = resolve_output_to_served_name(
            String("${ref:orders-coordinator.WRONG.endpoint}"), b.outputs
        )
    except e:
        raised = True
        assert_true(String(e).find(String("malformed")) >= 0, "malformed message")
    assert_true(raised, "a malformed ref raises")
    print("  test_malformed_ref_fails_closed: PASS")


def test_unknown_output_ref_fails_closed() raises:
    """A `${ref:...}` naming an output the bundle does NOT declare is a fail-closed
    raise (the dangling-ref case)."""
    var b = parse_bundle(_good_bundle())
    var raised = False
    try:
        _ = resolve_output_to_served_name(
            String("${ref:orders-coordinator.outputs.ghost}"), b.outputs
        )
    except e:
        raised = True
        assert_true(
            String(e).find(String("names no declared output")) >= 0,
            "unknown-output message",
        )
    assert_true(raised, "an unknown-output ref raises")
    print("  test_unknown_output_ref_fails_closed: PASS")


def test_well_formed_outputs_validate_clean() raises:
    """A well-formed outputs bundle (from_served names the bundle's served
    service) produces ZERO errors."""
    assert_equal(
        len(_errs(_good_bundle())), 0, "a well-formed outputs bundle is valid"
    )
    print("  test_well_formed_outputs_validate_clean: PASS")


def test_from_served_naming_no_service_fails_closed() raises:
    """(a) An output whose `from_served` names no served service in the bundle is
    a fail-closed error (a dangling reference that would never resolve)."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "orders-coordinator"\n'
        'build { name: "coord" dockerfile: "Dockerfile.coord" }\n'
        'spec { image { from_build: "coord" } port: 8080 }\n'
        'waves { env: "gamma" }\n'
        'outputs { name: "endpoint" from_served: "ghost-svc" }\n'
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(
            errs, String("does not name a served service in this bundle")
        ),
        "dangling from_served flagged",
    )
    print("  test_from_served_naming_no_service_fails_closed: PASS")


def test_duplicate_output_name_fails_closed() raises:
    """(b) Two outputs with the same name is a fail-closed error."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "coord" dockerfile: "Dockerfile.coord" }\n'
        'spec { image { from_build: "coord" } port: 8080 }\n'
        'waves { env: "gamma" }\n'
        'outputs { name: "endpoint" from_served: "svc" }\n'
        'outputs { name: "endpoint" from_served: "svc" }\n'
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("duplicate output name 'endpoint'")),
        "duplicate output name flagged",
    )
    print("  test_duplicate_output_name_fails_closed: PASS")


def test_empty_output_name_fails_closed() raises:
    """(c) An output with an empty `name` is a fail-closed error."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "coord" dockerfile: "Dockerfile.coord" }\n'
        'spec { image { from_build: "coord" } port: 8080 }\n'
        'waves { env: "gamma" }\n'
        'outputs { from_served: "svc" }\n'
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("'name' is required (an output name)")),
        "empty output name flagged",
    )
    print("  test_empty_output_name_fails_closed: PASS")


def test_missing_from_served_fails_closed() raises:
    """(d) An output with no `from_served` is a fail-closed error (only the
    served-URL output kind is built — the general value kinds are a later extension)."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "coord" dockerfile: "Dockerfile.coord" }\n'
        'spec { image { from_build: "coord" } port: 8080 }\n'
        'waves { env: "gamma" }\n'
        'outputs { name: "endpoint" }\n'
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("'from_served' is required")),
        "missing from_served flagged",
    )
    print("  test_missing_from_served_fails_closed: PASS")


def main() raises:
    test_outputs_parses_and_round_trips_fields()
    test_outputs_emit_round_trip()
    test_no_outputs_bundle_re_emits_byte_identically()
    test_symbolic_ref_parses_and_resolves()
    test_malformed_ref_fails_closed()
    test_unknown_output_ref_fails_closed()
    test_well_formed_outputs_validate_clean()
    test_from_served_naming_no_service_fails_closed()
    test_duplicate_output_name_fails_closed()
    test_empty_output_name_fails_closed()
    test_missing_from_served_fails_closed()
    print("PASS test_outputs")
