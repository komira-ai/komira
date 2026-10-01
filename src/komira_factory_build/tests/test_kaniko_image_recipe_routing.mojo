# =============================================================================
# komira_factory_build/tests/test_kaniko_image_recipe_routing.mojo — the kaniko
#   IMAGE-recipe ROUTING gate.
# =============================================================================
#
# Per the shared `output_dispatch` table (`routes_to_oci`), the in-pod build
# entrypoint dispatches a build recipe TWO ways:
#   * an `output_format: IMAGE` recipe carrying a `dockerfile:` (a
#     `FROM python:3.12-slim … COPY … CMD` shape) -> the KANIKO arm
#     (`kaniko --dockerfile … --context … --no-push --tar-path` then `crane digest`).
#   * an app-binary recipe (no Dockerfile — the plain `mojo build` output) -> the
#     CRANE-APPEND arm (append the built binary as a layer + crane digest).
#
# WHAT THIS PROVES:
#   1. `resolve_build_route(IMAGE, has_dockerfile=True)` -> BUILD_ROUTE_KANIKO.
#   2. `resolve_build_route(IMAGE, has_dockerfile=False)` -> BUILD_ROUTE_CRANE_APPEND
#      (an IMAGE output that is the plain app binary, not a Dockerfile).
#   3. the kaniko-arm command render carries `--dockerfile`, `--context`,
#      `--no-push`, `--tar-path`, then `crane digest` — the FINITE, no-served-PORT,
#      &&-gated shape (a failing step raises before any push/return).
#   4. the clone, stage-push and FROM-build renders keep their shapes.
#
# Pure value transformation — NO cloud, NO container, NO kaniko fork-exec (the
# command is a rendered String; the route is a pure ordinal function).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_factory_build import (
    resolve_build_route,
    render_kaniko_image_command,
    render_stage_push_command,
    render_clone_command,
    render_from_dockerfile,
    render_from_dockerfile_write_command,
    BUILD_ROUTE_KANIKO,
    BUILD_ROUTE_CRANE_APPEND,
    OUTPUT_FORMAT_IMAGE,
    OUTPUT_FORMAT_LIBRARY_ARTIFACT,
    OUTPUT_FORMAT_STATIC_TARGZ,
)


# =============================================================================
# The in-pod paths the in-pod executor probes — mirrored here so the write-command
# render test asserts against the EXACT path the `has_dockerfile` probe checks
# (kept in lock-step with the executor's IN_POD_* constants).
# =============================================================================
comptime _IN_POD_CONTEXT: String = "/tmp/komira-build/src"
comptime _IN_POD_DOCKERFILE: String = "/tmp/komira-build/src/Dockerfile"


# =============================================================================
# Test 1 — an output_format: IMAGE recipe WITH a dockerfile routes to KANIKO.
# =============================================================================
def test_image_dockerfile_routes_to_kaniko() raises:
    var route = resolve_build_route(OUTPUT_FORMAT_IMAGE, True)
    assert_equal(
        route,
        BUILD_ROUTE_KANIKO,
        "output_format: IMAGE + a dockerfile -> the kaniko arm",
    )


# =============================================================================
# Test 2 — an app-binary recipe (IMAGE output, NO dockerfile) routes to CRANE-APPEND.
# =============================================================================
def test_app_binary_routes_to_crane_append() raises:
    var route = resolve_build_route(OUTPUT_FORMAT_IMAGE, False)
    assert_equal(
        route,
        BUILD_ROUTE_CRANE_APPEND,
        "output_format: IMAGE with NO dockerfile (a plain app binary) -> crane-append",
    )


