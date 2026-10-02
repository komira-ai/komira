# =============================================================================
# src/kci_publish/flags.mojo -- the `kci publish` flags, parsed into
#   `PublishFlags` before anything is read or sent.
# =============================================================================
#
#   --declarations <file>        the artifact declarations (what the release is)
#   --artifacts <dir>            the release directory `kci build` wrote
#   --channels <file>            the channels file (kci_release_channel)
#   --channel <name>             the channel to publish to, declared there
#   --release-version <file>     release_version.sh's stdout for the release
#                                commit, run by the publish job
#   --expect-set-hash <64 hex>   the set hash that was approved
#   [--claim-new-name <name>]    a name this run may claim for the first
#                                time (repeat for several)
#   --report <file>              where the JSON report is written
#   [--require-environment <name>]  OIDC only: the job's `environment` claim
#   [--dry-run]                  steps 0 and 1 only: reads, no write
#   [--help]
#
# A value may follow its flag as the next argument or after `=`. Every flag
# not in brackets is required, and a missing one is refused naming the flag.
# A flag given twice (other than `--claim-new-name`), a claim given twice, an
# unknown flag, an EMPTY value, a positional argument and an
# `--expect-set-hash` that is not 64 lowercase hex are each refused too.
# Every refusal here is exit 2, before any file is read or any request sent.
#
# GONE: `--credential` (the channel's repository declares its credential, and
# nothing on the command line may override it) and `--approved-names` (the
# names an upload may claim are the ones the channel already holds plus
# `--claim-new-name`). Both are now unknown flags. There is no
# `--concurrency` (see `run.mojo`'s header: uploads are sequential).
#
# ⛔ NO SECRET IN ARGV: no flag takes a token.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_pkg_upload.identity import ascii_lower

from .verify import is_lower_hex_64


comptime PUBLISH_USAGE: String = (
    "usage: kci publish --declarations <file> --artifacts <release dir>"
    " --channels <file> --channel <name> --release-version <file>"
    " --expect-set-hash <64 hex> [--claim-new-name <name> ...]"
    " --report <file> [--require-environment <name>] [--dry-run]"
)


struct PublishFlags(Copyable, Movable):
    """The parsed flags. `help` set means nothing else was checked: the
    caller prints the usage and stops.

    Layout: owned values only. No pointer field."""

    var declarations_file: String
    var artifacts_dir: String
    var channels_file: String
    var channel: String
    var release_version_file: String
    var expect_set_hash: String
    var claims: List[String]
    var report_file: String
    var require_environment: String
    var dry_run: Bool
    var help: Bool

    def __init__(out self):
        self.declarations_file = String("")
        self.artifacts_dir = String("")
        self.channels_file = String("")
        self.channel = String("")
        self.release_version_file = String("")
        self.expect_set_hash = String("")
        self.claims = List[String]()
        self.report_file = String("")
        self.require_environment = String("")
        self.dry_run = False
        self.help = False


def _refuse(why: String) raises:
    raise Error(String("kci publish: ") + why + String("\n") + String(PUBLISH_USAGE))


def _value_flags() -> List[String]:
    var f = List[String]()
    f.append(String("--declarations"))
    f.append(String("--artifacts"))
    f.append(String("--channels"))
    f.append(String("--channel"))
    f.append(String("--release-version"))
    f.append(String("--expect-set-hash"))
    f.append(String("--claim-new-name"))
    f.append(String("--report"))
    f.append(String("--require-environment"))
    return f^


def _set_once(mut slot: String, name: String, var value: String) raises:
    if slot.byte_length() > 0:
        _refuse(name + String(" is given twice"))
    slot = value^


def parse_publish_flags(args: List[String]) raises -> PublishFlags:
    """Parse `args` (the arguments AFTER the program or verb name). RAISES
    on every refusal in the file header, with the usage line appended."""
    var flags = PublishFlags()
    var known = _value_flags()
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
        var is_known = False
        for k in range(len(known)):
            if known[k] == name:
                is_known = True
        if not is_known:
            _refuse(String("unknown flag '") + name + String("'"))
        if not has_value:
            if i >= len(args):
                _refuse(name + String(" needs a value"))
            value = args[i].copy()
            i += 1
        if value.strip().byte_length() == 0:
            _refuse(name + String(" has an EMPTY value"))
        if name == "--declarations":
            _set_once(flags.declarations_file, name, value^)
        elif name == "--artifacts":
            _set_once(flags.artifacts_dir, name, value^)
        elif name == "--channels":
            _set_once(flags.channels_file, name, value^)
        elif name == "--channel":
            _set_once(flags.channel, name, value^)
        elif name == "--release-version":
            _set_once(flags.release_version_file, name, value^)
        elif name == "--expect-set-hash":
            if not is_lower_hex_64(value):
                _refuse(
                    String("--expect-set-hash must be 64 lowercase hex characters; got '")
                    + value
                    + String("'")
                )
            _set_once(flags.expect_set_hash, name, value^)
        elif name == "--claim-new-name":
            for k in range(len(flags.claims)):
                if ascii_lower(flags.claims[k]) == ascii_lower(value):
                    _refuse(String("--claim-new-name '") + value + String("' is given twice"))
            flags.claims.append(value^)
        elif name == "--report":
            _set_once(flags.report_file, name, value^)
        else:
            _set_once(flags.require_environment, name, value^)
    var missing = List[String]()
    if flags.declarations_file.byte_length() == 0:
        missing.append(String("--declarations"))
    if flags.artifacts_dir.byte_length() == 0:
        missing.append(String("--artifacts"))
    if flags.channels_file.byte_length() == 0:
        missing.append(String("--channels"))
    if flags.channel.byte_length() == 0:
        missing.append(String("--channel"))
    if flags.release_version_file.byte_length() == 0:
        missing.append(String("--release-version"))
    if flags.expect_set_hash.byte_length() == 0:
        missing.append(String("--expect-set-hash"))
    if flags.report_file.byte_length() == 0:
        missing.append(String("--report"))
    if len(missing) > 0:
        _refuse(String("missing required flag(s): ") + String(", ").join(missing))
    return flags^
