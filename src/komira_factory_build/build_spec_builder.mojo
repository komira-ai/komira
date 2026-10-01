# =============================================================================
# komira_factory_build/build_spec_builder.mojo — `BuildSpecBuilder`, the
#   BUILD-Job spec builder.
# =============================================================================
#
# WHAT IT IS. A job manager turns a claimed Job into a `PlacementSpec` that the
#   placement-neutral `PodManager` seam places. A served deploy renders an
#   INFINITE spec (a container bound to $PORT that serves until replaced). A
#   build is a different container archetype: it clones source, compiles,
#   packages an OCI digest, pushes it, and EXITS. This builder renders that
#   FINITE spec from the build Job's facts (source ref, archetype, target env,
#   registry, build sub-identity).
#
# HOW IT DIFFERS FROM A SERVED DEPLOY:
#   * NO served port. A build exposes no endpoint, so `ports` stays empty and
#     `served_ports()` on the spec returns empty. That is how a reconciler
#     tells a FINITE build from an INFINITE serve.
#   * image = the BASE MOJO IMAGE (the compiler plus its `.mojoc` closure), not
#     a packaged app digest. The app digest is the build's OUTPUT, not its
#     input.
#   * command = the build-flow entrypoint the base image ships: clone,
#     `mojo build` + `mojo test`, OCI-package, push. A served deploy has no
#     command override (the app image's own entrypoint serves).
#
# WHAT IT BUILDS. A `PlacementSpec` with EXACTLY ONE `ContainerSpec`:
#   * name    = "factory-build" (the build container within the placement unit).
#   * image   = Job.config[base_image] or the caller's `default_base_image`.
#               An empty value still builds (the caller surfaces the missing
#               image).
#   * command = BUILD_FLOW_COMMAND, the fixed `/opt/factory/build_flow.sh`.
#   * env     = (in this order) the build inputs the build-flow reads:
#       KOMIRA_SOURCE_REF        = config[source_ref]        (clone target)
#       KOMIRA_SOURCE_COMMIT     = config[source_commit]     (pinned commit)
#       KOMIRA_ARCHETYPE         = config[archetype]         (build recipe key)
#       KOMIRA_TARGET_ENVIRONMENT= config[target_environment](promote target)
#       KOMIRA_APP_ID            = config[app_id]            (the app built)
#       KOMIRA_REGISTRY_URL      = config[registry_url]      (OCI push dest)
#       KOMIRA_IMAGE_TAG         = config[image_tag]         (the digest tag)
#       KOMIRA_BUILD_SA_EMAIL    = build_sa_email            (the build identity)
#       komira-bucket-name        = bucket_name               (build artifacts)
#   * account_ref = Job.account_ref — the per-Job customer cloud-account ref
#               (a NAME, never a secret) the placement conformer resolves to a
#               workload-identity handle and mints the BUILD identity's token
#               from.
#
# BUILD, DEPLOY AND PLACEMENT ARE SEPARATE IDENTITIES. This builder stamps the
#   BUILD sub-identity (`build_sa_email`) into the env, not the runtime or
#   placement identity. A build Job runs with registry-writer credentials only;
#   it cannot deploy or place VMs. The spec is self-describing (a unit test can
#   assert the identity on the spec without driving a pod manager); the
#   placement conformer resolves account_ref to the identity's handle and mints
#   the token at call time, never at rest here.
#
# CUSTODY (names only). Every env value is a NAME or HANDLE: the source ref
#   points at source in the customer's environment (the build-flow clones it
#   into build compute inside the customer boundary), the registry URL is a
#   name, the identity is an email. No artifact bytes, no secret values.
#
# ENCAPSULATION. A pure value transformation: a `BuildJobFacts` (read) + config
#   strings -> a `PlacementSpec` (owned, moved out). The struct is stateless (a
#   `@staticmethod build`); it holds no fields and no pointers. The output
#   `PlacementSpec` / `ContainerSpec` / `EnvVar` are ordinary owned value
#   structs (String / List).
# =============================================================================

from komira_k8s.k8s_types import EnvVar
from komira_placement.placement_types import (
    PlacementSpec,
    ContainerSpec,
)


