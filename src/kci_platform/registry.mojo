# =============================================================================
# kci_platform/registry.mojo: the platforms linked into this kci.
# =============================================================================
#
# Mojo links statically and loads no plugins, so `main` adds a description of
# each linked adapter set at start-up (`registry.add(describe(set))`), and the
# registry is an ordinary list. It answers the cross-platform questions:
# is an id linked, which linked platforms host a type, and is a set's
# declaration legal. It holds data only; lowering goes to the chosen set.
#
# "Which platforms host it" is computed from the sets linked into THIS binary
# and the refusal text says so; it cannot claim to know platforms it does not
# have.
# =============================================================================

from kci_platform.adapter import (
    AdapterSet,
    Absence,
    ABSENT_BY_DESIGN,
    NOT_YET,
    absence_word,
)
from kci_platform.catalog import Catalog, PORTABLE, PLATFORM_BOUND, portability_word
from kci_platform.platform_id import PlatformId


struct PlatformEntry(Copyable, Movable, Deinitable):
    var id: PlatformId
    var complete: Bool
    var implemented: List[Int]
    var absences: List[Absence]

    def __init__(
        out self,
        var id: PlatformId,
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


def describe[S: AdapterSet](s: S) -> PlatformEntry:
    """What the registry needs to know about `s`, as data."""
    return PlatformEntry(s.platform_id(), s.complete(), s.implemented(), s.absences())


def declaration_problems(catalog: Catalog, entry: PlatformEntry) -> List[String]:
    """Every way `entry`'s coverage declaration breaks the rules. Empty means
    legal. A type of the catalog must be implemented or declared absent,
    exactly once; an absence must be of the kind its portability allows; a
    complete platform has no NOT_YET (a complete platform hosts every
    PORTABLE type); and nothing outside the catalog may be claimed."""
    var out = List[String]()
    var who = String("platform \"") + entry.id.text() + String("\": ")
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
            if kind == ABSENT_BY_DESIGN and t.portability != PLATFORM_BOUND:
                out.append(
                    who
                    + String("type '")
                    + t.name
                    + String("' is ")
                    + portability_word(t.portability)
                    + String("; ABSENT_BY_DESIGN is legal only for a PLATFORM_BOUND type")
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


struct Registry(Movable, Deinitable):
    """The adapter sets linked into this binary, as descriptions."""

    var catalog: Catalog
    var entries: List[PlatformEntry]

    def __init__(out self, var catalog: Catalog):
        self.catalog = catalog^
        self.entries = List[PlatformEntry]()

    def add(mut self, var entry: PlatformEntry) raises:
        """Register a linked set. A duplicate id, or an illegal declaration,
        is refused here, at start-up, before any command runs."""
        if self.find(entry.id) >= 0:
            raise Error(
                String("registry: platform \"")
                + entry.id.text()
                + String("\" is linked twice")
            )
        var problems = declaration_problems(self.catalog, entry)
        if len(problems) > 0:
            var msg = String("registry: illegal coverage declaration:")
            for i in range(len(problems)):
                msg += String("\n  ") + problems[i]
            raise Error(msg)
        self.entries.append(entry^)

    def find(self, id: PlatformId) -> Int:
        for i in range(len(self.entries)):
            if self.entries[i].id == id:
                return i
        return -1

    def implementers(self, field: Int) -> List[String]:
        """The ids (for messages) of linked platforms that host `field`."""
        var out = List[String]()
        for i in range(len(self.entries)):
            if self.entries[i].implements(field):
                out.append(self.entries[i].id.text())
        return out^

    def linked_ids(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self.entries)):
            out.append(self.entries[i].id.text())
        return out^
