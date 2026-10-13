"""A hold is never dropped: what a change takes out of the coverage holds.

Each package's holds are its own file, `<package>/coverage_held`
(tools/build/coverage/README.md, "The 99% threshold and holds"): one metric
per line, `line` or `branch`. The coverage gate fails a library under the
target on a metric its package holds, and the census check fails a package
the census measured at the target that does not hold it; neither sees a
hold the change started from. This does: `affected --base <rev>`
(affected.mojo) reads each changed marker at the base and at the head and
refuses the change (BROKEN, which fails the per-change check) when a metric
the base held is gone: the marker deleted while its package's BUCK file
stays, or the metric's line taken out. A marker that is new, gains a
metric, or is deleted together with its package's BUCK file passes. A
malformed marker is the gate's and the census's to refuse.
"""

comptime HELD_FILE = "coverage_held"


def is_held_file(path: String) -> Bool:
    """Whether `path` (a repository path) is a package's held marker."""
    return path == String(HELD_FILE) or path.endswith(String("/") + String(HELD_FILE))


struct HeldChange(Copyable, Movable):
    """A changed marker: its text at the base and at the head (each with
    whether it is there at all), and whether its package still has a BUCK
    file at the head."""

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


def _metrics(text: String) -> List[String]:
    """The lines of `text` that are not comments or empty."""
    var out = List[String]()
    for l in text.split("\n"):
        var s = String(l)
        if s.byte_length() > 0 and not s.startswith("#"):
            out.append(s)
    return out^


def held_refusals(changes: List[HeldChange]) -> List[String]:
    """One message per metric the changes stop holding (`<path>: <metric>
    is no longer held`); empty when every hold of the base stays."""
    var out = List[String]()
    for i in range(len(changes)):
        ref c = changes[i]
        if not c.in_base or (not c.in_head and not c.package_stays):
            continue
        var head = _metrics(c.head) if c.in_head else List[String]()
        var base = _metrics(c.base)
        for k in range(len(base)):
            if base[k] not in head:
                out.append(c.path + String(": ") + base[k] + String(" is no longer held"))
    return out^


def refusal_reason(refusals: List[String]) -> String:
    """The BROKEN reason: every refusal, `; `-separated."""
    var s = String("a coverage hold was dropped (a package that reached the target stays held: tools/build/coverage/README.md, \"The 99% threshold and holds\"): ")
    for i in range(len(refusals)):
        if i > 0:
            s += String("; ")
        s += refusals[i]
    return s^
