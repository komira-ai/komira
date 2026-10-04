# =============================================================================
# src/kci_build/build.mojo -- one BUILD step: one build per declared
#   artifact, each into its own empty directory, then `release.json` last.
# =============================================================================
#
# `run_build(req, result, recorder, runner, git)`:
#
# 0. Checks that read but change nothing, each REFUSED before anything is
#    recorded or run: the platform is one kci releases (kci_contract's
#    platform table); `--revision-id` is a full commit id; then the path
#    flags, a wrong one being a usage error (KCI-E-USAGE, exit 2): `--work-dir`
#    is an absolute path to a directory; the platform's release directory
#    `<--release-dir>/<platform>` (kci_contract's layout) is absent or
#    empty; and `--log-dir` is neither `--release-dir` nor under it (both
#    compared absolute, `.`/`..` folded and every existing prefix resolved
#    through its symlinks): the release directory holds only member
#    directories and `release.json`; last, the declarations read and
#    validate (kci_artifact_declaration).
# 1. `recorder.begin` gets the RUNNING record (kci_contract's result
#    document) BEFORE the first effect (the first mkdir, the first git
#    command). A recorder that cannot record stops the step FAILED with
#    nothing done.
# 2. Derive the release stamp from git at `--revision-id`
#    (revision.mojo, through the `git` runner): refused for a shallow
#    clone, a HEAD that is not the revision, or modified tracked files,
#    before any build runs.
#    PLAN (`req.plan`, `kci run --plan`) stops here: each declaration's argv
#    is rendered for the resolved stamp (a declaration that does not render
#    is REFUSED, as it would be in a real run), and nothing else happens: no
#    build runs, the platform's release directory is not created and no
#    `release.json` is written. The git reads above did run, and their logs
#    went to `--log-dir` (never under `--release-dir`). Each artifact gets
#    an `artifacts[]` row with effect WOULD_BUILD.
# 3. For each artifact, in declarations-file order, one at a time (the order
#    is the contract's: a metapackage declared last reads, under
#    `{release_dir}`, the manifests of every artifact above it, each already
#    built and verified), with `<P>` the platform's release directory:
#      a. create `<P>/<name>/` (empty by construction: `<P>` was empty and
#         declaration names are unique);
#      b. run `render_build_argv(decls, name, <P>, platform, stamp)`
#         (`{out_dir}` is `<P>/<name>`, `{release_dir}` is `<P>`,
#         `{platform}` the platform) through the `ProcessRunner`, cwd
#         `--work-dir`, stdout and stderr to `<log>/<name>.stdout|.stderr`,
#         timeout `--build-timeout-s`;
#      c. a non-zero exit, a signal or a timeout is FAILED, naming the
#         artifact, the command line and the end of stderr; a build that
#         cannot be started is INDETERMINATE; either way, stop;
#      d. `kci_release_set.verify_member(name, <P>/<name>)`, and the
#         manifest's `platform` must be the step's or `noarch`: REFUSED
#         otherwise; stop.
# 4. Only when every artifact passed, and before `release.json`:
#      a. `<P>` must hold exactly the declared member directories: a build
#         that wrote a sibling of its own out dir (it is handed an absolute
#         path) is REFUSED, naming the entry;
#      b. `verify_member` runs again over every member, and a member whose
#         name, version, build or sha256 changed since its own check (a later
#         build wrote into it) is REFUSED. The set hash is computed from this
#         second pass, i.e. from the bytes that stay on disk.
#    Then write `<P>/release.json` LAST (kci.release_set major 2: the
#    revision, the platform, `produced_by` = --run-id/--attempt, the members
#    and the set hash). It is the commit marker: a run that stopped leaves
#    member directories and no `release.json`, and a PUBLISH step refuses a
#    directory without one.
# 5. The run's result document gets this step's row (its name, kind BUILD,
#    the platform, the outcome), one `artifacts[]` row per member (effect
#    BUILT, or WOULD_BUILD under plan, with the revision and the member's
#    platform), the set hash, and the first error. Writing the FINISHED
#    record is the caller's: a stage may hold more steps.
#
# Nothing run-specific reaches a member's files: the run id and attempt are
# in `release.json` (outside the set hash) and in the result, never in an
# argv (a build's manifest.json is written inside cached Buck2 actions, and a
# per-run value would make every run a cache miss).
#
# Human progress lines go to STDERR; the outcome's message and lines are the
# caller's to print.
#
# Sequential, not concurrent: one buck2 daemon serves one repository and
# blocks a second command with different args, so concurrency buys nothing
# for buck2 and is a hazard for a build system kci does not know. The farm
# still parallelises inside each build. Nothing here retries: a re-run is
# cheap (the cache) and the empty-directory rule makes it safe.
#
# kci knows no build tool. "Never build locally" is the declarations' to
# say (buck2's `-c komira.execution=remote` is a build-system arg there) and
# the machine's (the farm is a buckconfig buck2 reads at daemon start; see
# kci_artifact_declaration's example), never a kci flag. The stamp reaches
# the build only as the declarations' placeholders.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.io import FileDescriptor
from std.os import listdir, makedirs
from std.os.path import exists, isdir, realpath

