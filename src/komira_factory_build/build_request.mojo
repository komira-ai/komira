# =============================================================================
# komira_factory_build/build_request.mojo — the typed `BuildRequest` INPUT +
#   the kaniko IMAGE-recipe ROUTING.
# =============================================================================
#
# ONE TYPED BUILD INPUT. A build's inputs are spelled on three surfaces: the
# Job.config keys (`CFG_*` in `build_spec_builder.mojo`), the container env keys
# the build pod reads (`ENV_*`, the `KOMIRA_*` names), and the build-flow
# script's reads. `BuildRequest` is the one value those inputs ARE, so a new
# field (output_format, runtime_base) is added once instead of in three tables
# in lock-step.
#
# `to_env_config()` renders the SAME `KOMIRA_*` keys the pod already reads
# (reusing the shared `ENV_*` constants from `build_spec_builder`), so a
# `BuildRequest`-driven pod is byte-compatible with the build-flow script's
# reads. `build_request_from_env` is the pod entrypoint's arg DECODE — a pure
# function of the container env dict.
#
# THE KANIKO ROUTING. Per the shared `output_dispatch` table (`routes_to_oci`),
# a build recipe dispatches TWO ways:
#   * an `output_format: IMAGE` recipe carrying a `dockerfile:` (for example a
#     `FROM python:3.12-slim … COPY … CMD` shape) -> the KANIKO arm (userspace
#     unpack; no /dev/fuse, no daemon, so it runs inside a gVisor sandbox).
#   * an app-binary recipe (no Dockerfile — the plain `mojo build` output) -> the
#     CRANE-APPEND arm. The app-binary path never needs a Dockerfile executor,
#     so kaniko is scoped to the IMAGE-Dockerfile recipe ONLY.
#
# THE FINITE INVARIANTS the rendered kaniko command preserves:
#   (a) FINITE — no served `PORT` env (a serverless job rejects it).
#   (b) `&&`-gate — the steps are `&&`-joined so a failing kaniko step
#       short-circuits with a non-zero exit BEFORE `crane digest` (the exit code
#       IS the gate; no `;`/`||` masks a failure).
#   (c) `--no-push` — the pod produces a REAL OCI tarball LOCALLY; a separate
#       STAGE step pushes it by digest later (build and stage are separate).
#
# CUSTODY (names only). `source_ref` / `registry_url` / `build_sa_email` are
# HANDLES (a git ref, a registry path, an identity email) — never artifact
# bytes, never a secret. The workload-identity token is minted per call from
# `spec.account_ref`, never a field on `BuildRequest`.
#
# ENCAPSULATION. A flat value record + pure transforms. No UnsafePointer, no
# wildcard origin, no unsafe_from_address. Flat String / Optional[String] / Int /
# Int32 / Bool / Uuid fields — no byte-slab, no heap-owning inner type.
# =============================================================================

from komira_db import Uuid
from komira_db.db_uuid import from_hyphenated

from komira_deploy_bundle.output_dispatch import (
    OUTPUT_FORMAT_IMAGE as _OUTPUT_FORMAT_IMAGE,
    OUTPUT_FORMAT_LIBRARY_ARTIFACT as _OUTPUT_FORMAT_LIBRARY_ARTIFACT,
    OUTPUT_FORMAT_STATIC_TARGZ as _OUTPUT_FORMAT_STATIC_TARGZ,
    OUTPUT_FORMAT_FILE as _OUTPUT_FORMAT_FILE,
    routes_to_oci,
)

# Reuse the SHARED container env keys the pod already reads (do NOT re-spell
# them here). `build_request.to_env_config` stamps THESE, so a
# BuildRequest-driven pod is byte-compatible with the build-flow script.
from .build_spec_builder import (
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
)


# =============================================================================
# §0 — the OutputFormat ordinals, re-surfaced from the shared dispatch table so a
#      caller of `komira_factory_build` gets the OUTPUT_FORMAT_* names WITHOUT a
#      second import of `komira_deploy_bundle` (the single source of truth stays
#      output_dispatch — this is a re-export, not a re-definition).
# =============================================================================
comptime OUTPUT_FORMAT_IMAGE: Int = _OUTPUT_FORMAT_IMAGE
"""The Dockerfile's final stage IS the OCI image (docker-image). The DEFAULT (0)."""
comptime OUTPUT_FORMAT_LIBRARY_ARTIFACT: Int = _OUTPUT_FORMAT_LIBRARY_ARTIFACT
"""Extract `output` from a build stage (mojo-library: .mojopkg/binary) (1)."""
comptime OUTPUT_FORMAT_STATIC_TARGZ: Int = _OUTPUT_FORMAT_STATIC_TARGZ
"""Extract `output` dir, package as one .tar.gz (static-files) (2)."""
comptime OUTPUT_FORMAT_FILE: Int = _OUTPUT_FORMAT_FILE
"""Extract the SINGLE file at `output` into the object content store (3) — the
GENERIC file shape. Routes to CRANE_APPEND, never kaniko (`resolve_build_route`)."""


