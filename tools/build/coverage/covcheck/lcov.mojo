"""The lcov tracefile reader.

Records: `TN`, `SF`, `FN`, `FNDA`, `FNF`, `FNH`, `FNL`, `FNA`,
`DA:<line>,<hits>[,<checksum>]`, `BRDA:<line>,[e]<block>,<branch>,<taken|->`,
`BRF`, `BRH`, `LF`, `LH`, `end_of_record`. Only `SF`, `DA` and `BRDA` carry
data: the counts are recomputed from them, and the summary records (`LF`,
`LH`, `BRF`, `BRH`, `FNF`, `FNH`) are checked to be numbers and otherwise
ignored, so a tracefile whose summaries disagree with its data is measured
by its data. The function records are checked and ignored: `FN:<line>,...`,
`FNDA:<count>,...`, and lcov 2.2's `FNL:<index>,<line>[,<end line>]` and
`FNA:<index>,<count>,<name>`. `-` as a branch's taken count means its block
never ran: the branch counts, not taken. lcov 2's `e` before a block number
marks an exception branch: it is a branch like any other, kept apart from
the block without the `e`. A branch id may hold commas (lcov 2 writes an
expression): it is everything between the block and the last field.

A file named by several records (one per test, or by several tracefiles)
has its counts summed per line and per branch (`lcov -a`).

Refused, with `<origin>:<line>:`: a carriage return, a line that is not a
record (`<type>:...` or `end_of_record`), a record type not in the list, a
malformed number, a line number of 0 or above 10^9, a `DA` with fewer than 2
or more than 3 fields, a `BRDA` with fewer than 4 fields or an empty branch
id, a data record outside `SF` .. `end_of_record`, an `SF` or `TN` inside a
record, an `SF` naming no file, an `end_of_record` outside a record, and a
last record without `end_of_record`.
"""

from covcheck.model import FileCov, merge_by_path
from covcheck.text import MAX_LINE, has_byte, parse_count, split_lines, split_on, substr, suffix


def _fail(origin: String, line_no: Int, why: String) raises:
    raise Error(origin + String(":") + String(line_no) + String(": ") + why)


def _number(origin: String, line_no: Int, field: String, what: String) raises -> Int:
    var v = parse_count(field)
    if v < 0:
        _fail(origin, line_no, what + String(" '") + field + String("' is not a decimal number"))
    return v


def _line(origin: String, line_no: Int, field: String, what: String) raises -> Int:
    var v = _number(origin, line_no, field, what)
    if v == 0:
        _fail(origin, line_no, what + String(" 0 (lines start at 1)"))
    if v > MAX_LINE:
        _fail(origin, line_no, what + String(" ") + field + String(" is above 10^9"))
    return v


def parse_lcov(text: String, origin: String) raises -> List[FileCov]:
    """The files of the tracefile `text` (`origin` names it in errors), each
    path once."""
    if has_byte(text, 13):
        var lines_cr = split_lines(text)
        for i in range(len(lines_cr)):
            if has_byte(lines_cr[i], 13):
                _fail(origin, i + 1, String("carriage return (the tracefile must use LF line ends)"))
    var lines = split_lines(text)
    var files = List[FileCov]()
    var current = FileCov(String(""))
    var in_record = False
    var last_line = 0
    for i in range(len(lines)):
        var n = i + 1
        last_line = n
        var line = lines[i]
        if line.byte_length() == 0:
            continue
        if line == String("end_of_record"):
            if not in_record:
                _fail(origin, n, String("end_of_record outside a record"))
            files.append(current.copy())
            in_record = False
            continue
        var colon = line.find(":")
        if colon <= 0:
            _fail(origin, n, String("not a record: '") + line + String("'"))
        var kind = substr(line, 0, colon)
        var body = suffix(line, colon + 1)
        if kind == String("TN"):
            if in_record:
                _fail(origin, n, String("TN inside a record"))
            continue
        if kind == String("SF"):
            if in_record:
                _fail(origin, n, String("SF before the end_of_record of the previous file"))
            if body.byte_length() == 0:
                _fail(origin, n, String("SF names no file"))
            current = FileCov(body)
            in_record = True
            continue
        if (
            kind != String("FN") and kind != String("FNDA") and kind != String("FNF")
            and kind != String("FNH") and kind != String("DA") and kind != String("BRDA")
            and kind != String("BRF") and kind != String("BRH") and kind != String("LF")
            and kind != String("LH") and kind != String("FNL") and kind != String("FNA")
        ):
            _fail(origin, n, String("unknown record type '") + kind + String("'"))
        if not in_record:
            _fail(origin, n, kind + String(" outside SF .. end_of_record"))
        var f = split_on(body, 44)
        if kind == String("DA"):
            if len(f) < 2 or len(f) > 3:
                _fail(origin, n, String("DA needs <line>,<hits>[,<checksum>], not ") + String(len(f)) + String(" fields"))
            var at = _line(origin, n, f[0], String("DA line"))
            current.add_line(at, _number(origin, n, f[1], String("DA hits")))
        elif kind == String("BRDA"):
            if len(f) < 4:
                _fail(origin, n, String("BRDA needs <line>,<block>,<branch>,<taken>"))
            var at = _line(origin, n, f[0], String("BRDA line"))
            var exc = String("e") if f[1].startswith("e") else String("")
            var block = _number(origin, n, suffix(f[1], exc.byte_length()), String("BRDA block"))
            # The branch id may itself hold commas (lcov 2 writes an expression):
            # it is everything between the block and the last field.
            var first_two = f[0].byte_length() + f[1].byte_length() + 2
            var last = f[len(f) - 1]
            var branch = substr(body, first_two, body.byte_length() - last.byte_length() - 1)
            if branch.byte_length() == 0:
                _fail(origin, n, String("BRDA branch id is empty"))
            var taken = 0
            if last != String("-"):
                taken = _number(origin, n, last, String("BRDA taken"))
            current.add_branch(String(at) + String(",") + exc + String(block) + String(",") + branch, taken)
        elif kind == String("FN"):
            if len(f) < 2:
                _fail(origin, n, String("FN needs <line>,<name>"))
            _ = _number(origin, n, f[0], String("FN line"))
        elif kind == String("FNDA"):
            if len(f) < 2:
                _fail(origin, n, String("FNDA needs <count>,<name>"))
            _ = _number(origin, n, f[0], String("FNDA count"))
        elif kind == String("FNL"):
            if len(f) < 2 or len(f) > 3:
                _fail(origin, n, String("FNL needs <index>,<line>[,<end line>]"))
            _ = _number(origin, n, f[0], String("FNL index"))
            _ = _line(origin, n, f[1], String("FNL line"))
            if len(f) == 3:
                _ = _line(origin, n, f[2], String("FNL end line"))
        elif kind == String("FNA"):
            if len(f) < 3:
                _fail(origin, n, String("FNA needs <index>,<count>,<name>"))
            _ = _number(origin, n, f[0], String("FNA index"))
            _ = _number(origin, n, f[1], String("FNA count"))
        else:
            _ = _number(origin, n, body, kind)
    if in_record:
        _fail(origin, last_line, String("the last record has no end_of_record"))
    return merge_by_path(files^)
