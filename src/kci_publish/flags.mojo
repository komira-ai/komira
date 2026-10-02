# =============================================================================
# src/kci_publish/flags.mojo -- the `kci publish` flags, parsed into
#   `PublishFlags` before anything is read or sent.
# =============================================================================
#
#   --channels <file>          the channels file (kci_release_channel textproto)
#   --channel <name>           the channel to publish to, declared in that file
#   --artifacts <manifest>     one artifact manifest (repeat for several)
#   --approved-names <file>    the names this run may publish, one per line
#   --credential <spec>        oidc | token-file:<path> | token-secret:<name>
#   [--require-environment <name>]  OIDC only: the job's `environment` claim
#   [--dry-run]                plan only: no credential, no upload
#   [--help]
#
# A value may follow its flag as the next argument or after `=`. Every flag
# not in brackets is required, and a missing one is refused naming the flag.
# A flag given twice (other than `--artifacts`), an unknown flag, an empty
# value and a positional argument are each refused too. Every refusal here
# happens before any file is read or any request is sent.
#
# ⛔ NO SECRET IN ARGV. `/proc/<pid>/cmdline` is world-readable, and so is a
# CI log of the invocation. `--credential` names a FILE PATH or a SECRET NAME,
# never a token, and there is no flag that takes one.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================


comptime CREDENTIAL_OIDC: Int = 1
"""Trusted publishing: the GitHub Actions job's OIDC token, exchanged."""

comptime CREDENTIAL_TOKEN_FILE: Int = 2
"""One registry token, read from a file."""

comptime CREDENTIAL_TOKEN_SECRET: Int = 3
"""One registry token, resolved by name from a secret store."""

comptime _TOKEN_FILE_PREFIX: String = "token-file:"
comptime _TOKEN_SECRET_PREFIX: String = "token-secret:"

comptime PUBLISH_USAGE: String = (
    "usage: kci publish --channels <file> --channel <name>"
    " --artifacts <manifest> [--artifacts <manifest> ...]"
    " --approved-names <file>"
    " --credential oidc|token-file:<path>|token-secret:<name>"
    " [--require-environment <name>] [--dry-run]"
)


struct PublishFlags(Copyable, Movable, Deinitable):
    """The parsed flags. `credential_arg` is the path or secret name after the
    credential kind's prefix (EMPTY for `oidc`). `help` set means nothing
    else was checked: the caller prints the usage and stops.

    Layout: owned values only. No pointer field."""

    var channels_file: String
    var channel: String
    var artifacts: List[String]
    var approved_names_file: String
    var credential_kind: Int
    var credential_arg: String
    var require_environment: String
    var dry_run: Bool
    var help: Bool

    def __init__(out self):
        self.channels_file = String("")
        self.channel = String("")
        self.artifacts = List[String]()
        self.approved_names_file = String("")
        self.credential_kind = 0
        self.credential_arg = String("")
        self.require_environment = String("")
        self.dry_run = False
        self.help = False


def _refuse(why: String) raises:
    raise Error(String("kci publish: ") + why + String("\n") + String(PUBLISH_USAGE))


def _is_value_flag(name: String) -> Bool:
    return (
        name == "--channels"
        or name == "--channel"
        or name == "--artifacts"
        or name == "--approved-names"
        or name == "--credential"
        or name == "--require-environment"
    )


def parse_credential_spec(spec: String, mut flags: PublishFlags) raises:
    """Set the credential kind and argument from `--credential`'s value."""
    if spec == "oidc":
        flags.credential_kind = CREDENTIAL_OIDC
        flags.credential_arg = String("")
        return
    var kinds = List[String]()
    kinds.append(String(_TOKEN_FILE_PREFIX))
    kinds.append(String(_TOKEN_SECRET_PREFIX))
    for i in range(len(kinds)):
        if spec.startswith(kinds[i]):
            var arg = String(spec[byte = kinds[i].byte_length() :])
            if arg.strip().byte_length() == 0:
                _refuse(
                    String("--credential ")
                    + kinds[i]
                    + String(" names no ")
                    + (String("path") if i == 0 else String("secret"))
                )
            flags.credential_kind = (
                CREDENTIAL_TOKEN_FILE if i == 0 else CREDENTIAL_TOKEN_SECRET
            )
            flags.credential_arg = arg^
            return
    _refuse(
        String("--credential must be oidc, token-file:<path> or")
        + String(" token-secret:<name>; got '")
        + spec
        + String("'")
    )


def _set_once(mut slot: String, name: String, var value: String) raises:
    if slot.byte_length() > 0:
        _refuse(name + String(" is given twice"))
    slot = value^


def parse_publish_flags(args: List[String]) raises -> PublishFlags:
    """Parse `args` (the arguments AFTER the program or verb name). RAISES
    on every refusal in the file header, with the usage line appended."""
    var flags = PublishFlags()
    var credential_spec = String("")
    var dry_run_seen = False
    var i = 0
    while i < len(args):
        var a = args[i].copy()
        i += 1
        if a == "--help" or a == "-h":
            flags.help = True
            return flags^
        if a == "--dry-run":
            if dry_run_seen:
                _refuse(String("--dry-run is given twice"))
            dry_run_seen = True
            flags.dry_run = True
            continue
        if not a.startswith(String("--")):
            _refuse(String("unexpected argument '") + a + String("'"))
        var name = a.copy()
        var value = String("")
        var has_value = False
        var eq = a.find(String("="))
        if eq > 0:
            name = String(a[byte=:eq])
            value = String(a[byte = eq + 1 :])
            has_value = True
        if name == "--dry-run":
            _refuse(String("--dry-run takes no value"))
        if not _is_value_flag(name):
            _refuse(String("unknown flag '") + name + String("'"))
        if not has_value:
            if i >= len(args):
                _refuse(name + String(" needs a value"))
            value = args[i].copy()
            i += 1
        if value.strip().byte_length() == 0:
            _refuse(name + String(" has an EMPTY value"))
        if name == "--channels":
            _set_once(flags.channels_file, name, value^)
        elif name == "--channel":
            _set_once(flags.channel, name, value^)
        elif name == "--artifacts":
            flags.artifacts.append(value^)
        elif name == "--approved-names":
            _set_once(flags.approved_names_file, name, value^)
        elif name == "--credential":
            _set_once(credential_spec, name, value^)
        else:
            _set_once(flags.require_environment, name, value^)
    var missing = List[String]()
    if flags.channels_file.byte_length() == 0:
        missing.append(String("--channels"))
    if flags.channel.byte_length() == 0:
        missing.append(String("--channel"))
    if len(flags.artifacts) == 0:
        missing.append(String("--artifacts"))
    if flags.approved_names_file.byte_length() == 0:
        missing.append(String("--approved-names"))
    if credential_spec.byte_length() == 0:
        missing.append(String("--credential"))
    if len(missing) > 0:
        _refuse(String("missing required flag(s): ") + String(", ").join(missing))
    parse_credential_spec(credential_spec, flags)
    if (
        flags.require_environment.byte_length() > 0
        and flags.credential_kind != CREDENTIAL_OIDC
    ):
        _refuse(
            String("--require-environment checks the OIDC token's")
            + String(" `environment` claim, so it needs --credential oidc")
        )
    return flags^
