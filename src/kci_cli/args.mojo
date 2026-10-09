# =============================================================================
# src/kci_cli/args.mojo -- the `kci` command line: ONE parser, ONE command.
# =============================================================================
#
#   kci run [--machine <file>] --stage <S> [--only step:<name>|validation:<name>]...
#           [--affected-by <commit>] [--plan] [--admission] --revision-id <commit>
#           --run-id <id> --attempt <n> [--context <key=value>]...
#           --release-dir <dir> [--result-file <file>] [--summary-file <file>]
#           [--work-dir <dir> --log-dir <dir> [--build-timeout-s <n>]
#            [--build-budget-s <n>]]
#           [--release-version <file>] [--concurrency <n>]
#           [--secret-store <none|env>] [--scratch-dir <dir>]
#           [--release-set-hash <64 hex>]
#           [--pixi <file> --pixi-sha256 <hex>] [--channel file:///<dir>]
#   kci --help
#
# kci has exactly ONE command: `kci run --stage S` runs every step of stage S
# of the machine file, in order. There is no per-kind verb, no alias and no
# utility verb: the check of the CI workflow against the machine file is not a
# command, it is what `kci run` does at start-up under GitHub Actions
# (dispatch.mojo).
#
# The machine file is `--machine`, or kci_api's `DEFAULT_MACHINE_FILE`
# (`release/machine.textproto`) when the flag is absent; a relative path is
# relative to the directory kci is started in.
#
# OPERATION SELECTION. Three flags select what a run does, all positive:
#
#   --only step:<name> | validation:<name>   (repeatable) run only these;
#             the run is SELECTIVE and is never reported as a full one
#             (kci_api selection.mojo). The grammar is checked by
#             `selectors_of` before anything is read (KCI-E-SELECTOR,
#             exit 2); a selector naming nothing in the stage is refused
#             after the machine file is read (KCI-E-SELECTOR-NO-MATCH, 3).
#   --affected-by <commit>   the per-change check: every BUILD step of the
#             stage builds exactly the units (artifacts and checks of its
#             artifacts file) the change <commit>...--revision-id reaches,
#             and nothing ships (kci_build affected.mojo). <commit> is a
#             FULL commit id, like --revision-id (a CI job passes the pull
#             request's base sha, not a branch name). The run is SELECTIVE.
#             `--build-budget-s <n>` (with --affected-by only, refused
#             without it) is the seconds the per-change check's build of
#             the units may take in all, every run of it included
#             (kci_build affected_batch.mojo, THE BUDGET), counted from
#             kci's own start (`started_ns`, set by dispatch.mojo
#             `kci_main_with`), at most MAX_BUILD_BUDGET_S (a week); pr.yml
#             passes what is left of its job's time limit.
#             It is refused with --only, with --release-dir (nothing is
#             released, so there is no release directory; without
#             --affected-by the flag is required), and for a stage holding a
#             step that is not a BUILD step or any validation.
#   --plan    a dry run of the whole stage: a BUILD step resolves and
#             renders and builds nothing (with --affected-by: asks the
#             affected commands and builds nothing); a PUBLISH step checks
#             and reads and writes nothing to the channel.
#
# `--admission` (any stage; no value) asks for THE ADMISSION CHECK (rule
# R24 of the staged pipeline, dispatch.mojo's header, 4c): on a push to main,
# a re-run, or the first attempt of the first stage, whose revision is not
# main's releasable tip stops SUPERSEDED (exit 0) before any effect. It
# selects nothing and checks nothing on any other run.
#
# Every other flag is an input, never a selector. `--summary-file <file>`
# (any stage) names a markdown file kci APPENDS its summary to (never
# truncates): the outcome, the steps, and the NEW NAMES of this stage and of
# the stages after it. kci.yml passes the job summary, "$GITHUB_STEP_SUMMARY".
#
# Which flags a stage takes depends on its steps, so `parse_kci_args` checks
# only what the command line alone can say (unknown flags, values, flags
# given twice, the flags every run needs), and `require_stage_flags` checks
# the rest once the stage is resolved:
#
#   a selected BUILD step    needs --work-dir and --log-dir; --build-timeout-s
#                            and (with --affected-by) --build-budget-s
#                            optional
#   a selected PUBLISH step  needs --release-version; --concurrency,
#                            --secret-store optional
#   a selected validation    needs --scratch-dir, an ABSOLUTE path (the
#                            container mounts a directory under it; an ENV
#                            validation refuses one inside the checkout)
#   a selected CONDA_INSTALL_ENV validation
#                            needs --pixi, the ABSOLUTE path of the pinned
#                            pixi it installs with, and --pixi-sha256, its
#                            pin (64 lowercase hex): the validation runs
#                            pixi only when the bytes have that sha256
#   no selected step of that kind   its flags are refused (and
#                            --scratch-dir when no validation is selected,
#                            --pixi and --pixi-sha256 when no ENV one is)
#
# `--channel file:///<absolute directory>` (optional) is the PRE-PUBLISH
# local mode: the selected validations read and install from that directory
# (what `komira_pack conda-index` writes from a release directory) instead
# of the step's channel, so a release is validated before anything is
# published. Only a plain absolute file:/// location is accepted. It is
# refused unless the run is VALIDATION-ONLY: at least one validation is
# selected, every selected one is CONDA_INSTALL_ENV (a container cannot see
# this machine's directory), and no BUILD or PUBLISH step is selected. Under
# GitHub Actions it is refused too (dispatch.mojo): a workflow validates
# only what was published. The result row records the location
# (`channel_url`).
#
# Only the SELECTED steps and validations count (every one, without
# `--only`; `--only step:<s>` selects no validation). Which names
# a release publishes is its artifacts file's: there is no per-run claim.
#
# `--release-set-hash <64 lowercase hex>` (a selected PUBLISH step or
# validation): the set hash of the release the run was handed (kci.yml: the
# build job's, or the validate job's for prod). kci recomputes the release
# directory's set and refuses another (KCI-E-SET-HASH, exit 3) before any
# effect; under GitHub Actions a run that publishes or validates without it
# is a usage error (dispatch.mojo). It is refused with --affected-by and on a
# stage whose selection publishes and validates nothing.
#
# Every refusal here is a usage error (kci_api's KCI-E-USAGE, exit 2;
# a malformed `--only` is KCI-E-SELECTOR, also exit 2).
# `--run-id`, `--attempt` and `--context` follow kci_api's grammar; kci
# reads no CI-vendor environment variable for any of them.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_api import (
    DEFAULT_MACHINE_FILE,
    STEP_KIND_BUILD,
    STEP_KIND_PUBLISH,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    ContextEntry,
    RunIdentity,
    Selector,
    parse_attempt,
    parse_context_arg,
    parse_selectors,
    require_full_commit_id,
)
from kci_build import MAX_BUILD_BUDGET_S
from kci_release_machine import Selection, Stage
from kci_validate import ChannelUrl

