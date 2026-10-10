# =============================================================================
# vocabulary.mojo — scan a generic package's sources for product vocabulary and
# for early year-months: 2024 or 2025 with any month, or 2026 with month 01 to
# 08. Earlier years are not matched.
# =============================================================================
#
# Two checks per source line:
#   - a banned word (`banned_words()`): case-insensitive substring, deliberately
#     blunt. A false positive is a rename; a false negative is a product model
#     creeping into a generic package.
#   - an early date (`early_date_at`): a year 2024 or 2025 with any month, or
#     2026 with month 01 to 08, written as four year digits, then one of
#     `-`, `_`, `/`, `.` or nothing, then two month digits (01 to 12). The year
#     must not continue a longer number. Month names are not matched.
#
# The words and years are built from parts, so no line of this package holds a
# banned word or an early date whole, and a repository search for either finds
# only real uses.
# =============================================================================

from std.os import listdir
from std.os.path import isdir


def banned_words() -> List[String]:
    """The lower-case words no generic package may contain."""
    var out = List[String]()
    out.append(String("org") + "_id")
    out.append(String("workspace") + "_id")
    out.append(String("app") + "_id")
    out.append(String("env") + "_id")
    out.append(String("gra") + "nt")
    out.append(String("ten") + "ant")
    out.append(String("cust") + "omer")
    out.append(String("job") + " manager")
    out.append(String("managed") + " app")
    out.append(String("managed") + " deployment")
    out.append(String("control") + " plane")
    return out^


@always_inline
def _digit(b: UInt8) -> Int:
    """The value of an ASCII digit, or -1."""
    if b >= UInt8(48) and b <= UInt8(57):
        return Int(b) - 48
    return -1


@always_inline
def _is_separator(b: UInt8) -> Bool:
    # `-`, `.`, `/`, `_`
    return b == UInt8(45) or b == UInt8(46) or b == UInt8(47) or b == UInt8(95)


def early_date_at(line: String) -> Int:
    """The byte offset of the first early year-month in `line` (a year 2024 or
    2025 with any month 01 to 12, or 2026 with month 01 to 08), or -1 when there
    is none. Years before 2024 are not matched. See the header for the
    spellings matched."""
    var b = line.as_bytes()
    var n = len(b)
    var first_year = 2000 + 24
    var cut_year = 2000 + 26
    for i in range(n - 5):
        if i > 0 and _digit(b[i - 1]) >= 0:
            continue
        var d0 = _digit(b[i])
        var d1 = _digit(b[i + 1])
        var d2 = _digit(b[i + 2])
        var d3 = _digit(b[i + 3])
        if d0 < 0 or d1 < 0 or d2 < 0 or d3 < 0:
            continue
        var year = d0 * 1000 + d1 * 100 + d2 * 10 + d3
        if year < first_year or year > cut_year:
            continue
        var j = i + 4
        if _is_separator(b[j]):
            j += 1
        if j + 1 >= n:
            continue
        var m0 = _digit(b[j])
        var m1 = _digit(b[j + 1])
        if m0 < 0 or m1 < 0:
            continue
        var month = m0 * 10 + m1
        if month < 1 or month > 12:
            continue
        if year < cut_year or month <= 8:
            return i
    return -1


def scan_text(
    path: String, text: String, banned: List[String], mut hits: List[String]
):
    """Append one `path:line: <word>` hit per banned word on a line, and one
    `path:line: a date before September 2026` hit per line on which
    `early_date_at` finds an early year-month."""
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        var low = line.lower()
        for j in range(len(banned)):
            if banned[j] in low:
                hits.append(path + ":" + String(i + 1) + ": " + banned[j])
        if early_date_at(line) >= 0:
            hits.append(
                path + ":" + String(i + 1) + ": a date before September 2026"
            )


def _collect(dir: String, mut files: List[String]) raises:
    for name in listdir(dir):
        var path = dir + "/" + String(name)
        if isdir(path):
            _collect(path, files)
        elif path.endswith(".mojo"):
            files.append(path)


def scan_library(root: String, min_files: Int) raises -> String:
    """Scan every `.mojo` file under `root` and return the hits, one per line;
    empty when the sources are clean. Raises when fewer than `min_files` files
    are found, so a staging that holds nothing cannot pass."""
    var files = List[String]()
    _collect(root, files)
    if len(files) < min_files:
        raise Error(
            "expected at least "
            + String(min_files)
            + " library sources staged under "
            + root
            + ", found "
            + String(len(files))
        )
    var banned = banned_words()
    var hits = List[String]()
    for i in range(len(files)):
        var text: String
        with open(files[i], "r") as f:
            text = f.read()
        scan_text(files[i], text, banned, hits)
    var report = String("")
    for i in range(len(hits)):
        report += hits[i] + "\n"
    return report^
