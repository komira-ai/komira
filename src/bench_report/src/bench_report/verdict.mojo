# The two verdict vocabularies of a cell and the pass verdict. A cell records
# how komira's run ended (`StageOutcome`) and whether its values matched the
# reference (`ValueVerdict`); a ratio is only ever derived from a cell whose
# run ended in EXEC_OK and whose values are IDENTICAL or a DEPARTURE (equal
# values whose declared types differ in a way the Arrow representation forces,
# for the reason the verdict carries). A DEPARTURE cell is never a PASS: its
# verdict is DEPARTURE, whatever its ratio.

comptime STAGE_EXEC_OK = "EXEC_OK"
comptime STAGE_BIND_FAIL = "BIND_FAIL"
comptime STAGE_EXEC_FAIL = "EXEC_FAIL"
comptime STAGE_UNSUPPORTED = "UNSUPPORTED"

comptime VALUE_IDENTICAL = "IDENTICAL"
comptime VALUE_DIVERGENT = "DIVERGENT"
comptime VALUE_UNVERIFIED = "UNVERIFIED"
comptime VALUE_DEPARTURE = "DEPARTURE"

comptime CELL_PASS = "PASS"
comptime CELL_FAIL = "FAIL"
comptime CELL_NO_RATIO = "NO_RATIO"
comptime CELL_DEPARTURE = "DEPARTURE"


def split_tag(text: String) -> List[String]:
    """`text` cut at its first colon: the tag, and the detail after it. A text
    with no colon gives the tag alone."""
    var out = List[String]()
    var at = text.find(String(":"))
    if at < 0:
        out.append(text.copy())
        return out^
    out.append(String(text[byte=0:at]))
    out.append(String(text[byte = at + 1 : text.byte_length()]))
    return out^


def _refuse_place(text: String, what: String) raises:
    """The detail of a verdict is text about a cell, never a place on a
    machine: a slash, a backslash or a control character is refused."""
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == 0x2F or c == 0x5C or c < 0x20:
            raise Error(
                what + " detail looks like a path or holds a control character"
            )


def _joined(tag: String, detail: String) -> String:
    if detail.byte_length() == 0:
        return tag.copy()
    return tag + String(":") + detail


struct StageOutcome(Copyable, Movable):
    """How komira's run of one cell ended: `EXEC_OK`, `BIND_FAIL`,
    `EXEC_FAIL`, or `UNSUPPORTED:<construct>` for a query the engine refuses
    and names the construct of."""

    var kind: String
    var detail: String

    def __init__(out self, var kind: String, var detail: String) raises:
        self.kind = kind^
        self.detail = detail^
        var plain = (
            self.kind == String(STAGE_EXEC_OK)
            or self.kind == String(STAGE_BIND_FAIL)
            or self.kind == String(STAGE_EXEC_FAIL)
        )
        if plain and self.detail.byte_length() != 0:
            raise Error("stage " + self.kind + " takes no detail")
        if not plain:
            if self.kind != String(STAGE_UNSUPPORTED):
                raise Error("unknown stage '" + self.kind + "'")
            if self.detail.byte_length() == 0:
                raise Error("stage UNSUPPORTED must name the construct")
            _refuse_place(self.detail, String("stage UNSUPPORTED"))

    @staticmethod
    def exec_ok() raises -> StageOutcome:
        return StageOutcome(String(STAGE_EXEC_OK), String(""))

    @staticmethod
    def bind_fail() raises -> StageOutcome:
        return StageOutcome(String(STAGE_BIND_FAIL), String(""))

    @staticmethod
    def exec_fail() raises -> StageOutcome:
        return StageOutcome(String(STAGE_EXEC_FAIL), String(""))

    @staticmethod
    def unsupported(var construct: String) raises -> StageOutcome:
        return StageOutcome(String(STAGE_UNSUPPORTED), construct^)

    @staticmethod
    def parse(text: String) raises -> StageOutcome:
        var parts = split_tag(text)
        var detail = String("")
        if len(parts) == 2:
            detail = parts[1].copy()
        return StageOutcome(parts[0].copy(), detail^)

    def is_ok(self) -> Bool:
        return self.kind == String(STAGE_EXEC_OK)

    def text(self) -> String:
        return _joined(self.kind, self.detail)


struct ValueVerdict(Copyable, Movable):
    """Whether the values of a cell matched the reference: `IDENTICAL`,
    `DIVERGENT`, `DEPARTURE:<reason>` (equal values, an allowed departure of the
    declared types), or `UNVERIFIED:<cause>` when they could not be compared."""

    var kind: String
    var detail: String

    def __init__(out self, var kind: String, var detail: String) raises:
        self.kind = kind^
        self.detail = detail^
        var plain = (
            self.kind == String(VALUE_IDENTICAL)
            or self.kind == String(VALUE_DIVERGENT)
        )
        if plain and self.detail.byte_length() != 0:
            raise Error("value verdict " + self.kind + " takes no detail")
        if not plain:
            if self.kind != String(VALUE_UNVERIFIED) and self.kind != String(VALUE_DEPARTURE):
                raise Error("unknown value verdict '" + self.kind + "'")
            if self.detail.byte_length() == 0:
                raise Error("value verdict " + self.kind + " must name the " + (
                    String("cause") if self.kind == String(VALUE_UNVERIFIED) else String("reason")
                ))
            _refuse_place(self.detail, String("value verdict ") + self.kind)

    @staticmethod
    def identical() raises -> ValueVerdict:
        return ValueVerdict(String(VALUE_IDENTICAL), String(""))

    @staticmethod
    def divergent() raises -> ValueVerdict:
        return ValueVerdict(String(VALUE_DIVERGENT), String(""))

    @staticmethod
    def unverified(var cause: String) raises -> ValueVerdict:
        return ValueVerdict(String(VALUE_UNVERIFIED), cause^)

    @staticmethod
    def departure(var reason: String) raises -> ValueVerdict:
        return ValueVerdict(String(VALUE_DEPARTURE), reason^)

    @staticmethod
    def parse(text: String) raises -> ValueVerdict:
        var parts = split_tag(text)
        var detail = String("")
        if len(parts) == 2:
            detail = parts[1].copy()
        return ValueVerdict(parts[0].copy(), detail^)

    def is_identical(self) -> Bool:
        return self.kind == String(VALUE_IDENTICAL)

    def is_departure(self) -> Bool:
        return self.kind == String(VALUE_DEPARTURE)

    def is_matched(self) -> Bool:
        """Equal values: `IDENTICAL`, or a `DEPARTURE` (which is counted and
        shown apart from a pass)."""
        return self.is_identical() or self.is_departure()

    def text(self) -> String:
        return _joined(self.kind, self.detail)


def cell_verdict(
    ratio: Optional[Float64], pass_max: Float64, departure: Bool = False
) -> String:
    """`PASS` when the ratio is at most `pass_max`, `FAIL` above it, and
    `NO_RATIO` for a cell that has none. A cell whose values are a `DEPARTURE`
    (`departure` True) is `DEPARTURE` whatever the ratio, never `PASS`."""
    if not ratio:
        return String(CELL_NO_RATIO)
    if departure:
        return String(CELL_DEPARTURE)
    if ratio.value() <= pass_max:
        return String(CELL_PASS)
    return String(CELL_FAIL)