comptime CLI_VERB_RUN: String = "run"
comptime CLI_VERB_HELP: String = "help"

comptime KCI_USAGE: String = (
    "usage:\n"
    "  kci run [--machine <file>] --stage <S> [--only step:<name>|validation:<name>]... [--plan] [--admission]\n"
    "          [--affected-by <commit>] --revision-id <commit> --run-id <id> --attempt <n>\n"
    "          [--context <key=value>]... --release-dir <dir> [--result-file <file>] [--summary-file <file>]\n"
    "          [--work-dir <dir> --log-dir <dir> [--build-timeout-s <n>]]         (a selected BUILD step)\n"
    "          [--build-budget-s <n>]       (with --affected-by: the seconds the whole build of the units may take)\n"
    "          --release-version <file> [--concurrency <n>] [--secret-store <none|env>]  (a selected PUBLISH step)\n"
    "          --scratch-dir <dir>                                          (a selected validation)\n"
    "          [--release-set-hash <64 hex>]                  (a selected PUBLISH step or validation)\n"
    "          --pixi <file> --pixi-sha256 <hex>                  (a selected CONDA_INSTALL_ENV validation)\n"
    "          [--channel file:///<dir>]       (validations only: install from this local channel, not the step's)\n"
    "  kci --help\n"
    "kci has one command: kci run --stage S runs every step of stage S of the machine file, in order.\n"
    "--machine defaults to release/machine.textproto.\n"
    "--only runs only the named steps (or validations): a SELECTIVE run, never reported as a full one.\n"
    "--affected-by <commit>: build only the units the change <commit>...--revision-id reaches (no --release-dir).\n"
    "A step's validations run after it in a FULL run; with --only, only the validations it names run.\n"
    "--plan: a dry run; a BUILD step builds nothing, a PUBLISH step checks and reads and writes nothing.\n"
    "--admission: on a push to main, a re-run or the first stage's first attempt of a revision that is not\n"
    "main's releasable tip stops SUPERSEDED (exit 0) before anything is run.\n"
    "--summary-file: a markdown file kci appends its summary to (the outcome, the steps, the NEW NAMES).\n"
    "Under GitHub Actions kci first checks the workflow it runs under against the machine file.\n"
    "--secret-store: how a channel credential's secret NAME is resolved: none (default) refuses;\n"
    "env reads the environment variable of that name."
)