from kci_artifact_declaration import read_artifact_declarations, render_build_argv
from kci_artifact_declaration_proto.artifact_declaration import ArtifactDeclarations
from kci_contract import (
    ARTIFACT_BUILT,
    ARTIFACT_WOULD_BUILD,
    ERROR_BUILD_FAILED,
    ERROR_CANNOT_TELL,
    ERROR_DECLARATION,
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_PLATFORM_MISMATCH,
    ERROR_RESULT_FILE,
    ERROR_REVISION,
    ERROR_USAGE,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_REFUSED,
    RELEASE_MANIFEST_NAME,
    STEP_KIND_BUILD,
    ResultArtifact,
    ResultStep,
    RunRecorder,
    require_full_commit_id,
    require_member_platform,
    require_release_platform,
)
from kci_contract import RunResult as KciRunResult
from kci_release_set import (
    ReleaseIdentity,
    ReleaseMember,
    member_platform,
    release_manifest_of,
    render_release_manifest,
    verify_member,
)

from kci_build.request import BuildOutcome, BuildRequest
from kci_build.revision import derive_release_stamp
from kci_build.runner import ProcessRunner, RunResult, RunSpec

comptime _STDERR: FileDescriptor = FileDescriptor(2)


def _stop(outcome: String, error_id: String, why: String) -> BuildOutcome:
    return BuildOutcome(outcome.copy(), error_id.copy(), String("BUILD step: ") + why)


def _refused(error_id: String, why: String) -> BuildOutcome:
    return _stop(String(OUTCOME_REFUSED), error_id, why)


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def check_platform_dir(release_dir: String, platform_dir: String) raises -> BuildOutcome:
    """REFUSED unless `platform_dir` (`<release_dir>/<platform>`) is absent
    or an empty directory."""
    if exists(platform_dir) and not isdir(platform_dir):
        return _refused(
            String(ERROR_USAGE),
            String("--release-dir '") + release_dir + String("': '") + platform_dir
            + String("' is not a directory"),
        )
    if exists(platform_dir) and len(listdir(platform_dir)) > 0:
        return _refused(
            String(ERROR_USAGE),
            String("--release-dir '") + release_dir + String("': '") + platform_dir
            + String("' is not empty: it becomes this platform's release directory, and a file")
            + String(" from an earlier run could ride along"),
        )
    return BuildOutcome.succeeded(String(""))


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


def check_log_dir(release_dir: String, log_dir: String) raises -> BuildOutcome:
    """REFUSED when `log_dir` is `release_dir` or lies under it (file
    header)."""
    var top = resolved_path(release_dir)
    var log = resolved_path(log_dir)
    if log == top or top == "/" or log.startswith(top + String("/")):
        return _refused(
            String(ERROR_USAGE),
            String("--log-dir '")
            + log_dir
            + String("' is --release-dir '")
            + release_dir
            + String("' or lies under it ('")
            + log
            + String("' in '")
            + top
            + String("'): the release directory holds only the member directories and")
            + String(" release.json"),
        )
    return BuildOutcome.succeeded(String(""))


