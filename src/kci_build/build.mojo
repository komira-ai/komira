# =============================================================================
# src/kci_build/build.mojo -- one build per declared artifact, each into its
#   own empty directory, then `release.json` last.
# =============================================================================
#
# 1. Read the declarations (kci_artifact_declaration validates them).
#    Refuse a `--work-dir` that is not a directory and a `--out-dir` that is
#    not absent or empty, before anything runs.
# 2. For each artifact, in declarations-file order, one at a time:
#      a. create `<out>/<name>/` (empty by construction: `<out>` was empty
#         and declaration names are unique);
#      b. run `render_build_argv(decls, name, <out>/<name>)` through the
#         `ProcessRunner`, cwd `--work-dir`, stdout and stderr to
#         `<log>/<name>.stdout|.stderr`, timeout `--build-timeout-s`;
#      c. a non-zero exit, a signal or a timeout is FAILED, naming the
#         artifact, the command line and the end of stderr; a build that
#         cannot be started is CANNOT_TELL; either way, stop;
#      d. `kci_release_set.verify_member(name, <out>/<name>)`: REFUSED on
#         any refusal; stop.
# 3. Only when every artifact passed: compute the set hash and write
#    `<out>/release.json` LAST. It is the commit marker: a run that stopped
#    leaves member directories and no `release.json`, and `kci publish`
#    refuses a directory without one.
#
# Sequential, not concurrent: one buck2 daemon serves one repository and
# blocks a second command with different args, so concurrency buys nothing
# for buck2 and is a hazard for a build system kci does not know. The farm
# still parallelises inside each build. Nothing here retries: a re-run is
# cheap (the cache) and the empty-out-dir rule makes it safe.
#
# kci knows no build tool. "Never build locally" is the declarations' to
# say (buck2's `-c komira.execution=remote` and the farm `--config-file` are
# build-system args there), never a kci flag.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, makedirs
from std.os.path import exists, isdir, realpath

from kci_artifact_declaration import read_artifact_declarations, render_build_argv
from kci_release_set import (
    RELEASE_MANIFEST_NAME,
    ReleaseMember,
    release_manifest_of,
    render_release_manifest,
    verify_member,
)

from kci_build.request import (
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    BuildOutcome,
    BuildRequest,
)
from kci_build.runner import ProcessRunner, RunResult, RunSpec


def _refused(why: String) -> BuildOutcome:
    return BuildOutcome(EXIT_REFUSED, String("kci build: ") + why)


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def check_out_dir(out_dir: String) raises -> BuildOutcome:
    """REFUSED unless `out_dir` is absent or an empty directory."""
    if not exists(out_dir):
        return BuildOutcome(EXIT_OK, String(""))
    if not isdir(out_dir):
        return _refused(String("--out-dir '") + out_dir + String("' is not a directory"))
    if len(listdir(out_dir)) > 0:
        return _refused(
            String("--out-dir '")
            + out_dir
            + String("' is not empty: it becomes the release directory, and a file from an")
            + String(" earlier run could ride along")
        )
    return BuildOutcome(EXIT_OK, String(""))


def _failure(name: String, spec: RunSpec, r: RunResult) -> BuildOutcome:
    var why = (
        String("kci build: artifact '")
        + name
        + String("': `")
        + spec.command_line()
        + String("` ")
        + r.describe()
        + String(" (stderr: ")
        + spec.stderr_path
        + String(")")
    )
    if r.stderr_tail.byte_length() > 0:
        why += String("\n") + r.stderr_tail
    return BuildOutcome(EXIT_FAILED, why^)


def _member_line(m: ReleaseMember) -> String:
    return (
        m.manifest.name
        + String("  ")
        + m.manifest.version
        + String("  ")
        + m.build()
        + String("  ")
        + m.manifest.sha256_hex
    )


def build_release[R: ProcessRunner](req: BuildRequest, mut runner: R) -> BuildOutcome:
    """Build every declared artifact (file header)."""
    try:
        var decls = read_artifact_declarations(req.declarations_file)
        if not isdir(req.work_dir):
            return _refused(String("--work-dir '") + req.work_dir + String("' is not a directory"))
        var gate = check_out_dir(req.out_dir)
        if not gate.ok():
            return gate^
        makedirs(req.out_dir, exist_ok=True)
        makedirs(req.log_dir, exist_ok=True)
        var out = realpath(req.out_dir)
        var members = List[ReleaseMember]()
        for i in range(len(decls.artifacts)):
            var name = decls.artifacts[i].name.copy()
            var dir = out + String("/") + name
            makedirs(dir, exist_ok=False)
            var argv = render_build_argv(decls, name, dir)
            var rest = List[String]()
            for k in range(1, len(argv)):
                rest.append(argv[k].copy())
            var spec = RunSpec(
                argv[0].copy(),
                rest^,
                req.work_dir.copy(),
                req.build_timeout_s,
                req.log_dir + String("/") + name + String(".stdout"),
                req.log_dir + String("/") + name + String(".stderr"),
            )
            print(String("kci build: building ") + name + String(": ") + spec.command_line())
            var r: RunResult
            try:
                r = runner.run(spec)
            except e:
                return BuildOutcome(
                    EXIT_CANNOT_TELL,
                    String("kci build: artifact '")
                    + name
                    + String("': the build could not be started: ")
                    + String(e),
                )
            if not r.ok():
                return _failure(name, spec, r)
            try:
                members.append(verify_member(name, dir))
            except e:
                return _refused(String(e))
        var release = release_manifest_of(members)
        var text = render_release_manifest(release)
        _write(out + String("/") + String(RELEASE_MANIFEST_NAME), text)
        var outcome = BuildOutcome(
            EXIT_OK,
            String("kci build: ")
            + String(len(members))
            + String(" artifact(s) built and verified into ")
            + out,
        )
        for i in range(len(members)):
            outcome.lines.append(_member_line(members[i]))
        outcome.lines.append(String("SET_HASH ") + release.set_hash)
        outcome.set_hash = release.set_hash.copy()
        return outcome^
    except e:
        return _refused(String(e))
