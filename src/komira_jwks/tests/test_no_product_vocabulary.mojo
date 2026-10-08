# =============================================================================
# test_no_product_vocabulary.mojo: the JWK library names no product concept and
# carries no date of the first eight months of 2026 in the spellings below.
# =============================================================================
#
# This package is general-purpose and open source: the authorization model of
# whoever mints tokens is the minter's business. So no identifier, comment or
# docstring of the library may name one, and no line may carry a date in the
# first eight months of the year the repository opened (an internal timeline
# has no place in it). The check reads every library source file (declared as
# test data in the BUCK file; the tests/ directory is not among them) and
# fails naming the file and line of each hit.
#
# Matching is case-insensitive, deliberately blunt: a false positive is a
# rename, a false negative is the product model creeping back in. The word
# list is the one `komira_http_server`'s test of the same name uses. The date
# spellings matched, for a month M from 1 to 8 and a separator S of - _ / . :
#   * year first: `2026S0M` and the basic form `20260M`;
#   * year last: `0MS2026` (also the tail of a day-first `DDS0MS2026`) and
#     the month-first `0MSDDS2026`;
#   * a month name of January to August, full or in three letters, as a
#     whole word on a line that also holds `2026`.
# A single-digit month (`2026-3`) is not matched.
# =============================================================================

from std.os import listdir
from std.os.path import isdir
from std.testing import assert_equal, assert_true

comptime _ROOT = "src/komira_jwks"


# Spelled in parts so that no line of this file contains a banned word whole:
# a search of the repository for one of them then finds only real uses.
def _banned() -> List[String]:
    var out = List[String]()
    out.append(String("org") + "_id")
    out.append(String("workspace") + "_id")
    out.append(String("app") + "_id")
    out.append(String("env") + "_id")
    out.append(String("gra") + "nt")
    out.append(String("ten") + "ant")
    out.append(String("cust") + "omer")
    out.append(String("job") + " manager")
    # Year first: year, separator, month 01 to 08; and the basic form.
    var seps = List[String]()
    seps.append("-")
    seps.append("_")
    seps.append("/")
    seps.append(".")
    for m in range(1, 9):
        for s in range(len(seps)):
            out.append(_year() + seps[s] + "0" + String(m))
        out.append(_year() + "0" + String(m))
    return out^


def _year() -> String:
    return String("20") + "26"


def _months() -> List[String]:
    var out = List[String]()
    for name in [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
    ]:
        out.append(String(name))
    return out^


def _is_sep(c: UInt8) -> Bool:
    return (
        c == UInt8(ord("-"))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("/"))
        or c == UInt8(ord("."))
    )


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _is_month_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("1")) and c <= UInt8(ord("8"))


def _words(low: String) -> List[String]:
    """The runs of letters a to z in `low`."""
    var out = List[String]()
    var b = low.as_bytes()
    var start = -1
    for i in range(len(b) + 1):
        var alpha = i < len(b) and b[i] >= UInt8(ord("a")) and b[i] <= UInt8(
            ord("z")
        )
        if alpha and start < 0:
            start = i
        elif not alpha and start >= 0:
            out.append(String(low[byte=start:i]))
            start = -1
    return out^


def _year_last_date(low: String) -> String:
    """The year-last or month-name date form `low` holds, or "" for none."""
    var year = _year()
    if year not in low:
        return String("")
    var months = _months()
    var words = _words(low)
    for i in range(len(words)):
        for j in range(len(months)):
            if words[i] == months[j]:
                return String("month name ") + months[j]
    var b = low.as_bytes()
    var y = year.as_bytes()
    for k in range(3, len(b) - 3):
        if not (
            b[k] == y[0] and b[k + 1] == y[1] and b[k + 2] == y[2]
            and b[k + 3] == y[3]
        ):
            continue
        # 0M S year
        if (
            b[k - 3] == UInt8(ord("0"))
            and _is_month_digit(b[k - 2])
            and _is_sep(b[k - 1])
        ):
            return String("0M<sep><year>")
        # 0M S DD S year
        if (
            k >= 6
            and b[k - 6] == UInt8(ord("0"))
            and _is_month_digit(b[k - 5])
            and _is_sep(b[k - 4])
            and _is_digit(b[k - 3])
            and _is_digit(b[k - 2])
            and _is_sep(b[k - 1])
        ):
            return String("0M<sep>DD<sep><year>")
    return String("")


def _collect(dir: String, mut files: List[String]) raises:
    for name in listdir(dir):
        var path = dir + "/" + String(name)
        if isdir(path):
            _collect(path, files)
        elif path.endswith(".mojo"):
            files.append(path)


def _scan(path: String, banned: List[String], mut hits: List[String]) raises:
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var low = String(lines[i]).lower()
        for j in range(len(banned)):
            if banned[j] in low:
                hits.append(path + ":" + String(i + 1) + ": " + banned[j])
        var form = _year_last_date(low)
        if form.byte_length() > 0:
            hits.append(path + ":" + String(i + 1) + ": " + form)


def test_library_names_no_product_vocabulary() raises:
    var files = List[String]()
    _collect(String(_ROOT), files)
    # Refuse to pass over nothing: an empty staging would be a vacuous green.
    assert_true(
        len(files) >= 5,
        "expected the library sources staged as test data, found "
        + String(len(files)),
    )
    var banned = _banned()
    var hits = List[String]()
    for i in range(len(files)):
        _scan(files[i], banned, hits)
    var report = String("")
    for i in range(len(hits)):
        report += hits[i] + "\n"
    assert_equal(len(hits), 0, "product vocabulary or dates in komira_jwks:\n" + report)


def main() raises:
    test_library_names_no_product_vocabulary()
