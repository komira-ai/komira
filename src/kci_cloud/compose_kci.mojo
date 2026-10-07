# =============================================================================
# kci_cloud/compose_kci.mojo: the `kci` namespace, which holds the composite
#   definitions kci ships.
# =============================================================================
#
# kci ships two definitions, `kci.job` and `kci.app`, as files of the
# `kci_composites` package. They are DATA, read by the same loader as any
# author's definition (compose_load.mojo's load), and nothing in expansion
# branches on them. The one rule this module adds is that the namespace is
# kci's: a definition named `kci.<name>` is refused at load unless its name,
# version and digest are one of the rows below, so an author's file named
# `kci.job` cannot stand in for kci's. A changed definition is a new
# version, so a row is added, never edited; the welded test of
# `kci_composites` holds each shipped file to its row.
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
    (`compose_load.definition_digest`)."""
    var l = List[ShippedDefinition]()
    l.append(
        ShippedDefinition(
            String("kci.job"), String("1"), String("sha256:5f6725e11b62fc3659f232b0ec3e406cf1d01a4593c336f868dc16d728da8f35")
        )
    )
    l.append(
        ShippedDefinition(
            String("kci.app"), String("1"), String("sha256:809b753a464621b58aae999d33a5efc9216e094010bccc814a9c330483d06d08")
        )
    )
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
