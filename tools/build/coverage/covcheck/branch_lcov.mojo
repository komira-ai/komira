"""The branch record reader (`--branch-lcov`) and the check that lets the
records of several tests be summed by id.

The records are what cov_branch_classify writes for one test
(tools/build/coverage/branch/README.md): lcov `BRDA` lines whose block field
is `<col>:<kind>:<n>/<N>` instead of a block number. A file holds records
`SF:<path>`, then `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<taken|->` lines,
then `end_of_record`; an empty file (a test that ran none of the library's
code) holds none. `<kind>` is `br`, `select`, `switch`, `try` (a raising
call in a `try:` body: returned, raised into the handler) or `rhs`; `<N>` is how
many decisions of that kind one copy of the code holds at that line and
column, `<n>` which one (0 to N-1); `<arm>` numbers the decision's outcomes
from 0. `-` means the decision's code never ran: the arm counts, not taken,
so it adds 0 to a sum (`-` + n is n, and `-` + `-` is an arm still not
taken). A branch is keyed `<line>,<col>:<kind>:<n>/<N>,<arm>`, its numbers
written in decimal without leading zeros, so the same arm read from two
tests is one key and its counts are summed (model.FileCov).

Line data never comes from these files: they hold branches only, and a line
report (Cobertura or lcov) holds the lines. Refused, with `<origin>:<line>:`:
a carriage return, a blank line, any record but `SF`, `BRDA` and
`end_of_record` (a `DA`, `LF`, `FN`, `TN`, `BRF`... included), a record
outside `SF` .. `end_of_record`, an `SF` naming no file or naming a file a
second time, a `BRDA` without exactly four fields, a block field that is not
`<col>:<kind>:<n>/<N>`, an unknown kind, a column or line of 0 or above
10^9, `<n>` not below `<N>`, a malformed arm or count, the same arm twice,
and a last record without `end_of_record`. At each `end_of_record`: every
decision has arms 0 to k-1 (two for `br`, `select`, `try` and `rhs`, at least two
for `switch`), and every location has each of its `N` decisions.

Across reports (`DecisionShapes`): one test's classifier sees only its own
copies of the code, so two tests whose copies hold the same number of
decisions at a location but different ones are summed crosswise unnoticed;
what can be seen is two tests giving one location (line, column, kind) a
different `N`, or one decision a different number of arms, and both are
refused naming the file, the line and the two reports.
"""

from covcheck.model import FileCov
from covcheck.text import MAX_LINE, has_byte, parse_count, split_lines, split_on, substr, suffix


def _fail(origin: String, line_no: Int, why: String) raises:
    raise Error(origin + String(":") + String(line_no) + String(": ") + why)


def _kind_ok(kind: String) -> Bool:
    return (
        kind == String("br")
        or kind == String("select")
        or kind == String("switch")
        or kind == String("try")
        or kind == String("rhs")
    )


def _num(origin: String, n: Int, field: String, what: String, lo: Int) raises -> Int:
    """`field` as a decimal number from `lo` to 10^9."""
    var v = parse_count(field)
    if v < 0:
        _fail(origin, n, what + String(" '") + field + String("' is not a decimal number"))
    if v < lo:
        _fail(origin, n, what + String(" ") + field + String(" is below ") + String(lo))
    if v > MAX_LINE:
        _fail(origin, n, what + String(" ") + field + String(" is above 10^9"))
    return v


struct BranchId(Copyable, Movable):
    """A branch key's parts: `site` `<line>,<col>:<kind>`, `decision`
    `<site>:<n>/<N>`, the decision count `total` (N) and the `arm`."""

    var line: Int
    var site: String
    var decision: String
    var total: Int
    var arm: Int

    def __init__(out self, line: Int, site: String, decision: String, total: Int, arm: Int):
        self.line = line
        self.site = site
        self.decision = decision
        self.total = total
        self.arm = arm

    def key(self) -> String:
        return self.decision + String(",") + String(self.arm)


