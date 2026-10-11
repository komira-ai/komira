from std.os import getenv, listdir, makedirs
from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value

from covcheck.cli import EXIT_GATE, EXIT_INPUT, EXIT_OK, EXIT_USAGE, max_annotations, parse_args, run
from covcheck.text import read_text, sort_strings, write_text

# The command line end to end on the e2e fixtures: the summary byte for
# byte, the check-run files, the result JSON, the proposed ratchet, the
# gate's entry equal to the report's, and every exit code.

comptime E2E = "tools/build/coverage/tests/fixtures/e2e/"
comptime SHA = "0123456789abcdef0123456789abcdef01234567"


def _tmp(name: String) raises -> String:
    var d = getenv("TMPDIR") + String("/") + name
    makedirs(d, exist_ok=True)
    return d


def _repo_files(dir: String) raises -> String:
    """The fixture repository's `git ls-files -z`, written to `dir`."""
    var names = List[String]()
    names.append("BUCK")
    names.append("docs/x.md")
    names.append("src/alpha/BUCK")
    names.append("src/alpha/__init__.mojo")
    names.append("src/alpha/a.mojo")
    names.append("src/alpha/z.mojo")
    names.append("src/alpha/tests/test_a.mojo")
    names.append("src/beta/BUCK")
    names.append("src/beta/c.mojo")
    var b = List[UInt8]()
    for i in range(len(names)):
        var nb = names[i].as_bytes()
        for k in range(len(nb)):
            b.append(nb[k])
        b.append(UInt8(0))
    var path = dir + String("/repo_files")
    write_text(path, String(from_utf8_lossy=b))
    return path


def _common(dir: String) raises -> List[String]:
    var a = List[String]()
    a.append("--repo-files")
    a.append(_repo_files(dir))
    a.append("--source-root")
    a.append(String(E2E) + "root")
    a.append("--cobertura")
    a.append(String("src/alpha=") + String(E2E) + "cov_alpha.xml")
    a.append("--cobertura")
    a.append(String("src/beta=") + String(E2E) + "cov_beta.xml")
    a.append("--mutants")
    a.append(String(E2E) + "mutants.tsv")
    a.append("--ratchet")
    a.append(String(E2E) + "ratchet.tsv")
    a.append("--summary-out")
    a.append(dir + "/summary.md")
    a.append("--result-out")
    a.append(dir + "/result.json")
    return a^


def _report(dir: String) raises -> List[String]:
    var a = List[String]()
    a.append("report")
    a.extend(_common(dir))
    a.append("--diff")
    a.append(String(E2E) + "diff.txt")
    a.append("--head-sha")
    a.append(String(SHA))
    a.append("--checkrun-dir")
    a.append(dir + "/checkrun")
    a.append("--ratchet-out")
    a.append(dir + "/ratchet.tsv")
    return a^


def _gate(dir: String, mode: String) raises -> List[String]:
    var a = List[String]()
    a.append("gate")
    a.extend(_common(dir))
    a.append("--package")
    a.append("src/alpha")
    a.append("--mode")
    a.append(mode)
    return a^


def _first_diff(got: String, want: String) -> String:
    """The first line where `got` and `want` differ, both sides."""
    var g = got.split("\n")
    var w = want.split("\n")
    for i in range(max(len(g), len(w))):
        var gl = String(g[i]) if i < len(g) else String("<end>")
        var wl = String(w[i]) if i < len(w) else String("<end>")
        if gl != wl:
            return String("line ") + String(i + 1) + String(":\n got: ") + gl + String("\nwant: ") + wl
    return String("")