# =============================================================================
# Test 3 — LIBRARY_ARTIFACT + STATIC_TARGZ never route to kaniko (kaniko is ONLY
#   for a Dockerfile IMAGE recipe — the app-binary/library/static paths stay
#   crane-append/content: the app-binary path never needs a Dockerfile executor).
# =============================================================================
def test_non_image_never_routes_to_kaniko() raises:
    assert_false(
        resolve_build_route(OUTPUT_FORMAT_LIBRARY_ARTIFACT, True)
        == BUILD_ROUTE_KANIKO,
        "LIBRARY_ARTIFACT never routes to kaniko (kaniko is IMAGE-Dockerfile only)",
    )
    assert_false(
        resolve_build_route(OUTPUT_FORMAT_STATIC_TARGZ, True) == BUILD_ROUTE_KANIKO,
        "STATIC_TARGZ never routes to kaniko",
    )


# =============================================================================
# Test 4 — the kaniko-arm command render carries the FINITE, --no-push --tar-path
#   shape + `crane digest`, &&-gated (a failing step short-circuits before push).
# =============================================================================
def test_kaniko_command_shape() raises:
    var cmd = render_kaniko_image_command(
        String("apps/hello/Dockerfile"),
        String("apps/hello"),
        String("/tmp/build/image.tar"),
    )

    # the kaniko executor arm.
    assert_true(cmd.find(String("--dockerfile")) >= 0, "carries --dockerfile")
    assert_true(
        cmd.find(String("apps/hello/Dockerfile")) >= 0,
        "carries the Dockerfile path",
    )
    assert_true(cmd.find(String("--context")) >= 0, "carries --context")
    assert_true(
        cmd.find(String("apps/hello")) >= 0, "carries the build context",
    )

    # FINITE + local: --no-push (the pod does NOT push here; STAGE pushes by digest)
    # and --tar-path (produce a real OCI layout locally so crane digest can read it).
    assert_true(cmd.find(String("--no-push")) >= 0, "carries --no-push (FINITE)")
    assert_true(cmd.find(String("--tar-path")) >= 0, "carries --tar-path (local OCI)")
    assert_true(
        cmd.find(String("/tmp/build/image.tar")) >= 0,
        "carries the tarball output path",
    )

    # the digest read: `crane digest` off the tarball (a REAL manifest digest).
    assert_true(cmd.find(String("crane digest")) >= 0, "reads the digest via crane")

    # the &&-gate: a failing kaniko step short-circuits before `crane digest`
    # (the exit code IS the gate — no `;`/`||` masks a failure).
    assert_true(cmd.find(String("&&")) >= 0, "the steps are &&-gated (fail-closed)")
    assert_false(cmd.find(String("||")) >= 0, "no `||` masks a failure")

    # a served PORT env is NEVER emitted (a Cloud Run Job rejects it — FINITE).
    assert_false(
        cmd.find(String("PORT=")) >= 0, "no served PORT env (FINITE Job invariant)"
    )


# =============================================================================
# Test 5 — the kaniko flag is `--tar-path`, NOT `--tarball-path` (the exact-flag
#   falsifier).
#
# `--tarball-path` does NOT exist in kaniko v1.23.2 (the executor baked into the
# base image): kaniko rejects it with `Error: unknown flag: --tarball-path`, so a
# render that emitted it would be an UNRUNNABLE build command. The correct flag is
# `--tar-path` (`--tar-path string   Path to save the image in as a tarball
# instead of pushing`; the deprecated alias is `--tarPath`). The
# `assert_false(... "--tarball-path" ...)` below is the falsifier. The
# `crane digest --tarball` half is a real crane flag — hence the substring guard
# uses the "-path" suffix.
# =============================================================================
def test_kaniko_uses_tar_path_flag() raises:
    var cmd = render_kaniko_image_command(
        String("/df"), String("/ctx"), String("/out.tar")
    )

    # the corrected kaniko flag (v1.23.2): `--tar-path <out>`.
    assert_true(
        cmd.find(String("--tar-path /out.tar")) >= 0,
        "carries the correct kaniko flag `--tar-path /out.tar`",
    )

    # the falsifier: the buggy `--tarball-path` flag must NOT appear anywhere (it
    # is `unknown flag` to kaniko v1.23.2).
    assert_false(
        cmd.find(String("--tarball-path")) >= 0,
        "must NOT emit the nonexistent kaniko flag `--tarball-path`",
    )

    # the FINITE, offline shape is intact around the corrected flag.
    assert_true(cmd.find(String("--no-push")) >= 0, "carries --no-push (FINITE)")
    assert_true(
        cmd.find(String("crane digest --tarball /out.tar")) >= 0,
        "the crane digest read (crane's real --tarball flag) is unchanged",
    )


