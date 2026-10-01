# =============================================================================
# test_service_registry_cloud_scope — THE CLOUD SEGMENT, ENFORCED.
#
# A regional service name carries its cloud: `worker-us-central1` is
# ambiguous, `worker-gcp-us-central1` is not, because the same region token can
# exist on more than one provider (AWS, Azure and Kubernetes regions are named
# by their own catalogues). A generator that emits `<name>-<region>` produces a
# whole bucket of keys that carry no cloud at all.
#
# ★ WHAT THIS FILE IS FOR. The convention is only worth stating if it is
# ENFORCED. This file is the falsifier for four properties, each asserted over
# the SHIPPED composer (`regional_service_name`), shape check and decoder —
# never over a fixture that could stay green while the composed name was wrong:
#
#   1. COMPOSITION carries the cloud: `<name>-<cloud>-<region>`.
#   2. ★ THE REJECTION (the point of the file): a regional name with NO cloud
#      segment is REFUSED — both by `validate_regional_service_name` (the shape
#      check) and at the composer, which cannot be handed CLOUD_UNSPECIFIED and
#      produce a name anyway.
#   3. The cloud is a real DISCRIMINATOR: the same `us-central1` token on two
#      clouds composes two DIFFERENT names and two independently-resolvable
#      services.
#   4. The REGIONLESS posture still degrades to the bare name — a missing REGION
#      is legitimate, a missing CLOUD on a regional name is not.
#
# ⚠ PROPERTY 2 IS THE ONE THAT CANNOT BE WEAKENED. A cloud-less name is
# invisible until a second cloud collides with it, at which point it silently
# resolves the wrong provider's service. There is deliberately NO fallback
# segment: an empty one regenerates the banned shape, and a placeholder writes a
# key no reader ever composes.
#
# Hermetic: `SharedInMemoryConditionalStore`, no live bucket, no FFI, no
# resource files.
# =============================================================================

from komira_svcref.service_registry import (
    ServiceRegistry,
    regional_service_name,
    regional_service_name_region,
    cloud_segment,
    validate_regional_service_name,
    CLOUD_UNSPECIFIED,
    CLOUD_GCP,
    CLOUD_AWS,
    CLOUD_AZURE,
    CLOUD_KUBERNETES,
    CLOUD_LOCAL,
)

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


def _eq(got: String, want: String, ctx: String) raises:
    if got != want:
        raise Error(ctx + ": expected '" + want + "' but got '" + got + "'")


def _eq_opt(got: Optional[String], want: String, ctx: String) raises:
    if not got:
        raise Error(ctx + ": expected '" + want + "' but got None")
    if got.value() != want:
        raise Error(
            ctx + ": expected '" + want + "' but got '" + got.value() + "'"
        )


def _expect_none(got: Optional[String], ctx: String) raises:
    if got:
        raise Error(ctx + ": expected None but got '" + got.value() + "'")


# -----------------------------------------------------------------------------
# Gate 1 — composition carries the cloud, for every cloud in the closed set.
# -----------------------------------------------------------------------------


def test_composition_carries_the_cloud_segment() raises:
    print("-- test_composition_carries_the_cloud_segment --")
    _eq(
        regional_service_name(
            String("worker"), CLOUD_GCP, String("us-central1")
        ),
        String("worker-gcp-us-central1"),
        "GCP",
    )
    _eq(
        regional_service_name(String("example-api"), CLOUD_AWS, String("us-east-1")),
        String("example-api-aws-us-east-1"),
        "AWS",
    )
    _eq(
        regional_service_name(String("relay"), CLOUD_AZURE, String("eastus2")),
        String("relay-azure-eastus2"),
        "Azure",
    )
    _eq(
        regional_service_name(
            String("worker"), CLOUD_KUBERNETES, String("dc1")
        ),
        String("worker-kubernetes-dc1"),
        "k8s / on-prem",
    )
    _eq(
        regional_service_name(String("relay"), CLOUD_LOCAL, String("laptop")),
        String("relay-local-laptop"),
        "local",
    )
    # The segments are the short cloud aliases an environment declaration uses,
    # so a name maps back to the environment that produced it without a second
    # table.
    _eq(cloud_segment(CLOUD_GCP), String("gcp"), "segment gcp")
    _eq(cloud_segment(CLOUD_AWS), String("aws"), "segment aws")
    _eq(cloud_segment(CLOUD_AZURE), String("azure"), "segment azure")
    _eq(
        cloud_segment(CLOUD_KUBERNETES),
        String("kubernetes"),
        "segment kubernetes",
    )
    _eq(cloud_segment(CLOUD_LOCAL), String("local"), "segment local")
    print("   <name>-<cloud>-<region> for all five clouds OK")


