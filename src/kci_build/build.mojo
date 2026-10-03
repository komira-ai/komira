# =============================================================================
# src/kci_build/build.mojo -- one build per declared artifact, each into its
#   own empty directory, then `release.json` last.
# =============================================================================
#
# 1. Read the declarations (kci_artifact_declaration validates them).
#    Refuse a `--work-dir` that is not a directory, a `--out-dir` that is
#    not absent or empty, and a `--log-dir` that IS `--out-dir` or lies under
#    it (both compared absolute, `.`/`..` folded and every existing prefix
#    resolved through its symlinks), before anything runs: the out dir becomes
#    the release directory, and a log there is an entry no declaration names.
# 2. Derive the release stamp from git at `--revision-id`
#    (revision.mojo, through the `git` runner): refused for a shallow
#    clone, a HEAD that is not the revision, or modified tracked files,
#    before any build runs.
# 3. For each artifact, in declarations-file order, one at a time (the order
#    is the contract's: a metapackage declared last reads, under
#    `{release_dir}`, the manifests of every artifact above it, each already
#    built and verified):
#      a. create `<out>/<name>/` (empty by construction: `<out>` was empty
#         and declaration names are unique);
#      b. run `render_build_argv(decls, name, <out>, stamp)` (`{out_dir}` is
#         `<out>/<name>`, `{release_dir}` is `<out>`) through the
#         `ProcessRunner`, cwd `--work-dir`, stdout and stderr to
#         `<log>/<name>.stdout|.stderr`, timeout `--build-timeout-s`;
#      c. a non-zero exit, a signal or a timeout is FAILED, naming the
#         artifact, the command line and the end of stderr; a build that
#         cannot be started is CANNOT_TELL; either way, stop;
#      d. `kci_release_set.verify_member(name, <out>/<name>)`: REFUSED on
#         any refusal; stop.
# 4. Only when every artifact passed, and before `release.json`:
#      a. `<out>` must hold exactly the declared member directories: a build
#         that wrote a sibling of its own out dir (it is handed an absolute
#         path) is REFUSED, naming the entry;
#      b. `verify_member` runs again over every member, and a member whose
#         name, version, build or sha256 changed since its own check (a later
#         build wrote into it) is REFUSED. The set hash is computed from this
#         second pass, i.e. from the bytes that stay on disk.
#    Then compute the set hash and write `<out>/release.json` LAST. It is the
#    commit marker: a run that stopped leaves member directories and no
#    `release.json`, and `kci publish` refuses a directory without one.
#
# Sequential, not concurrent: one buck2 daemon serves one repository and
# blocks a second command with different args, so concurrency buys nothing
# for buck2 and is a hazard for a build system kci does not know. The farm
# still parallelises inside each build. Nothing here retries: a re-run is
# cheap (the cache) and the empty-out-dir rule makes it safe.
#
# kci knows no build tool. "Never build locally" is the declarations' to
# say (buck2's `-c komira.execution=remote` is a build-system arg there) and
# the machine's (the farm is a buckconfig buck2 reads at daemon start; see
# kci_artifact_declaration's example), never a kci flag. The stamp reaches
# the build only as the declarations' placeholders.
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
from kci_build.revision import derive_release_stamp
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


def _parent(path: String) -> String:
    """The lexical parent of the absolute `path`; `/` for `/` and `/x`."""
    var slash = path.rfind(String("/"))
    if slash <= 0:
        return String("/")
    return String(path[byte = :slash])


def resolved_path(path: String) raises -> String:
    """`path` made absolute (a relative one against the cwd) with `.` and `..`
    folded and every EXISTING prefix resolved through its symlinks; the
    missing tail, if any, is folded lexically. Two spellings of one place
    compare equal, whether or not it exists yet."""
    var cur = String("/") if path.startswith(String("/")) else realpath(String("."))
    var parts = path.split(String("/"))
    for i in range(len(parts)):
        var c = String(parts[i])
        if c.byte_length() == 0 or c == ".":
            continue
        if c == "..":
            cur = _parent(cur)
            continue
        var cand = (String("/") + c) if cur == "/" else (cur + String("/") + c)
        if exists(cand):
            cur = realpath(cand)
        else:
            cur = cand^
    return cur^