# =============================================================================
# Test 6 — the OPTIONAL functional test-gate: an `app_test` prefixes the kaniko
#   command with the baked `mojo_build_template.sh test <ctx>/<app_test> && ` so a
#   FAILING functional test short-circuits BEFORE `/kaniko/executor` (invariant (b)).
#
# THE GATE. A build must FAIL if its functional test fails. The rendered command
# prefixes `<template> test <ctx>/<file> && ` before the kaniko step so a non-zero
# test exit short-circuits the `&&` chain BEFORE kaniko builds anything (no digest).
# The test invocation is the BAKED template (`/opt/komira/bin/mojo_build_template.sh
# test <file>`), NOT a bare `mojo test` (which fails `unable to locate module 'std'`
# — the template threads `-I` + the vendored archives + MODULAR_HOME).
# =============================================================================
def test_kaniko_command_carries_test_gate() raises:
    var cmd = render_kaniko_image_command(
        String("/df"),
        String("/ctx"),
        String("/out.tar"),
        Optional[String](String("test_main.mojo")),
    )

    # the baked template test invocation, threaded with the context-relative test file.
    assert_true(
        cmd.find(String("/opt/komira/bin/mojo_build_template.sh test /ctx/test_main.mojo")) >= 0,
        "the test-gate invokes the baked template on <context>/<app_test>",
    )

    # the test-gate appears BEFORE `/kaniko/executor` (it runs first — the &&-gate
    # short-circuits the build if the functional test fails).
    var template_idx = cmd.find(String("/opt/komira/bin/mojo_build_template.sh"))
    var kaniko_idx = cmd.find(String("/kaniko/executor"))
    assert_true(template_idx >= 0, "the template invocation is present")
    assert_true(kaniko_idx >= 0, "the kaniko executor step is present")
    assert_true(
        template_idx < kaniko_idx,
        "the functional test-gate runs BEFORE /kaniko/executor (fail-closed)",
    )

    # the test-gate is `&&`-joined to the kaniko step (the template invocation is
    # followed by ` && ` — a failing test short-circuits before kaniko).
    assert_true(
        cmd.find(String("test /ctx/test_main.mojo && ")) >= 0,
        "the test-gate is &&-gated to the kaniko step (fail-closed)",
    )


# =============================================================================
# Test 7 — the test-gate is OPT-IN: the 3-arg render (NO app_test) emits NO
#   `mojo_build_template.sh` (byte-identical to today — the falsifier that the gate
#   never fires when there is no functional test to run).
# =============================================================================
def test_kaniko_command_no_test_gate_without_app_test() raises:
    var cmd = render_kaniko_image_command(
        String("/df"), String("/ctx"), String("/out.tar")
    )
    # NO test-gate when there is no app_test — the render is unchanged from today.
    assert_false(
        cmd.find(String("mojo_build_template.sh")) >= 0,
        "the 3-arg render (no app_test) emits NO test-gate (opt-in)",
    )
    # the kaniko step is still the FIRST token (no prefix).
    assert_equal(
        cmd.find(String("/kaniko/executor")),
        0,
        "without a test-gate, /kaniko/executor is the first token (unchanged)",
    )


