# =============================================================================
# komira_deploy_bundle/tests/test_enum_alias.mojo
#   — the enum short-alias middle path: friendly input, ONE canonical output.
# =============================================================================
#
# The parser accepts the SHORT enum token
# (`kind: API`) wherever it is an UNAMBIGUOUS suffix of exactly one declared value
# in that field's enum, in service of the LLM-writability tenet; ambiguous /
# unknown still errors. EMISSION stays canonical-full-only everywhere (emit /
# scaffold / patch). These tests pin: (1) each aliased enum resolves the short
# token to the canonical ordinal, (2) short input re-emits to canonical-full
# output, (3) a patch on a short-authored file preserves the author's spelling on
# UNTOUCHED lines while a patched enum line emits canonical, and (4) the
# unambiguous-suffix rule (exact-wins, ambiguity + unknown both error).
#
# Encapsulation: pure parse / emit / patch + value asserts. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_deploy_bundle.parser import (
    parse_bundle,
    resolve_enum_token,
    app_kind_values,
    compute_values,
)
from komira_deploy_bundle.emit import emit_bundle
from komira_deploy_bundle.patch import patch_set_field, patch_set_enum
from komira_rpc_bundle.app_bundle import AppKind, ValueFrom, GateOn
from komira_rpc_bundle.deploy_model import ComputeIntent, DatastoreNeed


# A bundle authored entirely with the SHORT enum tokens (kind: API, compute:
# SERVERLESS, datastore: NONE, gate_on: EXIT_CODE, value_from: DEPLOY_URL).
comptime _SHORT: String = (
    "kind: API\n"
    'name: "orders"\n'
    'build { name: "service" dockerfile: "Dockerfile" }\n'
    'build { name: "integ" dockerfile: "Dockerfile.integ" }\n'
    "spec {\n"
    '  image { from_build: "service" }\n'
    "  port: 8080\n"
    "  compute: SERVERLESS\n"
    "  datastore: NONE\n"
    "}\n"
    "waves {\n"
    '  env: "gamma"\n'
    "  validate {\n"
    '    name: "integ"\n'
    "    run_container {\n"
    '      image { from_build: "integ" }\n'
    "      gate_on: EXIT_CODE\n"
    '      env { name: "TARGET_URL" value_from: DEPLOY_URL }\n'
    "    }\n"
    "  }\n"
    "}\n"
)


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def test_short_aliases_resolve_to_canonical_ordinals() raises:
    """Every aliased enum field resolves its short token to the canonical value."""
    var b = parse_bundle(_SHORT)
    assert_equal(b.kind.value, AppKind.APP_KIND_API, "kind: API -> APP_KIND_API")
    var sp = b.spec.value().copy()
    assert_equal(
        sp.compute.value,
        ComputeIntent.COMPUTE_INTENT_SERVERLESS,
        "compute: SERVERLESS",
    )
    assert_equal(
        sp.datastore.value, DatastoreNeed.DATASTORE_NEED_NONE, "datastore: NONE"
    )
    var rc = b.waves[0].validate[0].run_container.value().copy()
    assert_equal(rc.gate_on.value, GateOn.GATE_ON_EXIT_CODE, "gate_on: EXIT_CODE")
    assert_equal(
        rc.env[0].value_from.value().value,
        ValueFrom.VALUE_FROM_DEPLOY_URL,
        "value_from: DEPLOY_URL",
    )
    print("  test_short_aliases_resolve_to_canonical_ordinals: PASS")


def test_short_input_reemits_canonical_full() raises:
    """Short input -> parse -> emit produces CANONICAL FULL enum lines (one
    canonical output), never the short form."""
    var out = emit_bundle(parse_bundle(_SHORT))
    assert_true(_contains(out, String("kind: APP_KIND_API\n")), "kind full")
    assert_true(
        _contains(out, String("compute: COMPUTE_INTENT_SERVERLESS\n")), "compute full"
    )
    assert_true(
        _contains(out, String("datastore: DATASTORE_NEED_NONE\n")), "datastore full"
    )
    assert_true(
        _contains(out, String("gate_on: GATE_ON_EXIT_CODE\n")), "gate_on full"
    )
    assert_true(
        _contains(out, String("value_from: VALUE_FROM_DEPLOY_URL\n")), "value_from full"
    )
    # the short forms are NOT emitted
    assert_true(not _contains(out, String("kind: API\n")), "no short kind")
    assert_true(not _contains(out, String("compute: SERVERLESS\n")), "no short compute")
    print("  test_short_input_reemits_canonical_full: PASS")


