# =============================================================================
# komira_factory_build/tests/test_build_spec_builder.mojo — the BUILD-Job spec
#   builder gate.
# =============================================================================
#
# BuildSpecBuilder renders the FINITE build spec (a served deploy renders an
# INFINITE one). Builds a `PlacementSpec` from fixture build-Job facts + the
# build inputs and asserts the correct build container:
#   * exactly ONE container (factory-build), image = the base Mojo image (config
#     override or default) — NOT a packaged app digest (that is the build OUTPUT).
#   * command = the build-flow (/opt/factory/build_flow.sh).
#   * env carries KOMIRA_SOURCE_REF / SOURCE_COMMIT / ARCHETYPE /
#     TARGET_ENVIRONMENT / APP_ID / REGISTRY_URL / IMAGE_TAG / BUILD_SA_EMAIL +
#     the bucket env.
#   * NO served port (a FINITE build exposes no endpoint — the FALSIFIABLE
#     distinction from an INFINITE serve; served_ports() is empty).
#   * the build sub-identity is stamped, and a config override wins over the arg.
#   * the account_ref (the per-Job token mint anchor) flows from the Job.
#
# Pure value transformation, NO cloud, NO container: the builder is stateless;
# the test drives it directly and asserts the rendered spec's shape.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false


from komira_placement.placement_types import PlacementSpec

from komira_factory_build import (
    BuildSpecBuilder,
    BuildJobFacts,
    BUILD_CONTAINER_NAME,
    BUILD_FLOW_COMMAND,
    ENV_SOURCE_REF,
    ENV_SOURCE_COMMIT,
    ENV_ARCHETYPE,
    ENV_TARGET_ENVIRONMENT,
    ENV_APP_ID,
    ENV_REGISTRY_URL,
    ENV_IMAGE_TAG,
    ENV_BUILD_SA_EMAIL,
    ENV_BUCKET_NAME,
    CFG_BASE_IMAGE,
    CFG_BUILD_SA_EMAIL,
)


comptime _NAMESPACE: String = "example-factory"
comptime _PROJECT: String = "example-customer"
comptime _REGION: String = "us-central1"
comptime _BUILD_SA: String = "factory-build@example-customer.iam.gserviceaccount.com"
comptime _BUCKET: String = "example-customer-bucket"
comptime _POD_NAME: String = "factory-build-abc123"
comptime _BASE_IMAGE_PINNED: String = "example-base-mojo:deadbeef"
comptime _SOURCE_REF: String = "https://git.example.com/apps/etl.git"
comptime _COMMIT: String = "cafef00dcafef00d"
comptime _REGISTRY_URL: String = "us-central1-docker.pkg.dev/example-customer/example-factory"
comptime _IMAGE_TAG: String = "sha-abc123"
comptime _APP_ID: String = "etl-pipeline"
comptime _ACCOUNT_REF: String = "conn-uuid-customer-42"


# =============================================================================
# A fixture BUILD Job carrying the build facts the control plane stamps (the
# source ref + commit + archetype + target env + app id + registry + tag + a
# pinned base image + an account_ref for the per-Job WIF mint).
# =============================================================================
# The caller's default base image (the caller passes its own pinned digest;
# this package does not own one). Registry-qualified and digest-pinned, so the
# assertions below read the same as for a real pin.
comptime _DEFAULT_BASE_IMAGE: String = "registry.example/builders/base-mojo@sha256:0000000000000000000000000000000000000000000000000000000000000000"


def _fixture_build_job() raises -> BuildJobFacts:
    var config = Dict[String, String]()
    config[String("source_ref")] = _SOURCE_REF
    config[String("source_commit")] = _COMMIT
    config[String("archetype")] = String("data_pipeline")
    config[String("target_environment")] = String("preprod")
    config[String("app_id")] = _APP_ID
    config[String("registry_url")] = _REGISTRY_URL
    config[String("image_tag")] = _IMAGE_TAG
    config[String("base_image")] = _BASE_IMAGE_PINNED
    return BuildJobFacts(config^, Optional[String](_ACCOUNT_REF))


