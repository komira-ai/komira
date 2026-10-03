# =============================================================================
# src/kci_cli/args.mojo -- the `kci` command line: ONE parser for every verb.
# =============================================================================
#
#   kci run [--machine <file>] --stage <S> --revision-id <commit>
#           --run-id <id> --attempt <n> [--context <key=value>]...
#           --release-dir <dir> [--result-file <file>]
#           [--work-dir <dir> --log-dir <dir> [--build-timeout-s <n>]]
#           [--plan] [--expect-set-hash <hex>] [--claim-new-name <name>]...
#           [--release-version <file>] [--concurrency <n>]
#           [--secret-store <none|env>]
#   kci ci check [--machine <file>] --workflow <file> [--result-file <file>]
#   kci --help
#
# `kci run --stage S` is THE verb for stages: it runs every step of stage S
# of the machine file, in order. There is no per-kind verb and no alias (the
# CEO's ruling): what a stage does is the machine file's to say. `ci check`
# is a utility that changes nothing.
#
# The machine file is `--machine`, or `DEFAULT_MACHINE_FILE` when the flag
# is absent (a relative path is relative to the directory kci is started
# in). That default is spelled here only.
#
# Which flags a stage takes depends on its steps, so `parse_kci_args` checks
# only what the command line alone can say (unknown flags, values, flags
# given twice, flags of another verb, the flags every run needs), and
# `require_stage_flags` checks the rest once the stage is resolved:
#
#   a BUILD step     needs --work-dir and --log-dir; --build-timeout-s optional
#   a PUBLISH step   needs --expect-set-hash and --release-version; --plan,
#                    --claim-new-name, --concurrency, --secret-store optional
#   no step of that kind   its flags are refused
#
# `--plan` is a PUBLISH step's flag: the step makes every check and reads the
# channel, and writes nothing to it. (A BUILD step changes nothing outside
# this machine either way; a plan of a BUILD step is not a thing yet.)
#
# Every refusal here is a usage error (kci_contract's KCI-E-USAGE, exit 2).
# `--run-id`, `--attempt` and `--context` follow kci_contract's grammar; kci
# reads no CI-vendor environment variable for any of them.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_contract import (
    ContextEntry,
    RunIdentity,
    parse_attempt,
    parse_context_arg,
    require_full_commit_id,
)
from kci_stage_graph import Stage

comptime DEFAULT_MACHINE_FILE: String = "release/machine.textproto"
"""The machine file `kci run` and `kci ci check` read when `--machine` is
absent: next to release/artifacts.textproto and release/channels.textproto."""

comptime CLI_VERB_RUN: String = "run"
comptime CLI_VERB_CI_CHECK: String = "ci check"
comptime CLI_VERB_HELP: String = "help"