# =============================================================================
# §0 — the build-spec constants (the base-Mojo-image FINITE-build surface).
# =============================================================================

# The build container's name within the placement unit.
comptime BUILD_CONTAINER_NAME: String = "factory-build"

# ── THE BASE MOJO IMAGE is the CALLER's, not this package's. ────────────────
#
# The pinned base Mojo image digest (and the compiler version it bakes) is a
# fact of the deployment that builds it, so the caller owns it and passes it as
# `BuildSpecBuilder.build(default_base_image=...)`. A config[base_image]
# override on the build Job still wins over it.

# The FIXED build-flow entrypoint the base image ships, installed at
# /opt/factory/build_flow.sh. The container's command runs it: clone -> mojo
# build + mojo test -> OCI-package -> push. It is an explicit command override
# because the base image's own default entrypoint is a shell.
comptime BUILD_FLOW_COMMAND: String = "/opt/factory/build_flow.sh"

# ---- the Job.config keys the build facts arrive on ----

# The source ref (a handle to source in the customer's environment, never the
# code itself). The build-flow clones it into build compute inside the
# customer boundary.
comptime CFG_SOURCE_REF: String = "source_ref"

# The pinned commit the build checks out (reproducibility: the build is pinned
# to an immutable commit, not a moving branch tip). Optional.
comptime CFG_SOURCE_COMMIT: String = "source_commit"

# The archetype ordinal/name selecting the build recipe and gate set. The
# build-flow branches its verify gates on it.
comptime CFG_ARCHETYPE: String = "archetype"

# The target Environment handle the built artifact promotes to (dev/preprod/prod).
comptime CFG_TARGET_ENVIRONMENT: String = "target_environment"

# The app id the build is for (the `(org_id, app_id)` key of the app endpoint).
comptime CFG_APP_ID: String = "app_id"

# The customer artifact registry URL the OCI digest pushes to (for example
# `<region>-docker.pkg.dev/<project>/<repo>`). A NAME.
comptime CFG_REGISTRY_URL: String = "registry_url"

# The image tag the packaged digest is pushed as (an immutable sha tag, not a
# mutable channel tag).
comptime CFG_IMAGE_TAG: String = "image_tag"

# The BUILD sub-identity email override (else the `build_sa_email` arg wins).
comptime CFG_BUILD_SA_EMAIL: String = "build_sa_email"

# The base Mojo image override (else the caller's `default_base_image`).
comptime CFG_BASE_IMAGE: String = "base_image"

# BUILD-RESULT CALLBACK: the base URL the build pod POSTs its pushed digest to
# (`${url}/internal/build-result`). A serverless job's stdout does not reach the
# controller, so the pod reports its result over HTTP. Rendered as
# KOMIRA_BUILD_RESULT_URL. Absent => not stamped (the local / dry-run path skips
# the callback). A NAME (a URL), never a token.
comptime CFG_BUILD_RESULT_URL: String = "build_result_url"

# BUILD-RESULT CALLBACK: the per-job bearer the callback POST presents as
# `Authorization: Bearer <token>` (the receiver's fail-closed build-result gate
# checks it). Rendered as KOMIRA_BUILD_RESULT_TOKEN. Absent => not stamped.
comptime CFG_BUILD_RESULT_TOKEN: String = "build_result_token"

# BUILD-RESULT CALLBACK: the run_id the callback body carries
# (`{"run_id": "<uuid>", ...}`). Rendered as KOMIRA_RUN_ID. Absent => not
# stamped.
comptime CFG_RUN_ID: String = "run_id"

# TEST GATE: the app's functional test entrypoint the build pod runs
# (`mojo test <app_test>`). A failing test short-circuits the build `&&` chain:
# no push, no callback, the deploy never advances. Rendered as KOMIRA_APP_TEST
# (the build-flow skips the gate when it is unset).
comptime CFG_APP_TEST: String = "app_test"

# The artifact's OUTPUT SHAPE ordinal (the `OutputFormat` int: 0=IMAGE /
# 1=LIBRARY_ARTIFACT / 2=STATIC_TARGZ). Stamped so the pod build extracts the
# same shape and emits the same marker as the operator's local build: both read
# the one shared dispatch table (`komira_deploy_bundle.output_dispatch`), so
# they cannot drift. Rendered as KOMIRA_OUTPUT_FORMAT. Absent => the pod
# defaults to IMAGE (0).
comptime CFG_OUTPUT_FORMAT: String = "output_format"

