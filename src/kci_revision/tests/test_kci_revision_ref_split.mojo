# =============================================================================
# kci_revision/tests/test_kci_revision_ref_split.mojo — THE REF/DIGEST
#   SPLIT GATE: `pullable_ref_of` and `digest_of_image_ref` are two halves of ONE
#   decision, and they may not disagree about which shape they were handed.
# =============================================================================
#
# This file links the one library and co-compiles nothing else, so the split is
# tested on its own, at a seconds-scale compile.
#
# Rule applied throughout (this package's convention): A TEST I CANNOT SEE FAIL IS
# WORTHLESS. Every test below names the concrete MUTANT it goes RED against, and
# the two that matter were run against that mutant and observed RED.
#
# THE FALSIFIERS THAT DEFINE THIS FILE
#
#   (1) test_the_two_halves_agree_on_which_shape_they_were_handed
#       The PAIRING invariant, which is the one property neither function can
#       guard alone and which `pullable_ref_of`'s own docstring ASSERTS: "The `@`
#       test is the same one `digest_of_image_ref` splits on, so the two halves
#       cannot disagree about which shape they were handed." That sentence is a
#       claim about TWO functions, so a test is what makes it more than an
#       inspection. RED against splitting one half on `find` while the other
#       splits on `rfind` — a one-character edit that is invisible for every
#       single-`@` ref and wrong for exactly the multi-`@` value a registry move
#       produces.
#
#       ⚠ "THE TWO HALVES AGREE" IS NOT ENOUGH TO CATCH THAT MUTANT. With
#       `digest_of_image_ref` split on `find`, the two halves still AGREE that
#       the value has a repo, so an invariant stated that way goes GREEN against
#       the mutant it names. "The two halves agree" is strictly weaker than "the
#       two halves split at the same `@`", and only the latter is the property
#       being claimed — which is the whole reason the `dig.find("@") == -1`
#       assertion exists. Both readings were RUN; the mutant is RED only under
#       the stronger one.
#
#   (2) test_a_bare_digest_has_no_pullable_ref
#       A bare `sha256:…` MUST yield "" and not a fabricated ref. RED against
#       `return image_value.copy()` unconditionally — fabricating a repo around a
#       bare digest is the shape that prints the repo twice.
#
# ⚠ WHAT THIS FILE DELIBERATELY DOES NOT TOUCH. `RevisionStore` and the minting
# allocator are covered by `test_kci_revision_store`, which needs an
# object-store conformer. Keeping those out is what lets this target stay a
# narrow, seconds-scale compile.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_revision import digest_of_image_ref, pullable_ref_of


# The shapes a revision record is actually handed, named once so every test below
# is arguing about the same strings.
comptime _FULL_REF: String = (
    "registry.example.com/example-project/apps/shop@sha256:"
    + "aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990000"
)
comptime _BARE_DIGEST: String = (
    "sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990000"
)


def test_a_full_ref_keeps_its_repo_and_yields_its_digest() raises:
    """The `<repo>@sha256:…` shape: the ref half passes through UNCHANGED, and the
    digest half is the part after the `@`.

    RED against a `pullable_ref_of` that returns the digest (the two halves
    swapped) — which type-checks, since both return `String`."""
    assert_equal(
        pullable_ref_of(_FULL_REF),
        _FULL_REF,
        "a full ref is its own pullable ref",
    )
    assert_equal(
        digest_of_image_ref(_FULL_REF),
        _BARE_DIGEST,
        "the digest half is everything after the @",
    )


def test_a_bare_digest_has_no_pullable_ref() raises:
    """FALSIFIER (2). A value with no `@` carries no repo, so there is no pullable
    ref and "" is the honest answer — while the digest half passes it through
    UNCHANGED rather than emptying it.

    RED against `pullable_ref_of` returning `image_value.copy()` unconditionally,
    i.e. fabricating a ref out of a bare digest — the shape that prints the repo
    twice.

    ⚠ The two halves answer DIFFERENTLY here and both are right, which is exactly
    why this shape needs its own test: "" from one and a full pass-through from
    the other is the CONTRACT, not an inconsistency."""
    assert_equal(
        pullable_ref_of(_BARE_DIGEST),
        String(""),
        "a bare digest has no ref form",
    )
    assert_equal(
        digest_of_image_ref(_BARE_DIGEST),
        _BARE_DIGEST,
        "a bare digest is already narrow and passes through",
    )


