# =============================================================================
# src/kci_cli/args.mojo -- the `kci` command line: ONE parser, ONE command.
# =============================================================================
#
#   kci run [--machine <file>] --stage <S> [--only step:<name>|validation:<name>]...
#           [--plan] --revision-id <commit>
#           --run-id <id> --attempt <n> [--context <key=value>]...
#           --release-dir <dir> [--result-file <file>] [--summary-file <file>]
#           [--work-dir <dir> --log-dir <dir> [--build-timeout-s <n>]]
#           [--release-version <file>] [--concurrency <n>]
#           [--secret-store <none|env>]
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
# OPERATION SELECTION. Exactly two flags select what a run does, and both
# are positive:
#
#   --only step:<name> | validation:<name>   (repeatable) run only these;
#             the run is SELECTIVE and is never reported as a full one
#             (kci_api selection.mojo). The grammar is checked by
#             `selectors_of` before anything is read (KCI-E-SELECTOR,
#             exit 2); a selector naming nothing in the stage is refused
#             after the machine file is read (KCI-E-SELECTOR-NO-MATCH, 3).
#   --plan    a dry run of the whole stage: a BUILD step resolves and
#             renders and builds nothing; a PUBLISH step checks and reads
#             and writes nothing to the channel.
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
#                            optional
#   a selected PUBLISH step  needs --release-version; --concurrency,
#                            --secret-store optional
#   no selected step of that kind   its flags are refused
#
# Only the SELECTED steps count (every step, without `--only`). Which names
# a release publishes is its artifacts file's: there is no per-run claim
# and no expected set hash on the command line.
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
    ContextEntry,
    RunIdentity,
    Selector,
    parse_attempt,
    parse_context_arg,
    parse_selectors,
    require_full_commit_id,
)
from kci_release_machine import Selection, Stage

comptime CLI_VERB_RUN: String = "run"
comptime CLI_VERB_HELP: String = "help"

comptime KCI_USAGE: String = (
    "usage:\n"
    "  kci run [--machine <file>] --stage <S> [--only step:<name>|validation:<name>]... [--plan]\n"
    "          --revision-id <commit> --run-id <id> --attempt <n>\n"
    "          [--context <key=value>]... --release-dir <dir> [--result-file <file>] [--summary-file <file>]\n"
    "          [--work-dir <dir> --log-dir <dir> [--build-timeout-s <n>]]         (a selected BUILD step)\n"
    "          --release-version <file> [--concurrency <n>] [--secret-store <none|env>]  (a selected PUBLISH step)\n"
    "  kci --help\n"
    "kci has one command: kci run --stage S runs every step of stage S of the machine file, in order.\n"
    "--machine defaults to release/machine.textproto.\n"
    "--only runs only the named steps (or validations): a SELECTIVE run, never reported as a full one.\n"
    "--plan: a dry run; a BUILD step builds nothing, a PUBLISH step checks and reads and writes nothing.\n"
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
    var plan: Bool
    var summary_file: String
    var release_version: String
    var concurrency: Int
    var store: SecretStoreChoice
    var only: List[String]
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
        self.plan = False
        self.summary_file = String("")
        self.release_version = String("")
        self.concurrency = 0
        self.store = SecretStoreChoice.NONE
        self.only = List[String]()
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
    return Error(String("kci: ") + why)


# The flags of `run`, by the kind of step that takes them.
def _run_common_flags() -> List[String]:
    var l = List[String]()
    for f in [
        "--machine", "--stage", "--only", "--plan", "--revision-id", "--run-id", "--attempt", "--context",
        "--release-dir", "--result-file", "--summary-file",
    ]:
        l.append(String(f))
    return l^


def build_flags() -> List[String]:
    var l = List[String]()
    for f in ["--work-dir", "--log-dir", "--build-timeout-s"]:
        l.append(String(f))
    return l^


def publish_flags() -> List[String]:
    var l = List[String]()
    for f in ["--release-version", "--concurrency", "--secret-store"]:
        l.append(String(f))
    return l^


def _member(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _repeatable(flag: String) -> Bool:
    return flag == String("--context") or flag == String("--only")


def _boolean(flag: String) -> Bool:
    return flag == String("--plan")


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
    elif flag == String("--plan"):
        cmd.plan = True
    elif flag == String("--summary-file"):
        cmd.summary_file = value.copy()
    elif flag == String("--release-version"):
        cmd.release_version = value.copy()
    elif flag == String("--concurrency"):
        cmd.concurrency = _positive_int(flag, value)
    elif flag == String("--secret-store"):
        cmd.store = _store_choice(value)


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
    for f in ["--stage", "--revision-id", "--run-id", "--attempt", "--release-dir"]:
        if not cmd.given(String(f)):
            raise usage_error(String("kci run needs ") + String(f))
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
    var has_build = _selected_kind(stage, sel, String(STEP_KIND_BUILD))
    var has_publish = _selected_kind(stage, sel, String(STEP_KIND_PUBLISH))
    var which = String("stage '") + stage.name + String("'")
    var has = String(" has")
    var holds_no = String(" has no")
    if len(cmd.only) > 0:
        which = String("the steps --only selects in stage '") + stage.name + String("'")
        has = String(" include")
        holds_no = String(" hold no")
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