def _failure(name: String, spec: RunSpec, r: RunResult) -> BuildOutcome:
    var why = (
        String("artifact '")
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
    return _stop(String(OUTCOME_FAILED), String(ERROR_BUILD_FAILED), why)


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


def _check_release_top(platform_dir: String, names: List[String]) raises -> BuildOutcome:
    """REFUSED unless `platform_dir` holds exactly the member directories
    `names`."""
    var raw = listdir(platform_dir)
    for i in range(len(raw)):
        var entry = String(raw[i])
        var declared = False
        for k in range(len(names)):
            if names[k] == entry:
                declared = True
                break
        if not declared:
            return _refused(
                String(ERROR_MEMBER),
                String("the release directory '")
                + platform_dir
                + String("' holds '")
                + entry
                + String("', which no declaration names: it holds only the member directories")
                + String(" and release.json (a build wrote outside its own directory)"),
            )
    for k in range(len(names)):
        if not isdir(platform_dir + String("/") + names[k]):
            return _refused(
                String(ERROR_MEMBER),
                String("artifact '")
                + names[k]
                + String("': its directory is gone from the release directory '")
                + platform_dir
                + String("' (a later build removed it)"),
            )
    return BuildOutcome.succeeded(String(""))


def _build[R: ProcessRunner, G: ProcessRunner, C: RunRecorder](
    req: BuildRequest,
    mut result: KciRunResult,
    mut recorder: C,
    mut runner: R,
    mut git: G,
    mut members: List[ReleaseMember],
    mut planned: List[String],
) -> BuildOutcome:
    """Steps 0 to 4 of the file header; `members` gets the verified members
    of a run that wrote `release.json`, `planned` the artifact names a plan
    would build."""
    try:
        require_release_platform(req.platform)
    except e:
        return _refused(String(ERROR_PLATFORM), String(e))
    try:
        require_full_commit_id(String("--revision-id"), req.revision_id)
    except e:
        return _refused(String(ERROR_REVISION), String(e))
    try:
        if not req.work_dir.startswith(String("/")):
            return _refused(
                String(ERROR_USAGE),
                String("--work-dir '") + req.work_dir
                + String("' is not an absolute path: it is the cwd every build resolves against"),
            )
        if not isdir(req.work_dir):
            return _refused(String(ERROR_USAGE), String("--work-dir '") + req.work_dir + String("' is not a directory"))
        if req.log_dir.byte_length() == 0:
            return _refused(String(ERROR_USAGE), String("--log-dir is EMPTY"))
        var pdir: String
        try:
            pdir = req.platform_dir()
        except e:
            return _refused(String(ERROR_USAGE), String("--release-dir: ") + String(e))
        var gate = check_platform_dir(req.release_dir, pdir)
        if not gate.ok():
            return gate^
        var logs = check_log_dir(req.release_dir, req.log_dir)
        if not logs.ok():
            return logs^
        var decls: ArtifactDeclarations
        try:
            decls = read_artifact_declarations(req.declarations_file)
        except e:
            return _refused(String(ERROR_DECLARATION), String(e))
        # ── step 1: RUNNING, before the first effect ────────────────────────
        result.revision = req.revision_id.copy()
        result.platform = req.platform.copy()
        result.set_run(req.run)
        try:
            recorder.begin(result.begin_record())
        except e:
            return _stop(
                String(OUTCOME_FAILED),
                String(ERROR_RESULT_FILE),
                String("the run's RUNNING record could not be written; nothing was done: ") + String(e),
            )
        makedirs(req.log_dir, exist_ok=True)
        var derived = derive_release_stamp(req, git)
        if not derived.ok():
            return BuildOutcome(derived.outcome.copy(), derived.error_id.copy(), derived.message.copy())
        var stamp = derived.stamp.value().copy()
        print(
            String("BUILD step: revision ") + stamp.revision_id + String(", platform ")
            + req.platform + String(", stamp commit ") + stamp.source_commit
            + String(", build number ") + String(stamp.build_number)
            + String(", commit time ") + String(stamp.timestamp_ms) + String(" ms"),
            file=_STDERR,
        )
        if req.plan:
            # PLAN (file header): render every declaration, build nothing,
            # create nothing under --release-dir.
            var would = List[String]()
            for i in range(len(decls.artifacts)):
                var name = decls.artifacts[i].name.copy()
                var argv: List[String]
                try:
                    argv = render_build_argv(decls, name, pdir, req.platform, stamp)
                except e:
                    return _refused(String(ERROR_DECLARATION), String("artifact '") + name + String("': ") + String(e))
                var line = String("")
                for k in range(len(argv)):
                    if k > 0:
                        line += String(" ")
                    line += argv[k]
                print(String("BUILD step: plan: would build ") + name + String(": ") + line, file=_STDERR)
                would.append(name^)
            var o = BuildOutcome.succeeded(
                String("BUILD step: plan: ") + String(len(would))
                + String(" artifact(s) would be built into ") + pdir + String("; nothing was built"),
            )
            for i in range(len(would)):
                o.lines.append(String("WOULD_BUILD ") + would[i])
            planned = would^
            return o^
        makedirs(pdir, exist_ok=True)
        var out = realpath(pdir)
        var built = List[ReleaseMember]()
        for i in range(len(decls.artifacts)):
            var name = decls.artifacts[i].name.copy()
            var dir = out + String("/") + name
            makedirs(dir, exist_ok=False)
            var argv = render_build_argv(decls, name, out, req.platform, stamp)
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
            print(String("BUILD step: building ") + name + String(": ") + spec.command_line(), file=_STDERR)
            var r: RunResult
            try:
                r = runner.run(spec)
            except e:
                return _stop(
                    String(OUTCOME_INDETERMINATE),
                    String(ERROR_CANNOT_TELL),
                    String("artifact '") + name + String("': the build could not be started: ") + String(e),
                )
            if not r.ok():
                return _failure(name, spec, r)
            var m: ReleaseMember
            try:
                m = verify_member(name, dir)
            except e:
                return _refused(String(ERROR_MEMBER), String(e))
            try:
                require_member_platform(req.platform, m.manifest.platform)
            except e:
                return _refused(
                    String(ERROR_PLATFORM_MISMATCH),
                    String("artifact '") + name + String("': its manifest's ") + String(e)
                    + String(" (this step builds for ") + req.platform + String(")"),
                )
            built.append(m^)
        var names = List[String]()
        for i in range(len(decls.artifacts)):
            names.append(decls.artifacts[i].name.copy())
        var top = _check_release_top(out, names)
        if not top.ok():
            return top^
        var final = List[ReleaseMember]()
        for i in range(len(built)):
            ref first = built[i]
            var again: ReleaseMember
            try:
                again = verify_member(first.declaration, first.dir)
            except e:
                return _refused(String(ERROR_MEMBER), String("after every build ran, ") + String(e))
            if _member_line(again) != _member_line(first) or again.size != first.size:
                return _refused(
                    String(ERROR_MEMBER),
                    String("artifact '")
                    + first.declaration
                    + String("': its directory changed after it was verified (a later build")
                    + String(" wrote into it): was `")
                    + _member_line(first)
                    + String("`, now `")
                    + _member_line(again)
                    + String("`"),
                )
            final.append(again^)
        var identity = ReleaseIdentity(
            req.revision_id.copy(), req.platform.copy(), req.run.run_id.copy(), req.run.attempt
        )
        var release = release_manifest_of(final, identity)
        var text = render_release_manifest(release)
        _write(out + String("/") + String(RELEASE_MANIFEST_NAME), text)
        var outcome = BuildOutcome.succeeded(
            String("BUILD step: ")
            + String(len(final))
            + String(" artifact(s) built and verified into ")
            + out,
        )
        for i in range(len(final)):
            outcome.lines.append(_member_line(final[i]))
        outcome.lines.append(String("SET_HASH ") + release.set_hash)
        outcome.set_hash = release.set_hash.copy()
        members = final^
        return outcome^
    except e:
        return _stop(String(OUTCOME_FAILED), String(ERROR_BUILD_FAILED), String(e))


def _record_result(
    req: BuildRequest,
    o: BuildOutcome,
    members: List[ReleaseMember],
    planned: List[String],
    mut result: KciRunResult,
) raises:
    """Step 5 of the file header."""
    result.steps.append(
        ResultStep(req.step_name.copy(), String(STEP_KIND_BUILD), req.platform.copy(), o.outcome.copy())
    )
    if o.error_id.byte_length() > 0:
        result.set_error(o.error_id.copy(), o.message.copy())
    if not o.ok():
        return
    for i in range(len(planned)):
        var row = ResultArtifact()
        row.effect = String(ARTIFACT_WOULD_BUILD)
        row.name = planned[i].copy()
        row.platform = req.platform.copy()
        row.revision = req.revision_id.copy()
        result.artifacts.append(row^)
    result.set_hash = o.set_hash.copy()
    for i in range(len(members)):
        ref m = members[i]
        var row = ResultArtifact()
        row.effect = String(ARTIFACT_BUILT)
        row.artifact_type = m.manifest.artifact_type.copy()
        row.build = m.build()
        row.file = m.manifest.file.copy()
        row.name = m.manifest.name.copy()
        row.platform = member_platform(m, req.platform)
        row.revision = req.revision_id.copy()
        row.sha256 = m.manifest.sha256_hex.copy()
        row.subdir = m.manifest.subdir.copy()
        row.version = m.manifest.version.copy()
        result.artifacts.append(row^)


def run_build[R: ProcessRunner, G: ProcessRunner, C: RunRecorder](
    req: BuildRequest, mut result: KciRunResult, mut recorder: C, mut runner: R, mut git: G
) -> BuildOutcome:
    """One BUILD step (file header). `git` runs the git commands of
    revision.mojo, `runner` the builds: two seams, so a test scripts each on
    its own. `recorder.begin` is called once, before the first effect; the
    step's row, artifacts, set hash and first error go into `result`.
    Never raises."""
    var members = List[ReleaseMember]()
    var planned = List[String]()
    var o = _build(req, result, recorder, runner, git, members, planned)
    try:
        _record_result(req, o, members, planned, result)
    except e:
        var lost = BuildOutcome(
            String(OUTCOME_INDETERMINATE),
            String(ERROR_CANNOT_TELL),
            o.message + String("\nBUILD step: the result document could not record this step: ") + String(e),
        )
        return lost^
    return o^