# =============================================================================
# §1 — the container env keys `BuildRequest` adds beyond the `ENV_*` set in
#      `build_spec_builder` (the build-flow script reads them by these names).
# =============================================================================
comptime ENV_APP_ENTRYPOINT: String = "KOMIRA_APP_ENTRYPOINT"
"""The app's composition entrypoint relative to the clone root (default main.mojo)
for the app-binary path; the served entry for a Dockerfile recipe."""
comptime ENV_RUNTIME_BASE_IMAGE: String = "KOMIRA_RUNTIME_BASE_IMAGE"
"""The RUNTIME base image the crane-append arm layers the app binary onto (default
debian:stable-slim)."""
comptime ENV_BASE_IMAGE: String = "KOMIRA_BASE_IMAGE"
"""The BUILDER base image (the base Mojo image) — the container image the build
runs ON. Carried on the request so a BuildRequest fully describes the build
without a second lookup."""
comptime ENV_DRY_RUN_PUSH: String = "KOMIRA_BUILD_DRY_RUN_PUSH"
"""1 => package + produce the digest, DO NOT push (the local end-to-end path)."""
comptime ENV_IMAGE_NAME: String = "KOMIRA_IMAGE_NAME"
"""The IMAGE NAME segment the build's push target is composed with —
`<registry_url>/<KOMIRA_IMAGE_NAME>:<tag>`. DISTINCT FROM `KOMIRA_APP_ID`, and that
distinction is the whole point of this key.

WHY THIS IS NOT `KOMIRA_APP_ID`. A deployment may publish an app under an image
name that differs from its app id (an app id `shop` published as
`shop-app`, say). If each executor composed the push target from the app id
itself, a push would land in a repository that the publishing step never reads,
and the release path would break at its first hop.

So the app id stays the app id (it is the key of the app, and the app-id OCI
label), and the image NAME travels as its own typed value — RESOLVED ONCE by the
placer, off the deployment's own app-to-image table, and carried. Neither
executor derives it; both are handed it. That is what makes the shell path safe
without duplicating the table into bash: the build-flow script READS this key
rather than reconstructing the name.

ABSENT => the executor falls back to the app id (the generic customer/BYOC
convention)."""
comptime ENV_MANAGED_APP_FROM_IMAGE: String = "KOMIRA_MANAGED_APP_FROM_IMAGE"
"""The FROM-build base image ref (a prebuilt image, for example
`.../live/<app>:latest`, that a trivial `FROM <ref>` Dockerfile re-homes into the
customer BUILD registry). PRESENT => the in-pod executor takes the FROM-build
route: it SKIPS the git clone and writes a one-line `FROM <ref>` Dockerfile into
the context dir (then the same kaniko -> tarball -> crane-digest -> stage-push
flow runs). ABSENT (the default) => the clone-build route (clone `source_ref` +
kaniko its Dockerfile). This is the DISCRIMINANT the two build shapes differ on —
everything downstream (kaniko, stage push, build-result callback) is identical. A
HANDLE (a registry image ref), never a secret."""


# =============================================================================
# §2 — the build-route ordinals (WHICH executor arm the in-pod build entrypoint
#      dispatches a recipe to). Kaniko is IMAGE-Dockerfile ONLY; everything else is
#      crane-append (the app-binary path never needs a Dockerfile executor).
# =============================================================================
comptime BUILD_ROUTE_CRANE_APPEND: Int = 0
"""Append the built app binary as a layer onto a runtime base + `crane digest`
(the plain `mojo build` app-binary path)."""
comptime BUILD_ROUTE_KANIKO: Int = 1
"""Build a real Dockerfile with kaniko (`--no-push --tarball`) + `crane digest`
(the `output_format: IMAGE` + `dockerfile:` recipe)."""


# =============================================================================
# §2b — the IN-POD BUILD ENTRYPOINT command. The fixed container ENTRYPOINT the
#   base image ships for the in-pod build path — the release CLI binary + its
#   in-pod build subcommand. When the placer selects this path it stamps THIS as
#   the pod command (instead of `/opt/factory/build_flow.sh`) and threads the
#   typed `BuildRequest` in via `to_env_config()`, which the entrypoint decodes via
#   `build_request_from_env` and dispatches via `resolve_build_route` /
#   `render_kaniko_image_command`. Otherwise the placer stamps the build-flow
#   command.
# =============================================================================
comptime MANIFOLD_IN_POD_ENTRYPOINT: String = "/opt/factory/manifold"
"""The release CLI binary the base image ships at this path (beside the
`/opt/factory/build_flow.sh` install). The base image must install it for the
in-pod build path to run."""
comptime MANIFOLD_IN_POD_SUBCOMMAND: String = "build-in-pod"
"""The release CLI subcommand the in-pod entrypoint runs — it reads the typed
`BuildRequest` from its container env (the `KOMIRA_*` keys `to_env_config`
renders), decodes it via `build_request_from_env`, and dispatches via
`resolve_build_route` (kaniko for an IMAGE+Dockerfile recipe / crane-append else)."""


def manifold_in_pod_command() -> String:
    """The full in-pod ENTRYPOINT-override command string the placer stamps on the
    stage job's command when the in-pod build path is selected:
    `/opt/factory/manifold build-in-pod`. The pod's container runs this (NOT the
    base image's `/bin/bash` default); the typed `BuildRequest` reaches it as
    container env (`BuildRequest.to_env_config()`), decoded by
    `build_request_from_env`. A pure String value transform (no pointer, no FFI) —
    the caller stamps the result on the config key the pod-spec render threads
    into `ContainerSpec.command`."""
    return MANIFOLD_IN_POD_ENTRYPOINT + String(" ") + MANIFOLD_IN_POD_SUBCOMMAND


