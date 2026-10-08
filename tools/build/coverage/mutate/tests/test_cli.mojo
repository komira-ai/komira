from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from mutate.cli import EXIT_INPUT, EXIT_OK, EXIT_USAGE, read_text, run, write_text
from mutate.sample import parse_list

# The command line end to end, through files: list a package, apply a
# mutant, and score statuses where one planted mutant survives (it is the
# one `survived` row and the one survivor of the summary) and the others are
# killed; every exit code.


def _dir(name: String) raises -> String:
    var d = getenv("TEST_TMPDIR") + "/" + name
    makedirs(d, exist_ok=True)
    return d


def _list(src: String, dest: String) -> List[String]:
    var a = List[String]()
    for s in ["list", "--src-dir"]:
        a.append(String(s))
    a.append(src)
    for s in ["--file", "a.mojo", "--file", "sub/b.mojo", "--sample", "0", "--seed", "s", "--out"]:
        a.append(String(s))
    a.append(dest)
    return a^


def _src(d: String) raises -> String:
    var src = _dir(d + "/src")
    _ = _dir(d + "/src/sub")
    write_text(src + "/a.mojo", "def f(x: Int) -> Bool:\n    return x < 3\n")
    write_text(src + "/sub/b.mojo", "# only a comment < 1\n")
    return src


def test_list_and_apply() raises:
    var d = _dir("la")
    var src = _src(d)
    assert_equal(run(_list(src, d + "/list.tsv")), EXIT_OK)
    var lf = parse_list(read_text(d + "/list.tsv"))
    assert_equal(lf.header, "# mutate list: 5 mutants, 5 sampled, seed s")
    var ids = String("")
    for r in lf.rows:
        ids += r.id + "\n"
    assert_equal(ids, "a.mojo:2:5:return_true\na.mojo:2:5:return_false\na.mojo:2:14:cmp_negate\na.mojo:2:16:const_inc\na.mojo:2:16:const_dec\n")
    var a = List[String]()
    for s in ["apply", "--src"]:
        a.append(String(s))
    a.append(src + "/a.mojo")
    for s in ["--path", "a.mojo", "--id", "a.mojo:2:14:cmp_negate", "--out"]:
        a.append(String(s))
    a.append(d + "/a.out")
    assert_equal(run(a), EXIT_OK)
    assert_equal(read_text(d + "/a.out"), "def f(x: Int) -> Bool:\n    return x >= 3\n")
    # the baseline writes the file unchanged
    var base = a.copy()
    base[6] = "baseline"
    assert_equal(run(base), EXIT_OK)
    assert_equal(read_text(d + "/a.out"), "def f(x: Int) -> Bool:\n    return x < 3\n")
    # an id the file does not have, and one naming another path
    var bad = a.copy()
    bad[6] = "a.mojo:2:15:cmp_negate"
    assert_equal(run(bad), EXIT_INPUT)
    var other = a.copy()
    other[4] = "sub/b.mojo"
    assert_equal(run(other), EXIT_INPUT)


def _status(d: String, name: String, text: String) raises -> String:
    var p = d + "/" + name
    write_text(p, text + "\nlog lines follow\n")
    return p


def _score_args(d: String, list: String, ids: List[String], surviving: String, drop_last: Bool, baseline_run: String = "ok") raises -> List[String]:
    var a = List[String]()
    a.append("score")
    a.append("--list")
    a.append(list)
    a.append("--label")
    a.append("//p:p")
    a.append("--src-repo")
    a.append("src/p/")
    a.append("--out-tsv")
    a.append(d + "/mutants.tsv")
    a.append("--out-md")
    a.append(d + "/summary.md")
    # The baseline first, as the build gives it; "" leaves it out.
    if baseline_run != "":
        a.append("--mutant")
        a.append("baseline")
        a.append("--precompile")
        a.append(_status(d, String("b.pre"), "ok"))
        a.append("--test")
        a.append("test_x")
        a.append("--build")
        a.append(_status(d, String("b.build"), "ok"))
        a.append("--run")
        a.append(_status(d, String("b.run"), baseline_run))
    var n = len(ids) - 1 if drop_last else len(ids)
    for i in range(n):
        a.append("--mutant")
        a.append(ids[i])
        a.append("--precompile")
        a.append(_status(d, String(i) + ".pre", "ok"))
        a.append("--test")
        a.append("test_x")
        a.append("--build")
        a.append(_status(d, String(i) + ".build", "ok"))
        a.append("--run")
        a.append(_status(d, String(i) + ".run", "ok" if ids[i] == surviving else "fail 1"))
    return a^