def split_id(key: String) -> BranchId:
    """The parts of a key this module wrote (`BranchId`)."""
    var c1 = key.find(",")
    var c2 = key.rfind(",")
    var block = substr(key, c1 + 1, c2)
    var slash = block.rfind("/")
    var colon = block.rfind(":")
    return BranchId(
        parse_count(substr(key, 0, c1)),
        substr(key, 0, c1 + 1 + colon),
        substr(key, 0, c2),
        parse_count(suffix(block, slash + 1)),
        parse_count(suffix(key, c2 + 1)),
    )


struct _Record(Movable):
    """The checks of one `SF` .. `end_of_record`."""

    var totals: Dict[String, Int]  # site -> N
    var decisions: Dict[String, Int]  # site -> decisions seen
    var arms: Dict[String, Int]  # decision -> arms seen
    var max_arm: Dict[String, Int]  # decision -> highest arm

    def __init__(out self):
        self.totals = Dict[String, Int]()
        self.decisions = Dict[String, Int]()
        self.arms = Dict[String, Int]()
        self.max_arm = Dict[String, Int]()


def _brda(origin: String, n: Int, body: String, mut f: FileCov, mut r: _Record) raises:
    var fs = split_on(body, 44)
    if len(fs) != 4:
        _fail(origin, n, String("BRDA needs <line>,<col>:<kind>:<n>/<N>,<arm>,<taken|-> (4 fields), not ") + String(len(fs)))
    var line = _num(origin, n, fs[0], String("BRDA line"), 1)
    var parts = split_on(fs[1], 58)
    if len(parts) != 3:
        _fail(origin, n, String("BRDA block '") + fs[1] + String("' is not <col>:<kind>:<n>/<N> (a branch record of cov_branch_classify)"))
    var col = _num(origin, n, parts[0], String("BRDA column"), 1)
    var kind = parts[1]
    if not _kind_ok(kind):
        _fail(origin, n, String("BRDA kind '") + kind + String("' is not br, select, switch, try or rhs"))
    var nn = split_on(parts[2], 47)
    if len(nn) != 2:
        _fail(origin, n, String("BRDA decision '") + parts[2] + String("' is not <n>/<N>"))
    var idx = _num(origin, n, nn[0], String("BRDA decision number"), 0)
    var total = _num(origin, n, nn[1], String("BRDA decision count"), 1)
    if idx >= total:
        _fail(origin, n, String("BRDA decision ") + String(idx) + String("/") + String(total) + String(": <n> must be below <N>"))
    var arm = _num(origin, n, fs[2], String("BRDA arm"), 0)
    var taken = 0
    if fs[3] != String("-"):
        taken = parse_count(fs[3])
        if taken < 0:
            _fail(origin, n, String("BRDA taken '") + fs[3] + String("' is not a decimal number or -"))
    var site = String(line) + String(",") + String(col) + String(":") + kind
    var decision = site + String(":") + String(idx) + String("/") + String(total)
    var key = decision + String(",") + String(arm)
    if key in f.branches:
        _fail(origin, n, String("BRDA ") + key + String(" is given twice in one record"))
    if site in r.totals:
        if r.totals[site] != total:
            _fail(origin, n, String("BRDA ") + key + String(": the location ") + site + String(" has ") + String(r.totals[site]) + String(" decisions in an earlier record line, not ") + String(total))
    else:
        r.totals[site] = total
    if decision in r.arms:
        r.arms[decision] = r.arms[decision] + 1
        r.max_arm[decision] = max(r.max_arm[decision], arm)
    else:
        r.arms[decision] = 1
        r.max_arm[decision] = arm
        r.decisions[site] = r.decisions.get(site, 0) + 1
    f.add_branch(key, taken)


def _close(origin: String, n: Int, f: FileCov, r: _Record) raises:
    """The checks at `end_of_record` (module header)."""
    for e in r.arms.items():
        var d = e.key
        var k = e.value
        if r.max_arm[d] != k - 1:
            _fail(origin, n, f.path + String(": the arms of ") + d + String(" are not 0 to ") + String(k - 1) + String(" (highest ") + String(r.max_arm[d]) + String(")"))
        var two = d.find(":switch:") < 0
        if (two and k != 2) or k < 2:
            _fail(origin, n, f.path + String(": ") + d + String(" has ") + String(k) + String(" arms, not ") + (String("2") if two else String("2 or more")))
    for e in r.totals.items():
        var seen = r.decisions.get(e.key, 0)
        if seen != e.value:
            _fail(origin, n, f.path + String(": the location ") + e.key + String(" has ") + String(seen) + String(" of its ") + String(e.value) + String(" decisions"))


