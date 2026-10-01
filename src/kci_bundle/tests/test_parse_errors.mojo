# =============================================================================
# kci_bundle/tests/test_parse_errors.mojo
#   — the AppBundle error-message GOLDENS (the LLM self-correction surface).
# =============================================================================
#
# The precise, position-carrying diagnostics are the WHOLE POINT of the authoring
# surface: an LLM authoring a
# bundle self-corrects WITHOUT a human because every error names the line/col and,
# for a near-miss, suggests the intended field/enum value. These goldens pin the
# exact message text — a regression that dulls an error (drops the position, the
# suggestion, or the container name) fails here.
#
# COVERAGE: unknown field (did-you-mean), bad enum value
# (the short-form -> full-prefixed suggestion), an unterminated string
# (lexical), a oneof-arm conflict, and the semantic dangling `from_build`
# (validate, not parse). Encapsulation: pure parse/validate + string asserts.
# Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_bundle.parser import parse_bundle
from kci_bundle.validate import validate_bundle


def _parse_error(text: String) -> String:
    """Parse `text`, returning the raised error message (or "" if it did not
    raise — a test failure signal)."""
    try:
        _ = parse_bundle(text)
        return String("")
    except e:
        return String(e)


def test_unknown_field_suggests_nearest() raises:
    """An unknown field in a message yields `line N, col M: unknown field 'X' in
    <Container> — did you mean 'Y'?`."""
    var bad = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        '  imge { from_build: "service" }\n'
        "}\n"
    )
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String(
            "line 4, col 3: unknown field 'imge' in AppSpec — did you mean"
            " 'image'?"
        ),
        "unknown-field golden",
    )
    print("  test_unknown_field_suggests_nearest: PASS")


def test_unknown_enum_lists_legal_values() raises:
    """A genuinely unknown enum value errors with the legal-value listing.

    Not a short alias of any declared value. The short form `API` is
    ACCEPTED as an alias (see test_enum_alias.mojo); only truly-unknown values
    error here."""
    var bad = String('kind: WIDGET\nname: "svc"\n')
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String(
            "line 1, col 7: unknown value 'WIDGET' for enum AppKind (legal"
            " values: APP_KIND_UNSPECIFIED, APP_KIND_API,"
            " APP_KIND_STATIC_FRONTEND, APP_KIND_DATA_PIPELINE,"
            " APP_KIND_SEARCH_CLUSTER, APP_KIND_DESKTOP_APPLICATION,"
            " APP_KIND_MOBILE_APPLICATION, APP_KIND_LIBRARY,"
            " APP_KIND_SHARED_INFRASTRUCTURE)"
        ),
        "unknown-enum golden",
    )
    print("  test_unknown_enum_lists_legal_values: PASS")


def test_near_miss_enum_typo_suggests() raises:
    """A near-miss typo of a full value name still gets a did-you-mean."""
    var bad = String('kind: APP_KIND_APK\nname: "svc"\n')
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String(
            "line 1, col 7: unknown value 'APP_KIND_APK' for enum AppKind — did"
            " you mean 'APP_KIND_API'?"
        ),
        "near-miss enum golden",
    )
    print("  test_near_miss_enum_typo_suggests: PASS")


def test_unterminated_string_reports_start() raises:
    """An unterminated string literal reports the position of its OPENING quote."""
    var bad = String('kind: APP_KIND_API\nname: "oops\n')
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String("line 2, col 7: unterminated string literal"),
        "unterminated-string golden",
    )
    print("  test_unterminated_string_reports_start: PASS")


def test_oneof_conflict_is_precise() raises:
    """Setting two arms of one oneof errors at the SECOND arm with a clear
    exactly-one-arm message."""
    var bad = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        "  image {\n"
        '    digest: "sha256:x"\n'
        '    from_build: "service"\n'
        "  }\n"
        "}\n"
    )
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String(
            "line 6, col 5: field 'from_build' conflicts with 'digest' —"
            " ImageRef.source is a oneof (set exactly one arm)"
        ),
        "oneof-conflict golden",
    )
    print("  test_oneof_conflict_is_precise: PASS")


