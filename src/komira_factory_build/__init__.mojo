# =============================================================================
# komira_factory_build/__init__.mojo — the BUILD-spec module facade.
# =============================================================================
#
# Renders the FINITE BUILD Job: the `PlacementSpec` a job manager places to RUN
# a build in the customer's environment (git-clone source -> plain `mojo build` +
# `mojo test` on the base Mojo image -> OCI-package -> push to the customer
# registry under the build sub-identity), plus the in-pod build commands
# (kaniko / crane renders) and the build-output marker parser.
#
# A LEAF: it does not depend on the job store, on a pipeline runtime, or on a
# Cloud Run / gRPC transport (a build is a FINITE in-cluster/VM Job, not a served
# endpoint). It uses ONLY the placement-neutral value types (`PlacementSpec` /
# `ContainerSpec` from komira_placement, `EnvVar` from komira_k8s) — the same
# currency a scheduler already speaks. A pure value transformation: a build
# Job's facts (read) -> a `PlacementSpec` (owned, moved out). No UnsafePointer,
# no wildcard origin.
# =============================================================================

from .build_spec_builder import (
    BuildSpecBuilder,
    BuildJobFacts,
    BUILD_CONTAINER_NAME,
    CFG_SOURCE_REF,
    CFG_SOURCE_COMMIT,
    CFG_ARCHETYPE,
    CFG_TARGET_ENVIRONMENT,
    CFG_APP_ID,
    CFG_REGISTRY_URL,
    CFG_IMAGE_TAG,
    CFG_BUILD_SA_EMAIL,
    CFG_BASE_IMAGE,
    CFG_BUILD_RESULT_URL,
    CFG_BUILD_RESULT_TOKEN,
    CFG_RUN_ID,
    CFG_APP_TEST,
    ENV_SOURCE_REF,
    ENV_SOURCE_COMMIT,
    ENV_ARCHETYPE,
    ENV_TARGET_ENVIRONMENT,
    ENV_APP_ID,
    ENV_APP_TEST,
    ENV_REGISTRY_URL,
    ENV_IMAGE_TAG,
    ENV_BUILD_SA_EMAIL,
    ENV_OUTPUT_FORMAT,
    ENV_RUN_ID,
    ENV_BUCKET_NAME,
    # The build-result callback keys the in-pod entrypoint reads directly (NOT
    # part of the typed BuildRequest — the placer stamps them alongside the
    # KOMIRA_* channel).
    ENV_BUILD_RESULT_URL,
    ENV_BUILD_RESULT_TOKEN,
    BUILD_FLOW_COMMAND,
    ARCHETYPE_DATA_PIPELINE,
    ARCHETYPE_ENDPOINT_SERVICE,
    ARCHETYPE_WEB_APP,
)

# The build-output marker contract and its ONE parser (callers may also import
# them from `komira_factory_build.managed_app_build_command` directly).
from .managed_app_build_command import (
    parse_pushed_digest,
    parse_pushed_build_result,
    PushedBuildResult,
    OCI_MANIFEST_MEDIA_TYPE,
    BUILD_RESULT_SUCCESS,
    BUILD_RESULT_FAILURE,
    PUSHED_DIGEST_MARKER,
    PUSHED_DIGEST_IS_FAKE_MARKER,
)

# The typed `BuildRequest` INPUT (one value instead of the CFG_*/ENV_*/KOMIRA_*
# tables) + the kaniko IMAGE-recipe ROUTING (an `output_format: IMAGE` +
# `dockerfile:` recipe -> kaniko `--no-push --tarball` + `crane digest`; the
# app-binary path -> crane-append).
from .build_request import (
    BuildRequest,
    build_request_from_env,
    build_request_env_keys,
    resolve_build_route,
    render_kaniko_image_command,
    render_stage_push_command,
    render_clone_command,
    # FROM-build: the trivial `FROM <prebuilt image>` Dockerfile render + the
    # FROM-base discriminant env key. A FROM-build skips the clone and otherwise
    # runs the SAME in-pod build path as a clone-build.
    render_from_dockerfile,
    render_from_dockerfile_write_command,
    ENV_MANAGED_APP_FROM_IMAGE,
    # The PUSH TARGET's image-NAME key — the `<registry>/<here>` segment, RESOLVED by
    # the placer off the deployment's app-to-image table and carried, so NEITHER
    # executor (this package's `render_stage_push_command`, nor the build-flow
    # script, which cannot read a Mojo table) derives it from the app id.
    ENV_IMAGE_NAME,
    BUILD_ROUTE_KANIKO,
    BUILD_ROUTE_CRANE_APPEND,
    # TRUST-CONTEXT BUILD-BACKEND SELECTOR: the pure resolver over the already-typed
    # `account_ref` (empty = the operator's own = trusted = ON_FARM_K8S; non-empty =
    # per-Job customer = isolated-external = CLOUD_RUN_JOB) + the 4-arm BuildBackend
    # ordinal set (beside the BUILD_ROUTE_* idiom). The placer resolves this and
    # stamps the ordinal; the job manager reads the stamped key itself and does not
    # import this package (the layering is one-way).
    BUILD_BACKEND_ON_FARM_K8S,
    BUILD_BACKEND_CLOUD_RUN_JOB,
    BUILD_BACKEND_SPOT_VM,
    BUILD_BACKEND_CLOUD_BUILD,
    resolve_build_backend,
    KANIKO_EXECUTOR,
    OUTPUT_FORMAT_IMAGE,
    OUTPUT_FORMAT_LIBRARY_ARTIFACT,
    OUTPUT_FORMAT_STATIC_TARGZ,
    OUTPUT_FORMAT_FILE,
    ENV_APP_ENTRYPOINT,
    ENV_RUNTIME_BASE_IMAGE,
    ENV_BASE_IMAGE,
    ENV_DRY_RUN_PUSH,
    # The in-pod build entrypoint (the release CLI's `build-in-pod` subcommand) the
    # placer stamps as the pod command when it selects the in-pod build path.
    MANIFOLD_IN_POD_ENTRYPOINT,
    MANIFOLD_IN_POD_SUBCOMMAND,
    manifold_in_pod_command,
)
