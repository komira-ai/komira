# =============================================================================
# komira_test_verdict/verdict.mojo -- what a teardown or a leak check found.
# =============================================================================
#
# Three kinds, numbered as the process exit codes a caller reports them with:
#
#   CLEAN        0  everything the run made is gone, and a re-list proved it.
#   CANNOT_TELL  3  the caller could not find out: a list raised, or an
#                   embedded server's stop was not confirmed. NEVER a pass.
#   LEAK         6  something the run made is still there: residue was listed,
#                   a delete failed, or an embedded server's temporary
#                   directory remained.
#
# When several findings disagree, the worst wins, and LEAK ranks above
# CANNOT_TELL: a LEAK is a proven fact with a name to fix, so it is the one a
# reader must see first. Both are red. Every finding is kept in `reasons`,
# whatever the final kind, so nothing a teardown saw is swallowed.
#
# `residue` holds keys RELATIVE to the run's prefix. `reasons` hold field
# names, operations and statuses, never a configured value.
# =============================================================================

comptime VERDICT_CLEAN: Int = 0
comptime VERDICT_CANNOT_TELL: Int = 3
comptime VERDICT_LEAK: Int = 6


def verdict_kind_name(kind: Int) -> String:
    if kind == VERDICT_CLEAN:
        return String("CLEAN")
    if kind == VERDICT_CANNOT_TELL:
        return String("CANNOT_TELL")
    if kind == VERDICT_LEAK:
        return String("LEAK")
    return String("UNKNOWN(") + String(kind) + ")"


def _rank(kind: Int) -> Int:
    if kind == VERDICT_LEAK:
        return 2
    if kind == VERDICT_CANNOT_TELL:
        return 1
    return 0


struct Verdict(Copyable, Movable, Writable):
    """A teardown's or a leak check's result; see the module header."""

    var kind: Int
    var residue: List[String]
    var reasons: List[String]

    def __init__(out self):
        """A CLEAN verdict with nothing recorded."""
        self.kind = VERDICT_CLEAN
        self.residue = List[String]()
        self.reasons = List[String]()

    def is_clean(self) -> Bool:
        return self.kind == VERDICT_CLEAN

    def _raise_to(mut self, kind: Int):
        if _rank(kind) > _rank(self.kind):
            self.kind = kind

    def add_leak(mut self, var reason: String):
        self._raise_to(VERDICT_LEAK)
        self.reasons.append(reason^)

    def add_cannot_tell(mut self, var reason: String):
        self._raise_to(VERDICT_CANNOT_TELL)
        self.reasons.append(reason^)

    def add_residue(mut self, var relative_key: String):
        """A key still present under the run's prefix: LEAK."""
        self._raise_to(VERDICT_LEAK)
        self.residue.append(relative_key^)

    def merge(mut self, other: Verdict):
        """Fold `other` in: the worst kind wins, and every residue key and
        reason of both is kept."""
        self._raise_to(other.kind)
        for k in other.residue:
            self.residue.append(k)
        for r in other.reasons:
            self.reasons.append(r)

    def kind_name(self) -> String:
        return verdict_kind_name(self.kind)

    def exit_code(self) -> Int:
        return self.kind

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.kind_name())
        if len(self.residue) > 0:
            writer.write(" residue=[")
            for i in range(len(self.residue)):
                if i > 0:
                    writer.write(", ")
                writer.write(self.residue[i])
            writer.write("]")
        if len(self.reasons) > 0:
            writer.write(" reasons=[")
            for i in range(len(self.reasons)):
                if i > 0:
                    writer.write("; ")
                writer.write(self.reasons[i])
            writer.write("]")

    def require_clean(self) raises:
        """Raise unless CLEAN; the message is the whole verdict."""
        if not self.is_clean():
            raise Error(String("komira_test_verdict: teardown verdict ") + String(self))