# =============================================================================
# §3 — BuildRequest — the typed build INPUT.
# =============================================================================
struct BuildRequest(Copyable, Movable):
    """The typed build INPUT — the ONE value a build's inputs ARE.

    A flat value record (flat String / Optional[String] / Int / Int32 / Bool /
    Uuid — no byte-slab, no heap-owning inner type). Names-only custody:
    `source_ref` / `registry_url` / `build_sa_email` are HANDLES, never secrets;
    the workload-identity token is minted per call, never a field here.

    * `source_ref`         — the clone target (a git URL or a local fixture path).
    * `source_commit`      — the pinned commit (reproducibility; optional).
    * `archetype`          — the build-recipe ordinal (KOMIRA_ARCHETYPE).
    * `target_environment` — the promote target env handle (dev/preprod/prod).
    * `app_id`             — the app id (labels the built image; the app's key).
    * `app_entrypoint`     — the app's main .mojo / served entry (default main.mojo).
    * `app_test`           — the functional test entrypoint (the &&-gate; optional).
    * `registry_url`       — the OCI push destination repo (a NAME; optional — an
                             unset registry is the dry-run local path).
    * `image_tag`          — the tag to push as (a sha tag; the single-digest id).
    * `build_sa_email`     — the BUILD sub-identity email (a NAME; optional).
    * `runtime_base_image` — the RUNTIME base the crane-append arm layers onto.
    * `base_image`         — the BUILDER base (the base Mojo image) the build runs on.
    * `output_format`      — the OUTPUT SHAPE ordinal (IMAGE / LIBRARY_ARTIFACT /
                             STATIC_TARGZ; the shared output_dispatch key).
    * `run_id`             — the run id (typed Uuid; carried in the build-result
                             callback body).
    * `bucket_name`        — the build-artifact / logs bucket (a NAME; optional).
    * `dry_run_push`       — package + digest WITHOUT pushing (the local e2e).
    * `managed_app_from_image` — the FROM-build base image ref (a prebuilt image
                             that a trivial `FROM <ref>` Dockerfile re-homes;
                             optional). PRESENT => the FROM-build route (SKIP
                             clone, render `FROM <ref>` into the context dir);
                             ABSENT => the clone-build route. The DISCRIMINANT the
                             two build shapes differ on — everything downstream is
                             identical. A HANDLE, never a secret.
    * `image_name`         — the IMAGE NAME segment the push target is composed with
                             (`<registry_url>/<image_name>:<image_tag>`). RESOLVED BY
                             THE PLACER off the deployment's app-to-image table — the
                             same row the publishing step reads its source from — so
                             the two legs of the release path cannot name different
                             repos. NOT necessarily the app id.
                             EMPTY => the executor falls back to `app_id` (the generic
                             customer/BYOC convention). A NAME, never a secret."""

    var source_ref: String
    var source_commit: Optional[String]
    var archetype: Int32
    var target_environment: String
    var app_id: String
    var app_entrypoint: String
    var app_test: Optional[String]
    var registry_url: Optional[String]
    var image_tag: String
    var build_sa_email: Optional[String]
    var runtime_base_image: String
    var base_image: String
    var output_format: Int
    var run_id: Uuid
    var bucket_name: Optional[String]
    var dry_run_push: Bool
    var managed_app_from_image: Optional[String]
    var image_name: String

    def __init__(
        out self,
        var source_ref: String,
        var source_commit: Optional[String],
        archetype: Int32,
        var target_environment: String,
        var app_id: String,
        var app_entrypoint: String,
        var app_test: Optional[String],
        var registry_url: Optional[String],
        var image_tag: String,
        var build_sa_email: Optional[String],
        var runtime_base_image: String,
        var base_image: String,
        output_format: Int,
        run_id: Uuid,
        var bucket_name: Optional[String],
        dry_run_push: Bool,
        var managed_app_from_image: Optional[String] = Optional[String](),
        var image_name: String = String(""),
    ):
        self.source_ref = source_ref^
        self.source_commit = source_commit^
        self.archetype = archetype
        self.target_environment = target_environment^
        self.app_id = app_id^
        self.app_entrypoint = app_entrypoint^
        self.app_test = app_test^
        self.registry_url = registry_url^
        self.image_tag = image_tag^
        self.build_sa_email = build_sa_email^
        self.runtime_base_image = runtime_base_image^
        self.base_image = base_image^
        self.output_format = output_format
        self.run_id = run_id
        self.bucket_name = bucket_name^
        self.dry_run_push = dry_run_push
        self.managed_app_from_image = managed_app_from_image^
        self.image_name = image_name^

    def push_image_name(self) -> String:
        """The image NAME the push target's `<registry>/<here>` segment MUST use —
        `image_name` when the placer resolved one, else `app_id`.

        THE ONE PLACE THE FALLBACK IS SPELLED. Both executors call THIS, never the
        fields: `render_stage_push_command` is handed its result, and `to_env_config`
        stamps its result on `KOMIRA_IMAGE_NAME` so the build-flow script reads an
        already-resolved name instead of re-deriving one. A fallback spelled at each
        call site is the same drift this whole field exists to prevent."""
        if self.image_name.byte_length() > 0:
            return self.image_name.copy()
        return self.app_id.copy()

    def to_env_config(self) -> Dict[String, String]:
        """Render this request to the container env dict the pod reads — the SAME
        `KOMIRA_*` keys the build-flow script consumes. An ABSENT optional is
        OMITTED (never an empty-string spoof), so the decode round-trips None
        faithfully. The pod's arg-encode counterpart of `build_request_from_env`."""
        var env = Dict[String, String]()
        env[ENV_SOURCE_REF] = self.source_ref.copy()
        if self.source_commit:
            env[ENV_SOURCE_COMMIT] = self.source_commit.value().copy()
        env[ENV_ARCHETYPE] = String(self.archetype)
        env[ENV_TARGET_ENVIRONMENT] = self.target_environment.copy()
        env[ENV_APP_ID] = self.app_id.copy()
        env[ENV_APP_ENTRYPOINT] = self.app_entrypoint.copy()
        if self.app_test:
            env[ENV_APP_TEST] = self.app_test.value().copy()
        if self.registry_url:
            env[ENV_REGISTRY_URL] = self.registry_url.value().copy()
        env[ENV_IMAGE_TAG] = self.image_tag.copy()
        if self.build_sa_email:
            env[ENV_BUILD_SA_EMAIL] = self.build_sa_email.value().copy()
        env[ENV_RUNTIME_BASE_IMAGE] = self.runtime_base_image.copy()
        env[ENV_BASE_IMAGE] = self.base_image.copy()
        env[ENV_OUTPUT_FORMAT] = String(self.output_format)
        env[ENV_RUN_ID] = self.run_id.to_hyphenated()
        if self.bucket_name:
            env[ENV_BUCKET_NAME] = self.bucket_name.value().copy()
        # dry_run_push renders as 1/0 (the build-flow reads KOMIRA_BUILD_DRY_RUN_PUSH).
        env[ENV_DRY_RUN_PUSH] = String("1") if self.dry_run_push else String("0")
        # The FROM-build base (the discriminant). Stamped ONLY when set; an absent
        # value is OMITTED (never an empty-string spoof), so the decode round-trips
        # None for the clone-build path.
        if self.managed_app_from_image:
            env[ENV_MANAGED_APP_FROM_IMAGE] = (
                self.managed_app_from_image.value().copy()
            )
        # The RESOLVED push image NAME (the `<registry>/<here>` segment). Stamped via
        # `push_image_name()` — the ONE place the image_name-else-app_id fallback is
        # spelled — so the build-flow reads a name the placer resolved rather than
        # reconstructing one from the app id. Omitted only when BOTH are empty, so a
        # request that names no image at all stays byte-identical on the wire.
        var push_name = self.push_image_name()
        if push_name.byte_length() > 0:
            env[ENV_IMAGE_NAME] = push_name^
        return env^