def test_report_end_to_end() raises:
    var dir = _tmp(String("report"))
    assert_equal(run(_report(dir)), EXIT_OK)
    var got = read_text(dir + "/summary.md")
    var want = read_text(String(E2E) + "summary.md")
    assert_true(got == want, _first_diff(got, want))
    var files = listdir(dir + "/checkrun")
    sort_strings(files)
    assert_equal(len(files), 2)
    assert_equal(files[0], "000.json")
    assert_equal(files[1], "001.json")
    var post = parse_json_value(read_text(dir + "/checkrun/000.json"))
    var anns = post.get(String("output")).get(String("annotations"))
    # a.mojo (changed) 5; z.mojo (in no report) runs 4-5 and 8 around its
    # exempt line 6, and that exemption; nothing for __init__.mojo.
    assert_equal(anns.array_len(), 8)
    assert_equal(anns.element_at(0).get(String("path")).as_string(), "src/alpha/a.mojo")
    assert_equal(Int(anns.element_at(0).get(String("start_line")).as_int64()), 2)
    assert_equal(Int(anns.element_at(0).get(String("end_line")).as_int64()), 3)
    assert_equal(anns.element_at(4).get(String("annotation_level")).as_string(), "notice")
    var z = String("")
    for i in range(5, 8):
        var e = anns.element_at(i)
        z += e.get(String("path")).as_string() + String(":") + String(Int(e.get(String("start_line")).as_int64()))
        z += String("-") + String(Int(e.get(String("end_line")).as_int64())) + String(" ") + e.get(String("title")).as_string() + String("\n")
    assert_equal(z,
        "src/alpha/z.mojo:4-5 File not compiled into any test\n"
        "src/alpha/z.mojo:6-6 Coverage exemption\n"
        "src/alpha/z.mojo:8-8 File not compiled into any test\n"
    )
    assert_equal(post.get(String("output")).get(String("summary")).as_string(), want)
    var last = parse_json_value(read_text(dir + "/checkrun/001.json"))
    assert_equal(last.get(String("status")).as_string(), "completed")
    assert_equal(last.get(String("conclusion")).as_string(), "neutral")
    var result = parse_json_value(read_text(dir + "/result.json"))
    assert_equal(result.get(String("conclusion")).as_string(), "neutral")
    assert_equal(Int(result.get(String("total")).get(String("line_found")).as_int64()), 10)
    assert_equal(Int(result.get(String("diff")).get(String("uncovered")).as_int64()), 2)
    assert_equal(result.get(String("touched_packages")).element_at(0).as_string(), "src/alpha")
    var findings = result.get(String("findings"))
    # src/beta: every line covered, no branch record, so BranchNotMeasured.
    assert_equal(findings.array_len(), 7)
    var unmeasured = 0
    for i in range(findings.array_len()):
        var f = findings.element_at(i)
        if f.get(String("kind")).as_string() == String("UnmeasuredFile"):
            unmeasured += 1
            assert_equal(f.get(String("path")).as_string(), "src/alpha/z.mojo")
            assert_equal(Int(f.get(String("line")).as_int64()), 0)
            assert_equal(Int(f.get(String("count")).as_int64()), 3)
        else:
            assert_true(f.get(String("count")).is_null())
    assert_equal(unmeasured, 1)
    var alpha = result.get(String("packages")).element_at(0)
    assert_equal(Int(alpha.get(String("files")).as_int64()), 2)
    assert_equal(Int(alpha.get(String("unmeasured_files")).as_int64()), 1)
    assert_equal(read_text(dir + "/ratchet.tsv"), "# floors for the end-to-end test\nsrc/alpha\t2500\t5000\nsrc/beta\t10000\t-\n")


