# komira_xml's canonical form against the conformance harness (a
# differential test): canonical_xml, the comparison a restXml client's
# bodies are judged by, against the harness's independent XML equivalence
# (komira//tools/build/proto-codegen, `xml_equiv`), over every XML body of
# botocore's rest-xml protocol corpus.
#
# `xml-equiv-verdicts` writes, for each non-empty request and response body
# of the cases botocore's ignore list does not skip, whether it parses as
# XML, and for each unordered pair of them whether the two are the same
# document (`rest_xml_verdicts.tsv`). This test reads the same bodies out of
# the corpus by case key and requires komira_xml to agree on every one:
#
#   a body:  komira_xml parses it  <=>  the verdict is `parses`
#   a pair:  canonical_xml(a) == canonical_xml(b) when both parse, else
#            a == b byte for byte  <=>  the verdict is `equal`
#
# Byte equality for a body that is not XML is botocore's own fallback, and
# the harness's. The two rest-xml case files are read from the botocore
# archive //third_party/botocore pins by sha256, staged at their paths in
# it; nothing is copied into this repository. The ignore list is applied
# by `xml-equiv-verdicts` when it writes the verdicts: which cases are
# skipped is read from the verdicts file, not from the list.

from std.collections import Dict

from komira_json import (
    JSON_ARRAY,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)
from komira_xml import canonical_xml


comptime _VERDICTS = "rest_xml_verdicts.tsv"
comptime _INPUT = "tests/unit/protocols/input/rest-xml.json"
comptime _OUTPUT = "tests/unit/protocols/output/rest-xml.json"

# The non-empty, non-skipped bodies at the pinned botocore release
# (third_party/botocore), as the verdicts file's own test counts them.
# Update them with the pin: a shrunken file cannot pass as the corpus.
comptime _INPUT_BODIES = 43
comptime _OUTPUT_BODIES = 57
# The pairs the harness calls the same document. Pinned too: were every
# pair `differ`, a canonical form that merged nothing would pass.
comptime _EQUAL_PAIRS = 8


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _member(v: JsonValue, key: String) -> Int:
    if v.kind != JSON_OBJECT:
        return -1
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == key:
            return i
    return -1


def _bodies(
    path: String, direction: String, holder: String
) raises -> Dict[String, String]:
    """Case key -> body: `<direction>/rest-xml.json#<id>` -> the string at
    `holder`.body of each case that has one."""
    var root = parse_json_value(_read(path))
    if root.kind != JSON_ARRAY:
        raise Error(path + ": not an array of suites")
    var out = Dict[String, String]()
    for s in range(len(root.children)):
        ref suite = root.children[s]
        var ci = _member(suite, "cases")
        if ci < 0:
            raise Error(path + ": a suite has no cases")
        ref cases = suite.children[ci]
        for c in range(len(cases.children)):
            ref cs = cases.children[c]
            var ii = _member(cs, "id")
            var hi = _member(cs, holder)
            if ii < 0 or hi < 0:
                continue
            ref h = cs.children[hi]
            var bi = _member(h, "body")
            if bi < 0 or h.children[bi].kind != JSON_STRING:
                continue
            var key = direction + "/rest-xml.json#" + cs.children[ii].text
            if key in out:
                raise Error(path + ": case key " + key + " is not unique")
            out[key] = h.children[bi].text
    return out^


def _fields(line: String) -> List[String]:
    var out = List[String]()
    for part in line.split("\t"):
        out.append(String(part))
    return out^


def test_canonical_agrees_with_harness() raises:
    var input = _bodies(String(_INPUT), "input", "serialized")
    var output = _bodies(String(_OUTPUT), "output", "response")

    var keys = List[String]()
    var bodies = List[String]()
    var canon = List[String]()
    var parses = List[Bool]()
    var pairs = 0
    var checked_pairs = 0
    var failures = List[String]()
    var n_input = 0
    var n_output = 0
    var n_equal = 0
    # `equal` pairs whose bytes differ: the ones only a canonical form, not
    # byte equality, can call the same.
    var n_equal_unlike = 0

    var text = _read(String(_VERDICTS))
    for raw in text.split("\n"):
        var line = String(raw)
        if line.byte_length() == 0:
            continue
        var f = _fields(line)
        if f[0] == "body" and len(f) == 3:
            var key = f[1]
            var body: String
            if key.startswith("input/"):
                body = input[key]
                n_input += 1
            elif key.startswith("output/"):
                body = output[key]
                n_output += 1
            else:
                raise Error("verdict body key in no direction: " + key)
            var c = String("")
            var ok = True
            try:
                c = canonical_xml(body)
            except:
                ok = False
            var want = f[2] == "parses"
            if f[2] != "parses" and f[2] != "raw":
                raise Error("verdict kind " + f[2] + " for " + key)
            if ok != want:
                failures.append(
                    key + ": harness says " + f[2] + ", komira_xml "
                    + ("parses" if ok else "refuses")
                )
            keys.append(key)
            bodies.append(body)
            canon.append(c^)
            parses.append(ok)
        elif f[0] == "pair" and len(f) == 4:
            pairs += 1
            var a = -1
            var b = -1
            for i in range(len(keys)):
                if keys[i] == f[1]:
                    a = i
                if keys[i] == f[2]:
                    b = i
            if a < 0 or b < 0:
                raise Error("pair names an unlisted body: " + line)
            var same: Bool
            if parses[a] and parses[b]:
                same = canon[a] == canon[b]
            else:
                same = bodies[a] == bodies[b]
            if f[3] != "equal" and f[3] != "differ":
                raise Error("pair verdict " + f[3])
            if f[3] == "equal":
                n_equal += 1
                if bodies[a] != bodies[b]:
                    n_equal_unlike += 1
            if same != (f[3] == "equal"):
                failures.append(
                    f[1] + " ~ " + f[2] + ": harness says " + f[3]
                    + ", komira_xml " + ("equal" if same else "differ")
                )
            checked_pairs += 1
        else:
            raise Error("not a body or pair record: " + line)

    if n_input != _INPUT_BODIES or n_output != _OUTPUT_BODIES:
        raise Error(
            "the verdicts list " + String(n_input) + " input and "
            + String(n_output) + " output bodies; the pinned corpus has "
            + String(_INPUT_BODIES) + " and " + String(_OUTPUT_BODIES)
        )
    var n = len(keys)
    if pairs != n * (n - 1) // 2 or checked_pairs != pairs:
        raise Error(
            "the verdicts hold " + String(pairs) + " pairs for "
            + String(n) + " bodies"
        )
    if n_equal != _EQUAL_PAIRS or n_equal_unlike == 0:
        raise Error(
            "the verdicts hold " + String(n_equal) + " equal pairs ("
            + String(n_equal_unlike) + " unlike byte for byte); the pinned "
            + "corpus has " + String(_EQUAL_PAIRS) + ", some unlike"
        )
    if len(failures) > 0:
        var msg = String(len(failures)) + " disagreement(s):"
        for i in range(min(len(failures), 20)):
            msg += "\n  " + failures[i]
        raise Error(msg)
    print("bodies", n, "pairs", pairs, "all agree")


def main() raises:
    test_canonical_agrees_with_harness()
    print("OK")