def check_log_dir(out_dir: String, log_dir: String) raises -> BuildOutcome:
    """REFUSED when `log_dir` is `out_dir` or lies under it (file header)."""
    var out = resolved_path(out_dir)
    var log = resolved_path(log_dir)
    if log == out or out == "/" or log.startswith(out + String("/")):
        return _refused(
            String("--log-dir '")
            + log_dir
            + String("' is --out-dir '")
            + out_dir
            + String("' or lies under it ('")
            + log
            + String("' in '")
            + out
            + String("'): the out dir becomes the release directory, which holds only the")
            + String(" member directories and release.json")
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


def _check_release_top(release_dir: String, names: List[String]) raises -> BuildOutcome:
    """REFUSED unless `release_dir` holds exactly the member directories `names`."""
    var raw = listdir(release_dir)
    for i in range(len(raw)):
        var entry = String(raw[i])
        var declared = False
        for k in range(len(names)):
            if names[k] == entry:
                declared = True
                break
        if not declared:
            return _refused(
                String("--out-dir '")
                + release_dir
                + String("' holds '")
                + entry
                + String("', which no declaration names: the release directory holds only the")
                + String(" member directories and release.json (a build wrote outside its own")
                + String(" directory)")
            )
    for k in range(len(names)):
        if not isdir(release_dir + String("/") + names[k]):
            return _refused(
                String("artifact '")
                + names[k]
                + String("': its directory is gone from --out-dir '")
                + release_dir
                + String("' (a later build removed it)")
            )
    return BuildOutcome(EXIT_OK, String(""))


def build_release[R: ProcessRunner, G: ProcessRunner](
    req: BuildRequest, mut runner: R, mut git: G
) -> BuildOutcome:
    """Build every declared artifact (file header). `git` runs the git
    commands of revision.mojo, `runner` the builds: two seams, so a test
    scripts each on its own."""
    try:
        var decls = read_artifact_declarations(req.declarations_file)
        if not isdir(req.work_dir):
            return _refused(String("--work-dir '") + req.work_dir + String("' is not a directory"))
        var gate = check_out_dir(req.out_dir)
        if not gate.ok():
            return gate^
        var logs = check_log_dir(req.out_dir, req.log_dir)
        if not logs.ok():
            return logs^
        makedirs(req.log_dir, exist_ok=True)
        var derived = derive_release_stamp(req, git)
        if not derived.ok():
            return BuildOutcome(derived.exit_code, derived.message.copy())
        var stamp = derived.stamp.value().copy()
        print(
            String("kci build: revision ") + stamp.revision_id + String(", stamp commit ")
            + stamp.source_commit + String(", build number ") + String(stamp.build_number)
            + String(", commit time ") + String(stamp.timestamp_ms) + String(" ms")
        )
        makedirs(req.out_dir, exist_ok=True)
        var out = realpath(req.out_dir)
        var members = List[ReleaseMember]()
        for i in range(len(decls.artifacts)):
            var name = decls.artifacts[i].name.copy()
            var dir = out + String("/") + name
            makedirs(dir, exist_ok=False)
            var argv = render_build_argv(decls, name, out, stamp)
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
        var names = List[String]()
        for i in range(len(decls.artifacts)):
            names.append(decls.artifacts[i].name.copy())
        var top = _check_release_top(out, names)
        if not top.ok():
            return top^
        var final = List[ReleaseMember]()
        for i in range(len(members)):
            ref first = members[i]
            var again: ReleaseMember
            try:
                again = verify_member(first.declaration, first.dir)
            except e:
                return _refused(String("after every build ran, ") + String(e))
            if _member_line(again) != _member_line(first) or again.size != first.size:
                return _refused(
                    String("artifact '")
                    + first.declaration
                    + String("': its directory changed after it was verified (a later build")
                    + String(" wrote into it): was `")
                    + _member_line(first)
                    + String("`, now `")
                    + _member_line(again)
                    + String("`")
                )
            final.append(again^)
        members = final^
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
