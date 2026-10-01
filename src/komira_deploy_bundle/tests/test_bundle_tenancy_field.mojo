# =============================================================================
# test_bundle_tenancy_field — `AppBundle.tenancy` IS A STORED FIELD, NOT A TOKEN
#   THE PARSER LOOKS AT AND THROWS AWAY.
# =============================================================================
#
# The deploy target is the customer's own account, so whose account a workload
# runs in is a first-class fact of the bundle.
#
# ── WHAT THIS EXISTS TO FALSIFY ─────────────────────────────────────────────
# A parser that VALIDATES the `tenancy:` token against the closed `Tenancy` set
# and then DISCARDS it. Two consequences:
#
#  (1) NOTHING DOWNSTREAM OF THE PARSE COULD BRANCH ON IT. The composer, the
#      validator and the applier all read an `AppBundle`, and without the field a
#      managed app is indistinguishable from a control-plane service.
#
#  (2) THE CANONICAL SERIALIZATION WOULD BE LOSSY. `emit_bundle` is the declared
#      round-trip partner of `parse_bundle`; `test_emit_completeness` derives the
#      legal field set from the PARSER at run time and fails if its fixture does
#      not author `tenancy`.
#
#      ⚠ NOT A PATCH HAZARD, though the shape invites the claim: the patch verb
#      is the comment-preserving BYTE splicer (`patch.mojo`) and never
#      round-trips a document through the emitter.
#
#      ⚠ AN EMIT-TO-EMIT ROUND TRIP CANNOT SEE IT: `emit(parse(x)) ==
#      emit(parse(emit(parse(x))))` holds for a field dropped on BOTH sides. Only
#      a comparison of the emitted form against the AUTHORED TEXT catches a
#      uniformly-dropped field.
#
# Pure parse + emit. No cloud, no network, no credentials. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_rpc_bundle.app_bundle import AppBundle, Tenancy
from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.emit import emit_bundle


# =============================================================================
#  (1) THE FIELD EXISTS, AND IT CARRIES WHAT THE DOCUMENT SAID
# =============================================================================
def test_parse_stores_every_concrete_tenancy() raises:
    """Each member of the closed `Tenancy` set survives the parse as itself.

    The falsifier for the old behaviour in its purest form: before field 15 this
    could not even be written, because there was nothing on `AppBundle` to read.
    """
    var head = String('kind: APP_KIND_API\nname: "t"\n')

    var cp = parse_bundle(
        String('kind: APP_KIND_API\ntenancy: TENANCY_CONTROL_PLANE\nname: "t"\n')
    )
    assert_equal(
        cp.tenancy.value,
        Tenancy.TENANCY_CONTROL_PLANE,
        "an authored TENANCY_CONTROL_PLANE must reach the struct",
    )

    var cust = parse_bundle(
        String('kind: APP_KIND_API\ntenancy: TENANCY_CUSTOMER\nname: "t"\n')
    )
    assert_equal(
        cust.tenancy.value,
        Tenancy.TENANCY_CUSTOMER,
        "an authored TENANCY_CUSTOMER must reach the struct — this is the value"
        " the deploy path has to branch on, and dropping it is what made"
        " publish-instead-of-deploy unimplementable",
    )

    # ⛔ ABSENT IS UNSPECIFIED, AND UNSPECIFIED IS NOT A SYNONYM FOR ANYTHING.
    # The `Tenancy` enum deliberately has no default: guessing "not control
    # plane" is how a managed app reaches Komira's account, and guessing the
    # other way breaks every correctly-placed app. So the parser infers nothing
    # from `kind`, from the name, or from the envs the waves name.
    var none_authored = parse_bundle(head)
    assert_equal(
        none_authored.tenancy.value,
        Tenancy.TENANCY_UNSPECIFIED,
        "a bundle authoring no tenancy must read UNSPECIFIED, never an inferred"
        " value",
    )
    print("  test_parse_stores_every_concrete_tenancy: PASS (3 values)")


def test_unknown_tenancy_token_is_still_a_positioned_error() raises:
    """Storing the value did not cost the closed-set check.

    `tenancy: TENANCY_CUSTMER` must remain a parse ERROR rather than landing on
    the zero ordinal — a typo that silently becomes UNSPECIFIED is a managed app
    with no declared trust boundary and a green parse.
    """
    var raised = False
    try:
        _ = parse_bundle(
            String('kind: APP_KIND_API\ntenancy: TENANCY_CUSTMER\nname: "t"\n')
        )
    except e:
        raised = True
        assert_true(
            String("Tenancy") in String(e),
            String(
                "the diagnostic must name the enum it checked against; got: "
            )
            + String(e),
        )
    assert_true(
        raised,
        "a misspelled tenancy token must RAISE, not resolve to UNSPECIFIED",
    )
    print("  test_unknown_tenancy_token_is_still_a_positioned_error: PASS")


# =============================================================================
#  (2) THE EMITTER DOES NOT DELETE IT — AND EMITS NOTHING WHEN THERE IS NONE
# =============================================================================
def test_emit_is_default_skip_for_an_unauthored_tenancy() raises:
    """A bundle that authors no tenancy emits no `tenancy:` line.

    The additive-safety half: field 15 must not put a new line into the emitted
    form of a document that never mentioned it. Stated over a synthetic bundle.
    """
    var emitted = emit_bundle(
        parse_bundle(String('kind: APP_KIND_API\nname: "t"\n'))
    )
    assert_false(
        String("tenancy:") in emitted,
        String(
            "emit_bundle wrote a `tenancy:` line for a bundle that authors"
            " none — a default-skip written the wrong way round, which changes"
            " the emitted form of every pre-tenancy document. Got:\n"
        )
        + emitted,
    )
    print("  test_emit_is_default_skip_for_an_unauthored_tenancy: PASS")


def test_tenancy_survives_a_parse_emit_parse_cycle() raises:
    """`parse(emit(parse(x))).tenancy == parse(x).tenancy`.

    A writer that puts `emit_bundle(parse_bundle(src))` back over the authored
    file deletes any value that does not survive this cycle.
    """
    var src = String(
        'kind: APP_KIND_API\ntenancy: TENANCY_CUSTOMER\nname: "t"\n'
    )
    var once = emit_bundle(parse_bundle(src))
    assert_true(
        String("tenancy: TENANCY_CUSTOMER") in once,
        String("emit dropped an authored tenancy. Emitted:\n") + once,
    )
    assert_equal(
        parse_bundle(once).tenancy.value,
        Tenancy.TENANCY_CUSTOMER,
        "a re-parsed emitted bundle must carry the same tenancy",
    )
    print("  test_tenancy_survives_a_parse_emit_parse_cycle: PASS")


def main() raises:
    print("=== test_bundle_tenancy_field ===")
    test_parse_stores_every_concrete_tenancy()
    test_unknown_tenancy_token_is_still_a_positioned_error()
    test_emit_is_default_skip_for_an_unauthored_tenancy()
    test_tenancy_survives_a_parse_emit_parse_cycle()
    print("ALL PASS")
