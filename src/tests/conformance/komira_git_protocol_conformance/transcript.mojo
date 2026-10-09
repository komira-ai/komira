# =============================================================================
# komira_git_protocol_conformance/transcript.mojo -- one scenario of the pinned
# git's transcripts (capture.sh), loaded from the test's share/transcripts/.
# =============================================================================
#
# A scenario is what capture.sh recorded: for each connection the bytes the
# git client wrote (`conn<n>.req`) and the bytes the git server wrote back
# (`conn<n>.resp`), and the server repository as it was before the exchange
# (refs, HEAD, objects, parents, tags), plus the client's shallow list and
# the server's settings where the scenario has them.
# =============================================================================

from std.os.path import exists
from std.pathlib import Path

from komira_git import AdvertisedRef, ObjectFormat, ObjectId
from komira_runtime_paths import data_path


struct Connection(Copyable, Movable):
    """The bytes each way of one connection."""

    var request: List[UInt8]
    var response: List[UInt8]

    def __init__(out self, var request: List[UInt8], var response: List[UInt8]):
        self.request = request^
        self.response = response^


struct Scenario(Movable):
    """One scenario directory of the transcripts."""

    var name: String
    var connections: List[Connection]
    var refs: List[AdvertisedRef]
    var head_target: String
    var objects: List[String]
    var parents: List[String]
    var tags: List[String]
    var shallow_before: List[String]
    var shallow_after: List[String]
    var settings: List[String]
    var parents_after: List[String]

    def __init__(out self, name: String) raises:
        """Load scenario `name`; raises when it has no connection."""
        self.name = name
        self.connections = List[Connection]()
        var n = 1
        while exists(_path(name, "conn" + String(n) + ".req")):
            self.connections.append(
                Connection(
                    Path(_path(name, "conn" + String(n) + ".req")).read_bytes(),
                    Path(_path(name, "conn" + String(n) + ".resp")).read_bytes(),
                )
            )
            n += 1
        if len(self.connections) == 0:
            raise Error("transcripts: scenario " + name + " has no connection")
        self.refs = List[AdvertisedRef]()
        var lines = _lines(name, "refs.txt")
        var sha1 = ObjectFormat.sha1()
        for i in range(len(lines)):
            var f = lines[i].split(" ")
            if len(f) != 3:
                raise Error("transcripts: bad refs.txt line: " + lines[i])
            var peeled: Optional[ObjectId] = None
            if String(f[2]) != "-":
                peeled = ObjectId.parse_hex(sha1, String(f[2]))
            self.refs.append(
                AdvertisedRef(String(f[1]), ObjectId.parse_hex(sha1, String(f[0])), "", peeled)
            )
        var head = _lines(name, "head.txt")
        self.head_target = head[0] if len(head) > 0 else String()
        self.objects = _lines(name, "objects.txt")
        self.parents = _lines(name, "parents.txt")
        self.tags = _lines(name, "tags.txt")
        self.shallow_before = _lines(name, "shallow_before.txt")
        self.shallow_after = _lines(name, "shallow_after.txt")
        self.settings = _lines(name, "settings.txt")
        self.parents_after = _lines(name, "parents_after.txt")

    def has_setting(self, setting: String) -> Bool:
        for i in range(len(self.settings)):
            if self.settings[i] == setting:
                return True
        return False

    def head(self) raises -> Optional[AdvertisedRef]:
        """HEAD as ls-refs lists it: the symbolic ref to `head_target`,
        naming that ref's object, or unborn when the ref does not exist."""
        if self.head_target.byte_length() == 0:
            return None
        for i in range(len(self.refs)):
            if self.refs[i].name == self.head_target:
                return AdvertisedRef("HEAD", self.refs[i].id, self.head_target)
        return AdvertisedRef("HEAD", ObjectId.zero(ObjectFormat.sha1()), self.head_target)


def _path(scenario: String, file: String) raises -> String:
    return data_path("transcripts/" + scenario + "/" + file)


def _lines(scenario: String, file: String) raises -> List[String]:
    """The non-empty lines of a scenario's text file; none when it is
    absent."""
    var out = List[String]()
    var p = _path(scenario, file)
    if not exists(p):
        return out^
    var text = Path(p).read_text()
    var lines = text.split("\n")
    for i in range(len(lines)):
        if lines[i].byte_length() > 0:
            out.append(String(lines[i]))
    return out^


def ids(hexes: List[String]) raises -> List[ObjectId]:
    """Each hex id as a sha1 ObjectId."""
    var out = List[ObjectId]()
    for i in range(len(hexes)):
        out.append(ObjectId.parse_hex(ObjectFormat.sha1(), hexes[i]))
    return out^


def minus(a: List[String], b: List[String]) -> List[String]:
    """The entries of `a` not in `b`, in `a`'s order."""
    var out = List[String]()
    for i in range(len(a)):
        var found = False
        for j in range(len(b)):
            if a[i] == b[j]:
                found = True
        if not found:
            out.append(a[i])
    return out^


def show(b: Span[UInt8, _]) -> String:
    """Printable ASCII as is, every other byte as \\xNN (for messages)."""
    var s = String()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 32 and c < 127:
            s += chr(c)
        else:
            var h = String("0123456789abcdef")
            s += "\\x" + chr(Int(h.as_bytes()[c >> 4])) + chr(Int(h.as_bytes()[c & 15]))
    return s^


def expect_bytes(
    got: List[UInt8], want: Span[UInt8, _], at: Int, what: String
) raises -> Int:
    """`got` must equal `want[at:at+len(got)]`; returns the offset after it.
    The refusal shows both from the first byte that differs."""
    var n = len(got)
    for i in range(n):
        if at + i >= len(want) or got[i] != want[at + i]:
            var end_got = i + 60 if i + 60 < n else n
            var end_want = at + i + 60 if at + i + 60 < len(want) else len(want)
            var w_start = at + i if at + i < len(want) else len(want)
            raise Error(
                what + ": differs from git at byte " + String(at + i)
                + "\n  komira_git: " + show(Span(got)[i:end_got])
                + "\n  git:        " + show(want[w_start:end_want])
            )
    return at + n