# -----------------------------------------------------------------------------
# Gate 2 — ★ THE REJECTION. A regional name with no cloud segment is REFUSED.
# -----------------------------------------------------------------------------


def test_cloudless_regional_name_is_rejected() raises:
    print("-- test_cloudless_regional_name_is_rejected --")
    # (a) THE SHAPE CHECK. `worker-us-central1` — name, region, no cloud — is
    #     not a well-formed regional service name.
    var rejected = False
    try:
        validate_regional_service_name(
            String("worker-us-central1"),
            String("worker"),
            String("us-central1"),
        )
    except:
        rejected = True
    if not rejected:
        raise Error(
            "★ THE CONVENTION IS NOT ENFORCED: 'worker-us-central1' was"
            " accepted as a regional service name. A bare region segment cannot"
            " disambiguate us-central1 on GCP from us-central1 on AWS/Azure."
        )

    # ...and the same shape for a DIFFERENT service, so the rejection is about
    # the SHAPE and not about the string `worker`.
    var rejected2 = False
    try:
        validate_regional_service_name(
            String("example-api-europe-west1"),
            String("example-api"),
            String("europe-west1"),
        )
    except:
        rejected2 = True
    if not rejected2:
        raise Error("cloud-less 'example-api-europe-west1' was accepted")

    # (b) THE COMPOSER cannot be talked into emitting one. CLOUD_UNSPECIFIED is
    #     the proto3 zero — i.e. exactly what an unresolved / defaulted binding
    #     carries — and it RAISES rather than degrading to `<name>-<region>`.
    var raised = False
    try:
        _ = regional_service_name(
            String("worker"), CLOUD_UNSPECIFIED, String("us-central1")
        )
    except:
        raised = True
    if not raised:
        raise Error(
            "regional_service_name accepted CLOUD_UNSPECIFIED for a REGIONAL name —"
            " an unresolved binding must fail loudly, never compose a cloud-less"
            " key"
        )

    # An out-of-range ordinal is refused for the same reason (no `unknown`
    # placeholder segment: it would put a key in the bucket nobody composes).
    var raised2 = False
    try:
        _ = regional_service_name(String("worker"), 99, String("us-central1"))
    except:
        raised2 = True
    if not raised2:
        raise Error("regional_service_name accepted an unknown cloud ordinal")

    # (c) ⛔ THERE IS NO WRITER ARM, AND THAT IS THE POINT. The registry key IS
    #     the service name, so there is no composition at the write door to
    #     refuse. The shape is guarded where the name is AUTHORED: the deploy
    #     tool's bundle gate asserts a region-qualified BUNDLE name is
    #     well-formed and agrees with the region that bundle deploys into.

    # And the well-formed name is ACCEPTED — a check that rejects everything
    # proves nothing.
    validate_regional_service_name(
        String("worker-gcp-us-central1"),
        String("worker"),
        String("us-central1"),
    )
    print("   cloud-less regional names rejected at shape and composer OK")


# -----------------------------------------------------------------------------
# Gate 3 — the cloud is a real DISCRIMINATOR.
# -----------------------------------------------------------------------------