def _path(a: String) -> List[String]:
    var p = List[String]()
    p.append(a)
    return p^


def test_patch_preserves_untouched_short_spelling() raises:
    """A set-field on a NON-enum field leaves the author's short enum lines
    byte-identical (comment/line preservation)."""
    var out = patch_set_field(_SHORT, _path(String("name")), String("orders2"), True)
    assert_true(_contains(out, String('name: "orders2"')), "name patched")
    # untouched short enum lines survive verbatim
    assert_true(_contains(out, String("kind: API\n")), "short kind preserved")
    assert_true(_contains(out, String("compute: SERVERLESS\n")), "short compute preserved")
    print("  test_patch_preserves_untouched_short_spelling: PASS")


def test_patch_enum_emits_canonical() raises:
    """The patch_set_enum op canonicalizes the patched line (short input ->
    canonical full) while every UNTOUCHED enum line keeps the author's short
    spelling."""
    # patch `kind` with the short token API -> the line becomes canonical full
    var out = patch_set_enum(
        _SHORT, _path(String("kind")), String("API"), app_kind_values()
    )
    assert_true(_contains(out, String("kind: APP_KIND_API\n")), "patched kind canonical")
    assert_true(not _contains(out, String("kind: API\n")), "short kind replaced")
    # the untouched compute line still carries the author's short spelling
    assert_true(
        _contains(out, String("compute: SERVERLESS\n")), "untouched compute preserved"
    )
    # re-parse: the whole file is still valid + kind is API
    var b = parse_bundle(out)
    assert_equal(b.kind.value, AppKind.APP_KIND_API, "re-parsed kind")
    print("  test_patch_enum_emits_canonical: PASS")


def test_resolve_enum_token_rules() raises:
    """The unambiguous-suffix rule: exact-full wins; a unique suffix resolves; a
    suffix of >1 value is ambiguous; no match is unknown."""
    # exact full name is returned unchanged
    assert_equal(
        resolve_enum_token(String("APP_KIND_API"), app_kind_values()),
        String("APP_KIND_API"),
        "exact full",
    )
    # short unambiguous suffix resolves to canonical
    assert_equal(
        resolve_enum_token(String("SERVERLESS"), compute_values()),
        String("COMPUTE_INTENT_SERVERLESS"),
        "short suffix",
    )
    # multi-word suffix resolves
    assert_equal(
        resolve_enum_token(String("STATIC_FRONTEND"), app_kind_values()),
        String("APP_KIND_STATIC_FRONTEND"),
        "multi-word suffix",
    )
    # ambiguity: a suffix shared by >1 declared value errors
    var ambiguous_legal = List[String]()
    ambiguous_legal.append(String("X_FOO_BAR"))
    ambiguous_legal.append(String("Y_BAR"))
    var amb_raised = False
    var amb_msg = String("")
    try:
        _ = resolve_enum_token(String("BAR"), ambiguous_legal)
    except e:
        amb_raised = True
        amb_msg = String(e)
    assert_true(amb_raised, "ambiguous raises")
    assert_true(_contains(amb_msg, String("ambiguous")), "ambiguous message")
    # unknown: not a suffix of anything
    var unk_raised = False
    try:
        _ = resolve_enum_token(String("ZED"), app_kind_values())
    except e:
        _ = e
        unk_raised = True
    assert_true(unk_raised, "unknown raises")
    print("  test_resolve_enum_token_rules: PASS")


def main() raises:
    test_short_aliases_resolve_to_canonical_ordinals()
    test_short_input_reemits_canonical_full()
    test_patch_preserves_untouched_short_spelling()
    test_patch_enum_emits_canonical()
    test_resolve_enum_token_rules()
    print("PASS test_enum_alias")
