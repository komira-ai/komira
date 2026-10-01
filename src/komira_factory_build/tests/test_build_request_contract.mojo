# =============================================================================
# komira_factory_build/tests/test_build_request_contract.mojo — the typed
#   `BuildRequest` CONTRACT gate.
# =============================================================================
#
# A build's inputs are spelled on three surfaces (the Job.config `CFG_*` keys,
# the container env `ENV_*` / `KOMIRA_*` keys, and the build-flow script's
# reads). `BuildRequest` is the ONE typed value they all describe.
#
# WHAT THIS PROVES. We build a `BuildRequest` from the full set of fields, render
# it to the container env dict (`to_env_config` — the exact `KOMIRA_*` keys the pod
# reads), and DECODE it back through the pod entrypoint's arg-decode
# (`build_request_from_env`). We then assert EVERY field round-trips typed.
#
# Pure value transformation — NO cloud, NO container, NO process environment: the
# decode is a pure function of an in-memory `Dict[String, String]` modeled on the
# pod's stamped container env (flat String / Optional / Int / Bool / Uuid).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_db import Uuid
from komira_db.db_uuid import from_hyphenated

from komira_factory_build import (
    BuildRequest,
    build_request_from_env,
    render_from_dockerfile,
    OUTPUT_FORMAT_IMAGE,
    ENV_SOURCE_REF,
    ENV_SOURCE_COMMIT,
    ENV_ARCHETYPE,
    ENV_TARGET_ENVIRONMENT,
    ENV_APP_ID,
    ENV_APP_ENTRYPOINT,
    ENV_APP_TEST,
    ENV_REGISTRY_URL,
    ENV_IMAGE_TAG,
    ENV_BUILD_SA_EMAIL,
    ENV_RUNTIME_BASE_IMAGE,
    ENV_BASE_IMAGE,
    ENV_OUTPUT_FORMAT,
    ENV_RUN_ID,
    ENV_BUCKET_NAME,
    ENV_MANAGED_APP_FROM_IMAGE,
)


comptime _SOURCE_REF: String = "https://git.example.com/apps/etl.git"
comptime _COMMIT: String = "cafef00dcafef00dcafef00dcafef00dcafef00d"
comptime _ARCHETYPE: Int32 = 1  # ARCHETYPE_ENDPOINT_SERVICE ordinal
comptime _TARGET_ENV: String = "preprod"
comptime _APP_ID: String = "hello-app"
comptime _ENTRYPOINT: String = "server.py"
comptime _APP_TEST: String = "test_main.mojo"
comptime _REGISTRY: String = "us-central1-docker.pkg.dev/example-project/example-repo/hello-app"
comptime _IMAGE_TAG: String = "sha-abc1234"
comptime _BUILD_SA: String = "factory-build@example-project.iam.gserviceaccount.com"
comptime _RUNTIME_BASE: String = "python:3.12-slim"
comptime _BASE_IMAGE: String = "example-base-mojo:deadbeef"
comptime _RUN_ID_HEX: String = "0192f0aa-1122-7abc-8def-001122334455"
comptime _BUCKET: String = "example-build-artifacts"


def _fixture_request() raises -> BuildRequest:
    """A fully-populated BuildRequest — every field the three key tables carry,
    typed (source_ref, source_commit, archetype, target_environment, app_id,
    app_entrypoint, app_test, registry_url, image_tag, build_sa_email,
    runtime_base_image, base_image, output_format, run_id, bucket_name, dry_run_push)."""
    return BuildRequest(
        _SOURCE_REF,
        Optional[String](_COMMIT),
        _ARCHETYPE,
        _TARGET_ENV,
        _APP_ID,
        _ENTRYPOINT,
        Optional[String](_APP_TEST),
        Optional[String](_REGISTRY),
        _IMAGE_TAG,
        Optional[String](_BUILD_SA),
        _RUNTIME_BASE,
        _BASE_IMAGE,
        OUTPUT_FORMAT_IMAGE,
        from_hyphenated(_RUN_ID_HEX),
        Optional[String](_BUCKET),
        False,  # dry_run_push
        Optional[String](),  # managed_app_from_image (absent — the clone-build path)
    )


