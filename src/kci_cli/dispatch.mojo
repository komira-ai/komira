# =============================================================================
# src/kci_cli/dispatch.mojo -- argv to one verb call, through the `KciVerbs`
#   seam.
# =============================================================================
#
# `kci_main_with` parses kci's own options (args.mojo), then calls exactly
# one method of `verbs` with the verb's arguments, unread, and returns its
# exit code. `LibraryVerbs` (library_verbs.mojo) is the real one: each
# method composes what the verb needs and calls its library. The welded
# tests drive a recording fake.
#
# Encapsulation: owned values and a generic seam; no pointer, no wildcard
# origin.
# =============================================================================

from .args import (
    EXIT_KCI_OK,
    EXIT_KCI_USAGE,
    KCI_USAGE,
    VERB_BUILD,
    KciInvocation,
    SecretStoreChoice,
    parse_kci_args,
)


trait KciVerbs:
    """One method per verb: the verb's arguments in, its exit code out."""

    def build(mut self, args: List[String]) -> Int:
        ...

    def publish(mut self, args: List[String], store: SecretStoreChoice) -> Int:
        ...


def kci_main_with[V: KciVerbs](args: List[String], mut verbs: V) -> Int:
    """`kci <args>`: parse, print the usage or a refusal, or run one verb.
    Returns the exit code (the verb's own, or 2 for a kci usage error)."""
    var inv: KciInvocation
    try:
        inv = parse_kci_args(args)
    except e:
        print(String(e))
        return EXIT_KCI_USAGE
    if inv.help:
        print(String(KCI_USAGE))
        return EXIT_KCI_OK
    if inv.verb == String(VERB_BUILD):
        return verbs.build(inv.verb_args)
    return verbs.publish(inv.verb_args, inv.store)