# ---- the archetype ordinals (mirror PipelineDefinition.archetype) ----
comptime ARCHETYPE_DATA_PIPELINE: String = "data_pipeline"
comptime ARCHETYPE_ENDPOINT_SERVICE: String = "endpoint_service"
comptime ARCHETYPE_WEB_APP: String = "web_app"

# ---- the container env keys the build-flow reads ----
comptime ENV_SOURCE_REF: String = "KOMIRA_SOURCE_REF"
comptime ENV_SOURCE_COMMIT: String = "KOMIRA_SOURCE_COMMIT"
comptime ENV_ARCHETYPE: String = "KOMIRA_ARCHETYPE"
comptime ENV_TARGET_ENVIRONMENT: String = "KOMIRA_TARGET_ENVIRONMENT"
comptime ENV_APP_ID: String = "KOMIRA_APP_ID"
comptime ENV_REGISTRY_URL: String = "KOMIRA_REGISTRY_URL"
comptime ENV_IMAGE_TAG: String = "KOMIRA_IMAGE_TAG"
comptime ENV_BUILD_SA_EMAIL: String = "KOMIRA_BUILD_SA_EMAIL"
# The build-result callback keys + the test-gate key: the callback base URL,
# the per-job bearer, the run_id (the callback body) and the test entrypoint.
comptime ENV_BUILD_RESULT_URL: String = "KOMIRA_BUILD_RESULT_URL"
comptime ENV_BUILD_RESULT_TOKEN: String = "KOMIRA_BUILD_RESULT_TOKEN"
comptime ENV_RUN_ID: String = "KOMIRA_RUN_ID"
comptime ENV_APP_TEST: String = "KOMIRA_APP_TEST"
# The container env key the build-flow reads to select the OUTPUT SHAPE's
# extraction + marker + scheme (the shared output_dispatch table). Unset => IMAGE.
comptime ENV_OUTPUT_FORMAT: String = "KOMIRA_OUTPUT_FORMAT"
# The build-artifact / logs bucket: the object-store client the build-flow
# writes build logs and intermediate artifacts to points here. This key must
# equal the bucket key the placement pod managers stamp: every library that
# defines it uses this one spelling, or the contract splits.
comptime ENV_BUCKET_NAME: String = "komira-bucket-name"


# =============================================================================
# §1 — BuildSpecBuilder — the stateless FINITE build-spec builder.
# =============================================================================
@fieldwise_init
struct BuildJobFacts(Copyable, Movable):
    """The two fields of a claimed build Job that the builder reads: its
    `config` map (the build facts the control plane stamps -- source ref,
    archetype, registry, image tag, base-image override, ...) and its
    `account_ref` (the per-Job customer cloud-account ref the placement
    conformer mints the BUILD identity's token from; empty = single-tenant
    fallback).

    A VALUE, not the job store's row type: the Job row belongs to the control
    plane's job store, and this package does not depend on it -- the caller
    that holds the row copies these two fields out (`BuildJobFacts(job.config.copy(),
    job.account_ref.copy())`)."""

    var config: Dict[String, String]
    var account_ref: Optional[String]