def test_gate_entry_is_the_report_entry() raises:
    var rdir = _tmp(String("gate_report"))
    assert_equal(run(_report(rdir)), EXIT_OK)
    var gdir = _tmp(String("gate"))
    assert_equal(run(_gate(gdir, String("enforce"))), EXIT_GATE)
    var report = parse_json_value(read_text(rdir + "/result.json"))
    var gate = parse_json_value(read_text(gdir + "/result.json"))
    var pkgs = report.get(String("packages"))
    var found = False
    for i in range(pkgs.array_len()):
        var p = pkgs.element_at(i)
        if p.get(String("package")).as_string() == String("src/alpha"):
            found = True
            assert_equal(gate.get(String("package")).serialize(), p.serialize())
    assert_true(found)
    assert_equal(gate.get(String("conclusion")).as_string(), "failure")
    assert_equal(gate.get(String("findings")).array_len(), 5)
    var ndir = _tmp(String("gate_neutral"))
    assert_equal(run(_gate(ndir, String("neutral"))), EXIT_OK)
    assert_true(read_text(ndir + "/summary.md").startswith("## Coverage of `src/alpha`: line 25.00% (2/8)"))
    # Census: the same findings, labelled, never a failing exit.
    var cdir = _tmp(String("gate_census"))
    assert_equal(run(_gate(cdir, String("census"))), EXIT_OK)
    var census = read_text(cdir + "/summary.md")
    assert_true(census.find("- **BelowTarget** (census) `src/alpha`: line 25.00%") >= 0, census)
    assert_equal(parse_json_value(read_text(cdir + "/result.json")).get(String("conclusion")).as_string(), "neutral")


def test_report_exit_never_carries_the_conclusion() raises:
    var dir = _tmp(String("enforce"))
    var a = _report(dir)
    a.append("--mode")
    a.append("enforce")
    assert_equal(run(a), EXIT_OK)
    var result = parse_json_value(read_text(dir + "/result.json"))
    assert_equal(result.get(String("conclusion")).as_string(), "failure")
    var last = parse_json_value(read_text(dir + "/checkrun/001.json"))
    assert_equal(last.get(String("conclusion")).as_string(), "failure")


def _with(var a: List[String], flag: String, value: String) -> List[String]:
    a.append(flag)
    a.append(value)
    return a^


def _sent(dir: String) raises -> Int:
    """How many annotations the check-run bodies in `dir` carry."""
    var files = listdir(dir + "/checkrun")
    var n = 0
    for i in range(len(files)):
        var v = parse_json_value(read_text(dir + "/checkrun/" + files[i]))
        n += v.get(String("output")).get(String("annotations")).array_len()
    return n


comptime CAP_NOTE_WRITTEN = "**Annotations**: 5 annotations omitted (cap 3); the full list is in the annotations file.\n"
comptime CAP_NOTE_NOT_WRITTEN = "**Annotations**: 5 annotations omitted (cap 3); the full list was not written (give --annotations-out).\n"


def test_annotation_cap_and_full_list() raises:
    # The e2e run has 8 annotations. Cap 3: the bodies carry the first 3
    # (the changed file's), the summary says 5 were left out and where the
    # full list is, and the --annotations-out file holds all 8 in order.
    var dir = _tmp(String("cap3"))
    var a = _with(_with(_report(dir), String("--max-annotations"), String("3")), String("--annotations-out"), dir + "/anns.json")
    assert_equal(run(a), EXIT_OK)
    assert_equal(_sent(dir), 3)
    var post = parse_json_value(read_text(dir + "/checkrun/000.json"))
    var sent = post.get(String("output")).get(String("annotations"))
    for i in range(3):
        assert_equal(sent.element_at(i).get(String("path")).as_string(), "src/alpha/a.mojo")
    var summary = read_text(dir + "/summary.md")
    assert_true(summary.find(CAP_NOTE_WRITTEN) >= 0, summary)
    assert_equal(post.get(String("output")).get(String("summary")).as_string(), summary)
    var full = parse_json_value(read_text(dir + "/anns.json"))
    assert_equal(full.array_len(), 8)
    assert_equal(full.element_at(0).serialize(), sent.element_at(0).serialize())
    assert_equal(full.element_at(7).get(String("path")).as_string(), "src/alpha/z.mojo")
    assert_equal(full.element_at(7).get(String("title")).as_string(), "File not compiled into any test")
    # Omitted, and no --annotations-out: the summary says the list was not written.
    var nd = _tmp(String("cap3_nofile"))
    assert_equal(run(_with(_report(nd), String("--max-annotations"), String("3"))), EXIT_OK)
    assert_equal(_sent(nd), 3)
    assert_true(read_text(nd + "/summary.md").find(CAP_NOTE_NOT_WRITTEN) >= 0)
    # A cap equal to the count: nothing omitted, no line, the file still full.
    var eq = _tmp(String("cap8"))
    var b = _with(_with(_report(eq), String("--max-annotations"), String("8")), String("--annotations-out"), eq + "/anns.json")
    assert_equal(run(b), EXIT_OK)
    assert_equal(_sent(eq), 8)
    assert_true(read_text(eq + "/summary.md").find("**Annotations**") < 0)
    assert_equal(read_text(eq + "/summary.md"), read_text(String(E2E) + "summary.md"))
    assert_equal(parse_json_value(read_text(eq + "/anns.json")).array_len(), 8)
    # The default is 1000.
    assert_equal(max_annotations(parse_args(_report(_tmp(String("cap_default"))))), 1000)


