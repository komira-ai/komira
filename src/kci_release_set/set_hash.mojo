# =============================================================================
# src/kci_release_set/set_hash.mojo -- the one hash that names a release set.
# =============================================================================
#
# For every artifact of the set, the metapackage included, one line
#
#   <name> TAB <version> TAB <build> TAB <sha256> LF
#
# the lines sorted bytewise and concatenated, and the sha256 of that text in
# 64 lowercase hex characters. The order the artifacts arrive in does not
# change it; changing any field of any line does. A field holding a TAB or a
# LF would make two different sets hash alike, so it is refused, as is a
# sha256 that is not 64 lowercase hex characters. An empty set is refused:
# there is nothing to approve.
#
# `kci build` prints it, `release.json` carries it, and `kci publish`
# recomputes it from the bytes on disk and compares it with the hash the
# release was approved under.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256_string

from kci_artifact_manifest import is_sha256_hex

from kci_release_set.member import ReleaseMember


struct SetHashLine(Copyable, Movable):
    """One artifact's line of the set hash.

    Layout: owned values only. No pointer field."""

    var name: String
    var version: String
    var build: String
    var sha256_hex: String

    def __init__(
        out self, var name: String, var version: String, var build: String, var sha256_hex: String
    ):
        self.name = name^
        self.version = version^
        self.build = build^
        self.sha256_hex = sha256_hex^


def _field(line: SetHashLine, what: String, value: String) raises:
    if value.find(String("\t")) >= 0 or value.find(String("\n")) >= 0:
        raise Error(
            String("release set hash: ")
            + line.name
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


def set_hash_text(lines: List[SetHashLine]) raises -> String:
    """The text that is hashed: every line, sorted bytewise."""
    if len(lines) == 0:
        raise Error(String("release set hash: the set is EMPTY"))
    var rendered = List[String]()
    for i in range(len(lines)):
        ref l = lines[i]
        _field(l, String("name"), l.name)
        _field(l, String("version"), l.version)
        _field(l, String("build"), l.build)
        if not is_sha256_hex(l.sha256_hex):
            raise Error(
                String("release set hash: ")
                + l.name
                + String(": sha256 is not 64 lowercase hex characters")
            )
        rendered.append(
            l.name + String("\t") + l.version + String("\t") + l.build + String("\t")
            + l.sha256_hex + String("\n")
        )
    sort_bytewise(rendered)
    var text = String("")
    for i in range(len(rendered)):
        text += rendered[i]
    return text^


def set_hash_of_lines(lines: List[SetHashLine]) raises -> String:
    """The set hash of `lines` (file header)."""
    return hex_lower_array_32(sha256_string(set_hash_text(lines)))


def release_set_hash(members: List[ReleaseMember]) raises -> String:
    """The set hash of verified members: one line each, from its manifest's
    `name`, `version` and `sha256` and its metadata's `build`."""
    var lines = List[SetHashLine]()
    for i in range(len(members)):
        ref m = members[i]
        lines.append(
            SetHashLine(
                m.manifest.name.copy(),
                m.manifest.version.copy(),
                m.build(),
                m.manifest.sha256_hex.copy(),
            )
        )
    return set_hash_of_lines(lines)