# =============================================================================
# Test 8 — the NATIVE source-clone command render: the in-pod executor
#   fork-execs THIS command to populate the kaniko --context dir. Covers: remote -> git clone; the
#   local-dir `[ -d ]` branch present (cp -R); the pinned-commit checkout suffix
#   present IFF source_commit is Some.
# =============================================================================
def test_clone_command_render_local_and_remote() raises:
    # (a) a REMOTE git URL with NO pinned commit.
    var remote = render_clone_command(
        String("https://github.com/acme/hello-app.git"),
        Optional[String](),
        String("/tmp/komira-build"),
        String("/tmp/komira-build/src"),
    )

    # idempotent: rm -rf the context dir first, then mkdir -p the workspace.
    assert_true(
        remote.find(String("rm -rf /tmp/komira-build/src")) >= 0,
        "the clone removes the context dir first (idempotent)",
    )
    assert_true(
        remote.find(String("mkdir -p /tmp/komira-build")) >= 0,
        "the clone creates the workspace parent",
    )
    # the runtime local-vs-remote branch: a `[ -d ]` test + BOTH arms (cp -R / clone).
    assert_true(
        remote.find(String("[ -d ")) >= 0,
        "the clone has the runtime local-dir `[ -d ]` branch test",
    )
    assert_true(remote.find(String("cp -R")) >= 0, "the local-dir arm is cp -R")
    assert_true(
        remote.find(String("git clone --quiet")) >= 0,
        "the remote arm is git clone --quiet",
    )
    assert_true(
        remote.find(String("https://github.com/acme/hello-app.git")) >= 0,
        "the clone targets the source_ref",
    )
    assert_true(
        remote.find(String("/tmp/komira-build/src")) >= 0,
        "the clone targets the context_dir",
    )
    # the steps are &&-gated (a bad ref / clone error exits non-zero -> the caller raises).
    assert_true(
        remote.find(String("&&")) >= 0, "the clone steps are &&-gated (fail-loud)"
    )
    # NO pinned commit -> NO checkout suffix.
    assert_false(
        remote.find(String("checkout")) >= 0,
        "NO pinned commit -> NO `git checkout` suffix",
    )

    # (b) a REMOTE git URL WITH a pinned commit -> the checkout suffix IS present.
    var pinned = render_clone_command(
        String("https://github.com/acme/hello-app.git"),
        Optional[String](String("deadbeef01234567")),
        String("/tmp/komira-build"),
        String("/tmp/komira-build/src"),
    )
    assert_true(
        pinned.find(String("git -C /tmp/komira-build/src checkout --quiet")) >= 0,
        "a pinned source_commit -> a `git -C <ctx> checkout --quiet` suffix",
    )
    assert_true(
        pinned.find(String("deadbeef01234567")) >= 0,
        "the checkout pins the given commit SHA",
    )


