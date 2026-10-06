"""The mutation-testing input: one row per mutant a mutation tool tried.

The format (the contract a mutation tool writes to):

    # comment lines start with '#'
    <path>\\t<line>\\t<status>\\t<operator>\\t<description>

Exactly five tab-separated fields. `<path>` is mapped like a coverage
report's path (paths.mojo); `<line>` is a decimal number from 1 to 10^9; `<status>` is
`killed`, `survived`, `timeout` or `error`; `<operator>` is non-empty;
`<description>` may be empty. Only `killed` kills a mutant: `timeout` and
`error` are counted on their own and are neither killed nor survived.

Refused, naming `<origin>:<line>`: a carriage return, an empty line, a row
with another number of fields, a malformed line number, an unknown status,
an empty path or operator.
"""

from covcheck.text import MAX_LINE, has_byte, parse_count, split_lines, split_on

comptime KILLED = "killed"
comptime SURVIVED = "survived"
comptime TIMEOUT = "timeout"
comptime ERROR = "error"


struct Mutant(Copyable, Movable):
    var path: String
    var line: Int
    var status: String
    var operator: String
    var description: String

    def __init__(out self, path: String, line: Int, status: String, operator: String, description: String):
        self.path = path
        self.line = line
        self.status = status
        self.operator = operator
        self.description = description


def _fail(origin: String, line_no: Int, why: String) raises:
    raise Error(origin + String(":") + String(line_no) + String(": ") + why)


def parse_mutants(text: String, origin: String) raises -> List[Mutant]:
    """The rows of the mutants file `text`, in file order."""
    var out = List[Mutant]()
    var lines = split_lines(text)
    for i in range(len(lines)):
        var n = i + 1
        var line = lines[i]
        if has_byte(line, 13):
            _fail(origin, n, String("carriage return (the file must use LF line ends)"))
        if line.startswith("#"):
            continue
        if line.byte_length() == 0:
            _fail(origin, n, String("an empty line (a comment starts with '#')"))
        var f = split_on(line, 9)
        if len(f) != 5:
            _fail(origin, n, String("a row has 5 tab-separated fields (path, line, status, operator, description), not ") + String(len(f)))
        if f[0].byte_length() == 0:
            _fail(origin, n, String("an empty path"))
        var at = parse_count(f[1])
        if at < 1 or at > MAX_LINE:
            _fail(origin, n, String("line '") + f[1] + String("' is not a decimal number from 1 to 10^9"))
        var st = f[2]
        if st != String(KILLED) and st != String(SURVIVED) and st != String(TIMEOUT) and st != String(ERROR):
            _fail(origin, n, String("status '") + st + String("' is not killed, survived, timeout or error"))
        if f[3].byte_length() == 0:
            _fail(origin, n, String("an empty operator"))
        out.append(Mutant(f[0], at, st, f[3], f[4]))
    return out^