def test_same_region_token_on_two_clouds_does_not_collide() raises:
    print("-- test_same_region_token_on_two_clouds_does_not_collide --")
    # `us-central1` is a GCP region name. AWS/Azure region tokens are drawn from
    # their own namespaces, but NOTHING stops an operator's on-prem/k8s catalogue
    # from reusing a token — and `CLOUD_KUBERNETES` region names are whatever the
    # operator says they are.
    #
    # ★ THE SEGMENT DISAMBIGUATES A **NAME**, NOT A KEY. Composing
    # `<name>-<cloud>-<region>` as a registry KEY on top of a bare service name
    # is how a key comes to exist that is no service's name. The registry key
    # IS the service name, so two clouds are two SERVICES with two NAMES — and
    # they cannot collide for the same reason `example-api` and `relay` cannot.
    var gcp = regional_service_name(
        String("worker"), CLOUD_GCP, String("us-central1")
    )
    var k8s = regional_service_name(
        String("worker"), CLOUD_KUBERNETES, String("us-central1")
    )
    _eq(gcp, String("worker-gcp-us-central1"), "the GCP name")
    _eq(k8s, String("worker-kubernetes-us-central1"), "the k8s name")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(gcp, String("https://worker-gcp.run.app"))
    reg.register(k8s, String("https://worker-k8s.internal"))
    _eq_opt(
        reg.resolve(gcp),
        String("https://worker-gcp.run.app"),
        "★ THE COLLISION THE SEGMENT REMOVES: GCP us-central1 after k8s"
        " us-central1 deployed",
    )
    _eq_opt(
        reg.resolve(k8s),
        String("https://worker-k8s.internal"),
        "k8s us-central1",
    )
    # ...and the cloud-LESS name is never written by anything.
    _expect_none(
        reg.resolve(String("worker-us-central1")),
        "no cloud-less name is produced by the composer",
    )
    # THE INVERSE agrees with the composer on both, and refuses the cloud-less
    # shape — the decode a permission grant binds a REGION on.
    _eq(
        regional_service_name_region(gcp), String("us-central1"), "gcp inverse"
    )
    _eq(
        regional_service_name_region(k8s), String("us-central1"), "k8s inverse"
    )
    _eq(
        regional_service_name_region(String("worker-us-central1")),
        String(""),
        "the cloud-less shape decodes to NOTHING — reading a region out of it is"
        " how `us` or `central1` becomes a region",
    )
    print("   one region token, two clouds, two independent services OK")


# -----------------------------------------------------------------------------
# Gate 4 — a MISSING REGION still degrades; the asymmetry is deliberate.
# -----------------------------------------------------------------------------


def test_regionless_posture_still_degrades_to_the_bare_name() raises:
    print("-- test_regionless_posture_still_degrades_to_the_bare_name --")
    # A deploy with no environment region carries an EMPTY region. That is a
    # legitimate posture (the caller genuinely has no region), so it degrades
    # to the bare name — and it does so even under CLOUD_UNSPECIFIED, because
    # with no region there is no regional name to qualify.
    _eq(
        regional_service_name(String("example-push"), CLOUD_UNSPECIFIED, String("")),
        String("example-push"),
        "regionless + unresolved cloud -> bare name, no raise",
    )
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("example-push"), String("https://push.run.app"))
    if len(reg.list()) != 1:
        raise Error(
            "a register must write EXACTLY one key — its name, got "
            + String(len(reg.list()))
        )
    _eq_opt(
        reg.resolve(String("example-push")),
        String("https://push.run.app"),
        "the bare key",
    )
    print("   missing REGION degrades; missing CLOUD on a regional name does not OK")


def main() raises:
    print("== the cloud segment in a SERVICE NAME ==")
    test_composition_carries_the_cloud_segment()
    test_cloudless_regional_name_is_rejected()
    test_same_region_token_on_two_clouds_does_not_collide()
    test_regionless_posture_still_degrades_to_the_bare_name()
    print("== ALL CLOUD-AXIS GATES PASS ==")