# =============================================================================
# Test 1 — a BuildRequest renders to the container env dict + DECODES back with
#   EVERY field present + typed (the round-trip).
# =============================================================================
def test_build_request_round_trips_through_env_decode() raises:
    var req = _fixture_request()

    # render to the container env dict (the exact KOMIRA_* keys the pod reads).
    var env = req.to_env_config()

    # DECODE back through the pod entrypoint's arg decode.
    var decoded = build_request_from_env(env)

    # every field round-trips typed.
    assert_equal(decoded.source_ref, _SOURCE_REF, "source_ref round-trips")
    assert_true(Bool(decoded.source_commit), "source_commit present")
    assert_equal(
        decoded.source_commit.value(), _COMMIT, "source_commit round-trips"
    )
    assert_equal(decoded.archetype, _ARCHETYPE, "archetype round-trips (typed Int32)")
    assert_equal(
        decoded.target_environment, _TARGET_ENV, "target_environment round-trips"
    )
    assert_equal(decoded.app_id, _APP_ID, "app_id round-trips")
    assert_equal(
        decoded.app_entrypoint, _ENTRYPOINT, "app_entrypoint round-trips"
    )
    assert_true(Bool(decoded.app_test), "app_test present")
    assert_equal(decoded.app_test.value(), _APP_TEST, "app_test round-trips")
    assert_true(Bool(decoded.registry_url), "registry_url present")
    assert_equal(
        decoded.registry_url.value(), _REGISTRY, "registry_url round-trips"
    )
    assert_equal(decoded.image_tag, _IMAGE_TAG, "image_tag round-trips")
    assert_true(Bool(decoded.build_sa_email), "build_sa_email present")
    assert_equal(
        decoded.build_sa_email.value(), _BUILD_SA, "build_sa_email round-trips"
    )
    assert_equal(
        decoded.runtime_base_image,
        _RUNTIME_BASE,
        "runtime_base_image round-trips",
    )
    assert_equal(decoded.base_image, _BASE_IMAGE, "base_image round-trips")
    assert_equal(
        decoded.output_format,
        OUTPUT_FORMAT_IMAGE,
        "output_format round-trips (typed Int)",
    )
    # Uuid is not Writable (no assert_equal candidate); compare via its round-trip
    # hyphenated form (the canonical String rendering) + the typed == operator.
    assert_true(
        decoded.run_id == from_hyphenated(_RUN_ID_HEX),
        "run_id round-trips (typed Uuid ==)",
    )
    assert_equal(
        decoded.run_id.to_hyphenated(),
        _RUN_ID_HEX,
        "run_id round-trips to the same hyphenated string",
    )
    assert_true(Bool(decoded.bucket_name), "bucket_name present")
    assert_equal(decoded.bucket_name.value(), _BUCKET, "bucket_name round-trips")
    assert_false(decoded.dry_run_push, "dry_run_push round-trips (False)")


# =============================================================================
# Test 2 — the render carries the exact converged KOMIRA_* env keys (the ONE
#   typed channel renders exactly these env keys — the pod reads THESE).
# =============================================================================
def test_env_config_carries_the_converged_keys() raises:
    var req = _fixture_request()
    var env = req.to_env_config()

    assert_true(env.__contains__(ENV_SOURCE_REF), "KOMIRA_SOURCE_REF stamped")
    assert_equal(env[ENV_SOURCE_REF], _SOURCE_REF, "KOMIRA_SOURCE_REF = source_ref")
    assert_true(
        env.__contains__(ENV_SOURCE_COMMIT), "KOMIRA_SOURCE_COMMIT stamped"
    )
    assert_true(env.__contains__(ENV_ARCHETYPE), "KOMIRA_ARCHETYPE stamped")
    assert_true(
        env.__contains__(ENV_TARGET_ENVIRONMENT),
        "KOMIRA_TARGET_ENVIRONMENT stamped",
    )
    assert_true(env.__contains__(ENV_APP_ID), "KOMIRA_APP_ID stamped")
    assert_true(
        env.__contains__(ENV_APP_ENTRYPOINT), "KOMIRA_APP_ENTRYPOINT stamped"
    )
    assert_true(env.__contains__(ENV_APP_TEST), "KOMIRA_APP_TEST stamped")
    assert_true(env.__contains__(ENV_REGISTRY_URL), "KOMIRA_REGISTRY_URL stamped")
    assert_true(env.__contains__(ENV_IMAGE_TAG), "KOMIRA_IMAGE_TAG stamped")
    assert_true(
        env.__contains__(ENV_BUILD_SA_EMAIL), "KOMIRA_BUILD_SA_EMAIL stamped"
    )
    assert_true(
        env.__contains__(ENV_RUNTIME_BASE_IMAGE),
        "KOMIRA_RUNTIME_BASE_IMAGE stamped",
    )
    assert_true(env.__contains__(ENV_BASE_IMAGE), "KOMIRA_BASE_IMAGE stamped")
    assert_true(
        env.__contains__(ENV_OUTPUT_FORMAT), "KOMIRA_OUTPUT_FORMAT stamped"
    )
    assert_true(env.__contains__(ENV_RUN_ID), "KOMIRA_RUN_ID stamped")
    assert_true(env.__contains__(ENV_BUCKET_NAME), "the bucket key stamped")


