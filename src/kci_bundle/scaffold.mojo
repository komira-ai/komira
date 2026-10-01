# =============================================================================
# kci_bundle/scaffold.mojo — the per-kind package baseline emitter.
# =============================================================================
#
# `scaffold_bundle(kind, name, intent) -> Dict[relpath, content]` — the ONE
# library function behind every scaffold frontend (a tool call or a CLI verb):
# one library function, many frontends. It lays down the WHOLE buildable package
# per kind, not just the manifest: the `komira.deploy.textproto` intent bundle, a
# pinned `pixi.toml` (the toolchain pin), a build-file skeleton, `Dockerfile` +
# `Dockerfile.integ`, and `tests/unit/` + `tests/integ/` stubs. Named tenet: THE
# PIPELINE RUNS
# THE EXACT COMMANDS A DEVELOPER RUNS LOCALLY — the scaffolded `build`/`test`
# tasks ARE the pipeline's BUILD/validate commands.
#
# The API kind is the rich template (the orders-api shape: two builds,
# a from_build image, three waves incl. a gamma run_container gated on
# GATE_ON_EXIT_CODE with a VALUE_FROM_DEPLOY_URL TARGET_URL); the other three
# kinds get a minimal-but-VALID bundle. Every emitted `komira.deploy.textproto`
# PARSES + VALIDATES clean (the scaffold-clean gate) — the image uses a
# `from_build` reference to a real build target, and `<REQUIRED: ...>` author-
# guidance lives in `#` comments (a placeholder value would fail the parse the
# scaffold's own output must pass).
#
# ENCAPSULATION: pure String templating into a `Dict[String, String]`. No
# pointer, no wildcard origin. Mojo 1.0.0b2.
# =============================================================================

from std.collections.dict import Dict

from kci_bundle.emit import quote


# ─── kind normalization ──────────────────────────────────────────────────────
def normalize_kind(k: String) raises -> StaticString:
    """Map a flexible kind token (`api` / `API` / `APP_KIND_API`) to the canonical
    full proto value name. Raises a precise, listing error on an unknown kind."""
    var u = k.upper()
    # tolerate the full prefix (byte-copy the suffix — no String slicing).
    var suffix = u
    var pfx = String("APP_KIND_")
    if u.startswith(pfx):
        var ub = u.as_bytes()
        var s = String("")
        for i in range(pfx.byte_length(), len(ub)):
            s += chr(Int(ub[i]))
        suffix = s^
    if suffix == String("API"):
        return "APP_KIND_API"
    if (
        suffix == String("STATIC_FRONTEND")
        or suffix == String("STATIC")
        or suffix == String("FRONTEND")
    ):
        return "APP_KIND_STATIC_FRONTEND"
    if (
        suffix == String("DATA_PIPELINE")
        or suffix == String("DATA")
        or suffix == String("PIPELINE")
    ):
        return "APP_KIND_DATA_PIPELINE"
    if (
        suffix == String("SEARCH_CLUSTER")
        or suffix == String("SEARCH")
        or suffix == String("CLUSTER")
    ):
        return "APP_KIND_SEARCH_CLUSTER"
    raise Error(
        String("unknown kind '")
        + k
        + String(
            "' (one of: api | static_frontend | data_pipeline | search_cluster)"
        )
    )


def _intent_line(intent: String) -> String:
    if intent.byte_length() == 0:
        return String("")
    return String(": ") + intent