def _without(a: List[String], flag: String) -> List[String]:
    var out = List[String]()
    var i = 0
    while i < len(a):
        if a[i] == flag:
            i += 2
            continue
        out.append(a[i])
        i += 1
    return out^


def test_usage_errors_exit_2() raises:
    var dir = _tmp(String("usage"))
    assert_equal(run(List[String]()), EXIT_USAGE)
    var bogus = List[String]()
    bogus.append("frobnicate")
    assert_equal(run(bogus), EXIT_USAGE)
    assert_equal(run(_with(_report(dir), String("--frob"), String("x"))), EXIT_USAGE)
    assert_equal(run(_without(_report(dir), String("--head-sha"))), EXIT_USAGE)
    assert_equal(run(_without(_report(dir), String("--source-root"))), EXIT_USAGE)
    assert_equal(run(_with(_without(_report(dir), String("--head-sha")), String("--head-sha"), String("abc"))), EXIT_USAGE)
    assert_equal(run(_with(_report(dir), String("--mode"), String("strict"))), EXIT_USAGE)
    assert_equal(run(_with(_report(dir), String("--target-bp"), String("10001"))), EXIT_USAGE)
    assert_equal(run(_with(_report(dir), String("--ratchet"), String("again"))), EXIT_USAGE)
    assert_equal(run(_without(_without(_report(dir), String("--cobertura")), String("--cobertura"))), EXIT_USAGE)
    assert_equal(run(_with(_gate(dir, String("enforce")), String("--diff"), String(E2E) + "diff.txt")), EXIT_USAGE)
    assert_equal(run(_without(_gate(dir, String("enforce")), String("--mode"))), EXIT_USAGE)
    # lcov and Cobertura identify branches differently: never mixed.
    assert_equal(run(_with(_report(dir), String("--lcov"), String(E2E) + "cov_alpha.xml")), EXIT_USAGE)
    # --max-annotations: a number of 1 or more, and only for report.
    assert_equal(run(_with(_report(dir), String("--max-annotations"), String("0"))), EXIT_USAGE)
    assert_equal(run(_with(_report(dir), String("--max-annotations"), String("-1"))), EXIT_USAGE)
    assert_equal(run(_with(_report(dir), String("--max-annotations"), String("many"))), EXIT_USAGE)
    assert_equal(run(_with(_gate(dir, String("enforce")), String("--max-annotations"), String("3"))), EXIT_USAGE)
    var dangling = _report(dir)
    dangling.append("--name")
    assert_equal(run(dangling), EXIT_USAGE)