# =============================================================================
# Test 9 — the BUILD render is PUSH-FREE even WITH a registry (the build/stage
#   split). The kaniko BUILD command MUST NOT emit `crane push` and MUST NOT resolve
#   a registry `crane digest <ref>` — it ends at the LOCAL `crane digest --tarball
#   <tar>`. The registry PUSH is the DISTINCT STAGE step (`render_stage_push_command`).
#
# THE BUG (the DNS failure this split fixes). kaniko, when it unpacks the Dockerfile
# base-image rootfs over the pod `/`, CLOBBERS /etc/resolv.conf (no nameserver). A
# `crane push` in the SAME `&&`-chain right after kaniko then has an empty resolv.conf
# -> the Go resolver falls back to loopback `[::1]:53` -> `connection refused`.
# Keeping the push OUT of the build chain (a) fixes that and
# (b) is the correct build->stage layering.
# =============================================================================
def test_kaniko_build_render_with_registry_is_push_free() raises:
    var cmd = render_kaniko_image_command(
        String("/tmp/komira-build/src/Dockerfile"),
        String("/tmp/komira-build/src"),
        String("/tmp/komira-build/image.tar"),
        Optional[String](),  # no app_test
        Optional[String](
            String("us-central1-docker.pkg.dev/example-project/example-repo")
        ),  # registry_url SET
        String("abc1234"),  # image_tag
        String("hello-app"),  # app_id
    )

    # THE LOAD-BEARING FALSIFIER: even WITH a registry, the BUILD render is push-free.
    assert_false(
        cmd.find(String("crane push")) >= 0,
        "the BUILD render emits NO `crane push` (the STAGE step pushes)",
    )
    # NO registry-marker echo in the build step (the STAGE step emits it).
    assert_false(
        cmd.find(String("PUSHED_IMAGE_DIGEST=")) >= 0,
        "the BUILD render emits NO PUSHED_IMAGE_DIGEST= marker (STAGE emits it)",
    )
    # The build step ends at the LOCAL tarball digest (no registry ref, no DNS).
    assert_true(
        cmd.find(String("crane digest --tarball /tmp/komira-build/image.tar")) >= 0,
        "the BUILD render ends at the LOCAL `crane digest --tarball <tar>`",
    )
    # NO registry `crane digest <ref>` (that resolves DNS — the split forbids it here).
    assert_false(
        cmd.find(String("crane digest us-central1")) >= 0,
        "the BUILD render does NOT resolve a registry `crane digest <ref>` (no DNS)",
    )
    # still &&-gated, no || mask, no served PORT.
    assert_true(cmd.find(String("&&")) >= 0, "the build steps are &&-gated")
    assert_false(cmd.find(String("||")) >= 0, "no `||` masks a failure")
    assert_false(cmd.find(String("PORT=")) >= 0, "no served PORT env (FINITE)")


# =============================================================================
# Test 10 — the DISTINCT STAGE-push render (`render_stage_push_command`): the local
#   tarball -> registry push WITH the resolv.conf DNS repair, the converged markers,
#   &&-gated with no `||` masking.
# =============================================================================
def test_stage_push_render_carries_dns_fix_and_markers() raises:
    var cmd = render_stage_push_command(
        String("/tmp/komira-build/image.tar"),  # tarball
        String("us-central1-docker.pkg.dev/example-project/example-repo"),  # registry_url
        String("abc1234"),  # image_tag
        String("hello-app"),  # app_id
    )

    # THE DNS FIX (the load-bearing falsifier): the stage push repairs a clobbered
    # /etc/resolv.conf by writing a valid metadata-DNS nameserver FIRST.
    assert_true(
        cmd.find(String("nameserver 169.254.169.254")) >= 0,
        "the stage push writes a valid nameserver (169.254.169.254 = GCP metadata DNS)",
    )
    assert_true(
        cmd.find(String("/etc/resolv.conf")) >= 0,
        "the stage push targets /etc/resolv.conf (the file kaniko clobbers)",
    )
    # IDEMPOTENT + NON-DESTRUCTIVE: only write if there is no nameserver already.
    assert_true(
        cmd.find(String("grep -q nameserver")) >= 0,
        "the DNS repair is guarded on an ABSENT nameserver (idempotent, non-destructive)",
    )
    # the DNS-repair step precedes the push.
    var dns_idx = cmd.find(String("resolv.conf"))
    var push_idx = cmd.find(String("crane push"))
    assert_true(dns_idx >= 0, "the DNS repair is present")
    assert_true(push_idx >= 0, "the crane push is present")
    assert_true(
        dns_idx < push_idx, "the DNS repair runs BEFORE the crane push (fixes the push)"
    )

    # the PUSH of the local tarball to the target `<repo>/<app>:<tag>`.
    assert_true(
        cmd.find(
            String(
                "crane push /tmp/komira-build/image.tar"
                " us-central1-docker.pkg.dev/example-project/example-repo/hello-app:abc1234"
            )
        )
        >= 0,
        "the stage push pushes the local tarball to <registry>/<app_id>:<image_tag>",
    )
    # the REAL registry digest marker (off the PUSHED manifest) + is_fake=0.
    assert_true(
        cmd.find(String("PUSHED_IMAGE_DIGEST=")) >= 0,
        "the stage push emits the converged PUSHED_IMAGE_DIGEST= marker",
    )
    assert_true(
        cmd.find(
            String(
                "crane digest"
                " us-central1-docker.pkg.dev/example-project/example-repo/hello-app:abc1234"
            )
        )
        >= 0,
        "the marker reads the PUSHED registry manifest digest (the real, pullable ref)",
    )
    assert_true(
        cmd.find(String("KOMIRA_BUILD_DIGEST_IS_FAKE=0")) >= 0,
        "the stage push stamps is_fake=0 (a real pushed OCI manifest)",
    )

    # &&-gated with no `||` masking the push (the `||` inside `sh -c '…'` is the DNS
    # repair's own fallback, INSIDE the child shell — the outer chain has none).
    assert_true(cmd.find(String("&&")) >= 0, "the stage-push steps are &&-gated")
    assert_false(
        cmd.find(String("|| crane")) >= 0,
        "no `||` masks the crane push (the only `||` is the DNS-repair fallback)",
    )