# =============================================================================
# Test 3 — the OPTIONAL fields are OMITTED when absent (a minimal request round-
#   trips to None, never an empty-string spoof — the typed channel is faithful).
# =============================================================================
def test_minimal_request_omits_absent_optionals() raises:
    # a minimal request: no commit, no app_test, no registry, no build_sa, no bucket.
    var req = BuildRequest(
        _SOURCE_REF,
        Optional[String](),  # source_commit absent
        _ARCHETYPE,
        _TARGET_ENV,
        _APP_ID,
        _ENTRYPOINT,
        Optional[String](),  # app_test absent
        Optional[String](),  # registry_url absent
        _IMAGE_TAG,
        Optional[String](),  # build_sa_email absent
        _RUNTIME_BASE,
        _BASE_IMAGE,
        OUTPUT_FORMAT_IMAGE,
        from_hyphenated(_RUN_ID_HEX),
        Optional[String](),  # bucket_name absent
        True,  # dry_run_push
        Optional[String](),  # managed_app_from_image absent
    )
    var env = req.to_env_config()

    # the absent optionals are NOT stamped (never an empty-string spoof).
    assert_false(
        env.__contains__(ENV_SOURCE_COMMIT),
        "an absent source_commit is not stamped",
    )
    assert_false(
        env.__contains__(ENV_APP_TEST), "an absent app_test is not stamped"
    )
    assert_false(
        env.__contains__(ENV_REGISTRY_URL),
        "an absent registry_url is not stamped",
    )
    assert_false(
        env.__contains__(ENV_BUILD_SA_EMAIL),
        "an absent build_sa_email is not stamped",
    )
    assert_false(
        env.__contains__(ENV_BUCKET_NAME), "an absent bucket_name is not stamped"
    )
    assert_false(
        env.__contains__(ENV_MANAGED_APP_FROM_IMAGE),
        "an absent managed_app_from_image is not stamped (the clone-build path)",
    )

    # decoding back yields None for each, and the dry_run_push flag survives.
    var decoded = build_request_from_env(env)
    assert_false(Bool(decoded.source_commit), "source_commit decodes to None")
    assert_false(Bool(decoded.app_test), "app_test decodes to None")
    assert_false(Bool(decoded.registry_url), "registry_url decodes to None")
    assert_false(Bool(decoded.build_sa_email), "build_sa_email decodes to None")
    assert_false(Bool(decoded.bucket_name), "bucket_name decodes to None")
    assert_false(
        Bool(decoded.managed_app_from_image),
        "managed_app_from_image decodes to None (clone-build — no FROM base)",
    )
    assert_true(decoded.dry_run_push, "dry_run_push round-trips (True)")


# =============================================================================
# Test 4 — output_format DEFAULTS to IMAGE when the env key is absent (byte-
#   compatible with a pod env that carries no stamp — the unset case is not a raise).
# =============================================================================
def test_output_format_defaults_to_image() raises:
    var req = _fixture_request()
    var env = req.to_env_config()
    # strip the output_format key entirely (an old pod env with no stamp).
    _ = env.pop(ENV_OUTPUT_FORMAT)
    var decoded = build_request_from_env(env)
    assert_equal(
        decoded.output_format,
        OUTPUT_FORMAT_IMAGE,
        "an unset KOMIRA_OUTPUT_FORMAT defaults to IMAGE (0)",
    )