def test_the_two_halves_agree_on_which_shape_they_were_handed() raises:
    """FALSIFIER (1) — THE PAIRING INVARIANT, the property neither function can
    guard alone.

    For EVERY value: `pullable_ref_of` returns "" if and only if
    `digest_of_image_ref` returned the value unchanged. Restated: the two halves
    split on the same `@`, so "has a repo" means the same thing to both.

    RED against splitting one half on `find` and the other on `rfind`. Both
    functions use `rfind` today, and for a single-`@` ref the two are
    indistinguishable — so this test carries a multi-`@` value, which is the only
    input that can tell them apart and the one a registry-qualified ref
    containing a port or a nested path can actually produce."""
    var cases = List[String]()
    cases.append(_FULL_REF)
    cases.append(_BARE_DIGEST)
    # No `@` and not a digest either — a plain tag-style ref.
    cases.append(String("registry.example.com/example-project/apps/shop:v3"))
    # ⚠ THE DISCRIMINATING CASE: more than one `@`. `find` would split at the
    # FIRST, `rfind` at the LAST, and only here do they differ.
    cases.append(
        String("registry.local/team@group/app@sha256:")
        + String("1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff")
    )
    # Empty: no `@`, so no ref form, and the digest half passes it through.
    cases.append(String(""))

    for i in range(len(cases)):
        var v = cases[i]
        var ref_form = pullable_ref_of(v)
        var dig = digest_of_image_ref(v)
        var ref_says_no_repo = ref_form.byte_length() == 0
        var dig_says_no_repo = dig == v
        assert_equal(
            ref_says_no_repo,
            dig_says_no_repo,
            (
                "the two halves must agree that '"
                + v
                + "' has no repo; ref half said "
                + String(ref_says_no_repo)
                + ", digest half said "
                + String(dig_says_no_repo)
            ),
        )
        # And when there IS a repo, the ref half must hand back the WHOLE value —
        # never a truncated one.
        if not ref_says_no_repo:
            assert_equal(
                ref_form, v, "a value with a repo is its own pullable ref: " + v
            )
            assert_true(
                dig.byte_length() < v.byte_length(),
                "the digest half must be strictly shorter than a full ref: " + v,
            )
            # ⚠⚠ THE ASSERTION THAT ACTUALLY DISCRIMINATES `rfind` FROM `find`,
            # AND THE ONLY REASON THIS TEST IS WORTH MORE THAN ITS DOCSTRING.
            #
            # The three assertions above all PASS against a `digest_of_image_ref`
            # split on `find` — MEASURED, not reasoned: that mutant was applied and
            # this test went GREEN. Agreement on "has a repo" is a strictly weaker
            # property than "both split at the SAME `@`", because a `find`-split
            # digest of a multi-`@` value is still non-empty, still != the input,
            # and still shorter than it.
            #
            # What separates them is that the digest half is by definition the
            # suffix after the LAST separator, so it CANNOT itself contain that
            # separator. `find` on `registry.local/team@group/app@sha256:…` yields
            # `group/app@sha256:…` — an `@` survives, and the value would be stored
            # as a "bare digest" that no registry can resolve.
            assert_equal(
                dig.find(String("@")),
                -1,
                (
                    "the digest half is the suffix after the LAST @, so it cannot"
                    " contain one; got '"
                    + dig
                    + "' from '"
                    + v
                    + "'"
                ),
            )


def main() raises:
    # The pairing invariant first — it is the reason this file exists.
    test_the_two_halves_agree_on_which_shape_they_were_handed()
    test_a_bare_digest_has_no_pullable_ref()
    test_a_full_ref_keeps_its_repo_and_yields_its_digest()
    print("test_kci_revision_ref_split: ALL PASS")
