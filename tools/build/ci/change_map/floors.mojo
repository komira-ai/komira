"""Coverage floors only rise: what a change lowers of them.

Each package's coverage floor is its own file, `<package>/coverage_floor.tsv`
(tools/build/coverage/README.md, "The ratchet"). The coverage gate fails a
library measured under its package's floor, and the census check fails a
floor under what the census measured; neither sees the floor the change
started from. This does: `affected --base <rev>` (affected.mojo) reads each
changed floor file at the base and at the head and refuses the change
(BROKEN, which fails the per-change check) when a floor went down, where
`lowered` (covcheck/ratchet.mojo) says what lowering is. A floor file that is
new, or deleted together with its package's BUCK file, lowers nothing; one
deleted while its package stays lowers every floor above 0 it held.
"""

from covcheck.ratchet import Ratchet, lowered, parse_ratchet

comptime FLOOR_FILE = "coverage_floor.tsv"


def is_floor_file(path: String) -> Bool:
    """Whether `path` (a repository path) is a package's floor file."""
    return path == String(FLOOR_FILE) or path.endswith(String("/") + String(FLOOR_FILE))


struct FloorChange(Copyable, Movable):
    """A changed floor file: its text at the base and at the head (each
    with whether it is there at all), and whether its package still has a
    BUCK file at the head."""

    var path: String
    var base: String
    var in_base: Bool
    var head: String
    var in_head: Bool
    var package_stays: Bool

    def __init__(out self, path: String, base: String, in_base: Bool, head: String, in_head: Bool, package_stays: Bool):
        self.path = path
        self.base = base
        self.in_base = in_base
        self.head = head
        self.in_head = in_head
        self.package_stays = package_stays


def floor_refusals(changes: List[FloorChange]) -> List[String]:
    """One message per floor the changes lower (`<path>: <lowered's
    message>`), and one per floor file that cannot be read as a ratchet
    (`<path>: <why>`): a change that makes a floor unreadable is never
    a pass. Empty when no floor went down."""
    var out = List[String]()
    for i in range(len(changes)):
        ref c = changes[i]
        if not c.in_base:
            continue
        if not c.in_head and not c.package_stays:
            continue
        try:
            var base = parse_ratchet(c.base, c.path + String(" at the base"))
            var head = Ratchet()
            if c.in_head:
                head = parse_ratchet(c.head, c.path)
            var l = lowered(base, head)
            for k in range(len(l)):
                out.append(c.path + String(": ") + l[k])
        except e:
            out.append(c.path + String(": cannot be read as a floor: ") + String(e))
    return out^


def refusal_reason(refusals: List[String]) -> String:
    """The BROKEN reason: every refusal, `; `-separated."""
    var s = String("a coverage floor was lowered (a floor only rises: tools/build/coverage/README.md, \"The ratchet\"): ")
    for i in range(len(refusals)):
        if i > 0:
            s += String("; ")
        s += refusals[i]
    return s^