# ─── the intent-bundle templates ─────────────────────────────────────────────
def _deploy_textproto_api(name: String, intent: String) -> String:
    """The rich API-kind bundle (the orders-api shape). Parses +
    validates clean; `<REQUIRED: ...>` guidance is in comments."""
    var q = quote(name)
    return (
        String("# komira.deploy.textproto — ")
        + name
        + _intent_line(intent)
        + String("\n")
        + String(
            "# Authored intent bundle (Deploy + CI/CD Standard). Edit the fields"
            " marked\n"
            "# <REQUIRED: ...>, then run the bundle validator.\n"
            "kind: APP_KIND_API\n"
        )
        + String("name: ")
        + q
        + String("\n\n")
        + String(
            'build {\n'
            '  name: "service"\n'
            '  dockerfile: "Dockerfile"\n'
            "}\n"
            'build {\n'
            '  name: "integ_tests"\n'
            '  dockerfile: "Dockerfile.integ"\n'
            "}\n\n"
            "spec {\n"
            "  # The BUILD wave produces this image from the \"service\" build"
            " target.\n"
            "  # BYO alternative (a pre-published image): replace the block with\n"
            '  #   image { digest: "<REQUIRED: sha256:...>" }   # and drop the'
            ' "service" build\n'
            "  image {\n"
            '    from_build: "service"\n'
            "  }\n"
            "  port: 8080                       # <REQUIRED: your service's listen"
            " port>\n"
            "  env {\n"
            '    name: "LOG_LEVEL"\n'
            '    value: "info"\n'
            "  }\n"
            "  scaling {\n"
            "    min: 0\n"
            "    max: 10\n"
            "  }\n"
            "  compute: COMPUTE_INTENT_SERVERLESS\n"
            "  datastore: DATASTORE_NEED_NONE\n"
            "}\n\n"
            "waves {\n"
            '  env: "dev"\n'
            "  validate {\n"
            '    name: "up"\n'
            "    http_check {\n"
            "      # NOT /healthz — Google's serverless edge answers that EXACT path\n"
            "      # with its own 404 before the request reaches your container, so a\n"
            "      # gate on it can never pass. Serve /healthz for the Cloud Run\n"
            "      # startup probe (that prober bypasses the edge) and probe /readyz\n"
            "      # from here. The bundle validator rejects the reserved path.\n"
            '      path: "/readyz"              # <REQUIRED: your readiness endpoint>\n'
            "      expect_status: 200\n"
            "      # OPTIONAL — a wall-clock budget for this probe, in ms. Omit it\n"
            "      # and latency is NOT checked (the default): a correct status\n"
            "      # arriving 20 s late still PASSES, so a large latency\n"
            "      # regression rides through this gate reported as healthy.\n"
            "      # Uncomment and set it from YOUR route's measured p99 — a\n"
            "      # guessed number that reds a healthy deploy gets deleted.\n"
            "      # max_latency_ms: 3000\n"
            "    }\n"
            "  }\n"
            "}\n"
            "waves {\n"
            '  env: "gamma"\n'
            "  validate {\n"
            '    name: "integ"\n'
            "    run_container {\n"
            "      image {\n"
            '        from_build: "integ_tests"\n'
            "      }\n"
            "      gate_on: GATE_ON_EXIT_CODE\n"
            "      env {\n"
            '        name: "TARGET_URL"\n'
            "        value_from: VALUE_FROM_DEPLOY_URL\n"
            "      }\n"
            "    }\n"
            "  }\n"
            "}\n"
            "waves {\n"
            '  env: "prod"\n'
            "}\n"
        )
    )


def _deploy_textproto_minimal(
    kind_value: String, name: String, intent: String
) -> String:
    """A minimal-but-VALID bundle for the non-API kinds: kind + name + one build +
    a from_build image + a single dev wave. Parses + validates clean."""
    var q = quote(name)
    return (
        String("# komira.deploy.textproto — ")
        + name
        + _intent_line(intent)
        + String("\n")
        + String(
            "# Authored intent bundle (Deploy + CI/CD Standard). Edit the fields"
            " marked\n"
            "# <REQUIRED: ...>, then run the bundle validator.\n"
            "kind: "
        )
        + kind_value
        + String("\n")
        + String("name: ")
        + q
        + String("\n\n")
        + String(
            'build {\n'
            '  name: "service"\n'
            '  dockerfile: "Dockerfile"\n'
            "}\n\n"
            "spec {\n"
            "  image {\n"
            '    from_build: "service"\n'
            "  }\n"
            "  port: 8080                       # <REQUIRED: your service's listen"
            " port, or remove>\n"
            "}\n\n"
            "waves {\n"
            '  env: "dev"\n'
            "}\n"
        )
    )


# ─── the ancillary package-baseline files ────────────────────────────────────
# ⛔ THE `mojo = "==<v>"` LINE BELOW IS A COUPLING TO THE REPOSITORY'S MOJO PIN,
# NOT A CONSTANT. It is written into the pixi.toml of EVERY scaffolded project,
# and its own neighbouring comment says it mirrors the toolchain pin — so when it
# drifts, the file says the opposite of what it does, in a file we hand to
# somebody else. WHEN THE REPOSITORY'S MOJO PIN MOVES, THIS MOVES IN THE SAME
# COMMIT. The scaffold test asserts the `==` shape, not the frozen value, so a
# test cannot pin the stale answer.
def _pixi_toml(name: String) -> String:
    return (
        String("[project]\n")
        + String('name = "')
        + name
        + String('"\n')
        + String(
            'channels = ["https://conda.modular.com/max-nightly", "conda-forge"]\n'
            'platforms = ["osx-arm64", "linux-64", "linux-aarch64"]\n'
            'version = "0.1.0"\n'
            "\n"
            "[dependencies]\n"
            "# Pinned toolchain — mirrors the toolchain pin. Do NOT drift"
            " (a\n"
            "# .mojoc is compiler-build-hash locked).\n"
            'mojo = "==1.0.0"\n'
            "\n"
            "[tasks]\n"
            "# THE PIPELINE RUNS THE EXACT COMMANDS A DEVELOPER RUNS LOCALLY:\n"
            "# `bazel test //...` locally IS the BUILD step's command; unit tests"
            " ride\n"
            "# inside BUILD, so the exit code is the gate.\n"
            'build = { cmd = "bazel build //...", description = "Build the service'
            ' (unit tests ride inside BUILD)." }\n'
            'test = { cmd = "bazel test //... --test_size_filters=small,medium",'
            ' description = "Run unit tests." }\n'
        )
    )


