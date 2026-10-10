# =============================================================================
# komira_db_conformance/report.mojo -- one target's check results and the gate.
# =============================================================================
#
# Every check of a suite runs, pass or fail, and is recorded here by name. The
# gate then holds the run to the target's list of known gaps:
#
#   * a check that failed and is not listed fails the gate;
#   * a listed check that passed fails the gate (the entry is stale: the gap
#     was closed, so the entry must go and the check now guards the fix);
#   * a listed check that failed for another reason (its error does not
#     contain the entry's `must_contain`) fails the gate;
#   * a listed name that no check carries fails the gate (a typo would
#     otherwise excuse nothing and pass).
#
# So a known gap is pinned to its exact symptom, not excused wholesale, and a
# target never passes by failing differently. Every result is printed, so the
# build log shows what each target passed.
# =============================================================================


def printable(s: String) -> String:
    """`s` with every byte outside printable ASCII (and the backslash) written
    as `\\xNN`, so a mis-decoded value prints as its bytes and cannot garble
    the build log (C1 control characters in a mojibake string otherwise cut
    the captured output short)."""
    var hex = String("0123456789abcdef")
    var digits = hex.as_bytes()
    var out = String()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 10:
            out += String(" | ")
        elif c < 0x20 or c > 0x7E or c == 0x5C:
            out += String("\\x")
            out += chr(Int(digits[c >> 4]))
            out += chr(Int(digits[c & 15]))
        else:
            out += chr(c)
    return out^


struct KnownGap(Copyable, Movable):
    """A check a target is known to fail: its name, a fragment its error must
    contain, and why (the defect it stands for)."""

    var check: String
    var must_contain: String
    var reason: String

    def __init__(
        out self, var check: String, var must_contain: String, var reason: String
    ) raises:
        if must_contain.byte_length() == 0:
            # An empty fragment is in every error: it would excuse any failure.
            raise Error(
                String("KnownGap ") + check + String(": empty must_contain")
            )
        self.check = check^
        self.must_contain = must_contain^
        self.reason = reason^


struct ConformanceReport(Movable):
    """The results of one suite run against one target, in run order."""

    var target: String
    var names: List[String]
    var errors: List[String]
    var failed: List[Bool]

    def __init__(out self, var target: String):
        self.target = target^
        self.names = List[String]()
        self.errors = List[String]()
        self.failed = List[Bool]()

    def ok(mut self, var name: String):
        self.names.append(name^)
        self.errors.append(String(""))
        self.failed.append(False)

    def fail(mut self, var name: String, var error: String):
        self.names.append(name^)
        self.errors.append(error^)
        self.failed.append(True)

    def count(self) -> Int:
        return len(self.names)

    def _index(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def gate(self, gaps: List[KnownGap]) raises:
        """Print every result and raise naming every violation (see the
        header). Returns normally only when every check passed or failed
        exactly as a listed gap says."""
        var problems = List[String]()
        for g in range(len(gaps)):
            if self._index(gaps[g].check) < 0:
                problems.append(
                    String("known gap names no check: ") + gaps[g].check
                )
        for i in range(len(self.names)):
            var gi = -1
            for g in range(len(gaps)):
                if gaps[g].check == self.names[i]:
                    gi = g
                    break
            var line = self.target + String(" ") + self.names[i]
            if not self.failed[i]:
                if gi >= 0:
                    problems.append(
                        String("STALE known gap (the check passes): ")
                        + self.names[i]
                    )
                    print(String("PASS-BUT-LISTED ") + line)
                else:
                    print(String("PASS ") + line)
                continue
            if gi < 0:
                problems.append(
                    String("FAILED ")
                    + self.names[i]
                    + String(": ")
                    + printable(self.errors[i])
                )
                print(String("FAIL ") + line + String(": ") + printable(self.errors[i]))
                continue
            if self.errors[i].find(gaps[gi].must_contain) < 0:
                problems.append(
                    String("known gap ")
                    + self.names[i]
                    + String(" failed differently (want '")
                    + gaps[gi].must_contain
                    + String("'): ")
                    + printable(self.errors[i])
                )
                print(String("FAIL ") + line + String(": ") + printable(self.errors[i]))
                continue
            print(
                String("GAP ")
                + line
                + String(": ")
                + printable(self.errors[i])
                + String(" [")
                + gaps[gi].reason
                + String("]")
            )
        if len(problems) > 0:
            var msg = (
                String("komira_db conformance: ")
                + self.target
                + String(": ")
                + String(len(problems))
                + String(" violation(s) of ")
                + String(len(self.names))
                + String(" checks:")
            )
            for p in range(len(problems)):
                msg += String("\n  ") + problems[p]
            raise Error(msg)
