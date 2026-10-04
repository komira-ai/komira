# =============================================================================
# src/kci_release_set/set_hash.mojo -- the one hash that names a release set.
# =============================================================================
#
# The hashed text (major 2 of kci.release_set) is a header line
#
#   release_set TAB 2 TAB <revision> TAB <platform> LF
#
# then, for every artifact of the set (the metapackage included), one line
#
#   <name> TAB <platform> TAB <version> TAB <build> TAB <subdir> TAB
#   <artifact_type> TAB <sha256> LF
#
# the member lines sorted bytewise; the hash is the sha256 of the whole text
# in 64 lowercase hex characters. The REVISION (the full commit id the set
# was built from) and the PLATFORM are in the hash, so an approval of one
# commit's set cannot be replayed onto another commit's or another
# platform's run. Who built it (release.json's `produced_by`) is NOT: an
# identical rebuild keeps its hash.
#
# The order the artifacts arrive in does not change the hash; changing any
# field of any line, the revision or the platform does. A field holding a
# TAB or a LF would make two different sets hash alike, so it is refused,
# as is a sha256 that is not 64 lowercase hex characters, a revision that is
# not a full commit id and a platform kci does not release. An empty set is
# refused: there is nothing to approve.
#
# The BUILD step prints it, `release.json` carries it, and the PUBLISH step
# recomputes it from the bytes on disk and compares it with the hash the
# release was approved under.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256_string

from kci_artifact_manifest import is_sha256_hex
from kci_contract import FORMAT_RELEASE_SET, current_major, require_full_commit_id, require_release_platform


struct SetHashLine(Copyable, Movable):
    """One artifact's line of the set hash.

    Layout: owned values only. No pointer field."""

    var name: String
    var platform: String
    var version: String
    var build: String
    var subdir: String
    var artifact_type: String
    var sha256_hex: String

    def __init__(
        out self,
        var name: String,
        var platform: String,
        var version: String,
        var build: String,
        var subdir: String,
        var artifact_type: String,
        var sha256_hex: String,
    ):
        self.name = name^
        self.platform = platform^
        self.version = version^
        self.build = build^
        self.subdir = subdir^
        self.artifact_type = artifact_type^
        self.sha256_hex = sha256_hex^


def _field(name: String, what: String, value: String) raises:
    if value.find(String("\t")) >= 0 or value.find(String("\n")) >= 0:
        raise Error(
            String("release set hash: ")
            + name
            + String(": ")
            + what
            + String(" holds a TAB or a newline")
        )


def bytewise_less(a: String, b: String) -> Bool:
    """True iff `a` sorts before `b` comparing bytes as unsigned."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = min(len(x), len(y))
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def sort_bytewise(mut items: List[String]):
    """Sort `items` in place, bytewise (insertion sort: sets are small)."""
    for i in range(1, len(items)):
        var j = i
        while j > 0 and bytewise_less(items[j], items[j - 1]):
            var t = items[j].copy()
            items[j] = items[j - 1].copy()
            items[j - 1] = t^
            j -= 1


def set_hash_text(revision: String, platform: String, lines: List[SetHashLine]) raises -> String:
    """The text that is hashed: the header line, then every member line
    sorted bytewise (file header)."""
    require_full_commit_id(String("release set hash: revision"), revision)
    require_release_platform(platform)
    if len(lines) == 0:
        raise Error(String("release set hash: the set is EMPTY"))
    var rendered = List[String]()
    for i in range(len(lines)):
        ref l = lines[i]
        _field(l.name, String("name"), l.name)
        _field(l.name, String("platform"), l.platform)
        _field(l.name, String("version"), l.version)
        _field(l.name, String("build"), l.build)
        _field(l.name, String("subdir"), l.subdir)
        _field(l.name, String("artifact_type"), l.artifact_type)
        if not is_sha256_hex(l.sha256_hex):
            raise Error(
                String("release set hash: ")
                + l.name
                + String(": sha256 is not 64 lowercase hex characters")
            )
        rendered.append(
            l.name + String("\t") + l.platform + String("\t") + l.version + String("\t")
            + l.build + String("\t") + l.subdir + String("\t") + l.artifact_type + String("\t")
            + l.sha256_hex + String("\n")
        )
    sort_bytewise(rendered)
    var text = (
        String("release_set\t") + String(current_major(String(FORMAT_RELEASE_SET))) + String("\t")
        + revision + String("\t") + platform + String("\n")
    )
    for i in range(len(rendered)):
        text += rendered[i]
    return text^


def set_hash_of_lines(revision: String, platform: String, lines: List[SetHashLine]) raises -> String:
    """The set hash of `lines` built from `revision` for `platform` (file
    header)."""
    return hex_lower_array_32(sha256_string(set_hash_text(revision, platform, lines)))
