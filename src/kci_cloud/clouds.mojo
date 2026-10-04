# =============================================================================
# kci_cloud/clouds.mojo: the clouds built into this kci.
# =============================================================================
#
# EVERY CLOUD IS BUILT INTO KCI. There is no plugin, no registration from
# outside and no "unknown id means somebody else's code": a new cloud is a
# module added to kci in an ordinary pull request. `main` lists the cloud
# adapters it was built with, once, at start-up (`clouds.add(describe(a))`),
# so `Clouds` is a closed list. It answers the cross-cloud questions: is an
# id one of the built-in clouds (`resolve`, which names the closest one on a
# typo), which built-in clouds host a type, and is an adapter's coverage
# declaration legal. It holds data only; lowering goes to the chosen adapter.
#
# "Which clouds host it" is computed from the clouds built into THIS binary
# and the refusal text says so; it cannot claim to know clouds it does not
# have.
# =============================================================================

from kci_cloud.adapter import (
    CloudAdapter,
    Absence,
    ABSENT_BY_DESIGN,
    NOT_YET,
    absence_word,
)
from kci_cloud.catalog import Catalog, PORTABLE, CLOUD_BOUND, portability_word
from kci_cloud.cloud_id import CloudId


struct CloudEntry(Copyable, Movable, Deinitable):
    var id: CloudId
    var complete: Bool
    var implemented: List[Int]
    var absences: List[Absence]

    def __init__(
        out self,
        var id: CloudId,
        complete: Bool,
        var implemented: List[Int],
        var absences: List[Absence],
    ):
        self.id = id^
        self.complete = complete
        self.implemented = implemented^
        self.absences = absences^

    def __init__(out self, *, copy: Self):
        self.id = copy.id.copy()
        self.complete = copy.complete
        self.implemented = copy.implemented.copy()
        self.absences = copy.absences.copy()

    def implements(self, field: Int) -> Bool:
        for i in range(len(self.implemented)):
            if self.implemented[i] == field:
                return True
        return False

    def absence_of(self, field: Int) -> Optional[Absence]:
        for i in range(len(self.absences)):
            if self.absences[i].field == field:
                return self.absences[i].copy()
        return None


def describe[S: CloudAdapter](s: S) -> CloudEntry:
    """What `Clouds` needs to know about the adapter `s`, as data."""
    return CloudEntry(s.cloud_id(), s.complete(), s.implemented(), s.absences())


def artifact_problems(catalog: Catalog, entry: CloudEntry) -> List[String]:
    """Every way `entry`'s coverage declaration breaks the rules. Empty means
    legal. A type of the catalog must be implemented or declared absent,
    exactly once; an absence must be of the kind its portability allows; a
    complete cloud has no NOT_YET (a complete cloud hosts every
    PORTABLE type); and nothing outside the catalog may be claimed."""
    var out = List[String]()
    var who = String("cloud \"") + entry.id.text() + String("\": ")
    for i in range(len(catalog.types)):
        ref t = catalog.types[i]
        var impl = 0
        for k in range(len(entry.implemented)):
            if entry.implemented[k] == t.field:
                impl += 1
        var absent = 0
        var kind = 0
        for k in range(len(entry.absences)):
            if entry.absences[k].field == t.field:
                absent += 1
                kind = entry.absences[k].kind
        if impl + absent == 0:
            out.append(
                who
                + String("type '")
                + t.name
                + String("' is neither implemented nor declared absent")
            )
            continue
        if impl + absent > 1:
            out.append(
                who + String("type '") + t.name + String("' is declared more than once")
            )
            continue
        if absent == 1:
            if kind == ABSENT_BY_DESIGN and t.portability != CLOUD_BOUND:
                out.append(
                    who
                    + String("type '")
                    + t.name
                    + String("' is ")
                    + portability_word(t.portability)
                    + String("; ABSENT_BY_DESIGN is legal only for a CLOUD_BOUND type")
                )
            elif kind == NOT_YET and t.portability != PORTABLE:
                out.append(
                    who
                    + String("type '")
                    + t.name
                    + String("' is ")
                    + portability_word(t.portability)
                    + String("; NOT_YET is legal only for a PORTABLE type")
                )
            elif kind == NOT_YET and entry.complete:
                out.append(
                    who
                    + String("claims to be complete but does not host PORTABLE type '")
                    + t.name
                    + String("'")
                )
            elif kind != ABSENT_BY_DESIGN and kind != NOT_YET:
                out.append(
                    who
                    + String("type '")
                    + t.name
                    + String("' has absence kind ")
                    + absence_word(kind)
                )
    for k in range(len(entry.implemented)):
        if catalog.index_of(entry.implemented[k]) < 0:
            out.append(
                who
                + String("implements field ")
                + String(entry.implemented[k])
                + String(", which is not in the catalog")
            )
    for k in range(len(entry.absences)):
        if catalog.index_of(entry.absences[k].field) < 0:
            out.append(
                who
                + String("declares field ")
                + String(entry.absences[k].field)
                + String(" absent, which is not in the catalog")
            )
    return out^


