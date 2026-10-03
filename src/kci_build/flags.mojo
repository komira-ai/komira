# =============================================================================
# src/kci_build/flags.mojo -- the `kci build` flags, parsed into a
#   `BuildRequest` before anything is read or run.
# =============================================================================
#
#   --declarations <file>      the artifact declarations
#                              (kci_artifact_declaration): what to build, and
#                              with which program and args
#   --work-dir <abs dir>       the cwd of every build (an absolute path)
#   --out-dir <dir>            absent or empty; becomes the release directory
#   --log-dir <dir>            each build's stdout and stderr go here; never
#                              --out-dir itself or a directory under it (the
#                              build refuses that before anything runs, after
#                              resolving both paths: build.mojo
#                              `check_log_dir`)
#   --revision-id <commit>     the release commit: a FULL commit id, exactly
#                              40 lowercase hex digits (an abbreviated id is
#                              refused here); it must be the commit checked
#                              out in --work-dir, in a clone with full
#                              history (revision.mojo), and the stamp is
#                              derived from it
#   [--build-timeout-s <n>]    per artifact; default 3600
#   [--help]
#
# Flags only: nothing is read from the environment. Every build-system
# spelling (which buck2, which config file, which platforms) is an arg in
# the declarations file, not a flag here.
#
# A value may follow its flag as the next argument or after `=`. A missing
# required flag, a flag given twice, an unknown flag, an empty value, a
# positional argument, a `--work-dir` that is not an absolute path, a
# `--revision-id` that is not a full 40-hex commit id and a timeout that is
# not a positive integer are each refused, naming the flag.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_artifact_declaration import require_full_commit_id

from kci_build.request import BuildRequest

comptime BUILD_USAGE: String = (
    "usage: kci build --declarations <file> --work-dir <abs dir> --out-dir <dir>"
    " --log-dir <dir> --revision-id <40-hex commit> [--build-timeout-s <n>]"
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
        name == "--declarations"
        or name == "--work-dir"
        or name == "--out-dir"
        or name == "--log-dir"
        or name == "--revision-id"
        or name == "--build-timeout-s"
    )


def _set_once(mut slot: String, name: String, var value: String) raises:
    if slot.byte_length() > 0:
        _refuse(name + String(" is given twice"))
    slot = value^


def _positive_int(name: String, value: String) raises -> Int:
    var b = value.as_bytes()
    var why = name + String(" must be a positive whole number of seconds; got '") + value + String("'")
    if len(b) == 0 or len(b) > 9:
        _refuse(why)
    var n = 0
    for i in range(len(b)):
        if b[i] < UInt8(48) or b[i] > UInt8(57):
            _refuse(why)
        n = n * 10 + Int(b[i] - UInt8(48))
    if n == 0:
        _refuse(why)
    return n


def parse_build_flags(args: List[String]) raises -> BuildFlags:
    """Parse `args` (the arguments AFTER the verb). RAISES on every refusal
    in the file header, with the usage line appended."""
    var flags = BuildFlags()
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
        if name == "--declarations":
            _set_once(r.declarations_file, name, value^)
        elif name == "--work-dir":
            _set_once(r.work_dir, name, value^)
        elif name == "--out-dir":
            _set_once(r.out_dir, name, value^)
        elif name == "--log-dir":
            _set_once(r.log_dir, name, value^)
        elif name == "--revision-id":
            _set_once(r.revision_id, name, value^)
        else:
            _set_once(build_timeout, name, value^)
    ref r = flags.request
    if r.declarations_file.byte_length() == 0:
        _refuse(String("--declarations is required"))
    if r.work_dir.byte_length() == 0:
        _refuse(String("--work-dir is required"))
    if not r.work_dir.startswith(String("/")):
        _refuse(
            String("--work-dir '") + r.work_dir
            + String("' is not an absolute path: it is the cwd every build resolves against")
        )
    if r.out_dir.byte_length() == 0:
        _refuse(String("--out-dir is required"))
    if r.log_dir.byte_length() == 0:
        _refuse(String("--log-dir is required"))
    if r.revision_id.byte_length() == 0:
        _refuse(String("--revision-id is required"))
    try:
        require_full_commit_id(String("--revision-id"), r.revision_id)
    except e:
        _refuse(String(e))
    if build_timeout.byte_length() > 0:
        r.build_timeout_s = _positive_int(String("--build-timeout-s"), build_timeout)
    return flags^
