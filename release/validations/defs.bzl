"""`kci_validations`: one runnable target per validation of the release machine file.

`./buck2 run //release/validations:<name> -- --release-dir <R> --revision-id <C>
[--channel file:///<dir>] [--scratch-dir <abs>] [--plan] [--result-file <f>]`
runs exactly

    kci run --stage <stage> --only validation:<name>
        --machine <abs path of release/machine.textproto>
        --pixi <the pinned pixi of the target platform's row>
        --pixi-sha256 <that row's pixi sha256>
        --preflight-image <that row's pre-flight helper image>
        <the arguments after `--`>

with kci and pixi built by this repository, from the repository's root (the
machine file's relative paths are relative to the directory kci starts in, and
a scratch directory inside the checkout is refused), whatever directory
`buck2 run` is started in. It adds no verb: the validation that runs is the
code kci.yml's `validate` job runs, and src/kci_workflow_check's test_repo_kci_yml
holds that job's `kci run` to these arguments. When the arguments name no
`--scratch-dir`, a fresh one is made under the system temp directory; no
`--run-id` means `local`, no `--attempt` means `1`.

`kci_validations` is the only way to declare one: it also declares `:names`,
which lists every validation target of the package with its stage and its
argument list, so src/kci_release_machine's welded test can hold the targets
equal to the machine file's validations both ways.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:table.bzl", "pinned_kwargs", "preflight_image", "registered_names", "row")

# Placeholders of the `:names` record for the arguments that differ by the
# machine that runs the target: paths, and the pin of its platform's row.
_KCI = "<kci>"
_MACHINE = "<machine>"
_PIXI = "<pixi>"
_PIXI_SHA256 = "<pixi-sha256>"  # the target platform row's pin: a Mac's differs
_PREFLIGHT_IMAGE = "<preflight-image>"  # the target platform row's helper image (a DEPLOY_PROBE's pre-flight)

# From the repository's root ($1): a scratch directory, a run id and an
# attempt when the caller gave none, then the kci command.
_LAUNCHER = """#!/bin/sh
set -eu
cd "$1"
shift
scratch= run_id= attempt=
for a in "$@"; do
    case $a in
        --scratch-dir|--scratch-dir=*) scratch=1 ;;
        --run-id|--run-id=*) run_id=1 ;;
        --attempt|--attempt=*) attempt=1 ;;
    esac
done
[ -n "$run_id" ] || set -- "$@" --run-id local
[ -n "$attempt" ] || set -- "$@" --attempt 1
[ -n "$scratch" ] || set -- "$@" --scratch-dir "$(mktemp -d)"
exec "$@"
"""

def _argv(stage, name, sha256, preflight):
    return [
        "run",
        "--stage",
        stage,
        "--only",
        "validation:" + name,
        "--machine",
        _MACHINE,
        "--pixi",
        _PIXI,
        "--pixi-sha256",
        sha256,
        "--preflight-image",
        preflight,
    ]

def _validation_impl(ctx):
    argv = _argv(ctx.attrs.stage, ctx.label.name, ctx.attrs.pixi_sha256, ctx.attrs.preflight_image)
    paths = {
        _MACHINE: ctx.attrs.machine,
        _PIXI: ctx.attrs.pixi[DefaultInfo].default_outputs[0],
    }
    launcher = ctx.actions.write(ctx.label.name + ".sh", _LAUNCHER, is_executable = True)
    command = cmd_args(
        launcher,
        cmd_args(ctx.attrs.root_file, parent = ctx.attrs.root_parents),
        ctx.attrs.kci[RunInfo],
        [paths.get(a, a) for a in argv],
        hidden = [ctx.attrs.machine],
    )
    return [
        DefaultInfo(default_output = launcher),
        RunInfo(args = command),
    ]

_kci_validation = rule(
    impl = _validation_impl,
    doc = "`kci run --stage <stage> --only validation:<name>` with the pinned pixi, from the repository root.",
    attrs = {
        "kci": attrs.dep(providers = [RunInfo]),
        "machine": attrs.source(),
        "pixi": attrs.dep(),
        "pixi_sha256": attrs.string(),
        "preflight_image": attrs.string(),
        # A source file of this package, and how many directories up from it
        # the repository's root is (a path on the machine `buck2 run` runs on).
        "root_file": attrs.source(),
        "root_parents": attrs.int(),
        "stage": attrs.string(),
    },
)

# The record is written from the same `_argv` the targets run, and depends on
# none of them: kci's own libraries read it in their welded tests, and kci is
# what the targets run.
def _names_impl(ctx):
    lines = []
    for name, stage in ctx.attrs.validations.items():
        lines.append(" ".join([name, stage, _KCI] + _argv(stage, name, _PIXI_SHA256, _PREFLIGHT_IMAGE)))
    out = ctx.actions.write(ctx.label.name + ".txt", "".join([l + "\n" for l in sorted(lines)]))
    return [DefaultInfo(default_output = out)]

_kci_validation_names = rule(
    impl = _names_impl,
    doc = "One line per validation target: `<name> <stage> <kci> <argv...>`, sorted; paths as placeholders.",
    attrs = {"validations": attrs.dict(attrs.string(), attrs.string())},
)

def _pixi_sha256_by_target_os():
    out = {}
    for n in registered_names():
        out["prelude//os/constraints:" + row(n)["os"]] = pinned_kwargs(n, "pixi")["sha256"]
    return select(out)

def _preflight_image_by_target_os():
    # The table's UNPINNED_IMAGE for a row with no recorded image: kci refuses it for any DEPLOY_PROBE.
    out = {}
    for n in registered_names():
        out["prelude//os/constraints:" + row(n)["os"]] = preflight_image(n)
    return select(out)

def _kci_validations(validations, visibility = None):
    """One runnable target per entry of `validations` ({name: stage}), and `:names`."""
    for name, stage in validations.items():
        _kci_validation(
            name = name,
            stage = stage,
            kci = "komira//bin/kci:kci",
            machine = "komira//release:machine.textproto",
            pixi = "komira//tools/build/toolchains:pixi",
            pixi_sha256 = _pixi_sha256_by_target_os(),
            preflight_image = _preflight_image_by_target_os(),
            root_file = "BUCK",
            root_parents = len(package_name().split("/")) + 1,
            visibility = visibility,
        )
    _kci_validation_names(
        name = "names",
        validations = validations,
        visibility = ["komira//src/kci_workflow_check:", "komira//src/kci_release_machine:"],
    )

kci_validations = declares_docs(_kci_validations)