def _env_value(spec: PlacementSpec, key: String) -> String:
    """The value of env `key` in the spec's FIRST container (empty if absent)."""
    ref c = spec.containers[0]
    for i in range(len(c.env)):
        if c.env[i].name == key:
            return c.env[i].value
    return String("")


def _env_has(spec: PlacementSpec, key: String) -> Bool:
    ref c = spec.containers[0]
    for i in range(len(c.env)):
        if c.env[i].name == key:
            return True
    return False


# =============================================================================
# Test 1 — the builder renders the FINITE build surface (single container, the
# base Mojo image, the build-flow command, the full env contract).
# =============================================================================
def test_builder_renders_build_surface() raises:
    var job = _fixture_build_job()
    var spec = BuildSpecBuilder.build(
        job,
        _DEFAULT_BASE_IMAGE,
        _POD_NAME,
        _NAMESPACE,
        _PROJECT,
        _REGION,
        _BUILD_SA,
        _BUCKET,
    )

    # exactly one container; the factory-build container.
    assert_equal(
        spec.container_count(), 1, "the build spec has exactly one container"
    )
    assert_equal(spec.name, _POD_NAME, "the spec name = the pod_name (build unit id)")
    assert_equal(spec.namespace, _NAMESPACE, "the spec namespace = the JM ns")
    ref c0 = spec.containers[0]
    assert_equal(
        c0.name, BUILD_CONTAINER_NAME, "the container is the factory-build container"
    )

    # image = the PINNED base Mojo image (config override), NOT a packaged digest.
    assert_equal(
        c0.image,
        _BASE_IMAGE_PINNED,
        "image = the base Mojo image (config[base_image]), not an app digest",
    )

    # command = the build-flow entrypoint.
    assert_equal(len(c0.command), 1, "the container carries the build-flow command")
    assert_equal(
        c0.command[0],
        BUILD_FLOW_COMMAND,
        "command = the build-flow (/opt/factory/build_flow.sh)",
    )

    # the env contract the build-flow reads.
    assert_equal(
        _env_value(spec, ENV_SOURCE_REF),
        _SOURCE_REF,
        "KOMIRA_SOURCE_REF = the source ref (the clone target in the customer env)",
    )
    assert_equal(
        _env_value(spec, ENV_SOURCE_COMMIT), _COMMIT, "KOMIRA_SOURCE_COMMIT = the pinned commit"
    )
    assert_equal(
        _env_value(spec, ENV_ARCHETYPE),
        String("data_pipeline"),
        "KOMIRA_ARCHETYPE = the archetype (selects the build recipe)",
    )
    assert_equal(
        _env_value(spec, ENV_TARGET_ENVIRONMENT),
        String("preprod"),
        "KOMIRA_TARGET_ENVIRONMENT = the promote target",
    )
    assert_equal(_env_value(spec, ENV_APP_ID), _APP_ID, "KOMIRA_APP_ID = the app id")
    assert_equal(
        _env_value(spec, ENV_REGISTRY_URL),
        _REGISTRY_URL,
        "KOMIRA_REGISTRY_URL = the customer registry (the OCI push dest)",
    )
    assert_equal(
        _env_value(spec, ENV_IMAGE_TAG),
        _IMAGE_TAG,
        "KOMIRA_IMAGE_TAG = the sha tag (the single-digest identity)",
    )

    # the bucket env (build artifacts / logs).
    assert_equal(
        _env_value(spec, ENV_BUCKET_NAME),
        _BUCKET,
        "the bucket env carries the build-artifact / logs bucket",
    )


# =============================================================================
# Test 2 — FALSIFIABLE: a FINITE build exposes NO served port.
#   This is the structural distinction between a build (FINITE) and a serve
#   (INFINITE). If BuildSpecBuilder ever leaked a served port (copying the
#   comms-deploy shape), served_ports() would be non-empty and this test FAILS.
# =============================================================================
def test_build_has_no_served_port() raises:
    var job = _fixture_build_job()
    var spec = BuildSpecBuilder.build(
        job, _DEFAULT_BASE_IMAGE, _POD_NAME, _NAMESPACE, _PROJECT, _REGION, _BUILD_SA, _BUCKET
    )
    ref c0 = spec.containers[0]
    assert_equal(
        len(c0.ports), 0, "a FINITE build container exposes NO served port"
    )
    assert_equal(
        len(spec.served_ports()),
        0,
        "served_ports() is empty for a FINITE build (the FINITE-vs-INFINITE distinction)",
    )