def build_request_env_keys() -> List[String]:
    """The container-env keys `to_env_config` may render — the SINGLE SOURCE OF TRUTH
    the in-pod entrypoint iterates to COLLECT the typed channel from its process
    environment (the entrypoint reads each key, then `build_request_from_env`
    decodes the Dict). Kept in lock-step with `to_env_config` above: EVERY key
    `to_env_config` writes appears here (an absent optional is simply not present,
    so a miss is faithfully omitted). The build-result callback keys
    (KOMIRA_BUILD_RESULT_URL / _TOKEN) are placer-overlaid, NOT part of the typed
    BuildRequest — the in-pod reader collects them separately."""
    var keys = List[String]()
    keys.append(ENV_SOURCE_REF)
    keys.append(ENV_SOURCE_COMMIT)
    keys.append(ENV_ARCHETYPE)
    keys.append(ENV_TARGET_ENVIRONMENT)
    keys.append(ENV_APP_ID)
    keys.append(ENV_APP_ENTRYPOINT)
    keys.append(ENV_APP_TEST)
    keys.append(ENV_REGISTRY_URL)
    keys.append(ENV_IMAGE_TAG)
    keys.append(ENV_BUILD_SA_EMAIL)
    keys.append(ENV_RUNTIME_BASE_IMAGE)
    keys.append(ENV_BASE_IMAGE)
    keys.append(ENV_OUTPUT_FORMAT)
    keys.append(ENV_RUN_ID)
    keys.append(ENV_BUCKET_NAME)
    keys.append(ENV_DRY_RUN_PUSH)
    keys.append(ENV_MANAGED_APP_FROM_IMAGE)
    keys.append(ENV_IMAGE_NAME)
    return keys^


# =============================================================================
# §4 — build_request_from_env — the pod entrypoint's arg DECODE. A pure function
#      of the container env dict -> a typed BuildRequest.
# =============================================================================
def _opt(config: Dict[String, String], key: String) raises -> Optional[String]:
    """The value at `key` as Some(non-empty) / None (absent OR empty => None, so an
    empty-string spoof never becomes a Some)."""
    if config.__contains__(key):
        var v = config[key]
        if v.byte_length() > 0:
            return Optional[String](v.copy())
    return Optional[String]()


def _req(
    config: Dict[String, String], key: String, default: String
) raises -> String:
    """The value at `key`, or `default` when absent/empty (a required field with a
    sane default — never a raise for a missing optional-with-default)."""
    if config.__contains__(key):
        var v = config[key]
        if v.byte_length() > 0:
            return v.copy()
    return default.copy()


def build_request_from_env(config: Dict[String, String]) raises -> BuildRequest:
    """DECODE a `BuildRequest` from the container env dict the pod carries (the ONE
    arg-decode surface). A pure function: every field is read from its `KOMIRA_*`
    key and typed. An absent optional decodes to None (via `_opt`); an unset
    `output_format` defaults to IMAGE; an unset `run_id` decodes to the nil Uuid.

    RAISES only on a malformed `run_id` (a present-but-unparseable hyphenated
    string — fail-loud, never a silent nil)."""
    # archetype: parse the ordinal (unset/empty => 1 = ENDPOINT_SERVICE default,
    # matching the build-flow's KOMIRA_ARCHETYPE default).
    var archetype: Int32 = 1
    if config.__contains__(ENV_ARCHETYPE):
        var a = config[ENV_ARCHETYPE]
        if a.byte_length() > 0:
            archetype = Int32(Int(a))

    # output_format: unset/empty => IMAGE (0).
    var output_format = OUTPUT_FORMAT_IMAGE
    if config.__contains__(ENV_OUTPUT_FORMAT):
        var of = config[ENV_OUTPUT_FORMAT]
        if of.byte_length() > 0:
            output_format = Int(of)

    # run_id: a present hyphenated string parses (fail-loud on malformed); an unset
    # key decodes to the nil Uuid (the local / dry-run path stamps no run_id).
    var run_id = Uuid()
    if config.__contains__(ENV_RUN_ID):
        var r = config[ENV_RUN_ID]
        if r.byte_length() > 0:
            run_id = from_hyphenated(r)

    # dry_run_push: "1" => True, anything else (incl. unset) => False.
    var dry = False
    if config.__contains__(ENV_DRY_RUN_PUSH):
        dry = config[ENV_DRY_RUN_PUSH] == String("1")

    return BuildRequest(
        _req(config, ENV_SOURCE_REF, String("")),
        _opt(config, ENV_SOURCE_COMMIT),
        archetype,
        _req(config, ENV_TARGET_ENVIRONMENT, String("dev")),
        _req(config, ENV_APP_ID, String("app")),
        _req(config, ENV_APP_ENTRYPOINT, String("main.mojo")),
        _opt(config, ENV_APP_TEST),
        _opt(config, ENV_REGISTRY_URL),
        _req(config, ENV_IMAGE_TAG, String("latest")),
        _opt(config, ENV_BUILD_SA_EMAIL),
        _req(config, ENV_RUNTIME_BASE_IMAGE, String("debian:stable-slim")),
        _req(config, ENV_BASE_IMAGE, String("")),
        output_format,
        run_id,
        _opt(config, ENV_BUCKET_NAME),
        dry,
        _opt(config, ENV_MANAGED_APP_FROM_IMAGE),
        # image_name: absent/empty decodes to EMPTY, and `push_image_name()` then
        # falls back to app_id — NOT decoded to app_id here, so the two facts stay
        # distinguishable on the decoded value (a caller can still see that no name
        # was resolved) and the fallback keeps living in exactly one place.
        _req(config, ENV_IMAGE_NAME, String("")),
    )


# =============================================================================
# §5 — resolve_build_route — the in-pod build dispatch (kaniko vs crane-append).
# =============================================================================
def resolve_build_route(output_format: Int, has_dockerfile: Bool) raises -> Int:
    """Route a build recipe to its executor arm: BUILD_ROUTE_KANIKO for an
    `output_format: IMAGE` recipe that carries a `dockerfile:`, else
    BUILD_ROUTE_CRANE_APPEND (the plain `mojo build` app-binary path). Kaniko is
    scoped to the IMAGE-Dockerfile recipe ONLY — a LIBRARY_ARTIFACT / STATIC_TARGZ /
    FILE output (or an IMAGE output with no Dockerfile) never routes to kaniko.

    A recipe routes to kaniko IFF (it is an OCI-scheme output — `routes_to_oci`,
    the shared output_dispatch predicate) AND (it is the IMAGE shape) AND (it
    carries a Dockerfile). Any other shape is crane-append. RAISES (via
    `routes_to_oci`) on an unknown output_format ordinal (fail-loud)."""
    if (
        output_format == OUTPUT_FORMAT_IMAGE
        and has_dockerfile
        and routes_to_oci(output_format)
    ):
        return BUILD_ROUTE_KANIKO
    return BUILD_ROUTE_CRANE_APPEND


# =============================================================================
# §6 — render_kaniko_image_command — the kaniko-arm command render (the FINITE,
#      --no-push --tarball + `crane digest`, &&-gated shape).
# =============================================================================
comptime KANIKO_EXECUTOR: String = "/kaniko/executor"
"""The kaniko executor path the base image installs — the userspace Dockerfile
builder (no /dev/fuse, no daemon, so it runs inside a gVisor sandbox)."""