def test_input_errors_exit_1() raises:
    var dir = _tmp(String("input"))
    var bad = dir + "/bad_ratchet.tsv"
    write_text(bad, String("src/b\t1\t-\nsrc/a\t1\t-\n"))
    var a = _without(_report(_tmp(String("input_a"))), String("--ratchet"))
    assert_equal(run(_with(a^, String("--ratchet"), bad)), EXIT_INPUT)
    var unmapped = dir + "/unmapped.xml"
    write_text(unmapped, String("<coverage><classes><class filename=\"src/alpha/gone.mojo\"><lines><line number=\"1\" hits=\"1\"/></lines></class></classes></coverage>\n"))
    assert_equal(run(_with(_report(_tmp(String("input_b"))), String("--cobertura"), unmapped)), EXIT_INPUT)
    var full = _tmp(String("input_c"))
    makedirs(full + "/checkrun", exist_ok=True)
    write_text(full + "/checkrun/stale.json", String("{}"))
    assert_equal(run(_report(full)), EXIT_INPUT)
    var nopkg = _without(_gate(_tmp(String("input_d")), String("enforce")), String("--package"))
    assert_equal(run(_with(nopkg^, String("--package"), String("src/nothere"))), EXIT_INPUT)


def test_gate_with_no_report() raises:
    # A library with no test has no report: `gate` takes none (`report`
    # still needs one, test_usage_errors_exit_2). The gated package is
    # measured all the same: NotMeasured, its files counted from their
    # source, exit 3 in enforce mode and 0 in census.
    var dir = _tmp(String("gate_none"))
    var a = _without(_without(_without(_gate(dir, String("enforce")), String("--cobertura")), String("--cobertura")), String("--mutants"))
    assert_equal(run(a), EXIT_GATE)
    var result = parse_json_value(read_text(dir + "/result.json"))
    assert_equal(result.get(String("conclusion")).as_string(), "failure")
    var kinds = String("")
    var findings = result.get(String("findings"))
    for i in range(findings.array_len()):
        kinds += findings.element_at(i).get(String("kind")).as_string() + String(" ")
    assert_equal(kinds, "BelowTarget MissingRow NotMeasured UnmeasuredFile UnmeasuredFile ")
    assert_true(read_text(dir + "/summary.md").find("- **NotMeasured** `src/alpha`: ") >= 0)
    var cdir = _tmp(String("gate_none_census"))
    var c = _without(_without(_without(_gate(cdir, String("census")), String("--cobertura")), String("--cobertura")), String("--mutants"))
    assert_equal(run(c), EXIT_OK)
    assert_equal(parse_json_value(read_text(cdir + "/result.json")).get(String("conclusion")).as_string(), "neutral")


def test_gate_test_sources() raises:
    # `gate --test-source P` sets aside a welded test outside the package's
    # tests/ (here src/alpha/z.mojo): with no report, z.mojo is no longer a
    # file no test compiled, so one UnmeasuredFile goes. A path that is no
    # repository file, or a file of another package, is an input error;
    # `report` has no such flag.
    var dir = _tmp(String("gate_test_source"))
    var base = _without(_without(_without(_gate(dir, String("census")), String("--cobertura")), String("--cobertura")), String("--mutants"))
    assert_equal(run(_with(base.copy(), String("--test-source"), String("src/alpha/z.mojo"))), EXIT_OK)
    var kinds = String("")
    var result = parse_json_value(read_text(dir + "/result.json"))
    var findings = result.get(String("findings"))
    for i in range(findings.array_len()):
        kinds += findings.element_at(i).get(String("kind")).as_string() + String(" ")
    assert_equal(kinds, "BelowTarget MissingRow NotMeasured UnmeasuredFile ")
    assert_equal(run(_with(base.copy(), String("--test-source"), String("src/alpha/gone.mojo"))), EXIT_INPUT)
    assert_equal(run(_with(base.copy(), String("--test-source"), String("src/beta/c.mojo"))), EXIT_INPUT)
    assert_equal(run(_with(_report(_tmp(String("report_test_source"))), String("--test-source"), String("src/alpha/z.mojo"))), EXIT_USAGE)


