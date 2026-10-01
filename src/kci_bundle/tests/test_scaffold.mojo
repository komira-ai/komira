# =============================================================================
# kci_bundle/tests/test_scaffold.mojo
#   — the per-kind package-baseline scaffolder.
# =============================================================================
#
# `scaffold_bundle` lays down the WHOLE buildable package per kind: the intent bundle + pinned pixi.toml + BUILD/MODULE skeleton +
# Dockerfiles + test stubs. The load-bearing invariant is SELF-CONSISTENCY — the
# komira.deploy.textproto the scaffolder emits must itself PARSE + VALIDATE CLEAN
# (a scaffold that emits an invalid bundle would send every new user straight
# into an error). These tests assert that for all four kinds, plus the file-map
# completeness, the pinned toolchain, and the kind normalization.
#
# Encapsulation: pure scaffold + parse/validate asserts. Mojo 1.0.0b2.
# =============================================================================

from std.collections.dict import Dict
from std.testing import assert_equal, assert_true

from kci_bundle.scaffold import scaffold_bundle, normalize_kind
from kci_bundle.parser import parse_bundle
from kci_bundle.validate import validate_bundle
from kci_bundle_proto.app_bundle import AppKind


def _assert_full_file_map(files: Dict[String, String]) raises:
    assert_true(
        String("komira.deploy.textproto") in files, "has intent bundle"
    )
    assert_true(String("pixi.toml") in files, "has pixi.toml")
    assert_true(String("BUILD.bazel") in files, "has BUILD.bazel")
    assert_true(String("MODULE.bazel") in files, "has MODULE.bazel")
    assert_true(String("Dockerfile") in files, "has Dockerfile")
    assert_true(String("Dockerfile.integ") in files, "has Dockerfile.integ")
    assert_true(
        String("tests/unit/test_smoke.sh") in files, "has unit test stub"
    )
    assert_true(
        String("tests/integ/test_integ.sh") in files, "has integ test stub"
    )


def test_api_scaffold_is_rich_and_valid() raises:
    """The API kind gets the orders-api shape (two builds, three waves) and it
    parses + validates clean; the intent text carries the header intent."""
    var files = scaffold_bundle(
        String("api"), String("orders-api"), String("Acme orders API")
    )
    _assert_full_file_map(files)

    var text = files[String("komira.deploy.textproto")]
    var b = parse_bundle(text)
    assert_equal(b.kind.value, AppKind.APP_KIND_API, "kind API")
    assert_equal(b.name, String("orders-api"), "name")
    assert_equal(len(b.build), 2, "service + integ_tests builds")
    assert_equal(len(b.waves), 3, "dev + gamma + prod waves")
    assert_equal(len(validate_bundle(b)), 0, "API scaffold validates clean")

    assert_true(
        text.find(String("Acme orders API")) >= 0, "intent in header comment"
    )
    # ⚠ THIS ASSERTS THE SHAPE, NOT A FROZEN VALUE: a frozen literal would
    # enforce a stale pin the day the repository's pin moves — a test pinning
    # the wrong answer. The shape is an EXACT pin (`==`), never a range, and
    # never a missing line.
    var _pixi = files[String("pixi.toml")]
    assert_true(
        _pixi.find(String('mojo = "==')) >= 0,
        "scaffolded pixi.toml states an EXACT mojo pin",
    )
    assert_true(
        _pixi.find(String('mojo = ">=')) < 0,
        "scaffolded pixi.toml never states a RANGE pin (a re-solve would move"
        " the customer's compiler with no diff anywhere)",
    )
    print("  test_api_scaffold_is_rich_and_valid: PASS")


def test_minimal_kinds_scaffold_valid() raises:
    """The three non-API kinds get a minimal-but-VALID bundle that parses +
    validates clean, with the correct kind."""
    var sf = scaffold_bundle(
        String("static_frontend"), String("marketing-site"), String("")
    )
    var b1 = parse_bundle(sf[String("komira.deploy.textproto")])
    assert_equal(b1.kind.value, AppKind.APP_KIND_STATIC_FRONTEND, "static kind")
    assert_equal(len(validate_bundle(b1)), 0, "static scaffold clean")

    var dp = scaffold_bundle(
        String("data_pipeline"), String("nightly-etl"), String("")
    )
    var b2 = parse_bundle(dp[String("komira.deploy.textproto")])
    assert_equal(b2.kind.value, AppKind.APP_KIND_DATA_PIPELINE, "pipeline kind")
    assert_equal(len(validate_bundle(b2)), 0, "pipeline scaffold clean")

    var sc = scaffold_bundle(
        String("search_cluster"), String("docs-search"), String("")
    )
    var b3 = parse_bundle(sc[String("komira.deploy.textproto")])
    assert_equal(b3.kind.value, AppKind.APP_KIND_SEARCH_CLUSTER, "search kind")
    assert_equal(len(validate_bundle(b3)), 0, "search scaffold clean")
    print("  test_minimal_kinds_scaffold_valid: PASS")


def test_normalize_kind_accepts_variants() raises:
    """Flexible kind tokens map to the canonical full value name; unknown raises."""
    assert_equal(normalize_kind(String("api")), String("APP_KIND_API"), "api")
    assert_equal(normalize_kind(String("API")), String("APP_KIND_API"), "API")
    assert_equal(
        normalize_kind(String("APP_KIND_API")), String("APP_KIND_API"), "full"
    )
    assert_equal(
        normalize_kind(String("static_frontend")),
        String("APP_KIND_STATIC_FRONTEND"),
        "static",
    )
    var raised = False
    try:
        _ = normalize_kind(String("nope"))
    except e:
        _ = e
        raised = True
    assert_true(raised, "unknown kind raises")
    print("  test_normalize_kind_accepts_variants: PASS")


def main() raises:
    test_api_scaffold_is_rich_and_valid()
    test_minimal_kinds_scaffold_valid()
    test_normalize_kind_accepts_variants()
    print("PASS test_scaffold")