struct SecretStoreChoice(ImplicitlyCopyable, Movable, Equatable):
    """Which `SecretStore` a PUBLISH step is given. Layout: one Int."""

    var kind: Int

    comptime NONE = SecretStoreChoice(0)
    comptime ENV = SecretStoreChoice(1)

    def __init__(out self, kind: Int):
        self.kind = kind

    def __eq__(self, other: Self) -> Bool:
        return self.kind == other.kind

    def __ne__(self, other: Self) -> Bool:
        return self.kind != other.kind

    def name(self) -> String:
        if self.kind == 1:
            return String("env")
        return String("none")


struct KciCommand(Copyable, Movable):
    """The parsed command line (file header). A flag not given is "" (or
    False / 0 / empty); `seen` lists every flag given, by name.

    Layout: owned values only. No pointer field."""

    var verb: String
    var machine: String
    var result_file: String
    var stage: String
    var revision_id: String
    var run_id: String
    var attempt: Int
    var context: List[ContextEntry]
    var release_dir: String
    var work_dir: String
    var log_dir: String
    var build_timeout_s: Int
    var build_budget_s: Int
    var started_ns: Int
    var plan: Bool
    var admission: Bool
    var summary_file: String
    var release_version: String
    var concurrency: Int
    var store: SecretStoreChoice
    var scratch_dir: String
    var pixi: String
    var pixi_sha256: String
    var channel: String
    var only: List[String]
    var affected_by: String
    var release_set_hash: String
    var seen: List[String]

    def __init__(out self):
        self.verb = String("")
        self.machine = String(DEFAULT_MACHINE_FILE)
        self.result_file = String("")
        self.stage = String("")
        self.revision_id = String("")
        self.run_id = String("")
        self.attempt = 0
        self.context = List[ContextEntry]()
        self.release_dir = String("")
        self.work_dir = String("")
        self.log_dir = String("")
        self.build_timeout_s = 0
        self.build_budget_s = 0
        self.started_ns = 0
        self.plan = False
        self.admission = False
        self.summary_file = String("")
        self.release_version = String("")
        self.concurrency = 0
        self.store = SecretStoreChoice.NONE
        self.scratch_dir = String("")
        self.pixi = String("")
        self.pixi_sha256 = String("")
        self.channel = String("")
        self.only = List[String]()
        self.affected_by = String("")
        self.release_set_hash = String("")
        self.seen = List[String]()

    def given(self, flag: String) -> Bool:
        for i in range(len(self.seen)):
            if self.seen[i] == flag:
                return True
        return False

    def run_identity(self) raises -> RunIdentity:
        """`--run-id`, `--attempt`, every `--context` (already checked)."""
        var r = RunIdentity(self.run_id.copy(), self.attempt)
        for i in range(len(self.context)):
            r.add_context(self.context[i].copy())
        return r^