def test_report_file_names() raises:
    # `[PKGDIR=]FILE`: the package directory is before the first `=`; a file
    # name holding `=` is given as `=FILE`, which is the same as no PKGDIR.
    var a = List[String]()
    a.append("gate")
    a.extend(_common(_tmp(String("file_names"))))
    a.append("--package")
    a.append("src/alpha")
    a.append("--mode")
    a.append("census")
    a.append("--cobertura")
    a.append("=out/a=b.xml")
    a.append("--cobertura")
    a.append("plain.xml")
    a.append("--cobertura")
    a.append("src/x/=c.xml")
    var p = parse_args(a)
    assert_equal(len(p.reports), 5)
    assert_equal(p.reports[0].pkgdir, "src/alpha")
    assert_equal(p.reports[2].pkgdir, "")
    assert_equal(p.reports[2].file, "out/a=b.xml")
    assert_equal(p.reports[3].pkgdir, "")
    assert_equal(p.reports[3].file, "plain.xml")
    assert_equal(p.reports[4].pkgdir, "src/x")
    assert_equal(p.reports[4].file, "c.xml")


def _branches(dir: String) raises -> String:
    """`<branch_hit>/<branch_found>` of the gate's package in `dir`."""
    var p = parse_json_value(read_text(dir + "/result.json")).get(String("package"))
    return p.get(String("branch_hit")).serialize() + String("/") + p.get(String("branch_found")).serialize()


def test_branch_lcov_flag() raises:
    # `--branch-lcov [PKGDIR=]F`, repeatable, on both commands, read with
    # Cobertura reports (no usage error): two tests' records for z.mojo
    # (which no line report names) add its branches to src/alpha's, summed
    # by id. A DA in such a file, records for a.mojo (whose Cobertura
    # report gives condition-coverage) and two files disagreeing on a
    # location's decisions are input errors; `report` still needs a line
    # report.
    var dir = _tmp(String("branch_lcov"))
    var one = dir + "/one.info"
    var two = dir + "/two.info"
    write_text(one, String("SF:src/alpha/z.mojo\nBRDA:5,5:br:0/1,0,-\nBRDA:5,5:br:0/1,1,3\nend_of_record\n"))
    write_text(two, String("SF:src/alpha/z.mojo\nBRDA:5,5:br:0/1,0,-\nBRDA:5,5:br:0/1,1,-\nend_of_record\n"))
    var plain = _tmp(String("branch_lcov_plain"))
    assert_equal(run(_gate(plain, String("census"))), EXIT_OK)
    assert_equal(_branches(plain), "1/2")
    var with_b = _tmp(String("branch_lcov_gate"))
    assert_equal(run(_with(_with(_gate(with_b, String("census")), String("--branch-lcov"), one), String("--branch-lcov"), String("src/alpha=") + two)), EXIT_OK)
    assert_equal(_branches(with_b), "2/4")
    var rdir = _tmp(String("branch_lcov_report"))
    assert_equal(run(_with(_report(rdir), String("--branch-lcov"), one)), EXIT_OK)
    var only = _with(_without(_without(_report(_tmp(String("branch_lcov_only"))), String("--cobertura")), String("--cobertura")), String("--branch-lcov"), one)
    assert_equal(run(only), EXIT_USAGE)
    var da = dir + "/da.info"
    write_text(da, String("SF:src/alpha/z.mojo\nDA:5,1\nend_of_record\n"))
    assert_equal(run(_with(_gate(_tmp(String("branch_lcov_da")), String("census")), String("--branch-lcov"), da)), EXIT_INPUT)
    var a = dir + "/a.info"
    write_text(a, String("SF:src/alpha/a.mojo\nBRDA:5,9:br:0/1,0,1\nBRDA:5,9:br:0/1,1,1\nend_of_record\n"))
    assert_equal(run(_with(_gate(_tmp(String("branch_lcov_a")), String("census")), String("--branch-lcov"), a)), EXIT_INPUT)
    var n2 = dir + "/n2.info"
    write_text(n2, String("SF:src/alpha/z.mojo\nBRDA:5,5:br:0/2,0,1\nBRDA:5,5:br:0/2,1,1\nBRDA:5,5:br:1/2,0,1\nBRDA:5,5:br:1/2,1,1\nend_of_record\n"))
    assert_equal(run(_with(_with(_gate(_tmp(String("branch_lcov_n")), String("census")), String("--branch-lcov"), one), String("--branch-lcov"), n2)), EXIT_INPUT)