def _build_bazel(name: String) -> String:
    return (
        String("# BUILD.bazel — ")
        + name
        + String(
            " package skeleton (scaffolded by the bundle scaffolder).\n"
            "# The BUILD step's command is the exact `bazel test //...` a"
            " developer runs\n"
            "# locally — unit tests ride inside BUILD, so the exit code"
            " is the\n"
            "# gate. There is no pipeline-only behavior.\n"
            'package(default_visibility = ["//visibility:public"])\n'
            "\n"
            "# TODO(<REQUIRED>): declare your service's build + unit-test"
            " target(s) here.\n"
            "# The `service` build target's Dockerfile output is the image the\n"
            '# spec `image { from_build: "service" }` resolves to.\n'
        )
    )


def _module_bazel(name: String) -> String:
    return (
        String("# MODULE.bazel — ")
        + name
        + String(
            " (bzlmod). Scaffolded by the bundle scaffolder.\n"
            'module(name = "'
        )
        + name
        + String(
            '", version = "0.1.0")\n'
            "\n"
            "# TODO(<REQUIRED>): add your bazel_dep(...) declarations.\n"
            '# bazel_dep(name = "rules_docker", version = "...")\n'
        )
    )


def _dockerfile(name: String) -> String:
    return (
        String("# Dockerfile — the \"service\" build target for ")
        + name
        + String(
            ".\n"
            "# Its output image is the digest the spec's"
            ' `image { from_build: "service" }`\n'
            "# resolves to at synth.\n"
            "FROM alpine:3.20            # <REQUIRED: set your service base image>\n"
            "# TODO(<REQUIRED>): COPY your compiled service + assets, set the"
            " entrypoint.\n"
            "# COPY ./build/service /service\n"
            "# EXPOSE 8080\n"
            '# ENTRYPOINT ["/service"]\n'
        )
    )


def _dockerfile_integ(name: String) -> String:
    return (
        String("# Dockerfile.integ — the \"integ_tests\" build target.\n")
        + String(
            "# Its entrypoint runs the integration tests against $TARGET_URL"
            " (injected by\n"
            "# the gamma wave's run_container as VALUE_FROM_DEPLOY_URL) and EXITS"
            " 0 on pass /\n"
            '# non-zero on fail — "your command exits 0" is the whole contract.\n'
            "FROM alpine:3.20\n"
            "RUN apk add --no-cache bash curl\n"
            "COPY tests/integ /tests/integ\n"
            'ENTRYPOINT ["/tests/integ/test_integ.sh"]\n'
        )
    )


def _test_unit_stub(name: String) -> String:
    return (
        String("#!/usr/bin/env bash\n")
        + String(
            "# Unit test stub (rides inside BUILD; the exit code is the gate).\n"
            "# THE PIPELINE RUNS THE EXACT COMMAND YOU RUN LOCALLY.\n"
            "set -euo pipefail\n"
            'echo "TODO(<REQUIRED>): add unit tests for '
        )
        + name
        + String('"\n')
        + String("exit 0\n")
    )


def _test_integ_stub(name: String) -> String:
    return (
        String("#!/usr/bin/env bash\n")
        + String(
            "# Integration test stub — runs against the DEPLOYED service."
            " $TARGET_URL is\n"
            "# injected by the gamma wave (VALUE_FROM_DEPLOY_URL). Exit 0 = pass"
            " (promotes),\n"
            "# non-zero = fail (blocks promotion).\n"
            "set -euo pipefail\n"
            ': "${TARGET_URL:?TARGET_URL must be set (injected as'
            ' VALUE_FROM_DEPLOY_URL)}"\n'
            'echo "TODO(<REQUIRED>): run integration tests against ${TARGET_URL}"\n'
            '# Example: curl -fsS "${TARGET_URL}/healthz"\n'
            "exit 0\n"
        )
    )


# ─── the entry point ─────────────────────────────────────────────────────────
def scaffold_bundle(
    kind: String, name: String, intent: String
) raises -> Dict[String, String]:
    """Emit the full package baseline for a new deploy bundle of `kind`, named
    `name`, with a free-text `intent` (goes into the bundle's header comment).
    Returns a map of relative-path -> file-content. The API kind gets the rich
    template; the other three kinds get a minimal-but-valid bundle.
    Raises on an unknown `kind`."""
    var kv = normalize_kind(kind)

    var files = Dict[String, String]()
    if kv == String("APP_KIND_API"):
        files[String("komira.deploy.textproto")] = _deploy_textproto_api(
            name, intent
        )
    else:
        files[String("komira.deploy.textproto")] = _deploy_textproto_minimal(
            kv, name, intent
        )
    files[String("pixi.toml")] = _pixi_toml(name)
    files[String("BUILD.bazel")] = _build_bazel(name)
    files[String("MODULE.bazel")] = _module_bazel(name)
    files[String("Dockerfile")] = _dockerfile(name)
    files[String("Dockerfile.integ")] = _dockerfile_integ(name)
    files[String("tests/unit/test_smoke.sh")] = _test_unit_stub(name)
    files[String("tests/integ/test_integ.sh")] = _test_integ_stub(name)
    return files^
