# =============================================================================
# src/kci_cli/args.mojo -- the `kci` command line up to the verb: kci's own
#   options, then the verb, then the verb's arguments, untouched.
# =============================================================================
#
#   kci [--secret-store <none|env>] build   <kci build flags>
#   kci [--secret-store <none|env>] publish <kci publish flags>
#   kci --help
#
# kci's own options come BEFORE the verb; everything after the verb belongs
# to the verb and is handed to its library unread (so `kci build --help` is
# the build verb's help). The verbs' flags are parsed by kci_build and
# kci_publish, never here.
#
#   --secret-store <kind>   which SecretStore resolves a secret NAME:
#                           `none` (default) resolves nothing and refuses,
#                           naming the secret; `env` reads the environment
#                           variable whose name is the secret's name
#                           (komira_secret_env). No flag takes a secret
#                           VALUE. Only `publish` resolves secrets, so the
#                           option is refused with `build`.
#   --help, -h              kci's usage; exit 0.
#
# Every refusal here is exit 2 (the verbs' own usage code), before any verb
# runs: no verb, an unknown verb, an unknown option, an option given twice,
# an empty or unknown --secret-store value, a missing value.
#
# The verbs are named as the CEO decided for the first release (`build`,
# `publish`); the release-machine form (`kci open-source build` /
# `kci open-source deploy-and-validate <env>`) is a follow-up.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================


comptime EXIT_KCI_OK: Int = 0
comptime EXIT_KCI_USAGE: Int = 2

comptime VERB_BUILD: String = "build"
comptime VERB_PUBLISH: String = "publish"

comptime KCI_USAGE: String = (
    "usage: kci [--secret-store <none|env>] <verb> [<verb flags>]\n"
    "verbs:\n"
    "  build    build every artifact of a declarations file at --revision-id"
    " into a release directory (kci build --help)\n"
    "  publish  publish a release directory to a conda channel, or refuse it"
    " whole; --dry-run reads only (kci publish --help)\n"
    "options (before the verb):\n"
    "  --secret-store <none|env>  how a channel credential's secret NAME is"
    " resolved: none (default) refuses; env reads the environment variable"
    " of that name. publish only."
)


struct SecretStoreChoice(Copyable, Movable, Equatable):
    """Which `SecretStore` the shell composes for a verb. Layout: one Int."""

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


struct KciInvocation(Copyable, Movable):
    """The parsed command line. `help` set means nothing else was read: the
    caller prints `KCI_USAGE` and stops.

    Layout: owned values only. No pointer field."""

    var help: Bool
    var verb: String
    var store: SecretStoreChoice
    var verb_args: List[String]

    def __init__(out self):
        self.help = False
        self.verb = String("")
        self.store = SecretStoreChoice.NONE
        self.verb_args = List[String]()


def _refuse(why: String) -> Error:
    return Error(String("kci: ") + why + String("\n") + String(KCI_USAGE))


def _store_choice(value: String) raises -> SecretStoreChoice:
    if value == String("none"):
        return SecretStoreChoice.NONE
    if value == String("env"):
        return SecretStoreChoice.ENV
    if value.byte_length() == 0:
        raise _refuse(String("--secret-store needs a value: none or env"))
    raise _refuse(
        String("--secret-store '") + value + String("' is not a store kind: none or env")
    )


def parse_kci_args(args: List[String]) raises -> KciInvocation:
    """`args` is argv without the program name. RAISES with the refusal (its
    text ends with the usage); nothing is read or run."""
    var inv = KciInvocation()
    var store_seen = False
    var i = 0
    while i < len(args):
        var a = args[i]
        if a == String("--help") or a == String("-h"):
            inv.help = True
            return inv^
        if a == String("--secret-store") or a.startswith(String("--secret-store=")):
            if store_seen:
                raise _refuse(String("--secret-store given twice"))
            store_seen = True
            var value: String
            if a == String("--secret-store"):
                if i + 1 >= len(args):
                    raise _refuse(String("--secret-store needs a value: none or env"))
                i += 1
                value = args[i]
            else:
                value = String(a[byte = len(String("--secret-store=")):])
            inv.store = _store_choice(value)
            i += 1
            continue
        if a.startswith(String("-")):
            raise _refuse(String("unknown option '") + a + String("' before the verb"))
        if a != String(VERB_BUILD) and a != String(VERB_PUBLISH):
            raise _refuse(String("unknown verb '") + a + String("': build or publish"))
        inv.verb = a.copy()
        for j in range(i + 1, len(args)):
            inv.verb_args.append(args[j].copy())
        break
    if inv.verb.byte_length() == 0:
        raise _refuse(String("no verb: build or publish"))
    if inv.verb == String(VERB_BUILD) and store_seen:
        raise _refuse(
            String("--secret-store applies to publish only; kci build resolves no secret")
        )
    return inv^
