# =============================================================================
# src/kci_contract/revision.mojo -- revision ids and artifact references.
# =============================================================================
#
# A REVISION is a full commit id: exactly 40 lowercase hex digits. An
# abbreviated id names a commit only as long as no other commit shares its
# prefix, so kci never accepts one.
#
# An artifact is referenced as (revision, platform, name): the commit it was
# built from, the platform it was built for (platform.mojo; `noarch` for an
# artifact that runs anywhere), and its declared name. Two runs of the same
# commit on two platforms make two different artifacts with one name, and
# the same name at two commits is two artifacts; the reference names
# exactly one.
#
# Pure functions over owned values; no pointer.
# =============================================================================

from kci_contract.platform import require_artifact_platform


def _is_lower_hex(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def is_full_commit_id(id: String) -> Bool:
    """True iff `id` is exactly 40 lowercase hex digits."""
    return id.byte_length() == 40 and _is_lower_hex(id)


def require_full_commit_id(what: String, id: String) raises:
    """Refuse unless `id` is a full commit id (file header). `what` names the
    value in the message (`--revision-id`, `revision_id`)."""
    if not is_full_commit_id(id):
        raise Error(
            what
            + String(" '")
            + id
            + String("' is not a full commit id (exactly 40 lowercase hex digits; an")
            + String(" abbreviated id is refused)")
        )


struct ArtifactRef(Copyable, Movable, Equatable):
    """One artifact: the revision it was built from, its platform, its name.
    Built only through the checking constructor.

    Layout: owned Strings. No pointer field."""

    var revision: String
    var platform: String
    var name: String

    def __init__(out self, var revision: String, var platform: String, var name: String) raises:
        require_full_commit_id(String("revision"), revision)
        require_artifact_platform(platform)
        if name.byte_length() == 0:
            raise Error(String("an artifact reference needs a name"))
        if name.find(String("/")) >= 0 or name.find(String("@")) >= 0:
            raise Error(String("artifact name '") + name + String("' holds '/' or '@'"))
        self.revision = revision^
        self.platform = platform^
        self.name = name^

    def __eq__(self, other: Self) -> Bool:
        return (
            self.revision == other.revision
            and self.platform == other.platform
            and self.name == other.name
        )

    def display(self) -> String:
        """`<name>@<revision>/<platform>`: how output names an artifact, so
        the revision is always part of the name."""
        return self.name + String("@") + self.revision + String("/") + self.platform
