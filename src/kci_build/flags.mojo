# =============================================================================
# src/kci_build/flags.mojo -- the `kci build` flags, parsed into a
#   `BuildRequest` before anything is read or run.
# =============================================================================
#
#   --buck2 <path>              the buck2 binary (absolute path)
#   --repo-root <dir>           the repository to build in (buck2's cwd)
#   --publishable <file>        the publishable list (allowlist.mojo)
#   [--only <target>]           build only this listed target (repeatable)
#   [--buck2-config <k=v>]      passed as `-c k=v` (repeatable)
#   [--target-platforms <p>]    passed as `--target-platforms p`
#   --probe-target <target>     the farm probe target (preflight.mojo)
#   [--probe-timeout-s <n>]     default 120
#   [--build-timeout-s <n>]     default 3600
#   --out-dir <dir>             absent or empty; packages + manifests go here
#   --log-dir <dir>             buck2's output and build reports go here
#   [--help]
#
# A value may follow its flag as the next argument or after `=`. A missing
# required flag, a flag given twice (other than the repeatable two), an
# unknown flag, an empty value, a positional argument and a timeout that is
# not a positive integer are each refused, naming the flag. So is a
# `--buck2-config` that sets `komira.execution` (kci build always builds on
# the farm) or `kci.probe_nonce` (kci build sets it).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_build.allowlist import label_problem
from kci_build.request import BuildRequest

comptime BUILD_USAGE: String = (
    "usage: kci build --buck2 <path> --repo-root <dir> --publishable <file>"
    " [--only <target> ...] [--buck2-config <k=v> ...] [--target-platforms <p>]"
    " --probe-target <target> [--probe-timeout-s <n>] [--build-timeout-s <n>]"
    " --out-dir <dir> --log-dir <dir>"
)


struct BuildFlags(Copyable, Movable):
    """The parsed request; `help` set means nothing else was checked.

    Layout: owned values only. No pointer field."""

    var request: BuildRequest
    var help: Bool

    def __init__(out self):
        self.request = BuildRequest()
        self.help = False


def _refuse(why: String) raises:
    raise Error(String("kci build: ") + why + String("\n") + String(BUILD_USAGE))


def _is_value_flag(name: String) -> Bool:
    return (
        name == "--buck2"
        or name == "--repo-root"
        or name == "--publishable"
        or name == "--only"
        or name == "--buck2-config"
        or name == "--target-platforms"
        or name == "--probe-target"
        or name == "--probe-timeout-s"
        or name == "--build-timeout-s"
        or name == "--out-dir"
        or name == "--log-dir"
    )


def _set_once(mut slot: String, name: String, var value: String) raises:
    if slot.byte_length() > 0:
        _refuse(name + String(" is given twice"))
    slot = value^


def _positive_int(name: String, value: String) raises -> Int:
    var b = value.as_bytes()
    if len(b) == 0 or len(b) > 9:
        _refuse(name + String(" must be a positive whole number of seconds; got '") + value + String("'"))
    var n = 0
    for i in range(len(b)):
        if b[i] < UInt8(48) or b[i] > UInt8(57):
            _refuse(name + String(" must be a positive whole number of seconds; got '") + value + String("'"))
        n = n * 10 + Int(b[i] - UInt8(48))
    if n == 0:
        _refuse(name + String(" must be a positive whole number of seconds; got '") + value + String("'"))
    return n


def _check_config(kv: String) raises:
    var eq = kv.find(String("="))
    if eq <= 0:
        _refuse(String("--buck2-config '") + kv + String("' is not key=value"))
    var key = String(kv[byte = :eq])
    if key == "komira.execution":
        _refuse(String("--buck2-config may not set komira.execution: kci build always builds on the farm"))
    if key == "kci.probe_nonce":
        _refuse(String("--buck2-config may not set kci.probe_nonce: kci build sets it"))


def parse_build_flags(args: List[String]) raises -> BuildFlags:
    """Parse `args` (the arguments AFTER the verb). RAISES on every refusal
    in the file header, with the usage line appended."""
    var flags = BuildFlags()
    var probe_timeout = String("")
    var build_timeout = String("")
    var i = 0
    while i < len(args):
        var a = args[i].copy()
        i += 1
        if a == "--help":
            flags.help = True
            return flags^
        if not a.startswith(String("--")):
            _refuse(String("unexpected argument '") + a + String("'"))
        var name = a.copy()
        var value = String("")
        var eq = a.find(String("="))
        if eq >= 0:
            name = String(a[byte = :eq])
            value = String(a[byte = eq + 1 :])
        if not _is_value_flag(name):
            _refuse(String("unknown flag '") + name + String("'"))
        if eq < 0:
            if i >= len(args):
                _refuse(name + String(" needs a value"))
            value = args[i].copy()
            i += 1
        if value.strip().byte_length() == 0:
            _refuse(name + String(" has an EMPTY value"))
        ref r = flags.request
        if name == "--buck2":
            _set_once(r.buck2_path, name, value^)
        elif name == "--repo-root":
            _set_once(r.repo_root, name, value^)
        elif name == "--publishable":
            _set_once(r.publishable_file, name, value^)
        elif name == "--only":
            var problem = label_problem(value)
            if problem.byte_length() > 0:
                _refuse(String("--only '") + value + String("' ") + problem)
            for j in range(len(r.only)):
                if r.only[j] == value:
                    _refuse(String("--only ") + value + String(" is given twice"))
            r.only.append(value^)
        elif name == "--buck2-config":
            _check_config(value)
            r.buck2_config.append(value^)
        elif name == "--target-platforms":
            _set_once(r.target_platforms, name, value^)
        elif name == "--probe-target":
            _set_once(r.probe_target, name, value^)
        elif name == "--probe-timeout-s":
            _set_once(probe_timeout, name, value^)
        elif name == "--build-timeout-s":
            _set_once(build_timeout, name, value^)
        elif name == "--out-dir":
            _set_once(r.out_dir, name, value^)
        else:
            _set_once(r.log_dir, name, value^)
    ref r = flags.request
    if r.buck2_path.byte_length() == 0:
        _refuse(String("--buck2 is required"))
    if r.repo_root.byte_length() == 0:
        _refuse(String("--repo-root is required"))
    if r.publishable_file.byte_length() == 0:
        _refuse(String("--publishable is required"))
    if r.probe_target.byte_length() == 0:
        _refuse(String("--probe-target is required"))
    if r.out_dir.byte_length() == 0:
        _refuse(String("--out-dir is required"))
    if r.log_dir.byte_length() == 0:
        _refuse(String("--log-dir is required"))
    if probe_timeout.byte_length() > 0:
        r.probe_timeout_s = _positive_int(String("--probe-timeout-s"), probe_timeout)
    if build_timeout.byte_length() > 0:
        r.build_timeout_s = _positive_int(String("--build-timeout-s"), build_timeout)
    return flags^