def usage_error(why: String) -> Error:
    """A refused command line: `why` as is. The dispatcher records it and
    prints it after its one `kci: ` (dispatch.mojo `_stop`)."""
    return Error(why)


# The flags of `run`, by the kind of step that takes them.
def _run_common_flags() -> List[String]:
    var l = List[String]()
    for f in [
        "--machine", "--stage", "--only", "--affected-by", "--plan", "--admission", "--revision-id", "--run-id",
        "--attempt",
        "--context", "--release-dir", "--result-file", "--summary-file", "--release-set-hash",
    ]:
        l.append(String(f))
    return l^


def build_flags() -> List[String]:
    var l = List[String]()
    for f in ["--work-dir", "--log-dir", "--build-timeout-s", "--build-budget-s"]:
        l.append(String(f))
    return l^


def publish_flags() -> List[String]:
    var l = List[String]()
    for f in ["--release-version", "--concurrency", "--secret-store"]:
        l.append(String(f))
    return l^


def validation_flags() -> List[String]:
    var l = List[String]()
    l.append(String("--scratch-dir"))
    return l^


def env_validation_flags() -> List[String]:
    """The flags of a CONDA_INSTALL_ENV validation (file header)."""
    var l = List[String]()
    l.append(String("--pixi"))
    l.append(String("--pixi-sha256"))
    return l^


def local_channel_flags() -> List[String]:
    """The PRE-PUBLISH local mode's flag (file header)."""
    var l = List[String]()
    l.append(String("--channel"))
    return l^


