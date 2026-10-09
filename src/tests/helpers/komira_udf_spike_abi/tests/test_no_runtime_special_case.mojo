# No special case per language or per runtime in the contract, the harness
# or the suite: every runtime gets every case, and what the harness knows of
# a runtime comes from describe.
#
# The check reads every library source of this package (the .mojo files
# outside tests/, both headers) and every case under cases/ and
# cases_runner/, staged as test data at their repository paths, and fails
# naming the file and line of each hit of:
#   - a runtime id of the namespaces komira ships (`komira/...`,
#     `komira-test/...`), which only a special case would name;
#   - the name of a language, a language runtime or its data library, as a
#     whole word, case-insensitive (the list is _banned_words). The harness's
#     own language is not in the list: it names its source files.
# Words and ids are built from parts, so this file holds none of them whole.
#
# Mutant planted: `if caps.runtime_id == "<the broken echo's id>": ...`
# added to conform.mojo's run_suite: red, naming conform.mojo and the line.

from std.os import listdir
from std.os.path import isdir
from std.testing import assert_equal, assert_true

comptime ROOT = "src/tests/helpers/komira_udf_spike_abi"


def _banned_words() -> List[String]:
    var out = List[String]()
    out.append(String("pyt") + "hon")
    out.append(String("cpyt") + "hon")
    out.append(String("pyar") + "row")
    out.append(String("num") + "py")
    out.append(String("pan") + "das")
    out.append(String("pol") + "ars")
    out.append(String("java") + "script")
    out.append(String("type") + "script")
    out.append(String("no") + "de")
    out.append(String("node") + "js")
    out.append(String("na") + "pi")
    out.append(String("v") + "8")
    out.append(String("de") + "no")
    out.append(String("ja") + "va")
    out.append(String("j") + "vm")
    out.append(String("dot") + "net")
    out.append(String("csh") + "arp")
    out.append(String("go") + "lang")
    out.append(String("wa") + "sm")
    out.append(String("wasm") + "time")
    out.append(String("ru") + "st")
    out.append(String("zi") + "g")
    out.append(String("c") + "pp")
    out.append(String("ec") + "ho")
    return out^


def _banned_ids() -> List[String]:
    return [String("komira") + "/", String("komira") + "-test/"]


def _is_word_byte(b: UInt8) -> Bool:
    return (b >= 0x61 and b <= 0x7A) or (b >= 0x30 and b <= 0x39) or b == 0x5F


def _lower(s: String) -> List[UInt8]:
    var bytes = s.as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        var b = bytes[i]
        out.append(b + 0x20 if b >= 0x41 and b <= 0x5A else b)
    return out^


def _find_at(line: List[UInt8], word: List[UInt8], at: Int) -> Bool:
    if at + len(word) > len(line):
        return False
    for k in range(len(word)):
        if line[at + k] != word[k]:
            return False
    return True


def scan_line(line: String) -> String:
    """The first banned word (as a whole word) or id (anywhere) in `line`,
    or ""."""
    var low = _lower(line)
    var ids = _banned_ids()
    for i in range(len(ids)):
        var w = _lower(ids[i])
        for at in range(len(low)):
            if _find_at(low, w, at):
                return ids[i]
    var words = _banned_words()
    for i in range(len(words)):
        var w = _lower(words[i])
        for at in range(len(low)):
            if not _find_at(low, w, at):
                continue
            var before = at == 0 or not _is_word_byte(low[at - 1])
            var end = at + len(w)
            var after = end == len(low) or not _is_word_byte(low[end])
            if before and after:
                return words[i]
    return ""


def _files(dir: String, mut out: List[String]) raises:
    var names = List[String]()
    for n in listdir(dir):
        names.append(String(n))
    sort(names)
    for i in range(len(names)):
        var path = dir + "/" + names[i]
        if isdir(path):
            if names[i] != "tests":
                _files(path, out)
        elif names[i].endswith(".mojo") or names[i].endswith(".h") or names[i].endswith(".json"):
            out.append(path)


def main() raises:
    # The scanner itself, so a scanner that matches nothing cannot pass.
    assert_equal(scan_line("if rt == " + String("\"komira") + "-test/x\":"), String("komira") + "-test/")
    assert_equal(scan_line("a " + String("Pyt") + "hon fixture"), String("pyt") + "hon")
    assert_equal(scan_line("the plan " + String("no") + "de_id"), "", "a word inside an identifier")
    assert_equal(scan_line("runtime_ids and nodes"), "")
    var files = List[String]()
    _files(ROOT, files)
    var mojo = 0
    var json = 0
    var hits = String()
    for i in range(len(files)):
        if files[i].endswith(".mojo"):
            mojo += 1
        if files[i].endswith(".json"):
            json += 1
        with open(files[i], "r") as f:
            var lines = f.read().split("\n")
            for n in range(len(lines)):
                var w = scan_line(String(lines[n]))
                if w != "":
                    hits += files[i] + ":" + String(n + 1) + ": '" + w + "'\n"
    print("scanned", len(files), "files:", mojo, "Mojo,", json, "cases")
    assert_true(mojo >= 10, "the library's sources are staged")
    assert_true(json >= 98, "the cases are staged")
    assert_equal(hits, "", "a runtime or language named in the harness or the suite:\n" + hits)
    print("test_no_runtime_special_case: ok")
