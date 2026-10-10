# =============================================================================
# suite.mojo -- the pinned JSONTestSuite test_parsing corpus, as bytes
# =============================================================================
#
# third_party/jsontestsuite extracts the suite's test_parsing/ directory; a
# test declares it as data at `jsontestsuite` (BUCK), so it is
# `share/jsontestsuite/test_parsing/<name>` beside the test executable.
#
# Every file is read as raw bytes and stays raw bytes: several files hold
# ill-formed UTF-8 on purpose, and a parser's own UTF-8 check is part of what
# the suite tests, so nothing here decodes them.
#
# The file name's prefix is the verdict the suite requires:
#   y_  the text is JSON; a parser must accept it;
#   n_  the text is not JSON; a parser must reject it;
#   i_  RFC 8259 leaves it to the implementation (a number past the range of a
#       double, a lone surrogate escape, nesting 500 deep, ...): either answer
#       is conformant; only a crash is not.
#
# `load_suite` requires exactly the pinned suite's counts per prefix
# (`check_suite_names`), so an extraction that lost files, or a newer pin
# nobody re-read, fails rather than passing on fewer cases.
# =============================================================================

from std.os import listdir
from std.pathlib import Path

from komira_runtime_paths import data_path

# Where the test declares the extracted tree (its test_data destination).
comptime SUITE_DATA_DIR = "jsontestsuite/test_parsing"

# The pinned suite's size (third_party/jsontestsuite/test_parsing.bzl).
comptime SUITE_Y_FILES = 95
comptime SUITE_N_FILES = 188
comptime SUITE_I_FILES = 35
comptime SUITE_FILES = SUITE_Y_FILES + SUITE_N_FILES + SUITE_I_FILES

comptime KIND_Y: UInt8 = 0
comptime KIND_N: UInt8 = 1
comptime KIND_I: UInt8 = 2


def kind_of(name: String) raises -> UInt8:
    """The suite verdict a file name carries in its prefix."""
    if name.startswith("y_"):
        return KIND_Y
    if name.startswith("n_"):
        return KIND_N
    if name.startswith("i_"):
        return KIND_I
    raise Error("suite file '" + name + "' has none of the prefixes y_, n_, i_")


def kind_name(kind: UInt8) -> String:
    if kind == KIND_Y:
        return String("y")
    if kind == KIND_N:
        return String("n")
    return String("i")


@fieldwise_init
struct SuiteFile(Copyable, Movable):
    var name: String
    var kind: UInt8
    var bytes: List[UInt8]


def _sorted(var names: List[String]) -> List[String]:
    """`names` in bytewise order (insertion sort: 318 names, run once)."""
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j] < names[j - 1]:
            names.swap_elements(j, j - 1)
            j -= 1
    return names^


def check_suite_names(names: List[String]) raises:
    """Raises unless `names` are exactly the pinned suite's counts of y_, n_
    and i_ `.json` files and nothing else (an extraction that lost files, a
    stray file, or a newer pin nobody re-read)."""
    var counts: List[Int] = [0, 0, 0]
    for ref name in names:
        if not name.endswith(".json"):
            raise Error("suite directory holds '" + name + "', not a .json file")
        counts[Int(kind_of(name))] += 1
    if (
        counts[0] != SUITE_Y_FILES
        or counts[1] != SUITE_N_FILES
        or counts[2] != SUITE_I_FILES
    ):
        raise Error(
            "the suite directory holds " + String(counts[0]) + " y_, "
            + String(counts[1]) + " n_ and " + String(counts[2])
            + " i_ files; the pinned suite has " + String(SUITE_Y_FILES) + ", "
            + String(SUITE_N_FILES) + " and " + String(SUITE_I_FILES)
        )


def load_suite_from(dir: String) raises -> List[SuiteFile]:
    """Every file of `dir`, in bytewise name order, with its bytes. Raises
    when `dir` cannot be listed and unless its names pass
    `check_suite_names`."""
    var names = List[String]()
    for n in listdir(dir):
        names.append(String(n))
    names = _sorted(names^)
    check_suite_names(names)
    var out = List[SuiteFile]()
    for ref name in names:
        out.append(
            SuiteFile(name=name, kind=kind_of(name), bytes=suite_file_bytes(dir, name))
        )
    return out^


def suite_file_bytes(dir: String, name: String) raises -> List[UInt8]:
    """One suite file's raw bytes."""
    return Path(dir + "/" + name).read_bytes()


def load_suite() raises -> List[SuiteFile]:
    """The suite, from the test's declared data (see the module header)."""
    return load_suite_from(data_path(SUITE_DATA_DIR))


def suite_dir() raises -> String:
    """The extracted test_parsing directory beside the test executable."""
    return data_path(SUITE_DATA_DIR)