def _is_sha256_hex(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 64:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def _member(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _repeatable(flag: String) -> Bool:
    return flag == String("--context") or flag == String("--only")


def _boolean(flag: String) -> Bool:
    return flag == String("--plan") or flag == String("--admission")


def _positive_int(flag: String, value: String) raises -> Int:
    var b = value.as_bytes()
    if len(b) == 0 or len(b) > 9 or Int(b[0]) == 48:
        raise usage_error(flag + String(" '") + value + String("' is not a positive decimal integer"))
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            raise usage_error(flag + String(" '") + value + String("' is not a positive decimal integer"))
        n = n * 10 + (c - 48)
    return n


def _store_choice(value: String) raises -> SecretStoreChoice:
    if value == String("none"):
        return SecretStoreChoice.NONE
    if value == String("env"):
        return SecretStoreChoice.ENV
    raise usage_error(String("--secret-store '") + value + String("' is not a store kind: none or env"))


def _set(mut cmd: KciCommand, flag: String, value: String) raises:
    if value.byte_length() == 0 and not _boolean(flag):
        raise usage_error(flag + String(" is EMPTY"))
    if flag == String("--machine"):
        cmd.machine = value.copy()
    elif flag == String("--result-file"):
        cmd.result_file = value.copy()
    elif flag == String("--stage"):
        cmd.stage = value.copy()
    elif flag == String("--only"):
        cmd.only.append(value.copy())
    elif flag == String("--revision-id"):
        try:
            require_full_commit_id(String("--revision-id"), value)
        except e:
            raise usage_error(String(e))
        cmd.revision_id = value.copy()
    elif flag == String("--affected-by"):
        try:
            require_full_commit_id(String("--affected-by"), value)
        except e:
            raise usage_error(String(e))
        cmd.affected_by = value.copy()
    elif flag == String("--release-set-hash"):
        var b = value.as_bytes()
        var ok = len(b) == 64
        for i in range(len(b)):
            var c = Int(b[i])
            if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
                ok = False
        if not ok:
            raise usage_error(String("--release-set-hash '") + value + String("' is not 64 lowercase hex characters"))
        cmd.release_set_hash = value.copy()
    elif flag == String("--run-id"):
        cmd.run_id = value.copy()
    elif flag == String("--attempt"):
        try:
            cmd.attempt = parse_attempt(value)
        except e:
            raise usage_error(String(e))
    elif flag == String("--context"):
        try:
            cmd.context.append(parse_context_arg(value))
        except e:
            raise usage_error(String(e))
    elif flag == String("--release-dir"):
        cmd.release_dir = value.copy()
    elif flag == String("--work-dir"):
        cmd.work_dir = value.copy()
    elif flag == String("--log-dir"):
        cmd.log_dir = value.copy()
    elif flag == String("--build-timeout-s"):
        cmd.build_timeout_s = _positive_int(flag, value)
    elif flag == String("--build-budget-s"):
        cmd.build_budget_s = _positive_int(flag, value)
        if cmd.build_budget_s > MAX_BUILD_BUDGET_S:
            raise usage_error(
                flag + String(" '") + value + String("' is more than ") + String(MAX_BUILD_BUDGET_S)
                + String(" (a week)")
            )
    elif flag == String("--plan"):
        cmd.plan = True
    elif flag == String("--admission"):
        cmd.admission = True
    elif flag == String("--summary-file"):
        cmd.summary_file = value.copy()
    elif flag == String("--release-version"):
        cmd.release_version = value.copy()
    elif flag == String("--concurrency"):
        cmd.concurrency = _positive_int(flag, value)
    elif flag == String("--secret-store"):
        cmd.store = _store_choice(value)
    elif flag == String("--scratch-dir"):
        if not value.startswith(String("/")):
            raise usage_error(String("--scratch-dir '") + value + String("' is not an absolute path (a container mounts a directory under it)"))
        cmd.scratch_dir = value.copy()
    elif flag == String("--pixi"):
        if not value.startswith(String("/")):
            raise usage_error(String("--pixi '") + value + String("' is not an absolute path"))
        cmd.pixi = value.copy()
    elif flag == String("--pixi-sha256"):
        if not _is_sha256_hex(value):
            raise usage_error(String("--pixi-sha256 '") + value + String("' is not 64 lowercase hex characters"))
        cmd.pixi_sha256 = value.copy()
    elif flag == String("--channel"):
        var why = String("")
        try:
            if not ChannelUrl(value).is_local():
                why = String("it is not a file:/// location")
        except e:
            why = String(e)
        if why.byte_length() > 0:
            raise usage_error(
                String("--channel '") + value + String("' is not file:///<absolute directory>, a local channel")
                + String(" (") + why + String(")")
            )
        cmd.channel = value.copy()


def _find_value(args: List[String], flag: String) -> String:
    var eq = flag + String("=")
    for i in range(len(args)):
        if args[i] == flag and i + 1 < len(args):
            return args[i + 1].copy()
        if args[i].startswith(eq):
            return String(args[i][byte = eq.byte_length() :])
    return String("")


def find_result_file(args: List[String]) -> String:
    """`--result-file`'s value wherever it is, or "": so a refused command
    line can still be recorded in the file it names."""
    return _find_value(args, String("--result-file"))


def find_summary_file(args: List[String]) -> String:
    """`--summary-file`'s value wherever it is, or "": so a refused command
    line still reaches the job summary."""
    return _find_value(args, String("--summary-file"))


def parse_kci_args(args: List[String]) raises -> KciCommand:
    """`args` is argv without the program name. RAISES a usage error (file
    header); nothing is read."""
    var cmd = KciCommand()
    if len(args) == 0:
        raise usage_error(String("no command: there is one, kci run --stage <S>"))
    var first = args[0]
    if first == String("--help") or first == String("-h"):
        cmd.verb = String(CLI_VERB_HELP)
        return cmd^
    if first == String("run"):
        cmd.verb = String(CLI_VERB_RUN)
    elif first.startswith(String("-")):
        raise usage_error(String("'") + first + String("' before the command: kci run comes first"))
    elif first == String("ci"):
        raise usage_error(
            String("there is one command: kci run (`kci ci check` is gone: under GitHub Actions, kci run checks")
            + String(" the workflow it runs under against the machine file at start-up)")
        )
    else:
        raise usage_error(
            String("unknown command '") + first
            + String("': there is one command, `kci run --stage <S>` (no build, publish or other verb)")
        )
    var start = 1
    var allowed = _run_common_flags()
    allowed.extend(build_flags())
    allowed.extend(publish_flags())
    allowed.extend(validation_flags())
    allowed.extend(env_validation_flags())
    allowed.extend(local_channel_flags())
    var i = start
    while i < len(args):
        var a = args[i]
        if a == String("--help") or a == String("-h"):
            cmd.verb = String(CLI_VERB_HELP)
            return cmd^
        if not a.startswith(String("--")):
            raise usage_error(String("unexpected argument '") + a + String("'"))
        var flag = a.copy()
        var value = String("")
        var has_value = False
        var eq = a.find(String("="))
        if eq > 0:
            flag = String(a[byte = 0:eq])
            value = String(a[byte = eq + 1 :])
            has_value = True
        if not _member(allowed, flag):
            raise usage_error(String("unknown flag '") + flag + String("' for kci ") + cmd.verb)
        if cmd.given(flag) and not _repeatable(flag):
            raise usage_error(flag + String(" is given twice"))
        if _boolean(flag):
            if has_value:
                raise usage_error(flag + String(" takes no value"))
        elif not has_value:
            if i + 1 >= len(args):
                raise usage_error(flag + String(" needs a value"))
            i += 1
            value = args[i].copy()
        _set(cmd, flag, value)
        cmd.seen.append(flag^)
        i += 1
    for f in ["--stage", "--revision-id", "--run-id", "--attempt"]:
        if not cmd.given(String(f)):
            raise usage_error(String("kci run needs ") + String(f))
    if cmd.given(String("--affected-by")):
        if cmd.given(String("--only")):
            raise usage_error(
                String("--affected-by and --only both select what runs: --affected-by builds the units a")
                + String(" change reaches in every BUILD step of the stage; give one")
            )
        if cmd.given(String("--release-dir")):
            raise usage_error(
                String("--release-dir is not used with --affected-by: the per-change check releases nothing")
            )
        if cmd.given(String("--release-set-hash")):
            raise usage_error(
                String("--release-set-hash is not used with --affected-by: the per-change check releases nothing")
            )
    else:
        if cmd.given(String("--build-budget-s")):
            raise usage_error(
                String("--build-budget-s bounds the per-change check's build of the units: it is used only")
                + String(" with --affected-by")
            )
        if not cmd.given(String("--release-dir")):
            raise usage_error(String("kci run needs --release-dir"))
    try:
        _ = cmd.run_identity()
    except e:
        raise usage_error(String(e))
    return cmd^


def selectors_of(cmd: KciCommand) raises -> List[Selector]:
    """Every `--only`, parsed (kci_api `parse_selectors`): raises on a
    malformed selector or the same one twice. The caller records the
    refusal as KCI-E-SELECTOR (exit 2) before anything is read."""
    return parse_selectors(cmd.only)


def _selected_kind(stage: Stage, sel: Selection, kind: String) -> Bool:
    for i in range(len(stage.steps)):
        if sel.steps[i] and stage.steps[i].kind == kind:
            return True
    return False


def require_stage_flags(cmd: KciCommand, stage: Stage, sel: Selection) raises:
    """The flags of the step kinds the SELECTED steps of `stage` hold, and
    only those (file header). Raises a usage error."""
    if cmd.affected_by.byte_length() > 0:
        for i in range(len(stage.steps)):
            if stage.steps[i].kind != STEP_KIND_BUILD:
                raise usage_error(
                    String("--affected-by builds what a change reaches and nothing else, and stage '")
                    + stage.name + String("' has the ") + stage.steps[i].kind + String(" step '")
                    + stage.steps[i].name + String("'")
                )
        if len(sel.validations) > 0:
            raise usage_error(
                String("--affected-by builds what a change reaches and nothing else, and stage '")
                + stage.name + String("' has the validation '") + sel.validations[0] + String("'")
            )
    var has_build = _selected_kind(stage, sel, String(STEP_KIND_BUILD))
    var has_publish = _selected_kind(stage, sel, String(STEP_KIND_PUBLISH))
    var which = String("stage '") + stage.name + String("'")
    var has = String(" has")
    var holds_no = String(" has no")
    if len(cmd.only) > 0:
        which = String("the steps --only selects in stage '") + stage.name + String("'")
        has = String(" include")
        holds_no = String(" hold no")
    _require_validation_only(cmd, stage, sel, has_build, has_publish)
    var bf = build_flags()
    var pf = publish_flags()
    if has_build:
        for f in ["--work-dir", "--log-dir"]:
            if not cmd.given(String(f)):
                raise usage_error(which + has + String(" a BUILD step: kci run needs ") + String(f))
    else:
        for i in range(len(bf)):
            if cmd.given(bf[i]):
                raise usage_error(bf[i] + String(" is a BUILD step's flag, and ") + which + holds_no + String(" BUILD step"))
    if has_publish:
        for f in ["--release-version"]:
            if not cmd.given(String(f)):
                raise usage_error(which + has + String(" a PUBLISH step: kci run needs ") + String(f))
    else:
        for i in range(len(pf)):
            if cmd.given(pf[i]):
                raise usage_error(pf[i] + String(" is a PUBLISH step's flag, and ") + which + holds_no + String(" PUBLISH step"))
    if cmd.given(String("--release-set-hash")) and not has_publish and len(sel.validations) == 0:
        raise usage_error(
            String("--release-set-hash holds a PUBLISH step or a validation to the set it was handed, and ") + which
            + holds_no + String(" PUBLISH step and no validation is selected")
        )
    var vwhich = String("stage '") + stage.name + String("'")
    if len(cmd.only) > 0:
        vwhich = String("--only in stage '") + stage.name + String("'")
    if len(sel.validations) > 0:
        if not cmd.given(String("--scratch-dir")):
            raise usage_error(vwhich + String(" selects a validation: kci run needs --scratch-dir"))
    elif cmd.given(String("--scratch-dir")):
        raise usage_error(String("--scratch-dir is a validation's flag, and ") + vwhich + String(" selects no validation"))
    var env_name = _selected_env_validation(stage, sel)
    var ef = env_validation_flags()
    if env_name.byte_length() > 0:
        for i in range(len(ef)):
            if not cmd.given(ef[i]):
                raise usage_error(
                    vwhich + String(" selects the CONDA_INSTALL_ENV validation '") + env_name
                    + String("': kci run needs ") + ef[i]
                )
    else:
        for i in range(len(ef)):
            if cmd.given(ef[i]):
                raise usage_error(
                    ef[i] + String(" is a CONDA_INSTALL_ENV validation's flag, and ") + vwhich
                    + String(" selects none")
                )


def _require_validation_only(cmd: KciCommand, stage: Stage, sel: Selection, has_build: Bool, has_publish: Bool) raises:
    """`--channel` only on a validation-only run of CONDA_INSTALL_ENV
    validations (file header)."""
    if not cmd.given(String("--channel")):
        return
    var why = String("--channel names a local channel, which only a validation-only run reads, and ")
    if has_build or has_publish:
        raise usage_error(
            why + String("the run selects the ") + (String("BUILD") if has_build else String("PUBLISH"))
            + String(" step of stage '") + stage.name + String("': select the validations with --only validation:<name>")
        )
    if len(sel.validations) == 0:
        raise usage_error(why + String("the run selects no validation of stage '") + stage.name + String("'"))
    for n in range(len(sel.validations)):
        for k in range(len(stage.steps)):
            for m in range(len(stage.steps[k].validations)):
                ref v = stage.steps[k].validations[m]
                if v.name == sel.validations[n] and v.kind != VALIDATION_KIND_CONDA_INSTALL_ENV:
                    raise usage_error(
                        why + String("the selected validation '") + v.name + String("' is ") + v.kind
                        + String(", not CONDA_INSTALL_ENV: a container cannot read this machine's directory")
                    )


def _selected_env_validation(stage: Stage, sel: Selection) -> String:
    """The first selected CONDA_INSTALL_ENV validation's name, "" for none."""
    for n in range(len(sel.validations)):
        for k in range(len(stage.steps)):
            for m in range(len(stage.steps[k].validations)):
                ref v = stage.steps[k].validations[m]
                if v.name == sel.validations[n] and v.kind == VALIDATION_KIND_CONDA_INSTALL_ENV:
                    return v.name.copy()
    return String("")