def test_gate_floor_fails_in_every_mode() raises:
    # src/alpha measures line 25.00% (2/8). Under a floor of 25.01% the gate
    # exits 3 (EXIT_GATE) in census and neutral mode, not only in enforce,
    # and says why; at 25.00%, or under it, census exits 0. cov_gate.sh
    # turns exit 3 into a failed gate in every mode.
    var dir = _tmp(String("gate_floor"))
    var above = dir + "/above.tsv"
    var at = dir + "/at.tsv"
    var under = dir + "/under.tsv"
    write_text(above, String("src/alpha\t2501\t-\n"))
    write_text(at, String("src/alpha\t2500\t-\n"))
    write_text(under, String("src/alpha\t2499\t-\n"))
    for mode in [String("census"), String("neutral")]:
        var r = dir + "/" + mode + "_red"
        makedirs(r, exist_ok=True)
        assert_equal(run(_with(_without(_gate(r, mode), String("--ratchet")), String("--ratchet"), above)), EXIT_GATE, mode)
        var result = parse_json_value(read_text(r + "/result.json"))
        assert_equal(result.get(String("conclusion")).as_string(), "failure", mode)
        var summary = read_text(r + "/summary.md")
        assert_true(summary.find("**Regression**") >= 0 and summary.find("below its floor 25.01%") >= 0, summary)
        for floor in [at, under]:
            var g = dir + "/" + mode + "_green"
            makedirs(g, exist_ok=True)
            assert_equal(run(_with(_without(_gate(g, mode), String("--ratchet")), String("--ratchet"), floor)), EXIT_OK, mode + floor)
            assert_equal(parse_json_value(read_text(g + "/result.json")).get(String("conclusion")).as_string(), "neutral", mode + floor)


def _levels(dir: String, prefix: String) raises -> String:
    """The annotation levels of the paths under `prefix` in the full
    annotation list (`anns.json` of `dir`), each once, sorted."""
    var anns = parse_json_value(read_text(dir + "/anns.json"))
    var seen = List[String]()
    for i in range(anns.array_len()):
        var a = anns.element_at(i)
        if not a.get(String("path")).as_string().startswith(prefix):
            continue
        var l = a.get(String("annotation_level")).as_string()
        var has = False
        for k in range(len(seen)):
            if seen[k] == l:
                has = True
        if not has:
            seen.append(l)
    sort_strings(seen)
    var s = String("")
    for k in range(len(seen)):
        s += seen[k] + String(" ")
    return s^


def _package_kinds(result: JsonValue, key: String) raises -> String:
    """`<package>:<kind>` of each finding in `key` of a result JSON."""
    var fs = result.get(key)
    var s = String("")
    for i in range(fs.array_len()):
        var f = fs.element_at(i)
        s += f.get(String("package")).as_string() + String(":") + f.get(String("kind")).as_string() + String(" ")
    return s^


