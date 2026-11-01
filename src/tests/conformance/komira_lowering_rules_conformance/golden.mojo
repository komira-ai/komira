# =============================================================================
# golden: the expected decisions, read from golden/payload_narrow.txt
# =============================================================================
#
# One case per line, in the optimizer table's row form (render.mojo):
# `<case> => <rendering>`, or `<case> =>` for a plan with no scan. Lines
# starting `#` and blank lines are comments. A line without exactly one ` =>`,
# or a case named twice, is refused with its line number.
# =============================================================================


@fieldwise_init
struct GoldenRow(Copyable, Movable):
    var name: String
    var text: String  # the whole row, as `render.row` writes it
    var line: Int


def parse_golden(text: String) raises -> List[GoldenRow]:
    """The rows of a golden file's text."""
    var rows = List[GoldenRow]()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var fields = line.split(" =>")
        if len(fields) != 2:
            raise Error("golden line " + String(i + 1) + ": expected exactly one ` =>`: " + line)
        var name = String(fields[0])
        for r in range(len(rows)):
            if rows[r].name == name:
                raise Error("golden line " + String(i + 1) + ": case " + name + " is also on line " + String(rows[r].line))
        rows.append(GoldenRow(name, line, i + 1))
    return rows^


def read_golden(path: String) raises -> List[GoldenRow]:
    """The rows of the golden file at `path`."""
    with open(path, "r") as f:
        return parse_golden(f.read())
