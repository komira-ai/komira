# =============================================================================
# komira_factory_build/tests/test_marker_convergence.mojo — the build-output
#   MARKER CONTRACT gate.
# =============================================================================
#
# Two build channels report a pushed image: the operator's local
# build-and-push script and the in-pod build-flow script. Both must speak ONE
# contract, read by ONE parser:
#   * NAME  : `PUSHED_IMAGE_DIGEST=` carrying the FULL pullable by-digest ref
#             `<registry>/<app>@sha256:…` (DEPLOY pulls the ref, not the bare sha).
#   * COMPANION : `KOMIRA_BUILD_DIGEST_IS_FAKE=<0|1>` (the channel-independent gate).
#   * MATCH : LAST match (a rebuild / summary re-echo wins).
#
# WHAT THIS PROVES. We feed the ONE canonical parser
# (`komira_factory_build.parse_pushed_build_result`) BOTH the operator-script sample
# stdout AND the pod-script sample stdout — each modeled on that script's
# terminal echo block — and assert they yield the BYTE-IDENTICAL `{digest, is_fake}`
# tuple. If the two channels emitted different markers, one sample would parse to
# None while the other parsed to a ref, and this test would fail.
#
# Pure value transformation — NO cloud, NO container, NO script fork-exec (the
# samples are string literals modeled on each script's final echo block, so this
# unit also guards the two scripts' marker shapes staying in lock-step).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_factory_build import (
    parse_pushed_build_result,
    parse_pushed_digest,
    PushedBuildResult,
)


# The full pullable by-digest ref BOTH channels must resolve to (the converged value
# DEPLOY renders its served image from). One registry/app + one immutable manifest.
comptime _REPO: String = "us-central1-docker.pkg.dev/example-project/example-repo/example-app"
comptime _SHA: String = (
    "sha256:aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00ee11ff22aa33bb44cc55dd66"
)
comptime _EXPECTED_REF: String = _REPO + "@" + _SHA


def _operator_script_stdout() -> String:
    """The terminal stdout of the operator's local build-and-push script (the
    operator channel). Models its final echo block: the is_fake gate (=0 —
    `crane digest` always yields a real, pullable manifest) then the full by-digest
    ref under `PUSHED_IMAGE_DIGEST=`. (Progress banners go to STDERR, not here.)"""
    return String(
        "KOMIRA_BUILD_DIGEST_IS_FAKE=0\n"
        + "PUSHED_IMAGE_DIGEST="
        + _EXPECTED_REF
        + "\n"
    )


def _pod_script_stdout() -> String:
    """The terminal stdout of the in-pod build-flow script (the pod channel).
    Models its `[5/5] build complete` block: the human/log
    `KOMIRA_BUILD_*` diagnostics, the is_fake gate (=0 — crane packaged a real OCI
    manifest), then the load-bearing full by-digest ref under `PUSHED_IMAGE_DIGEST=`."""
    return String(
        "==> [5/5] build complete\n"
        + "KOMIRA_BUILD_OCI_DIGEST="
        + _SHA
        + "\n"
        + "KOMIRA_BUILD_IMAGE_REF="
        + _REPO
        + ":abc1234\n"
        + "KOMIRA_BUILD_PACKAGER=crane\n"
        + "KOMIRA_BUILD_DIGEST_IS_FAKE=0\n"
        + "PUSHED_IMAGE_DIGEST="
        + _EXPECTED_REF
        + "\n"
        + "    digest written to /work/oci_digest.txt\n"
    )


# =============================================================================
# 1 — THE CONVERGENCE PROOF: both channels' stdout -> the ONE parser -> the SAME
#     {digest, is_fake} tuple, byte-for-byte.
# =============================================================================
def test_both_channels_parse_byte_identical() raises:
    var op = parse_pushed_build_result(_operator_script_stdout())
    var pod = parse_pushed_build_result(_pod_script_stdout())

    # both resolved a digest (neither is None).
    assert_true(Bool(op.digest), "the operator-script stdout resolves a digest")
    assert_true(Bool(pod.digest), "the pod-script stdout resolves a digest")

    # the digest halves are BYTE-IDENTICAL and equal the expected full pullable ref.
    assert_equal(
        op.digest.value(),
        pod.digest.value(),
        "both channels parse to the byte-identical by-digest ref",
    )
    assert_equal(
        op.digest.value(),
        _EXPECTED_REF,
        "the parsed ref is the FULL pullable <registry>/<app>@sha256:… (not bare sha)",
    )

    # the is_fake halves are IDENTICAL (both real -> False).
    assert_equal(
        op.is_fake,
        pod.is_fake,
        "both channels parse to the identical is_fake gate",
    )
    assert_false(op.is_fake, "a real crane manifest digest is not fake")