# =============================================================================
# Test 5 — the FROM-IMAGE field round-trips: a BuildRequest carrying
#   `managed_app_from_image` (a prebuilt `.../live/<app>:latest` FROM base) stamps
#   the KOMIRA_MANAGED_APP_FROM_IMAGE key + decodes back to the same value. This is
#   the discriminant the in-pod executor keys the FROM-build (no clone) route on.
# =============================================================================
comptime _FROM_IMAGE: String = "us-central1-docker.pkg.dev/example-project/live/hello-app:latest"


def test_managed_app_from_image_round_trips() raises:
    # A managed-app FROM-build request: NO clone (empty source_ref), the catalog FROM
    # base set. output_format IMAGE (the FROM-Dockerfile is an IMAGE recipe).
    var req = BuildRequest(
        String(""),  # source_ref EMPTY (a FROM-build does NOT clone)
        Optional[String](),  # source_commit
        _ARCHETYPE,
        _TARGET_ENV,
        String("hello-app"),  # app_id
        _ENTRYPOINT,
        Optional[String](),  # app_test
        Optional[String](_REGISTRY),  # registry_url (the push target)
        _IMAGE_TAG,
        Optional[String](),  # build_sa_email
        _RUNTIME_BASE,
        _BASE_IMAGE,
        OUTPUT_FORMAT_IMAGE,
        from_hyphenated(_RUN_ID_HEX),
        Optional[String](),  # bucket_name
        False,  # dry_run_push
        Optional[String](_FROM_IMAGE),  # managed_app_from_image (the catalog FROM base)
    )
    var env = req.to_env_config()

    # the FROM image is stamped on the converged KOMIRA_* key.
    assert_true(
        env.__contains__(ENV_MANAGED_APP_FROM_IMAGE),
        "KOMIRA_MANAGED_APP_FROM_IMAGE is stamped when the FROM base is set",
    )
    assert_equal(
        env[ENV_MANAGED_APP_FROM_IMAGE],
        _FROM_IMAGE,
        "KOMIRA_MANAGED_APP_FROM_IMAGE == the catalog FROM base",
    )

    # decode back — the FROM image round-trips typed.
    var decoded = build_request_from_env(env)
    assert_true(
        Bool(decoded.managed_app_from_image),
        "the decoded managed_app_from_image is present",
    )
    assert_equal(
        decoded.managed_app_from_image.value(),
        _FROM_IMAGE,
        "managed_app_from_image round-trips typed",
    )


# =============================================================================
# Test 6 — render_from_dockerfile: the pure one-line `FROM <base_ref>` Dockerfile
#   render (the FROM-build recipe). NO clone, NO COPY, NO CMD — the prebuilt
#   image IS the app; the build just re-tags it into the customer registry.
# =============================================================================
def test_render_from_dockerfile_one_line() raises:
    var df = render_from_dockerfile(_FROM_IMAGE)
    # the Dockerfile is exactly the one-line `FROM <ref>` (a trailing newline is fine).
    assert_true(
        df.find(String("FROM ") + _FROM_IMAGE) >= 0,
        "render_from_dockerfile emits `FROM <base_ref>`",
    )
    # it is a FROM-ONLY recipe — no clone-derived COPY / no CMD override (the catalog
    # image already carries its entrypoint; the FROM-build only re-homes it).
    assert_false(
        df.find(String("COPY")) >= 0,
        "the FROM-build Dockerfile has NO COPY (no clone / no source to copy)",
    )
    assert_false(
        df.find(String("RUN ")) >= 0,
        "the FROM-build Dockerfile has NO RUN step (a trivial re-tag)",
    )
    # the very first token is `FROM` (a valid Dockerfile).
    assert_equal(
        df.find(String("FROM")), 0, "the Dockerfile begins with the FROM instruction"
    )


def main() raises:
    test_build_request_round_trips_through_env_decode()
    test_env_config_carries_the_converged_keys()
    test_minimal_request_omits_absent_optionals()
    test_output_format_defaults_to_image()
    test_managed_app_from_image_round_trips()
    test_render_from_dockerfile_one_line()
    print("PASS test_build_request_contract")