def _edit_distance(a: String, b: String) -> Int:
    """Levenshtein distance over bytes (ids are ASCII by grammar)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var prev = List[Int]()
    for j in range(len(y) + 1):
        prev.append(j)
    for i in range(1, len(x) + 1):
        var cur = List[Int]()
        cur.append(i)
        for j in range(1, len(y) + 1):
            var cost = 0 if x[i - 1] == y[j - 1] else 1
            var best = prev[j] + 1
            if cur[j - 1] + 1 < best:
                best = cur[j - 1] + 1
            if prev[j - 1] + cost < best:
                best = prev[j - 1] + cost
            cur.append(best)
        prev = cur^
    return prev[len(y)]


struct Clouds(Movable, Deinitable):
    """The cloud adapters built into this binary, as descriptions. A closed
    list: see the file header."""

    var catalog: Catalog
    var entries: List[CloudEntry]

    def __init__(out self, var catalog: Catalog):
        self.catalog = catalog^
        self.entries = List[CloudEntry]()

    def add(mut self, var entry: CloudEntry) raises:
        """Add a built-in cloud. A duplicate id, or an illegal declaration,
        is refused here, at start-up, before any command runs."""
        if self.find(entry.id) >= 0:
            raise Error(
                String("clouds: cloud \"")
                + entry.id.text()
                + String("\" is built in twice")
            )
        var problems = artifact_problems(self.catalog, entry)
        if len(problems) > 0:
            var msg = String("clouds: illegal coverage declaration:")
            for i in range(len(problems)):
                msg += String("\n  ") + problems[i]
            raise Error(msg)
        self.entries.append(entry^)

    def find(self, id: CloudId) -> Int:
        for i in range(len(self.entries)):
            if self.entries[i].id == id:
                return i
        return -1

    def resolve(self, id: String) raises -> CloudId:
        """The built-in cloud named `id` (a cell's `cloud`, `--cloud=<id>`).
        Anything else is refused, naming every built-in cloud and, when one
        is within two edits, the one the author probably meant. There is no
        other path: an unknown id is a typo or a cloud this kci was not built
        with, never a plugin to look for."""
        var want = CloudId(id)
        if self.find(want) >= 0:
            return want^
        var msg = (
            String("kci: \"")
            + id
            + String("\" is not a cloud built into this kci (built in: ")
        )
        var best = -1
        var best_d = 3
        for i in range(len(self.entries)):
            if i > 0:
                msg += String(", ")
            var have = self.entries[i].id.text()
            msg += have
            var d = _edit_distance(id, have)
            if d < best_d:
                best_d = d
                best = i
        if len(self.entries) == 0:
            msg += String("none")
        msg += String(")")
        if best >= 0:
            msg += (
                String("; did you mean \"")
                + self.entries[best].id.text()
                + String("\"?")
            )
        raise Error(msg)

    def implementers(self, field: Int) -> List[String]:
        """The ids (for messages) of built-in clouds that host `field`."""
        var out = List[String]()
        for i in range(len(self.entries)):
            if self.entries[i].implements(field):
                out.append(self.entries[i].id.text())
        return out^

    def ids(self) -> List[String]:
        """Every built-in cloud's id, in the order `main` added them."""
        var out = List[String]()
        for i in range(len(self.entries)):
            out.append(self.entries[i].id.text())
        return out^