# =============================================================================
# Test 11 — the stage-push repo path shape: an EMPTY app_id degrades to the bare
#   registry_url (a single-image repo).
# =============================================================================
def test_stage_push_empty_app_id_degrades_to_bare_registry() raises:
    var cmd = render_stage_push_command(
        String("/out.tar"),
        String("us-central1-docker.pkg.dev/example-project/example-repo"),  # registry_url
        String("latest"),  # image_tag
        String(""),  # EMPTY app_id
    )
    # the push target is the bare registry_url:tag (no `/` app segment appended).
    assert_true(
        cmd.find(
            String(
                "crane push /out.tar us-central1-docker.pkg.dev/example-project/example-repo:latest"
            )
        )
        >= 0,
        "an empty app_id pushes to the bare <registry_url>:<tag> (single-image repo)",
    )


# =============================================================================
# Test 12 — the stage-push AUTHENTICATES the push: before
#   `crane push` the render MUST mint the pod's AMBIENT SA access token off the GCE/
#   Cloud Run metadata server and run `crane auth login <registry-host> -u
#   oauth2accesstoken -p <token>`.
#
# WHY. Without a prior `crane auth login`, a push from the minimal base image (NO
# gcloud, NO docker-credential-gcloud) finds no credential helper in crane's
# google-keychain fallback and is DENIED (`Unauthenticated request …
# artifactregistry.repositories.uploadArtifacts`) even though the pod's identity
# holds `artifactregistry.writer` (IAM is fine — the pod just never authenticated).
#
# THE SHAPE (the same as the build-flow script's push step): mint the token from the metadata
# server (`curl -H "Metadata-Flavor: Google" http://metadata.google.internal/…/token`,
# `sed`-parse the `access_token`) and `crane auth login <registry-host> -u
# oauth2accesstoken -p <token>` BEFORE the push — all &&-gated (fail-loud).
# =============================================================================
def test_stage_push_authenticates_before_push() raises:
    var cmd = render_stage_push_command(
        String("/tmp/komira-build/image.tar"),  # tarball
        String("us-central1-docker.pkg.dev/example-project/example-repo"),  # registry_url
        String("abc1234"),  # image_tag
        String("hello-app"),  # app_id
    )

    # THE FALSIFIER (a): the render mints the ambient SA token off the metadata server.
    assert_true(
        cmd.find(
            String(
                "curl -s -H 'Metadata-Flavor: Google'"
                " http://metadata.google.internal/computeMetadata/v1/instance/"
                "service-accounts/default/token"
            )
        )
        >= 0,
        "the stage push mints the ambient SA token off the GCE metadata server",
    )
    # the token is `sed`-parsed out of the metadata JSON `access_token`.
    assert_true(
        cmd.find(String("access_token")) >= 0,
        "the render parses the metadata `access_token` (never a Mojo/log value)",
    )

    # THE FALSIFIER (b): `crane auth login <registry-host> -u oauth2accesstoken` — the
    # host is the FIRST `/`-segment of registry_url (the `${REGISTRY_URL%%/*}` shape).
    assert_true(
        cmd.find(
            String(
                "crane auth login us-central1-docker.pkg.dev -u oauth2accesstoken -p"
            )
        )
        >= 0,
        "the stage push runs `crane auth login <registry-host> -u oauth2accesstoken`",
    )

    # ORDERING: the auth login precedes the push (an unauthenticated push is DENIED).
    var auth_idx = cmd.find(String("crane auth login"))
    var push_idx = cmd.find(String("crane push"))
    assert_true(auth_idx >= 0, "the crane auth login is present")
    assert_true(push_idx >= 0, "the crane push is present")
    assert_true(
        auth_idx < push_idx,
        "the `crane auth login` runs BEFORE `crane push` (authenticates the push)",
    )

    # the auth is &&-gated to the push (a failed mint/login short-circuits, no || mask).
    assert_true(
        cmd.find(String("&& crane auth login")) >= 0,
        "the auth step is &&-gated (fail-loud — a failed login short-circuits the push)",
    )