def test_score_planted_survivor() raises:
    var d = _dir("sc")
    var src = _src(d)
    var list = d + "/list.tsv"
    assert_equal(run(_list(src, list)), EXIT_OK)
    var lf = parse_list(read_text(list))
    var ids = List[String]()
    for r in lf.rows:
        ids.append(r.id)
    assert_equal(run(_score_args(d, list, ids, String("a.mojo:2:16:const_inc"), False)), EXIT_OK)
    var tsv = read_text(d + "/mutants.tsv")
    assert_equal(
        tsv,
        String("# mutation score: killed 4 of 5 (80.00%); survived 1, timeout 0, error 0\n")
        + "src/p/a.mojo\t2\tkilled\treturn_true\tcol 5: insert `return True`; test_x: failed (exit 1)\n"
        + "src/p/a.mojo\t2\tkilled\treturn_false\tcol 5: insert `return False`; test_x: failed (exit 1)\n"
        + "src/p/a.mojo\t2\tkilled\tcmp_negate\tcol 14: < -> >=; test_x: failed (exit 1)\n"
        + "src/p/a.mojo\t2\tsurvived\tconst_inc\tcol 16: 3 -> 4; every test passed\n"
        + "src/p/a.mojo\t2\tkilled\tconst_dec\tcol 16: 3 -> 2; test_x: failed (exit 1)\n",
    )
    var md = read_text(d + "/summary.md")
    var survivors = String(md[byte = md.find("## Survivors") : md.find("## Timeouts")])
    assert_equal(survivors, "## Survivors\n\n- `src/p/a.mojo:2:16` const_inc: 3 -> 4\n\n")


def test_score_refusals() raises:
    var d = _dir("rf")
    var src = _src(d)
    var list = d + "/list.tsv"
    assert_equal(run(_list(src, list)), EXIT_OK)
    var lf = parse_list(read_text(list))
    var ids = List[String]()
    for r in lf.rows:
        ids.append(r.id)
    # a mutant of the list not given
    assert_equal(run(_score_args(d, list, ids, String(""), True)), EXIT_INPUT)
    # a mutant given twice
    var twice = ids.copy()
    twice[1] = twice[0]
    assert_equal(run(_score_args(d, list, twice, String(""), False)), EXIT_INPUT)
    # no baseline; a baseline whose run failed (a broken harness: every test
    # fails, so every mutant would be killed) scores nothing
    assert_equal(run(_score_args(d, list, ids, String(""), False, String(""))), EXIT_INPUT)
    write_text(d + "/mutants.tsv", "stale")
    assert_equal(run(_score_args(d, list, ids, String(""), False, String("fail 2"))), EXIT_INPUT)
    assert_equal(read_text(d + "/mutants.tsv"), "stale")
    # usage: no command, an unknown command, an unknown flag, a missing value
    assert_equal(run(List[String]()), EXIT_USAGE)
    var unknown = List[String]()
    unknown.append("lint")
    assert_equal(run(unknown), EXIT_USAGE)
    var flag = _list(src, list)
    flag[1] = "--source-dir"
    assert_equal(run(flag), EXIT_USAGE)
    var short = List[String]()
    short.append("list")
    short.append("--out")
    assert_equal(run(short), EXIT_USAGE)


def main() raises:
    test_list_and_apply()
    test_score_planted_survivor()
    test_score_refusals()
    print("test_cli: PASS")