def parse_branch_lcov(text: String, origin: String) raises -> List[FileCov]:
    """The files of the branch record file `text` (`origin` names it in
    errors), each path once, with branches and no line."""
    if has_byte(text, 13):
        _fail(origin, 1, String("carriage return (the file must use LF line ends)"))
    var lines = split_lines(text)
    var files = List[FileCov]()
    var named = Dict[String, Bool]()
    var current = FileCov(String(""))
    var rec = _Record()
    var in_record = False
    for i in range(len(lines)):
        var n = i + 1
        var line = lines[i]
        if line == String("end_of_record"):
            if not in_record:
                _fail(origin, n, String("end_of_record outside a record"))
            _close(origin, n, current, rec)
            files.append(current.copy())
            in_record = False
            continue
        var colon = line.find(":")
        if colon <= 0:
            _fail(origin, n, String("not a record: '") + line + String("' (a branch record file holds SF, BRDA and end_of_record only)"))
        var kind = substr(line, 0, colon)
        var body = suffix(line, colon + 1)
        if kind == String("SF"):
            if in_record:
                _fail(origin, n, String("SF before the end_of_record of the previous file"))
            if body.byte_length() == 0:
                _fail(origin, n, String("SF names no file"))
            if body in named:
                _fail(origin, n, String("SF ") + body + String(" is named a second time"))
            named[body] = True
            current = FileCov(body)
            rec = _Record()
            in_record = True
        elif kind == String("BRDA"):
            if not in_record:
                _fail(origin, n, String("BRDA outside SF .. end_of_record"))
            _brda(origin, n, body, current, rec)
        else:
            _fail(origin, n, String("'") + kind + String("' record in a branch record file, which holds SF, BRDA and end_of_record only (line data comes from the line reports)"))
    if in_record:
        _fail(origin, len(lines), String("the last record has no end_of_record"))
    return files^


struct DecisionShapes(Movable):
    """What the reports read so far give each location and decision, to
    refuse a report that disagrees (module header)."""

    var totals: Dict[String, Int]
    var arms: Dict[String, Int]
    var origins: Dict[String, String]

    def __init__(out self):
        self.totals = Dict[String, Int]()
        self.arms = Dict[String, Int]()
        self.origins = Dict[String, String]()

    def add(mut self, f: FileCov, origin: String) raises:
        """Records the shapes of `f` (a repository path's branches from the
        report `origin`); raises on a disagreement with an earlier report."""
        var arms = Dict[String, Int]()
        var totals = Dict[String, Int]()
        var lines = Dict[String, Int]()
        for e in f.branches.items():
            var b = split_id(e.key)
            arms[b.decision] = arms.get(b.decision, 0) + 1
            totals[b.site] = b.total
            lines[b.site] = b.line
        for e in totals.items():
            var k = f.path + String("\x00") + e.key
            if k in self.totals and self.totals[k] != e.value:
                var col_kind = suffix(e.key, e.key.find(",") + 1)
                raise Error(
                    f.path + String(":") + String(lines[e.key]) + String(": ") + self.origins[k] + String(" gives ")
                    + String(self.totals[k]) + String(" decision(s) at ") + col_kind + String(" and ") + origin
                    + String(" gives ") + String(e.value)
                    + String(": the tests' copies of this code hold different decisions at one location, so their branch records cannot be summed by id")
                )
            if k not in self.totals:
                self.totals[k] = e.value
                self.origins[k] = origin
        for e in arms.items():
            var k = f.path + String("\x00") + e.key
            if k in self.arms and self.arms[k] != e.value:
                raise Error(
                    f.path + String(":") + String(split_id(e.key + String(",0")).line) + String(": ") + self.origins[k]
                    + String(" gives the decision ") + e.key + String(" ") + String(self.arms[k]) + String(" arms and ") + origin
                    + String(" gives it ") + String(e.value) + String(": its branch records cannot be summed by id")
                )
            if k not in self.arms:
                self.arms[k] = e.value
                self.origins[k] = origin