def test_dangling_from_build_is_a_semantic_error() raises:
    """A `from_build` that names no BuildTarget is caught by the semantic pass
    (not the parse) with a did-you-mean over the known build names."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        "spec {\n"
        '  image { from_build: "servic" }\n'
        "  port: 8080\n"
        "}\n"
        'waves { env: "dev" }\n'
    )
    var bundle = parse_bundle(text)  # parses fine — the ref is structurally valid
    var errs = validate_bundle(bundle)
    assert_equal(len(errs), 1, "exactly one semantic error")
    assert_equal(
        errs[0],
        String(
            "spec.image.from_build 'servic' does not name a build target — did"
            " you mean 'service'?"
        ),
        "dangling-from_build golden",
    )
    print("  test_dangling_from_build_is_a_semantic_error: PASS")


def test_expected_integer_error() raises:
    """A quoted string where an integer is required is a precise type error."""
    var bad = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        '  port: "eighty"\n'
        "}\n"
    )
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String("line 4, col 9: field 'port' expects an integer, found string"),
        "expected-integer golden",
    )
    print("  test_expected_integer_error: PASS")


def test_keep_last_n_zero_is_rejected() raises:
    """`keep_last_n: 0` is rejected at authoring with a precise, position-carrying
    error. 0 is the intuitive spelling for "unlimited / disable pruning", but
    `select_revisions_to_prune` treats keep_last_n <= 0 as keep=0 — i.e. DELETE
    every non-serving revision — so an unguarded 0 would mass-prune all rollback
    history on the next deploy. A parser without the lower bound accepts it
    silently, so `_parse_error` returns "" and this golden assertion fails."""
    var bad = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        "  keep_last_n: 0\n"
        "}\n"
    )
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String(
            "line 4, col 3: field 'keep_last_n' must be >= 1 (the count of"
            " NEWEST revisions to KEEP); got 0. Omit the field to use the"
            " default retention; 0 is NOT an unlimited/keep-all sentinel — it"
            " would prune every non-serving revision."
        ),
        "keep_last_n-zero golden",
    )
    print("  test_keep_last_n_zero_is_rejected: PASS")


def test_keep_last_n_negative_is_rejected() raises:
    """A negative `keep_last_n` is likewise rejected (the same >= 1 guard). Proves
    the lower bound is `< 1`, not merely `== 0`."""
    var bad = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        "  keep_last_n: -3\n"
        "}\n"
    )
    var msg = _parse_error(bad)
    assert_equal(
        msg,
        String(
            "line 4, col 3: field 'keep_last_n' must be >= 1 (the count of"
            " NEWEST revisions to KEEP); got -3. Omit the field to use the"
            " default retention; 0 is NOT an unlimited/keep-all sentinel — it"
            " would prune every non-serving revision."
        ),
        "keep_last_n-negative golden",
    )
    print("  test_keep_last_n_negative_is_rejected: PASS")


# =============================================================================
# ⛔⛔ `compute: COMPUTE_INTENT_SERVERFUL` IS REFUSED BY NAME.
#
# THE DEFECT THIS PINS: a declared value that does nothing. The proto declares
# it, but the deploy's GCP `DeploymentSpec` construction builds
# `COMPUTE_INTENT_SERVERLESS` and never reads the authored field. So accepting it
# gives: author it -> GREEN deploy -> receive SERVERLESS. A wrong answer that has
# crossed the customer boundary cannot be walked back by reading the code.
#
# A parser that RETURNS a bundle for this input makes `_parse_error` yield "" and
# the golden below red on its first assertion.
# =============================================================================
def test_serverful_compute_intent_is_refused_by_name() raises:
    var bad = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        '  image { from_build: "service" }\n'
        "  compute: COMPUTE_INTENT_SERVERFUL\n"
        "}\n"
    )
    var msg = _parse_error(bad)
    assert_true(
        msg != String(""),
        "authoring COMPUTE_INTENT_SERVERFUL must RAISE — accepting it returns a"
        " bundle that deploys as SERVERLESS under the name SERVERFUL",
    )
    assert_equal(
        msg,
        String(
            "line 5, col 3: compute: COMPUTE_INTENT_SERVERFUL is NOT SUPPORTED."
            " This bundle would deploy as COMPUTE_INTENT_SERVERLESS regardless"
            " — the authored value is not read by any mapper, and both GCP"
            " DeploymentSpec sites set SERVERLESS unconditionally — so accepting"
            " it would hand back a different deployment from the one written."
            " SUPPORTED: COMPUTE_INTENT_SERVERLESS (Cloud Run on GCP, Lambda on"
            " AWS) and COMPUTE_INTENT_UNSPECIFIED (which the mapper defaults to"
            " serverless). NOT SUPPORTED: COMPUTE_INTENT_SERVERFUL — the"
            " always-on VM / ECS / K8s-Deployment realization it names has no"
            " conformer in this tree. Write COMPUTE_INTENT_SERVERLESS, or omit"
            " `compute` entirely."
        ),
        "serverful-refusal golden — it must NAME the value, say what IS"
        " supported, and say what to write instead; a bare 'unsupported' leaves"
        " the author with nothing to do",
    )
    print("  test_serverful_compute_intent_is_refused_by_name: PASS")


# =============================================================================
# ⛔ THE CONTROL ROWS — the refusal is about ONE VALUE, not about the field.
#
# Without these, the refusal above is equally satisfied by a parser that rejects
# `compute:` outright, or by one that rejects every ComputeIntent — either of
# which would break every serverless bundle while this golden stayed green.
# =============================================================================
def test_serverless_and_unspecified_compute_still_parse() raises:
    var ok_serverless = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        '  image { from_build: "service" }\n'
        "  compute: COMPUTE_INTENT_SERVERLESS\n"
        "}\n"
    )
    assert_equal(
        _parse_error(ok_serverless),
        String(""),
        "COMPUTE_INTENT_SERVERLESS must still parse — it is what a serverless"
        " bundle authors",
    )
    var ok_unspecified = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        "spec {\n"
        '  image { from_build: "service" }\n'
        "  compute: COMPUTE_INTENT_UNSPECIFIED\n"
        "}\n"
    )
    assert_equal(
        _parse_error(ok_unspecified),
        String(""),
        "COMPUTE_INTENT_UNSPECIFIED must still parse (the mapper defaults it)",
    )
    print("  test_serverless_and_unspecified_compute_still_parse: PASS")


# =============================================================================
# ⛔ AND THE VOCABULARY ROW — SERVERFUL must stay a KNOWN value.
#
# The obvious "fix" is to delete it from `compute_values()`. That would make the
# tokenizer report it as an UNKNOWN enum value, which is a LIE: it is a declared
# value of a proto this repo ships, and the author would be told to check their
# spelling instead of that the feature does not exist. This is the same rule
# `cloud_variant_cloud_values` states for `CLOUD_UNSPECIFIED`.
# =============================================================================
def test_serverful_is_still_a_KNOWN_value_not_an_unknown_one() raises:
    var msg = _parse_error(
        String(
            "kind: APP_KIND_API\n"
            'name: "svc"\n'
            "spec {\n"
            "  compute: COMPUTE_INTENT_SERVERFUL\n"
            "}\n"
        )
    )
    # ⚠ THE UNKNOWN-VALUE ASSERT COMES FIRST, AND THAT ORDER IS THE POINT. Both
    # ways of getting this wrong produce a message with no "NOT SUPPORTED" in
    # it, so leading with that assert makes BOTH mutants red on the SAME line
    # and the diagnosis is lost. Leading with the UNKNOWN-value assert splits
    # them: dropping the value from `compute_values()` reds HERE, deleting the
    # refusal reds BELOW.
    assert_true(
        msg.find(String("unknown value")) < 0,
        "COMPUTE_INTENT_SERVERFUL must NOT be reported as an UNKNOWN enum value"
        " — it is a declared value of a proto this repo ships and documents."
        " Deleting it from `compute_values()` is the tempting fix and it tells"
        " the author to check their spelling, sending them to look for a typo"
        " that is not there instead of learning the feature does not exist",
    )
    assert_true(
        msg.find(String("NOT SUPPORTED")) >= 0,
        "the refusal must say the value is UNSUPPORTED",
    )
    print("  test_serverful_is_still_a_KNOWN_value_not_an_unknown_one: PASS")


def main() raises:
    test_unknown_field_suggests_nearest()
    test_unknown_enum_lists_legal_values()
    test_near_miss_enum_typo_suggests()
    test_unterminated_string_reports_start()
    test_oneof_conflict_is_precise()
    test_dangling_from_build_is_a_semantic_error()
    test_expected_integer_error()
    test_keep_last_n_zero_is_rejected()
    test_keep_last_n_negative_is_rejected()
    # ⚠ ORDER IS DELIBERATE. The KNOWN-value row runs FIRST so that the two
    # ways this refusal can be got wrong red at their OWN assertions rather
    # than at the golden, which subsumes both and would attribute every mutant
    # to one line: deleting the refusal reds its NOT-SUPPORTED assert, and the
    # tempting "just drop it from compute_values()" fix reds its UNKNOWN-value
    # assert. The golden then pins the exact text.
    test_serverful_is_still_a_KNOWN_value_not_an_unknown_one()
    test_serverful_compute_intent_is_refused_by_name()
    test_serverless_and_unspecified_compute_still_parse()
    print("PASS test_parse_errors")
