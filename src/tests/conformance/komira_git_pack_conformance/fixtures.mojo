# =============================================================================
# komira_git_pack_conformance/fixtures.mojo -- reading what gen_packs.sh wrote:
# the files of the `packs` directory, `git cat-file --batch` dumps, and the
# normalized `git verify-pack -v` listings.
# =============================================================================

from std.collections import Dict
from std.pathlib import Path

from komira_runtime_paths import data_path

from komira_git import ObjectFormat, ObjectId, ObjectKind


def read_fixture(name: String) raises -> List[UInt8]:
    """The bytes of `packs/<name>` (the test's staged data)."""
    return Path(data_path("packs/" + name)).read_bytes()


def _line_end(data: Span[UInt8, _], start: Int) raises -> Int:
    for i in range(start, len(data)):
        if data[i] == 10:
            return i
    raise Error("fixtures: no newline after offset " + String(start))


def _words(data: Span[UInt8, _], start: Int, end: Int) -> List[String]:
    var out = List[String]()
    var cur = String()
    for i in range(start, end):
        var c = Int(data[i])
        if c == 32:
            if cur.byte_length() > 0:
                out.append(cur)
                cur = String()
        else:
            cur += chr(c)
    if cur.byte_length() > 0:
        out.append(cur)
    return out^


struct GitObjects(Movable):
    """Every object of a repository, as `git cat-file --batch` printed it."""

    var format: ObjectFormat
    var ids: List[ObjectId]
    var kinds: List[ObjectKind]
    var payloads: List[List[UInt8]]
    var _by_id: Dict[String, Int]

    def __init__(out self, format: ObjectFormat):
        self.format = format
        self.ids = List[ObjectId]()
        self.kinds = List[ObjectKind]()
        self.payloads = List[List[UInt8]]()
        self._by_id = Dict[String, Int]()

    def count(self) -> Int:
        return len(self.ids)

    def find(self, id: ObjectId) -> Int:
        """The position of `id`, or -1."""
        try:
            return self._by_id[id.to_hex()]
        except:
            return -1


def parse_batch(format: ObjectFormat, data: Span[UInt8, _]) raises -> GitObjects:
    """Read `<id> <type> <size>\\n<payload>\\n` records to the end."""
    var out = GitObjects(format)
    var p = 0
    while p < len(data):
        var nl = _line_end(data, p)
        var w = _words(data, p, nl)
        if len(w) != 3:
            raise Error("fixtures: batch header at " + String(p) + " has " + String(len(w)) + " fields")
        var id = ObjectId.parse_hex(format, w[0])
        var kind = ObjectKind.from_name(w[1].as_bytes())
        var size = Int(w[2])
        var start = nl + 1
        if start + size + 1 > len(data) or data[start + size] != 10:
            raise Error("fixtures: batch payload of " + w[0] + " is not " + String(size) + " bytes and a newline")
        var payload = List[UInt8](capacity=size)
        payload.extend(data[start : start + size])
        out._by_id[id.to_hex()] = len(out.ids)
        out.ids.append(id)
        out.kinds.append(kind)
        out.payloads.append(payload^)
        p = start + size + 1
    return out^


struct VerifyLine(Copyable, Movable):
    """One object line of `git verify-pack -v`, normalized by gen_packs.sh:
    id, type, size, size in the pack, offset, depth (0 for a non-delta) and
    base id (`-` for a non-delta)."""

    var id: String
    var kind: String
    var size: Int
    var packed_size: Int
    var offset: Int
    var depth: Int
    var base: String

    def __init__(out self, var words: List[String]) raises:
        self.id = words[0]
        self.kind = words[1]
        self.size = Int(words[2])
        self.packed_size = Int(words[3])
        self.offset = Int(words[4])
        self.depth = Int(words[5])
        self.base = words[6]


def parse_verify(data: Span[UInt8, _]) raises -> List[VerifyLine]:
    """Every line of a `<name>.verify` file."""
    var out = List[VerifyLine]()
    var p = 0
    while p < len(data):
        var nl = _line_end(data, p)
        var w = _words(data, p, nl)
        if len(w) != 7:
            raise Error("fixtures: verify line at " + String(p) + " has " + String(len(w)) + " fields")
        out.append(VerifyLine(w^))
        p = nl + 1
    return out^


def parse_ids(data: Span[UInt8, _]) raises -> List[String]:
    """One id per line (thin.ids)."""
    var out = List[String]()
    var p = 0
    while p < len(data):
        var nl = _line_end(data, p)
        var w = _words(data, p, nl)
        if len(w) != 1:
            raise Error("fixtures: id line at " + String(p) + " has " + String(len(w)) + " fields")
        out.append(w[0])
        p = nl + 1
    return out^
