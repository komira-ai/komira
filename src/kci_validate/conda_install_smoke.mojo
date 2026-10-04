# =============================================================================
# src/kci_validate/conda_install_smoke.mojo -- a CONDA_INSTALL_SMOKE
#   validation: install what a PUBLISH step just published, from that step's
#   channel, into a clean environment, check every installed file is the one
#   the release holds, and run a smoke program against it.
# =============================================================================
#
# `run_install_smoke` runs one validation (kci_stage_graph's `StageValidation`)
# of a PUBLISH step whose channel is `channel_url`, against the release the
# step published (kci_publish's `LoadedRelease`; its `release.json` entries
# are the set). In order:
#
#   1. `validation.install` must be a name of the release set.
#   2. `<scratch_dir>/<validation.name>/` is made fresh. One that already
#      exists and is not empty is refused: a validation never reads what an
#      earlier run left behind.
#   3. It writes `pixi.toml` there:
#        [workspace] channels = [<channel_url>, <extra_channel>...],
#                    platforms = [<the conda subdir of the release platform>]
#        [dependencies] <install> = { version = "==<V>", build = "<B>",
#                                     channel = "<channel_url>" }
#      with V and B the release's own. The `channel =` pin, and the channel
#      listed first under pixi's strict channel priority, keep every package
#      of the set to the step's channel; the extra channels can only supply
#      packages outside the set (the compiler, say).
#   4. `pixi install --manifest-path <dir>/pixi.toml`, started with EXACTLY
#      PATH, HOME, PIXI_HOME, PIXI_CACHE_DIR and TMPDIR (the last four under
#      <dir>). Nothing else this process holds reaches the installer: a CI
#      job that may still request an identity token after its upload does
#      not hand that ability to a package solver.
#   5. Every member of the release set must have a record in
#      `<dir>/.pixi/envs/default/conda-meta/*.json` whose `name`, `version`,
#      `build` and `sha256` are the release's and whose `url` is under
#      `<channel_url>/`. A member with no record, a record without a
#      `sha256`, a file from another channel, or a record that does not parse
#      is a failure. (This is the data `conda list --json` reads; reading it
#      directly needs no conda on the runner.)
#   6. `pixi run --manifest-path <dir>/pixi.toml --frozen mojo run
#      <repo_root>/<program>` in the same environment. It must exit 0 and
#      print the line `<stem> smoke: OK`, where <stem> is the program's file
#      name without `.mojo` and without a leading `smoke_`
#      (`release/smoke/smoke_komira_encoding.mojo` prints
#      `komira_encoding smoke: OK`).
#
# FAIL CLOSED. Every way this can go wrong is VALIDATION_FAILED with a check
# row saying what was expected and what was found: a name outside the set,
# a used scratch directory, an installer that cannot be started, a solve that
# fails, a nonzero exit, a timeout, an unreadable environment, any record that
# differs, a smoke program without its OK line. There is no SKIP: a
# validation that could not run is a validation that failed. The first
# failing phase ends the validation; later phases are not attempted.
#
# Under `--plan` nothing runs: no process, no directory. The row says
# WOULD_VALIDATE with no outcome and no checks, so it can never read as a
# pass (kci_contract refuses a WOULD_VALIDATE row with either).
#
# The process is started through kci_build's ProcessRunner seam
# (SupervisorRunner for real runs, ScriptedRunner in the welded tests).
# Nothing here names a channel, a package or an organisation.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, makedirs
from std.os.path import exists, isdir

from komira_json import JsonValue, parse_json_value

from kci_build.runner import ProcessRunner, RunResult, RunSpec
from kci_contract import (
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
    ResultValidationCheck,
    platform_row,
)
from kci_publish.inputs import LoadedRelease
from kci_release_channel import ARTIFACT_TYPE_CONDA
from kci_release_set.release_manifest import ReleaseEntry
from kci_stage_graph import VALIDATION_TOOL_PIXI, StageValidation

comptime SMOKE_OK_SUFFIX: String = " smoke: OK"
"""What the smoke program's OK line ends with (file header, step 6)."""

comptime INSTALL_TIMEOUT_S: Int = 1800
"""How long the installer may run before it is stopped (a failure)."""

comptime SMOKE_TIMEOUT_S: Int = 900
"""How long the smoke program may run, its compile included."""

comptime ENV_DIR: String = ".pixi/envs/default"
"""Where pixi puts the default environment, under the manifest's directory."""