comptime KCI_USAGE: String = (
    "usage:\n"
    "  kci run [--machine <file>] --stage <S> --revision-id <commit> --run-id <id> --attempt <n>\n"
    "          [--context <key=value>]... --release-dir <dir> [--result-file <file>]\n"
    "          [--work-dir <dir> --log-dir <dir> [--build-timeout-s <n>]]         (a stage with a BUILD step)\n"
    "          [--plan] --expect-set-hash <hex> --release-version <file>\n"
    "          [--claim-new-name <name>]... [--concurrency <n>] [--secret-store <none|env>]  (a PUBLISH step)\n"
    "  kci ci check [--machine <file>] --workflow <file> [--result-file <file>]\n"
    "  kci --help\n"
    "kci run --stage S runs every step of stage S of the machine file, in order.\n"
    "--machine defaults to release/machine.textproto. --plan: a PUBLISH step checks and reads, and writes nothing.\n"
    "kci ci check holds a CI workflow to the machine file's stages.\n"
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
    var expect_set_hash: String
    var claims: List[String]
    var release_version: String
    var concurrency: Int
    var store: SecretStoreChoice
    var workflow: String
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
        self.expect_set_hash = String("")
        self.claims = List[String]()
        self.release_version = String("")
        self.concurrency = 0
        self.store = SecretStoreChoice.NONE
        self.workflow = String("")
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


# The flags of `run`, by the kind of step that takes them, and of `ci check`.
def _run_common_flags() -> List[String]:
    var l = List[String]()
    for f in ["--machine", "--stage", "--revision-id", "--run-id", "--attempt", "--context", "--release-dir", "--result-file"]:
        l.append(String(f))
    return l^


def build_flags() -> List[String]:
    var l = List[String]()
    for f in ["--work-dir", "--log-dir", "--build-timeout-s"]:
        l.append(String(f))
    return l^


def publish_flags() -> List[String]:
    var l = List[String]()
    for f in ["--plan", "--expect-set-hash", "--claim-new-name", "--release-version", "--concurrency", "--secret-store"]:
        l.append(String(f))
    return l^


def _ci_check_flags() -> List[String]:
    var l = List[String]()
    for f in ["--machine", "--workflow", "--result-file"]:
        l.append(String(f))
    return l^


def _member(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _repeatable(flag: String) -> Bool:
    return flag == String("--context") or flag == String("--claim-new-name")


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
    elif flag == String("--expect-set-hash"):
        cmd.expect_set_hash = value.copy()
    elif flag == String("--claim-new-name"):
        cmd.claims.append(value.copy())
    elif flag == String("--release-version"):
        cmd.release_version = value.copy()
    elif flag == String("--concurrency"):
        cmd.concurrency = _positive_int(flag, value)
    elif flag == String("--secret-store"):
        cmd.store = _store_choice(value)
    elif flag == String("--workflow"):
        cmd.workflow = value.copy()


def find_result_file(args: List[String]) -> String:
    """`--result-file`'s value wherever it is, or "": so a refused command
    line can still be recorded in the file it names."""
    for i in range(len(args)):
        if args[i] == String("--result-file") and i + 1 < len(args):
            return args[i + 1].copy()
        if args[i].startswith(String("--result-file=")):
            return String(args[i][byte = String("--result-file=").byte_length() :])
    return String("")


def parse_kci_args(args: List[String]) raises -> KciCommand:
    """`args` is argv without the program name. RAISES a usage error (file
    header); nothing is read."""
    var cmd = KciCommand()
    if len(args) == 0:
        raise usage_error(String("no verb: run or ci check"))
    var first = args[0]
    if first == String("--help") or first == String("-h"):
        cmd.verb = String(CLI_VERB_HELP)
        return cmd^
    var start: Int
    var allowed: List[String]
    if first == String("run"):
        cmd.verb = String(CLI_VERB_RUN)
        start = 1
        allowed = _run_common_flags()
        allowed.extend(build_flags())
        allowed.extend(publish_flags())
    elif first == String("ci"):
        if len(args) < 2 or args[1] != String("check"):
            raise usage_error(String("`kci ci` takes one verb: check"))
        cmd.verb = String(CLI_VERB_CI_CHECK)
        start = 2
        allowed = _ci_check_flags()
    elif first.startswith(String("-")):
        raise usage_error(String("'") + first + String("' before the verb: the verb comes first (run or ci check)"))
    else:
        raise usage_error(
            String("unknown verb '") + first
            + String("': `kci run --stage <S>` runs a stage (there is no build or publish verb), `kci ci check` checks a workflow")
        )
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
    if cmd.verb == String(CLI_VERB_RUN):
        for f in ["--stage", "--revision-id", "--run-id", "--attempt", "--release-dir"]:
            if not cmd.given(String(f)):
                raise usage_error(String("kci run needs ") + String(f))
        try:
            _ = cmd.run_identity()
        except e:
            raise usage_error(String(e))
    else:
        if not cmd.given(String("--workflow")):
            raise usage_error(String("kci ci check needs --workflow"))
    return cmd^


def require_stage_flags(cmd: KciCommand, stage: Stage) raises:
    """The flags of the step kinds stage `stage` holds, and only those (file
    header). Raises a usage error."""
    var has_build = stage.has_kind(String("BUILD"))
    var has_publish = stage.has_kind(String("PUBLISH"))
    var bf = build_flags()
    var pf = publish_flags()
    if has_build:
        for f in ["--work-dir", "--log-dir"]:
            if not cmd.given(String(f)):
                raise usage_error(String("stage '") + stage.name + String("' has a BUILD step: kci run needs ") + String(f))
    else:
        for i in range(len(bf)):
            if cmd.given(bf[i]):
                raise usage_error(
                    bf[i] + String(" is a BUILD step's flag, and stage '") + stage.name + String("' has no BUILD step")
                )
    if has_publish:
        for f in ["--expect-set-hash", "--release-version"]:
            if not cmd.given(String(f)):
                raise usage_error(String("stage '") + stage.name + String("' has a PUBLISH step: kci run needs ") + String(f))
    else:
        for i in range(len(pf)):
            if cmd.given(pf[i]):
                raise usage_error(
                    pf[i] + String(" is a PUBLISH step's flag, and stage '") + stage.name + String("' has no PUBLISH step")
                )