comptime MOJO_TEST_TEMPLATE: String = "/opt/komira/bin/mojo_build_template.sh"
"""The build/test template the base image installs — `<template> test <testfile>`
threads the `-I` package root + the vendored link archives + MODULAR_HOME, which a
bare `mojo test` lacks (it fails `unable to locate module 'std'`). The functional
test-gate PREFIXES the kaniko command with `<template> test <context>/<app_test> && `
so a FAILING test short-circuits (invariant (b)) BEFORE `/kaniko/executor` ever runs."""


def render_kaniko_image_command(
    dockerfile: String,
    context_dir: String,
    tarball_out: String,
    app_test: Optional[String] = Optional[String](),
    registry_url: Optional[String] = Optional[String](),
    image_tag: String = String("latest"),
    app_id: String = String(""),
) -> String:
    """Render the kaniko IMAGE-recipe BUILD command for an `output_format: IMAGE` +
    `dockerfile:` recipe (the in-pod build entrypoint runs it as the BUILD step).

    BUILD AND STAGE ARE SPLIT (this render is PUSH-FREE). This is the BUILD verb
    only: it produces a REAL OCI tarball LOCALLY and reads the LOCAL manifest digest
    — it does NOT touch the registry and does NOT resolve DNS. The registry PUSH is
    a DISTINCT STAGE step (`render_stage_push_command`) the pod runs AFTER this
    build. The split is load-bearing: kaniko, when it unpacks the Dockerfile
    base-image rootfs over the pod filesystem `/`, CLOBBERS `/etc/resolv.conf`
    (leaves it with no nameserver) — so a `crane push` in the SAME `&&` chain right
    after kaniko has an empty resolv.conf and the Go resolver falls back to loopback
    `[::1]:53` (connection refused). Keeping the push out of the build chain gives
    the stage step a chance to repair resolv.conf first.

    So in ALL cases the render is:

        [<template> test <context>/<app_test> &&]
        /kaniko/executor --dockerfile <dockerfile> --context <context>
          --no-push --tar-path <tarball_out>
          && crane digest --tarball <tarball_out>

    THE INVARIANTS:
      * TEST-GATE (`&&`) — the `mojo_build_template.sh test` runs FIRST; a failing
        functional test exits non-zero and the `&&` short-circuits BEFORE
        `/kaniko/executor` (invariant (b): a failing test never produces a digest).
        The test invocation is the template (NOT a bare `mojo test`, which fails
        `unable to locate module 'std'`); the template threads `-I` + the vendored
        archives + MODULAR_HOME. The gate is OPT-IN: an absent `app_test` omits it.
      * `--no-push` on kaniko — kaniko builds a REAL OCI tarball LOCALLY; the STAGE
        step (`render_stage_push_command`) pushes that tarball to the registry AFTER
        repairing DNS. The image lands in the customer BUILD registry so DEPLOY can
        pull it by digest.
      * LOCAL DIGEST — `crane digest --tarball <tarball_out>` reads the LOCAL kaniko
        tarball manifest digest (a bare `sha256:…`), offline, NO registry, NO DNS.
        This local digest is NOT the reported digest (the STAGE push emits the REAL
        registry digest); it is the build step's terminal proof of a produced image.
      * `&&`-gate — every step is `&&`-joined so a failing kaniko/crane-digest step
        short-circuits with a non-zero exit (the exit code IS the gate; no `;`/`||`
        masks a failure).
      * NO served `PORT` env (a serverless job rejects it — the FINITE invariant).

    THE `registry_url` / `image_tag` / `app_id` PARAMS are RETAINED in the signature
    (so the caller can thread them straight through to `render_stage_push_command`
    without re-deriving them) but PRODUCE NO PUSH here — the build render is push-free
    regardless of whether a registry is set.

    A pure String value transform — no fork-exec here (the caller spawns it). The
    values are HANDLES (a registry path, a tag) — never a secret."""
    # registry_url / image_tag / app_id are the STAGE-step's target-ref inputs, NOT
    # used by the (push-free) BUILD render — silence unused-param by discarding.
    _ = registry_url
    _ = image_tag
    _ = app_id
    var cmd = String("")
    # The OPT-IN functional test-gate: `<template> test <context>/<app_test> && `
    # BEFORE the kaniko step. Some(non-empty) only — an absent/empty app_test omits it.
    if app_test:
        var test_file = app_test.value()
        if test_file.byte_length() > 0:
            cmd += MOJO_TEST_TEMPLATE
            cmd += String(" test ") + context_dir + String("/") + test_file
            cmd += String(" && ")
    cmd += KANIKO_EXECUTOR
    cmd += String(" --dockerfile ") + dockerfile
    cmd += String(" --context ") + context_dir
    cmd += String(" --no-push")
    # kaniko's write-a-local-tarball flag is `--tar-path` (kaniko v1.23.2, the
    # executor the base image bakes in); `--tarball-path` does NOT exist and
    # kaniko rejects it with `unknown flag`.
    cmd += String(" --tar-path ") + tarball_out
    # The build step ALWAYS ends at the LOCAL tarball digest — NO registry, NO DNS.
    # `crane digest --tarball` prints the bare local manifest digest (kaniko's tarball
    # manifest sha256). The registry push is the DISTINCT STAGE step.
    cmd += String(" && crane digest --tarball ") + tarball_out
    return cmd^


# =============================================================================
# §6b — render_stage_push_command — the DISTINCT STAGE-step push (local tarball ->
#      registry) with the DNS repair. Runs AFTER the (push-free) kaniko build.
# =============================================================================
comptime STAGE_METADATA_DNS: String = "169.254.169.254"
"""The GCP metadata-server DNS the stage-push writes into /etc/resolv.conf when
kaniko has clobbered it. kaniko, unpacking the Dockerfile base-image rootfs over the
pod filesystem `/`, overwrites `/etc/resolv.conf` (leaving no nameserver) — so the
subsequent registry push's Go resolver falls back to loopback `[::1]:53`
(connection refused). 169.254.169.254 is the always-reachable GCP metadata DNS a
Cloud Run Job's ambient network routes."""


