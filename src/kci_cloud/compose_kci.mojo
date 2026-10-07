# =============================================================================
# kci_cloud/compose_kci.mojo: the `kci` namespace, which holds the composite
#   definitions kci ships.
# =============================================================================
#
# The definitions kci ships are DATA, read by the same loader as any
# author's definition (compose.mojo's load), and nothing in expansion
# branches on them. The one rule this module adds is that the namespace is
# kci's: a definition named `kci.<name>` is refused at load unless its name,
# version and digest are one of the rows below (none yet), so an author's
# file cannot stand in for one of kci's. A changed definition is a new
# version, so a row is added, never edited.
# =============================================================================


comptime KCI_NAMESPACE = "kci"
"""The namespace of the definitions kci ships."""


struct ShippedDefinition(Copyable, Movable):
    """One definition kci ships: its name, version and digest."""

    var name: String
    var version: String
    var digest: String

    def __init__(out self, name: String, version: String, digest: String):
        self.name = name.copy()
        self.version = version.copy()
        self.digest = digest.copy()


def shipped_definitions() -> List[ShippedDefinition]:
    """Every definition kci ships, by name, version and digest
    (`compose_load.definition_digest`): none yet."""
    var l = List[ShippedDefinition]()
    return l^


def kci_definition_problem(name: String, version: String, digest: String) -> String:
    """Why a definition of `name`, `version` and `digest` is refused as a
    stand-in for one kci ships, or empty (any other namespace is the
    author's)."""
    if not name.startswith(String(KCI_NAMESPACE) + String(".")):
        return String("")
    var shipped = shipped_definitions()
    var versions = String("")
    for i in range(len(shipped)):
        ref s = shipped[i]
        if s.name != name:
            continue
        if s.version == version and s.digest == digest:
            return String("")
        versions += (String(", ") if versions.byte_length() > 0 else String("")) + s.name + String("@") + s.version + String(" ") + s.digest
    return (
        String("the kci namespace holds the definitions kci ships, and ")
        + name
        + String("@")
        + version
        + String(" ")
        + digest
        + String(" is not one of them")
        + ((String(" (kci ships: ") + versions + String(")")) if versions.byte_length() > 0 else String(""))
        + String("; name an author's definition in the author's own namespace")
    )