struct BuildSpecBuilder:
    """The BUILD-Job spec builder. STATELESS — a single `@staticmethod build`.

    Maps a build Job's facts + the namespace + the build inputs (base image /
    registry / build_sa_email / bucket_name) into a one-container FINITE-Job
    `PlacementSpec` carrying the base-Mojo-image build surface (the build-flow
    command + KOMIRA_SOURCE_REF/ARCHETYPE/REGISTRY_URL/IMAGE_TAG/BUILD_SA_EMAIL +
    the bucket env). The scheduler hands the result to the PodManager seam to
    RUN the build.

    Unlike a served deploy spec: NO served port (a build exposes no endpoint),
    image = the base Mojo image (not a packaged app digest — that is the
    build's OUTPUT), command = the build-flow.

    ENCAPSULATION: a pure value transformation. No fields, no pointers; the
    output is an owned `PlacementSpec` moved out."""

    @staticmethod
    def build(
        job: BuildJobFacts,
        default_base_image: String,
        pod_name: String,
        namespace: String,
        project: String,
        region: String,
        build_sa_email: String,
        bucket_name: String,
    ) raises -> PlacementSpec:
        """Render the FINITE build `PlacementSpec` from a claimed build Job's
        facts + the namespace + the build inputs. `pod_name` is the server-set
        durable name (the build unit id); `project` / `region` are carried for
        parity with the VM/serverless paths (placement addressing is composed by
        the pod manager from its own config — the builder records them as build
        inputs). `build_sa_email` is the BUILD sub-identity — the fallback if
        config does not override it.

        The result is moved out, ready for the PodManager seam.

        The ONE container:
          * image   = config[base_image] or `default_base_image` (the base Mojo
                      builder image; the app digest is the OUTPUT, not the input).
          * command = the build-flow (BUILD_FLOW_COMMAND) — clone, mojo build +
                      test, OCI-package, push.
          * env in order: KOMIRA_SOURCE_REF, KOMIRA_SOURCE_COMMIT,
                      KOMIRA_ARCHETYPE, KOMIRA_TARGET_ENVIRONMENT,
                      KOMIRA_APP_ID, KOMIRA_REGISTRY_URL, KOMIRA_IMAGE_TAG,
                      KOMIRA_BUILD_SA_EMAIL, komira-bucket-name.
          * ports   = NONE (a FINITE build exposes no served endpoint).
          * account_ref = job.account_ref (the per-Job customer cloud-account
                      ref the placement conformer mints the BUILD token from)."""
        var spec = PlacementSpec(pod_name, namespace)

        # ---- the image: the base Mojo builder image (config override or default) ----
        # The app digest is the build's OUTPUT, never its input — so unlike a
        # served deploy (which pulls a packaged digest), the build's image is
        # the base Mojo image. A build Job may carry a specific base-image
        # digest in config[base_image]; else the caller's default.
        var base_image = default_base_image
        if job.config.__contains__(CFG_BASE_IMAGE):
            var v = job.config[CFG_BASE_IMAGE]
            if v.byte_length() > 0:
                base_image = v

        var c = ContainerSpec(BUILD_CONTAINER_NAME, base_image)

        # ---- command: the fixed build-flow entrypoint ----
        # The base image ships the build-flow at BUILD_FLOW_COMMAND; the
        # container command runs it (overriding the base image's default shell
        # entrypoint). The build-flow reads its inputs from the env below.
        c.command.append(BUILD_FLOW_COMMAND)

        # ---- env: the source ref (the clone target in the customer env) ----
        # A handle to source in the customer env, never the code itself.
        # The build-flow git-clones it into build compute inside the boundary.
        if job.config.__contains__(CFG_SOURCE_REF):
            c.env.append(EnvVar(ENV_SOURCE_REF, job.config[CFG_SOURCE_REF]))

        # ---- env: the pinned commit (reproducibility) ----
        if job.config.__contains__(CFG_SOURCE_COMMIT):
            c.env.append(EnvVar(ENV_SOURCE_COMMIT, job.config[CFG_SOURCE_COMMIT]))

        # ---- env: the archetype (selects the build recipe + gate set) ----
        if job.config.__contains__(CFG_ARCHETYPE):
            c.env.append(EnvVar(ENV_ARCHETYPE, job.config[CFG_ARCHETYPE]))

        # ---- env: the target Environment (promote target) ----
        if job.config.__contains__(CFG_TARGET_ENVIRONMENT):
            c.env.append(
                EnvVar(
                    ENV_TARGET_ENVIRONMENT, job.config[CFG_TARGET_ENVIRONMENT]
                )
            )

        # ---- env: the app id (the (org_id, app_id) key of the app endpoint) ----
        if job.config.__contains__(CFG_APP_ID):
            c.env.append(EnvVar(ENV_APP_ID, job.config[CFG_APP_ID]))

        # ---- env: the customer registry URL (the OCI push destination) ----
        # A NAME; the pushed digest lands in the customer's OWN registry.
        if job.config.__contains__(CFG_REGISTRY_URL):
            c.env.append(EnvVar(ENV_REGISTRY_URL, job.config[CFG_REGISTRY_URL]))

        # ---- env: the image tag (the single-digest identity — a sha tag) ----
        if job.config.__contains__(CFG_IMAGE_TAG):
            c.env.append(EnvVar(ENV_IMAGE_TAG, job.config[CFG_IMAGE_TAG]))

        # ---- env: the BUILD sub-identity ----
        # A config override wins (a per-Job build identity); else the
        # build_sa_email arg. Self-documenting on the spec: the build runs
        # UNDER this identity (registry-writer only — it cannot deploy or place
        # VMs). The placement conformer resolves account_ref -> this identity's
        # handle and mints the token at call time.
        var sa = build_sa_email
        if job.config.__contains__(CFG_BUILD_SA_EMAIL):
            var v = job.config[CFG_BUILD_SA_EMAIL]
            if v.byte_length() > 0:
                sa = v
        if sa.byte_length() > 0:
            c.env.append(EnvVar(ENV_BUILD_SA_EMAIL, sa))

        # ---- env: BUILD-RESULT CALLBACK — the base URL the build pod POSTs its
        # pushed digest to. Without it the build-flow skips the callback (the
        # local / dry-run path).
        if job.config.__contains__(CFG_BUILD_RESULT_URL):
            c.env.append(
                EnvVar(ENV_BUILD_RESULT_URL, job.config[CFG_BUILD_RESULT_URL])
            )

        # ---- env: BUILD-RESULT CALLBACK — the per-job bearer the POST presents ----
        if job.config.__contains__(CFG_BUILD_RESULT_TOKEN):
            c.env.append(
                EnvVar(
                    ENV_BUILD_RESULT_TOKEN, job.config[CFG_BUILD_RESULT_TOKEN]
                )
            )

        # ---- env: BUILD-RESULT CALLBACK — the run_id the callback body carries ----
        if job.config.__contains__(CFG_RUN_ID):
            c.env.append(EnvVar(ENV_RUN_ID, job.config[CFG_RUN_ID]))

        # ---- env: TEST GATE — the functional test entrypoint the pod runs
        # (`mojo test <app_test>`); a failing test short-circuits the build `&&`
        # (no push, no callback, the deploy never advances).
        if job.config.__contains__(CFG_APP_TEST):
            c.env.append(EnvVar(ENV_APP_TEST, job.config[CFG_APP_TEST]))

        # ---- env: output_format — the artifact OUTPUT SHAPE ordinal the pod
        # build reads to select the same (extraction, marker, scheme) as the
        # operator's local build (the shared output_dispatch table). Unset =>
        # the pod defaults to IMAGE.
        if job.config.__contains__(CFG_OUTPUT_FORMAT):
            var of = job.config[CFG_OUTPUT_FORMAT]
            if of.byte_length() > 0:
                c.env.append(EnvVar(ENV_OUTPUT_FORMAT, of))

        # ---- env: the build-artifact / logs bucket ----
        if bucket_name.byte_length() > 0:
            c.env.append(EnvVar(ENV_BUCKET_NAME, bucket_name))

        # ---- NO served port: a FINITE build exposes no endpoint. ----
        # (We deliberately append nothing to c.ports — `served_ports()` on the
        # spec returns empty, which is how the reconciler distinguishes a FINITE
        # build from an INFINITE serve.)

        spec.containers.append(c^)

        # ---- the per-Job customer cloud-account ref (the token mint anchor) ----
        # The placement conformer resolves this NAME to the BUILD identity's
        # handle and mints a per-Job token from it. Empty => single-tenant
        # fallback (the conformer uses its own held handle). A NAME, never a
        # secret — the token lives in the call frame, never at rest here.
        if job.account_ref:
            spec.account_ref = job.account_ref.value()

        # `project` / `region` are build facts; placement addressing is composed
        # by the pod manager from its own held config, so they are not re-stamped
        # on the container env (avoid a second source of truth). Touched so the
        # signature documents them as build inputs.
        _ = project
        _ = region

        return spec^