def render_stage_push_command(
    tarball_out: String,
    registry_url: String,
    image_tag: String = String("latest"),
    image_name: String = String(""),
) -> String:
    """Render the STAGE-step PUSH command (local tarball -> registry) the pod runs
    AFTER the (push-free) kaniko build. This step repairs DNS, authenticates, pushes,
    and emits the REAL registry digest DEPLOY pulls.

    The shape:

        sh -c 'grep -q nameserver /etc/resolv.conf 2>/dev/null
                 || echo "nameserver 169.254.169.254" > /etc/resolv.conf'
          && crane auth login <registry-host> -u oauth2accesstoken -p "$(curl -s
                 -H 'Metadata-Flavor: Google' http://metadata.google.internal/
                 computeMetadata/v1/instance/service-accounts/default/token
                 | sed -n '<parse the access_token JSON field>')"
          && crane push <tarball_out> <registry_url>/<app_id>:<image_tag>
          && echo "PUSHED_IMAGE_DIGEST=<registry_url>/<app_id>@$(crane digest <registry_url>/<app_id>:<image_tag>)"
          && echo "KOMIRA_BUILD_DIGEST_IS_FAKE=0"

    THE STEPS (all `&&`-gated, fail-closed — no `;`/`||` masks a failure):

      1. DNS REPAIR — kaniko clobbers `/etc/resolv.conf` when it unpacks the
         Dockerfile base-image rootfs over `/` (leaving no nameserver), so the push's
         Go resolver falls back to loopback `[::1]:53` (connection refused). This
         prepends an IDEMPOTENT + NON-DESTRUCTIVE repair: write a valid
         `nameserver 169.254.169.254` (the GCP metadata DNS) ONLY IF
         `/etc/resolv.conf` has no `nameserver` line already (`grep -q nameserver … ||
         echo … > …`) — so a healthy resolv.conf is left untouched and a clobbered one
         is repaired before the push resolves the registry host.
      2. AUTH — the minimal base image ships NO gcloud and NO
         docker-credential-gcloud, so crane's google-keychain fallback finds no
         credential helper and the push is DENIED (`Unauthenticated request …`) even
         when the pod's identity holds registry-writer (IAM is fine — the pod just
         never authenticated). This mints the pod's AMBIENT identity access token off
         the GCE/Cloud Run metadata server (`curl -s -H 'Metadata-Flavor: Google'
         http://metadata.google.internal/computeMetadata/v1/instance/
         service-accounts/default/token`, `sed`-parsing the `access_token`) inside the
         child shell (never logged), then runs `crane auth login <registry-host> -u
         oauth2accesstoken -p <token>` for the registry host BEFORE the push. This is
         the single-tenant case ("use whatever identity the pod runs as"); a
         multi-tenant build would mint a federated per-customer token here instead.
      3. PUSH — `crane push <tarball> <registry>/<app_id>:<image_tag>` pushes the LOCAL
         kaniko tarball to the target registry using the crane login from step 2.
         The image lands in the customer BUILD registry so DEPLOY can pull it by digest.
      4. MARKER — `echo "PUSHED_IMAGE_DIGEST=<registry>/<app_id>@$(crane digest
         <ref>)"` prints the FULL pullable by-digest ref off the PUSHED registry
         manifest (NOT the local tarball digest) — the REAL registry digest that gets
         reported + the value DEPLOY resolves. `KOMIRA_BUILD_DIGEST_IS_FAKE=0` marks
         it as a real pushed OCI manifest. These are the same markers
         `parse_pushed_build_result` reads on both build channels.

    THE IMAGE PATH is `<registry_url>/<image_name>`, and `image_name` is NOT
    necessarily the app id. A deployment may publish an app under a different image
    name than its app id; the placer resolves that name once (off the deployment's
    app-to-image table, the same row the publishing step reads) and carries it on
    `BuildRequest.image_name`. This render DERIVES NOTHING: it is handed the name,
    which is what makes it impossible for it to disagree with the publish. Callers
    pass `request.push_image_name()`, never a bare field.

    An empty `image_name` degrades to the bare `registry_url` (a single-image repo).

    A pure String value transform — no fork-exec here (the caller spawns it). The
    values are HANDLES (a registry path, a tag) — never a secret. The access token that
    authenticates the push is minted at RUNTIME by the rendered shell (off the metadata
    server, into a `crane auth login -p "$(…)"` command substitution) — it is NEVER a
    Mojo field, an argument to this function, or a log line: the render carries only the
    `curl … | sed …` recipe, never a token value."""
    var image_repo = registry_url.copy()
    if image_name.byte_length() > 0:
        image_repo += String("/") + image_name
    var pushed_ref = image_repo + String(":") + image_tag
    # (1) DNS REPAIR — idempotent + non-destructive: only write a nameserver if
    # /etc/resolv.conf has none (kaniko clobbered it). A healthy resolv.conf is left
    # untouched. Single-quoted `sh -c` so the `||` binds inside the child shell, NOT
    # the outer `&&` chain (which would let a failed grep mask the push).
    var cmd = String(
        "sh -c 'grep -q nameserver /etc/resolv.conf 2>/dev/null"
        ' || echo "nameserver '
    ) + STAGE_METADATA_DNS + String('" > /etc/resolv.conf\'')
    # (2) AUTH — authenticate crane to the registry host with the pod's AMBIENT
    # identity access token, minted at runtime off the GCE/Cloud Run metadata server.
    # The minimal base image ships NO gcloud + NO docker-credential-gcloud, so without
    # this crane's google-keychain fallback finds no credential helper and the push is
    # DENIED (Unauthenticated). The token never appears as a Mojo value — it is a
    # `$(curl … | sed …)` command substitution inside the rendered `-p "…"`, so it is
    # fetched + consumed entirely in the child shell (never logged). Host = the first
    # `/`-segment of registry_url (the `${REGISTRY_URL%%/*}` shape). &&-gated: a failed
    # mint/login short-circuits before the push (fail-loud, no || mask). A multi-tenant
    # build would mint a federated per-customer token here instead of the pod default.
    var slash = registry_url.find(String("/"))
    var registry_host = (
        String(registry_url[byte=:slash]) if slash
        >= 0 else registry_url.copy()
    )
    cmd += String(
        " && crane auth login "
    ) + registry_host + String(
        " -u oauth2accesstoken -p \"$(curl -s -H 'Metadata-Flavor: Google'"
        " http://metadata.google.internal/computeMetadata/v1/instance/"
        "service-accounts/default/token"
        " | sed -n 's/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p')\""
    )
    # (3) PUSH the local tarball to the target registry (now crane-authenticated above).
    cmd += String(" && crane push ") + tarball_out + String(" ") + pushed_ref
    # (4) MARKER off the PUSHED registry manifest (the REAL registry digest, pullable).
    cmd += String(' && echo "PUSHED_IMAGE_DIGEST=')
    cmd += image_repo + String("@$(crane digest ") + pushed_ref
    cmd += String(')"')
    # A REAL pushed OCI manifest — never the content-sha256 fallback.
    cmd += String(' && echo "KOMIRA_BUILD_DIGEST_IS_FAKE=0"')
    return cmd^