comptime MANIFEST_NAME: String = "pixi.toml"


def _join(a: String, b: String) -> String:
    if a.byte_length() == 0:
        return b.copy()
    if a.endswith(String("/")):
        return a + b
    return a + String("/") + b


def smoke_stem(program: String) -> String:
    """The program's file name without `.mojo` and without a leading
    `smoke_`."""
    var slash = program.rfind(String("/"))
    var base = String(program[byte = slash + 1 :]) if slash >= 0 else program.copy()
    if base.endswith(String(".mojo")):
        base = String(base[byte = : base.byte_length() - 5])
    if base.startswith(String("smoke_")) and base.byte_length() > 6:
        base = String(base[byte=6:])
    return base^


def smoke_ok_line(program: String) -> String:
    """The line the smoke program must print (file header, step 6)."""
    return smoke_stem(program) + String(SMOKE_OK_SUFFIX)


def _toml_string(s: String) -> String:
    """A TOML basic string: `\\` and `"` escaped."""
    return String('"') + s.replace(String("\\"), String("\\\\")).replace(String('"'), String('\\"')) + String('"')


def install_manifest_text(
    validation: StageValidation, channel_url: String, subdir: String, version: String, build: String
) -> String:
    """The `pixi.toml` of step 3 (file header)."""
    var channels = _toml_string(channel_url)
    for i in range(len(validation.extra_channels)):
        channels += String(", ") + _toml_string(validation.extra_channels[i])
    return (
        String("# Written by kci for validation '")
        + validation.name
        + String("': installs the release from its channel only.\n[workspace]\nname = \"kci-")
        + validation.name
        + String("\"\nchannels = [")
        + channels
        + String("]\nplatforms = [")
        + _toml_string(subdir)
        + String("]\n\n[dependencies]\n")
        + validation.install
        + String(" = { version = ")
        + _toml_string(String("==") + version)
        + String(", build = ")
        + _toml_string(build)
        + String(", channel = ")
        + _toml_string(channel_url)
        + String(" }\n")
    )


def smoke_child_env(dir: String, child_path: String) -> List[String]:
    """The installer's and the smoke program's whole environment (step 4)."""
    var env = List[String]()
    env.append(String("PATH=") + child_path)
    env.append(String("HOME=") + _join(dir, String("home")))
    env.append(String("PIXI_HOME=") + _join(dir, String("pixi_home")))
    env.append(String("PIXI_CACHE_DIR=") + _join(dir, String("cache")))
    env.append(String("TMPDIR=") + _join(dir, String("tmp")))
    return env^


def _conda_entries(release: LoadedRelease) -> List[ReleaseEntry]:
    var out = List[ReleaseEntry]()
    for i in range(len(release.recomputed.entries)):
        if release.recomputed.entries[i].artifact_type == ARTIFACT_TYPE_CONDA:
            out.append(release.recomputed.entries[i].copy())
    return out^


def _names(entries: List[ReleaseEntry]) -> String:
    var s = String("")
    for i in range(len(entries)):
        if i > 0:
            s += String(" ")
        s += entries[i].name
    return s^


def _expected_record(e: ReleaseEntry, channel_url: String) -> String:
    return (
        e.name + String(" ") + e.version + String(" ") + e.build
        + String(" sha256 ") + e.sha256_hex + String(" from ") + channel_url + String("/")
    )


def _str_or_missing(doc: JsonValue, key: String) -> String:
    """`doc[key]` when it is a string; `<no KEY>` otherwise."""
    if not doc.has(key):
        return String("<no ") + key + String(">")
    try:
        var v = doc.get(key)
        if v.is_string():
            return v.as_string()
    except:
        pass
    return String("<no ") + key + String(">")


struct _Rec(Copyable, Movable):
    """One conda-meta record, as read. Layout: owned Strings only."""

    var file: String
    var name: String
    var version: String
    var build: String
    var sha256: String
    var url: String

    def __init__(out self, var file: String, doc: JsonValue):
        self.file = file^
        self.name = _str_or_missing(doc, String("name"))
        self.version = _str_or_missing(doc, String("version"))
        self.build = _str_or_missing(doc, String("build"))
        self.sha256 = _str_or_missing(doc, String("sha256"))
        self.url = _str_or_missing(doc, String("url"))

    def describe(self) -> String:
        return (
            self.name + String(" ") + self.version + String(" ") + self.build
            + String(" sha256 ") + self.sha256 + String(" from ") + self.url
        )