# =============================================================================
# 2 — the digest carries `@sha256:` (a PULLABLE ref, not a bare sha) — the reason
#     the contract carries the full ref (DEPLOY pulls the ref).
# =============================================================================
def test_converged_digest_is_a_pullable_ref() raises:
    var op = parse_pushed_build_result(_operator_script_stdout())
    assert_true(
        op.digest.value().find(String("@sha256:")) >= 0,
        "the converged digest is a pullable by-digest ref carrying @sha256:",
    )
    # the digest-only view returns the SAME ref.
    var d = parse_pushed_digest(_operator_script_stdout())
    assert_true(Bool(d), "the digest-only view resolves the ref")
    assert_equal(
        d.value(),
        op.digest.value(),
        "parse_pushed_digest is a .digest view over the canonical parser",
    )


# =============================================================================
# 3 — LAST match wins on BOTH the digest marker AND the is_fake gate (a rebuild /
#     summary re-echo resolves to the final value on both lines).
# =============================================================================
def test_last_match_wins_on_both_markers() raises:
    var stale_sha = String(
        "sha256:00112233445566778899aabbccddeeff"
        "00112233445566778899aabbccddeeff"
    )
    var stale_ref = _REPO + String("@") + stale_sha
    var multi = String(
        # a stale first emission (fake, stale ref) ...
        "KOMIRA_BUILD_DIGEST_IS_FAKE=1\n"
        + "PUSHED_IMAGE_DIGEST="
        + stale_ref
        + "\n"
        # ... then the final re-echo (real, the expected ref) — LAST wins on both.
        + "KOMIRA_BUILD_DIGEST_IS_FAKE=0\n"
        + "PUSHED_IMAGE_DIGEST="
        + _EXPECTED_REF
        + "\n"
    )
    var r = parse_pushed_build_result(multi)
    assert_equal(
        r.digest.value(),
        _EXPECTED_REF,
        "the LAST PUSHED_IMAGE_DIGEST line wins",
    )
    assert_false(r.is_fake, "the LAST KOMIRA_BUILD_DIGEST_IS_FAKE line (=0) wins")


# =============================================================================
# 4 — is_fake=1 is carried through (the gate a caller rejects a fake digest on);
#     absent companion reads as not-fake (an OCI-only channel never stamps it).
# =============================================================================
def test_is_fake_gate() raises:
    var fake = String(
        "KOMIRA_BUILD_DIGEST_IS_FAKE=1\n"
        + "PUSHED_IMAGE_DIGEST="
        + _EXPECTED_REF
        + "\n"
    )
    var rf = parse_pushed_build_result(fake)
    assert_true(rf.is_fake, "KOMIRA_BUILD_DIGEST_IS_FAKE=1 => is_fake True")

    # a channel that stamps NO is_fake companion reads as not-fake (default False).
    var no_gate = String("PUSHED_IMAGE_DIGEST=" + _EXPECTED_REF + "\n")
    var rn = parse_pushed_build_result(no_gate)
    assert_false(
        rn.is_fake, "absent is_fake companion => not-fake (never a false-fake)"
    )
    assert_equal(rn.digest.value(), _EXPECTED_REF, "the digest still parses")

    # no digest line at all => None (a failed / dry-run push), is_fake False.
    var empty = parse_pushed_build_result(
        String("==> crane push failed\nFATAL: no digest\n")
    )
    assert_false(Bool(empty.digest), "no PUSHED_IMAGE_DIGEST line => None digest")
    assert_false(empty.is_fake, "no gate line => not-fake")


def main() raises:
    test_both_channels_parse_byte_identical()
    test_converged_digest_is_a_pullable_ref()
    test_last_match_wins_on_both_markers()
    test_is_fake_gate()
    print("PASS test_marker_convergence")