# =============================================================================
# §7 — render_clone_command — the NATIVE source-clone command render (the shell
#      command the in-pod executor fork-execs to populate the kaniko --context dir).
# =============================================================================
def render_clone_command(
    source_ref: String,
    source_commit: Optional[String],
    workspace: String,
    context_dir: String,
) -> String:
    """Render the ONE `&&`-gated shell command the in-pod executor fork-execs to
    clone `source_ref` into `context_dir` (the kaniko --context / the source root
    where the recipe's Dockerfile lands). It has the same semantics as the
    build-flow script's clone, rendered natively (it does not shell out to the
    script).

    The shape (WITHOUT a pinned commit — `source_commit` None/empty):

        rm -rf <context_dir> && mkdir -p <workspace>
          && if [ -d "<source_ref>" ]; then cp -R "<source_ref>" <context_dir>;
             else git clone --quiet "<source_ref>" <context_dir>; fi

    The shape WITH a pinned commit (`source_commit` Some(non-empty)) appends:

          && git -C <context_dir> checkout --quiet "<commit>"

    THE SEMANTICS:
      * IDEMPOTENT — `rm -rf <context_dir>` first (a re-run never fails on a stale
        dir), then `mkdir -p <workspace>` (the parent tmpfs root).
      * LOCAL-vs-REMOTE branch at RUNTIME — a `[ -d "<ref>" ]` shell test picks the
        branch INSIDE the ONE rendered command (Mojo cannot reliably `stat` a remote
        URL at render time), so ONE command handles both: a LOCAL directory (a fixture
        / pre-checked-out mirror) is `cp -R`'d; a remote git URL is `git clone
        --quiet`'d.
      * PINNED COMMIT (optional) — `git -C <ctx> checkout --quiet <commit>` AFTER the
        clone (reproducibility). Only emitted when `source_commit` is Some(non-empty).
      * `&&`-GATED (fail-loud) — every step is `&&`-joined so ANY failure (a bad ref,
        a clone error, a missing commit) exits non-zero; the caller RAISES on that,
        so a bad `source_ref` never silently leaves an empty `context_dir` (which
        would mis-route to has_dockerfile=False -> crane-append).

    A pure String value transform — no fork-exec here (the caller spawns it). The
    values are HANDLES (a git ref / a commit id), never a secret."""
    var cmd = String("rm -rf ") + context_dir
    cmd += String(" && mkdir -p ") + workspace
    # The runtime local-vs-remote branch (`if [ -d "$src" ]`).
    cmd += String(' && if [ -d "') + source_ref + String('" ]; then cp -R "')
    cmd += source_ref + String('" ') + context_dir
    cmd += String('; else git clone --quiet "')
    cmd += source_ref + String('" ') + context_dir + String("; fi")
    # The optional pinned-commit checkout AFTER the clone (reproducibility).
    if source_commit:
        var commit = source_commit.value()
        if commit.byte_length() > 0:
            cmd += String(" && git -C ") + context_dir
            cmd += String(' checkout --quiet "') + commit + String('"')
    return cmd^


# =============================================================================
# §7b — render_from_dockerfile — the FROM-build Dockerfile render (the trivial
#      `FROM <prebuilt image>` recipe). The twin of §7's clone command: a
#      clone-build CLONES the source repo + kanikos its Dockerfile; a FROM-build
#      writes THIS one-line `FROM <ref>` Dockerfile into the context dir (NO clone)
#      then kanikos it — everything downstream identical.
# =============================================================================
def render_from_dockerfile(base_ref: String) -> String:
    """Render the FROM-build Dockerfile: a single `FROM <base_ref>` instruction (a
    prebuilt image, for example `.../live/<app>:latest`). A prebuilt app has no
    source to compile, so the "build" is a trivial re-home of that image into the
    customer BUILD registry via kaniko.

    The Dockerfile is therefore JUST the FROM: no COPY (there is no cloned source), no
    RUN (nothing to compile), no CMD override (the prebuilt image already carries its
    entrypoint). kaniko builds this into the SAME local OCI tarball the clone-build
    recipe produces, so the STAGE push (`render_stage_push_command`) + the
    build-result callback run unchanged.

    The shape:

        FROM <base_ref>

    A pure String value transform — no fork-exec here (the in-pod executor writes the
    result into the kaniko --context dir). The value is a HANDLE (a registry image
    ref), never a secret."""
    return String("FROM ") + base_ref + String("\n")


def render_from_dockerfile_write_command(
    base_ref: String,
    context_dir: String,
    dockerfile_path: String,
) -> String:
    """Render the ONE `&&`-gated shell command the in-pod executor fork-execs to
    MATERIALIZE the FROM-build recipe on disk — the NO-CLONE twin of
    `render_clone_command`. A clone-build CLONES the source repo (its Dockerfile
    ships at the clone root); a FROM-build writes a trivial one-line `FROM <ref>`
    Dockerfile into the context dir with NO clone, then kanikos it — everything
    downstream identical.

    THE LOAD-BEARING INVARIANT. The Dockerfile MUST land at EXACTLY
    `dockerfile_path` — the SAME path the in-pod executor's `has_dockerfile` probe
    (the signal `resolve_build_route` keys on) checks. If the write mkdir's a
    different dir, or the redirect targets a different path, `has_dockerfile` reads
    False and the build mis-routes to crane-append (which then runs `mojo build` on a
    NONEXISTENT `<ctx>/test_main.mojo`). So the context dir is created FIRST
    (`mkdir -p <context_dir>`), then the Dockerfile is written to `dockerfile_path`
    verbatim.

    The shape:

        rm -rf <context_dir>
          && mkdir -p <context_dir>
          && printf %s 'FROM <base_ref>
    ' > <dockerfile_path>

    THE SEMANTICS (matching `render_clone_command`'s idempotent, fail-loud shape):
      * IDEMPOTENT — `rm -rf <context_dir>` first (a re-run never fails on a stale
        dir), then `mkdir -p <context_dir>` (create the context dir BEFORE the write,
        so the redirect never fails `No such file or directory` on a fresh pod).
      * WRITE-TO-EXACTLY-`dockerfile_path` — `printf %s '<FROM ...>' > <dockerfile_path>`
        writes the recipe to the SAME path the `has_dockerfile` probe checks. The
        Dockerfile content is a fixed `FROM <ref>\n` — single-quote it so the shell
        takes it verbatim (an image ref is a HANDLE the caller renders, never
        attacker-controlled, and has no single-quote).
      * `&&`-GATED (fail-loud) — every step is `&&`-joined so ANY failure (a failed
        mkdir, a failed write) exits non-zero; the caller RAISES on that, so a failed
        context prep never silently leaves an empty context dir (which would mis-route
        to has_dockerfile=False -> crane-append).

    A pure String value transform — no fork-exec here (the caller spawns it). The
    value is a HANDLE (a registry image ref), never a secret."""
    var dockerfile = render_from_dockerfile(base_ref)
    var cmd = String("rm -rf ") + context_dir
    cmd += String(" && mkdir -p ") + context_dir
    cmd += String(" && printf %s '") + dockerfile + String("' > ")
    cmd += dockerfile_path
    return cmd^