def check_installed_records(
    meta_dir: String, entries: List[ReleaseEntry], channel_url: String
) -> List[ResultValidationCheck]:
    """Step 5: one check per release member, plus one per conda-meta file
    that does not parse, or one check when the directory cannot be read."""
    var checks = List[ResultValidationCheck]()
    var recs = List[_Rec]()
    var files = List[String]()
    try:
        if not isdir(meta_dir):
            raise Error(String("not a directory"))
        var raw = listdir(meta_dir)
        for i in range(len(raw)):
            var f = String(raw[i])
            if f.endswith(String(".json")):
                files.append(f^)
    except e:
        checks.append(
            ResultValidationCheck(
                String("installed environment"),
                String("a readable ") + meta_dir,
                String(e),
                False,
            )
        )
        return checks^
    for i in range(len(files)):
        var path = _join(meta_dir, files[i])
        try:
            var doc = parse_json_value(open(path, "r").read())
            if not doc.is_object():
                raise Error(String("not a JSON object"))
            recs.append(_Rec(files[i].copy(), doc))
        except e:
            checks.append(
                ResultValidationCheck(
                    String("conda-meta ") + files[i],
                    String("a package record"),
                    String(e),
                    False,
                )
            )
    var prefix = channel_url + String("/")
    for i in range(len(entries)):
        ref e = entries[i]
        var want = _expected_record(e, channel_url)
        var got = String("no record")
        var ok = False
        for j in range(len(recs)):
            if recs[j].name != e.name:
                continue
            got = recs[j].describe()
            ok = (
                recs[j].version == e.version
                and recs[j].build == e.build
                and recs[j].sha256 == e.sha256_hex
                and recs[j].url.startswith(prefix)
            )
            break
        checks.append(ResultValidationCheck(String("installed ") + e.name, want^, got^, ok))
    return checks^


def _has_line(text: String, line: String) -> Bool:
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var l = String(lines[i])
        if l.endswith(String("\r")):
            l = String(l[byte = : l.byte_length() - 1])
        if l == line:
            return True
    return False


def _read_or_empty(path: String) -> String:
    try:
        return open(path, "r").read()
    except:
        return String("")


def _run_checked[
    R: ProcessRunner
](
    mut runner: R, var spec: RunSpec, what: String, mut checks: List[ResultValidationCheck]
) -> Bool:
    """Run `spec`; append the check `what` (expected `exit 0`); True when it
    exited 0. A process that cannot be started is a failed check."""
    var got: String
    var ok = False
    try:
        var r = runner.run(spec)
        got = r.describe()
        ok = r.ok()
        if not ok and r.stderr_tail.byte_length() > 0:
            got += String(": ") + r.stderr_tail
    except e:
        got = String("not started: ") + String(e)
    checks.append(ResultValidationCheck(what.copy(), String("exit 0"), got^, ok))
    return ok


def _finish(var row: ResultValidation, var checks: List[ResultValidationCheck]) -> ResultValidation:
    var all_ok = len(checks) > 0
    for i in range(len(checks)):
        if not checks[i].ok:
            all_ok = False
    row.outcome = String(OUTCOME_SUCCEEDED) if all_ok else String(OUTCOME_VALIDATION_FAILED)
    row.checks = checks^
    return row^


