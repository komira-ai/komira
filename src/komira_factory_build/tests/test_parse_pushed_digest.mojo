# =============================================================================
# komira_factory_build/tests/test_parse_pushed_digest.mojo — the digest-only
#   view of the build-output marker parser.
# =============================================================================
#
# `parse_pushed_digest` extracts the pushed by-digest ref (the value the BUILD
# stage records as the run's digest) from a push command's stdout; None when no
# marker line is present; the LAST marker line wins.
#
# Pure value transformation, NO cloud, NO container.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_factory_build import parse_pushed_digest


def test_parse_pushed_digest() raises:
    var repo = String("us-central1-docker.pkg.dev/example-project/example-apps")
    var hexa = String("aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00ee11ff22aa33bb44cc55dd66")
    var hexb = String("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
    var expected = repo + String("/app@sha256:") + hexa
    var output = (
        String("==> [3/3] crane push -> ") + repo + String("/app:abc123\n")
        + String("\n")
        + String("PUSHED_IMAGE_REF=") + repo + String("/app:abc123\n")
        + String("PUSHED_IMAGE_DIGEST=") + expected + String("\n")
    )
    var parsed = parse_pushed_digest(output)
    assert_true(Bool(parsed), "the pushed digest is parsed from the push output")
    assert_equal(
        parsed.value(),
        expected,
        "the parsed digest is the exact by-digest ref the push emitted",
    )

    # a push that emitted NO digest (a failed / not-yet-pushed run) => None.
    var no_digest = parse_pushed_digest(
        String("==> crane push failed\nFATAL: crane digest returned empty\n")
    )
    assert_false(
        Bool(no_digest), "no PUSHED_IMAGE_DIGEST line => None (nothing to record)"
    )

    # LAST match wins (a summary re-echo resolves to the final value).
    var multi = (
        String("PUSHED_IMAGE_DIGEST=") + repo + String("/app@sha256:") + hexb + String("\n")
        + String("PUSHED_IMAGE_DIGEST=") + expected + String("\n")
    )
    assert_equal(
        parse_pushed_digest(multi).value(),
        expected,
        "the LAST PUSHED_IMAGE_DIGEST line wins",
    )


def main() raises:
    test_parse_pushed_digest()
    print("PASS test_parse_pushed_digest")