def test_info_package() raises:
    # A test-only package (`--info-package DIR`: DIR and every package under
    # it) is measured and shown, its findings information: they leave
    # `findings` (so the conclusion, the gate's exit and the annotation
    # level) for `info_findings`, and its annotations are notices.
    var base = _tmp(String("info_none"))
    assert_equal(run(_with(_with(_report(base), String("--mode"), String("enforce")), String("--annotations-out"), base + "/anns.json")), EXIT_OK)
    assert_true(_levels(base, String("src/alpha/")).find("failure") >= 0)
    var dir = _tmp(String("info_alpha"))
    var a = _with(_with(_report(dir), String("--mode"), String("enforce")), String("--annotations-out"), dir + "/anns.json")
    assert_equal(run(_with(a^, String("--info-package"), String("src/alpha/"))), EXIT_OK)
    var r = parse_json_value(read_text(dir + "/result.json"))
    # src/beta's BranchNotMeasured and src/gone's ExtraRow still count.
    assert_equal(r.get(String("conclusion")).as_string(), "failure")
    assert_equal(r.get(String("info_packages")).serialize(), String('["src/alpha"]'))
    var f = _package_kinds(r, String("findings"))
    var i = _package_kinds(r, String("info_findings"))
    assert_true(f.find("src/alpha:") < 0 and f.find("src/beta:BranchNotMeasured") >= 0, f)
    assert_true(i.find("src/alpha:BelowTarget") >= 0 and i.find("src/beta:") < 0, i)
    assert_equal(_levels(dir, String("src/alpha/")), "notice ")
    var summary = read_text(dir + "/summary.md")
    assert_true(summary.find("### Info: test-only packages, declaration-only files (") >= 0, summary)
    assert_true(summary.find(" | info: BelowTarget") >= 0, summary)
    assert_true(summary.find("except a test-only package (`src/alpha` and under)") >= 0, summary)
    # Every package under `src`: nothing fails, no annotation is a failure,
    # and the last body concludes success.
    var all = _tmp(String("info_all"))
    var b = _with(_with(_report(all), String("--mode"), String("enforce")), String("--annotations-out"), all + "/anns.json")
    assert_equal(run(_with(b^, String("--info-package"), String("src"))), EXIT_OK)
    var ra = parse_json_value(read_text(all + "/result.json"))
    assert_equal(ra.get(String("conclusion")).as_string(), "success")
    assert_equal(ra.get(String("findings")).array_len(), 0)
    assert_equal(_levels(all, String("src/")), "notice ")
    assert_equal(parse_json_value(read_text(all + "/checkrun/001.json")).get(String("conclusion")).as_string(), "success")
    assert_true(read_text(all + "/checkrun/000.json").find('"annotation_level":"failure"') < 0)
    # The gate: src/alpha below the target is exit 3 in enforce mode, and 0
    # as a test-only package; a prefix that is not a whole segment
    # (`src/alph`) covers nothing.
    var g = _tmp(String("info_gate"))
    assert_equal(run(_with(_gate(g, String("enforce")), String("--info-package"), String("src/alpha"))), EXIT_OK)
    var rg = parse_json_value(read_text(g + "/result.json"))
    assert_equal(rg.get(String("conclusion")).as_string(), "success")
    assert_true(_package_kinds(rg, String("info_findings")).find("src/alpha:BelowTarget") >= 0)
    assert_equal(run(_with(_gate(_tmp(String("info_gate_seg")), String("enforce")), String("--info-package"), String("src/alph"))), EXIT_GATE)
    assert_equal(run(_with(_gate(_tmp(String("info_gate_abs")), String("enforce")), String("--info-package"), String("/src/alpha"))), EXIT_USAGE)
    assert_equal(run(_with(_gate(_tmp(String("info_gate_slash")), String("enforce")), String("--info-package"), String("///"))), EXIT_USAGE)


def main() raises:
    test_report_end_to_end()
    test_gate_entry_is_the_report_entry()
    test_report_exit_never_carries_the_conclusion()
    test_annotation_cap_and_full_list()
    test_usage_errors_exit_2()
    test_input_errors_exit_1()
    test_gate_with_no_report()
    test_gate_test_sources()
    test_gate_floor_fails_in_every_mode()
    test_report_file_names()
    test_branch_lcov_flag()
    test_info_package()
    print("test_cli: PASS")