# =============================================================================
# Test 13 — the FROM-build WRITE-COMMAND render
#   (`render_from_dockerfile_write_command`): the in-pod executor fork-execs THIS
#   command to MATERIALIZE the `FROM <prebuilt image>` recipe on disk (the no-clone
#   twin of `render_clone_command`).
#
# THE HAZARD. If the FROM Dockerfile does not land at EXACTLY the path the
# executor's `path_exists(IN_POD_DOCKERFILE)` probe checks
# (IN_POD_DOCKERFILE = /tmp/komira-build/src/Dockerfile), `has_dockerfile` reads
# FALSE and the FROM-build mis-routes to BUILD_ROUTE_CRANE_APPEND (plain
# mojo-build), which then fails
# `mojo: error: cannot open input file '/tmp/komira-build/src/test_main.mojo'`.
# The write must (1)
# `mkdir -p` the context dir BEFORE the redirect (so it never fails on a fresh pod)
# and (2) redirect to EXACTLY IN_POD_DOCKERFILE with `FROM <ref>` content.
# =============================================================================
def test_from_dockerfile_write_command_targets_exact_dockerfile_path() raises:
    var cmd = render_from_dockerfile_write_command(
        String("us-central1-docker.pkg.dev/example-project/live/hello-app:latest"),
        _IN_POD_CONTEXT,
        _IN_POD_DOCKERFILE,
    )

    # (1) the context dir is created FIRST (mkdir -p BEFORE the redirect) — so the
    # redirect never fails `No such file or directory` on a fresh pod.
    var mkdir_idx = cmd.find(String("mkdir -p ") + _IN_POD_CONTEXT)
    assert_true(
        mkdir_idx >= 0,
        "the write mkdir -p's the context dir (/tmp/komira-build/src) first",
    )

    # (2) THE LOAD-BEARING FALSIFIER: the redirect targets EXACTLY IN_POD_DOCKERFILE
    # — the same path the `has_dockerfile` probe checks. A miss here mis-routes the build.
    var redirect = String("' > ") + _IN_POD_DOCKERFILE
    var redirect_idx = cmd.find(redirect)
    assert_true(
        redirect_idx >= 0,
        (
            "the write redirects to EXACTLY IN_POD_DOCKERFILE"
            " (/tmp/komira-build/src/Dockerfile) — the path has_dockerfile checks"
        ),
    )

    # the mkdir precedes the redirect (create the dir, THEN write into it).
    assert_true(
        mkdir_idx < redirect_idx,
        "the mkdir -p runs BEFORE the redirect (so the write never fails on a fresh pod)",
    )

    # the recipe content is `FROM <ref>` (the pure render — the single source of truth).
    assert_true(
        cmd.find(
            String("FROM us-central1-docker.pkg.dev/example-project/live/hello-app:latest")
        )
        >= 0,
        "the write carries the `FROM <prebuilt image>` recipe content",
    )
    # the content matches render_from_dockerfile verbatim (one source of truth).
    assert_true(
        cmd.find(
            render_from_dockerfile(
                String("us-central1-docker.pkg.dev/example-project/live/hello-app:latest")
            )
        )
        >= 0,
        "the write content is exactly render_from_dockerfile(base_ref)",
    )

    # idempotent: rm -rf the context dir first (a re-run never fails on a stale dir).
    assert_true(
        cmd.find(String("rm -rf ") + _IN_POD_CONTEXT) >= 0,
        "the write removes the context dir first (idempotent)",
    )

    # &&-gated (fail-loud): a failed mkdir/write exits non-zero -> the caller raises.
    assert_true(
        cmd.find(String("&&")) >= 0, "the write steps are &&-gated (fail-loud)"
    )
    assert_false(cmd.find(String("||")) >= 0, "no `||` masks a failure")

    # NO clone — a FROM-build has no source to clone.
    assert_false(
        cmd.find(String("git clone")) >= 0,
        "the FROM-build write does NOT clone (the app is a prebuilt image)",
    )