# =============================================================================
# Test 3 — the BUILD sub-identity (build ⊥ deploy ⊥ placement) is stamped, and
#   a config override wins over the arg (a per-Job build SA).
# =============================================================================
def test_build_sa_stamped_and_override() raises:
    # (a) no config override => the arg build_sa_email is stamped.
    var job = _fixture_build_job()
    var spec = BuildSpecBuilder.build(
        job, _DEFAULT_BASE_IMAGE, _POD_NAME, _NAMESPACE, _PROJECT, _REGION, _BUILD_SA, _BUCKET
    )
    assert_equal(
        _env_value(spec, ENV_BUILD_SA_EMAIL),
        _BUILD_SA,
        "KOMIRA_BUILD_SA_EMAIL = the build SA arg (the build ⊥ deploy ⊥ placement identity)",
    )

    # (b) a config override wins over the arg (a per-Job build SA).
    var job2 = _fixture_build_job()
    var override_sa = String("per-job-build@customer.iam.gserviceaccount.com")
    job2.config[CFG_BUILD_SA_EMAIL] = override_sa
    var spec2 = BuildSpecBuilder.build(
        job2, _DEFAULT_BASE_IMAGE, _POD_NAME, _NAMESPACE, _PROJECT, _REGION, _BUILD_SA, _BUCKET
    )
    assert_equal(
        _env_value(spec2, ENV_BUILD_SA_EMAIL),
        override_sa,
        "a config[build_sa_email] override wins over the arg",
    )


# =============================================================================
# Test 4 — the account_ref (the per-Job WIF mint anchor) flows from Job.account_ref.
# =============================================================================
def test_account_ref_flows() raises:
    var job = _fixture_build_job()
    var spec = BuildSpecBuilder.build(
        job, _DEFAULT_BASE_IMAGE, _POD_NAME, _NAMESPACE, _PROJECT, _REGION, _BUILD_SA, _BUCKET
    )
    assert_equal(
        spec.account_ref,
        _ACCOUNT_REF,
        "the account_ref (the per-Job WIF mint anchor) flows from Job.account_ref",
    )


# =============================================================================
# Test 5 — the default base image is used when config carries no base_image, and
#   the image is NEVER a packaged app digest (the build's image is its INPUT
#   toolchain, the digest is its OUTPUT).
# =============================================================================
def test_default_base_image_and_never_app_digest() raises:
    var job = _fixture_build_job()
    # strip the base_image override so the default applies.
    _ = job.config.pop(CFG_BASE_IMAGE)
    var spec = BuildSpecBuilder.build(
        job, _DEFAULT_BASE_IMAGE, _POD_NAME, _NAMESPACE, _PROJECT, _REGION, _BUILD_SA, _BUCKET
    )
    ref c0 = spec.containers[0]
    assert_equal(
        c0.image,
        _DEFAULT_BASE_IMAGE,
        "with no config[base_image], the caller's default base Mojo image is used",
    )
    # The image is a base-mojo image, NEVER the (empty) binary_uri or an app digest.
    #
    # `find`, NOT `startswith`: a real base image is registry-qualified and
    # digest-pinned (`<registry>/<path>/base-mojo@sha256:…`), so the image NAME is
    # a path segment rather than a prefix. A bare name with no registry host would
    # not be pullable by a serverless runtime.
    assert_true(
        c0.image.find(String("base-mojo")) >= 0,
        String(
            "the build image must be the base Mojo image (an INPUT toolchain), never"
            " an app digest; got: "
        )
        + c0.image,
    )


def main() raises:
    test_builder_renders_build_surface()
    test_build_has_no_served_port()
    test_build_sa_stamped_and_override()
    test_account_ref_flows()
    test_default_base_image_and_never_app_digest()
    print("PASS test_build_spec_builder")