# =============================================================================
# §8 — the BuildBackend ordinals + the TRUST-CONTEXT selector. The companion of
#      §5's `resolve_build_route` on a DIFFERENT axis: `resolve_build_route` picks
#      WHICH executor ARM a recipe runs (kaniko vs crane-append); this picks WHICH
#      BACKEND VEHICLE the build lands on (the operator's own compute vs an
#      isolated per-Job customer vehicle), keyed on the build's TRUST CONTEXT.
#
# THE TRUST SIGNAL IS ALREADY TYPED ON THE WIRE. `account_ref` (the cloud
#   connection id — a NAME, never a secret) IS the trust axis:
#     * EMPTY  => single-tenant = the operator's own = TRUSTED — the build belongs
#                 on the operator's own Kubernetes compute -> BUILD_BACKEND_ON_FARM_K8S.
#     * NON-EMPTY => a per-Job CUSTOMER account = ISOLATED-EXTERNAL (it runs in the
#                 customer's account, isolated) -> BUILD_BACKEND_CLOUD_RUN_JOB (the
#                 default; SPOT_VM is the preferred long-term vehicle and
#                 CLOUD_BUILD a fallback, so the resolver returns the one
#                 isolated-external backend that exists).
#   So the resolver is a PURE function over `account_ref` — NO I/O, NO environment
#   variable. This is the SAME idiom as §5's pure ordinal resolver.
#
# Only BUILD_BACKEND_CLOUD_RUN_JOB has an implemented backend (the Cloud Run Job
#   pod-manager conformer); ON_FARM_K8S / SPOT_VM / CLOUD_BUILD are reserved
#   ordinals for conformers not yet built. A job manager whose registry lookup is
#   fail-safe falls a build that resolves to an UNREGISTERED backend back to the
#   working path, so a trusted build never strands on a missing backend.
#
# ENCAPSULATION: pure value/Int work (no pointer, no wildcard origin, no byte-slab).
# =============================================================================
comptime BUILD_BACKEND_ON_FARM_K8S: Int = 0
"""Trusted (the operator's own) -> the operator's own Kubernetes compute. A
reserved ordinal: its conformer (a Kubernetes Job pod manager driven by a pull
agent) is NOT built yet. The resolver returns this for an EMPTY `account_ref`
(single-tenant = the operator's own); until its conformer registers, a fail-safe
registry lookup falls this back to the CLOUD_RUN_JOB backend / the SERVICE path."""
comptime BUILD_BACKEND_CLOUD_RUN_JOB: Int = 1
"""Isolated-external DEFAULT — the Cloud Run Job pod-manager conformer. The only
implemented build backend. The resolver returns this for a NON-EMPTY `account_ref`
(a per-Job customer account = isolated-external)."""
comptime BUILD_BACKEND_SPOT_VM: Int = 2
"""Isolated-external PREFERRED long-term — a per-Job spot/preemptible VM torn down
after the build (the strongest isolation for untrusted foreign code). A reserved
ordinal: its conformer is NOT built yet. See the resolver's docstring note on the
future `spot` arm."""
comptime BUILD_BACKEND_CLOUD_BUILD: Int = 3
"""Isolated-external FALLBACK — a provider-managed builder (GCP Cloud Build / AWS
CodeBuild). A reserved ordinal: its conformer is NOT built yet. NEVER a default (it
runs on provider-SHARED infrastructure, reintroducing the cross-tenant risk the
per-Job vehicles avoid); selected only on an explicit provider fallback."""


def resolve_build_backend(account_ref: String) raises -> Int:
    """The PURE trust-context selector over the ALREADY-typed `account_ref`
    placement field — NO I/O, NO environment variable. Trust axis FIRST:

      * `len(account_ref) == 0`  -> BUILD_BACKEND_ON_FARM_K8S
        (an EMPTY account_ref = single-tenant = the operator's own = TRUSTED).
      * else                     -> BUILD_BACKEND_CLOUD_RUN_JOB
        (a NON-EMPTY account_ref = a per-Job CUSTOMER account = ISOLATED-EXTERNAL —
        the Cloud Run Job default).

    FUTURE EXTENSION — a `spot` arm. A fuller resolver would take a `spot: Bool`
    (+ `compute`/`provider`) and route the isolated-external case to
    BUILD_BACKEND_SPOT_VM when `spot`. This resolver keeps the signature to
    `account_ref` ALONE for now, because (a) only CLOUD_RUN_JOB has an implemented
    backend and (b) no caller threads a `spot` intent yet — a clean pure function
    beats a param that is always False. When SPOT_VM's conformer lands and the
    placer threads `spot`, widen the arm.

    FUTURE REFINEMENT — the trust predicate. The trust axis is
    `len(account_ref) == 0` today. If an operator runs its own compute in a SECOND
    account, a non-empty `account_ref` could still mean "the operator's own" — then
    the predicate needs an explicit `is_own_account(account_ref)` rather than mere
    presence. Noted so the contract is stable for that change.

    RAISES only for the `String` op surface convention (mirrors §5's `raises`
    resolver); it never itself raises for a well-formed `account_ref`."""
    if account_ref.byte_length() == 0:
        # EMPTY account_ref = single-tenant = the operator's own = trusted.
        return BUILD_BACKEND_ON_FARM_K8S
    # NON-EMPTY account_ref = per-Job customer account = isolated-external.
    return BUILD_BACKEND_CLOUD_RUN_JOB