# =============================================================================
# Test 14 — the FROM-build write ENABLES the kaniko route: after the write lands a
#   Dockerfile at IN_POD_DOCKERFILE, has_dockerfile is True, so an IMAGE recipe
#   routes to BUILD_ROUTE_KANIKO (NOT crane-append). This ties the write render
#   (Test 13) to the route resolver end-to-end.
#
# THE ROUTING HALF. With has_dockerfile=False (a write mis-target), an IMAGE
# recipe falls through `resolve_build_route` to BUILD_ROUTE_CRANE_APPEND (plain
# mojo-build) — the wrong arm. A correct write guarantees has_dockerfile=True, so
# the IMAGE recipe routes to KANIKO.
# =============================================================================
def test_from_build_routes_to_kaniko_not_crane_append() raises:
    # PRE-write (empty context dir): has_dockerfile is False -> crane-append (the
    # WRONG arm — what a mis-targeted write produces).
    assert_equal(
        resolve_build_route(OUTPUT_FORMAT_IMAGE, False),
        BUILD_ROUTE_CRANE_APPEND,
        "with NO Dockerfile present, an IMAGE recipe routes to crane-append",
    )
    # POST-write (the write landed a Dockerfile at IN_POD_DOCKERFILE): has_dockerfile
    # is True -> KANIKO (the RIGHT arm — the FROM-build re-homes the prebuilt image).
    assert_equal(
        resolve_build_route(OUTPUT_FORMAT_IMAGE, True),
        BUILD_ROUTE_KANIKO,
        (
            "with the FROM Dockerfile present at IN_POD_DOCKERFILE, the IMAGE recipe"
            " routes to KANIKO (NOT crane-append)"
        ),
    )


def main() raises:
    test_image_dockerfile_routes_to_kaniko()
    test_app_binary_routes_to_crane_append()
    test_non_image_never_routes_to_kaniko()
    test_kaniko_command_shape()
    test_kaniko_uses_tar_path_flag()
    test_kaniko_command_carries_test_gate()
    test_kaniko_command_no_test_gate_without_app_test()
    test_clone_command_render_local_and_remote()
    test_kaniko_build_render_with_registry_is_push_free()
    test_stage_push_render_carries_dns_fix_and_markers()
    test_stage_push_empty_app_id_degrades_to_bare_registry()
    test_stage_push_authenticates_before_push()
    test_from_dockerfile_write_command_targets_exact_dockerfile_path()
    test_from_build_routes_to_kaniko_not_crane_append()
    print("PASS test_kaniko_image_recipe_routing")