def run_install_smoke[
    R: ProcessRunner
](
    mut runner: R,
    step: String,
    validation: StageValidation,
    channel_url: String,
    release: LoadedRelease,
    platform: String,
    scratch_dir: String,
    repo_root: String,
    child_path: String,
    plan: Bool = False,
) raises -> ResultValidation:
    """One CONDA_INSTALL_SMOKE validation of PUBLISH step `step` (file
    header). RAISES only on a caller's error (another kind, an unknown
    platform); everything about the environment is a failed check."""
    if validation.kind != VALIDATION_KIND_CONDA_INSTALL_SMOKE:
        raise Error(
            String("validation '") + validation.name + String("' is ") + validation.kind
            + String(", not ") + String(VALIDATION_KIND_CONDA_INSTALL_SMOKE)
        )
    var subdir = platform_row(platform).conda_subdir
    if plan:
        return ResultValidation(
            validation.name.copy(),
            step.copy(),
            validation.kind.copy(),
            String(VALIDATION_WOULD_VALIDATE),
            String(""),
        )
    var row = ResultValidation(
        validation.name.copy(), step.copy(), validation.kind.copy(), String(VALIDATION_VALIDATED), String("")
    )
    var checks = List[ResultValidationCheck]()
    var entries = _conda_entries(release)

    # 1. the name must be one of the set's
    var install_at = -1
    for i in range(len(entries)):
        if entries[i].name == validation.install:
            install_at = i
    checks.append(
        ResultValidationCheck(
            String("install is a release member"),
            validation.install.copy(),
            _names(entries),
            install_at >= 0,
        )
    )
    if install_at < 0:
        return _finish(row^, checks^)
    if validation.tool != VALIDATION_TOOL_PIXI:
        checks.append(
            ResultValidationCheck(String("tool"), String(VALIDATION_TOOL_PIXI), validation.tool.copy(), False)
        )
        return _finish(row^, checks^)

    # 2. a fresh directory
    var dir = _join(scratch_dir, validation.name)
    var fresh = True
    var why = String("absent")
    try:
        if exists(dir):
            if not isdir(dir):
                fresh = False
                why = String("exists and is not a directory")
            elif len(listdir(dir)) > 0:
                fresh = False
                why = String("exists and is not empty")
            else:
                why = String("empty")
        if fresh:
            makedirs(dir, exist_ok=True)
            makedirs(_join(dir, String("home")), exist_ok=True)
            makedirs(_join(dir, String("pixi_home")), exist_ok=True)
            makedirs(_join(dir, String("cache")), exist_ok=True)
            makedirs(_join(dir, String("tmp")), exist_ok=True)
    except e:
        fresh = False
        why = String(e)
    checks.append(ResultValidationCheck(String("scratch directory ") + dir, String("absent or empty"), why^, fresh))
    if not fresh:
        return _finish(row^, checks^)

    # 3. the manifest
    var manifest = _join(dir, String(MANIFEST_NAME))
    try:
        var f = open(manifest, "w")
        f.write_bytes(
            install_manifest_text(
                validation, channel_url, subdir, entries[install_at].version, entries[install_at].build
            ).as_bytes()
        )
        f.close()
    except e:
        checks.append(ResultValidationCheck(String("write ") + manifest, String("written"), String(e), False))
        return _finish(row^, checks^)

    # 4. install, with exactly the listed environment
    var env = smoke_child_env(dir, child_path)
    var iargv = List[String]()
    iargv.append(String("install"))
    iargv.append(String("--manifest-path"))
    iargv.append(manifest.copy())
    var ispec = RunSpec(
        validation.tool.copy(),
        iargv^,
        dir.copy(),
        INSTALL_TIMEOUT_S,
        _join(dir, String("install.stdout")),
        _join(dir, String("install.stderr")),
    )
    ispec.set_env(env.copy())
    if not _run_checked(runner, ispec^, String("install"), checks):
        return _finish(row^, checks^)

    # 5. every member installed from this channel, with the release's bytes
    var record_checks = check_installed_records(
        _join(_join(dir, String(ENV_DIR)), String("conda-meta")), entries, channel_url
    )
    var records_ok = True
    for i in range(len(record_checks)):
        if not record_checks[i].ok:
            records_ok = False
        checks.append(record_checks[i].copy())
    if not records_ok:
        return _finish(row^, checks^)

    # 6. the smoke program, in the same environment
    var sargv = List[String]()
    sargv.append(String("run"))
    sargv.append(String("--manifest-path"))
    sargv.append(manifest.copy())
    sargv.append(String("--frozen"))
    sargv.append(String("mojo"))
    sargv.append(String("run"))
    sargv.append(_join(repo_root, validation.program))
    var sout = _join(dir, String("smoke.stdout"))
    var sspec = RunSpec(
        validation.tool.copy(),
        sargv^,
        dir.copy(),
        SMOKE_TIMEOUT_S,
        sout.copy(),
        _join(dir, String("smoke.stderr")),
    )
    sspec.set_env(env^)
    if not _run_checked(runner, sspec^, String("smoke program"), checks):
        return _finish(row^, checks^)
    var want = smoke_ok_line(validation.program)
    var printed = _has_line(_read_or_empty(sout), want)
    checks.append(
        ResultValidationCheck(
            String("smoke output"),
            String("the line '") + want + String("'"),
            String("printed") if printed else String("not printed"),
            printed,
        )
    )
    return _finish(row^, checks^)
