from std.testing import assert_equal, assert_true

from covcheck.diff import Diff, parse_diff

# The changed lines of `git diff --unified=0 -M`: every block shape git
# writes, keyed by the new path.


def _lines(d: Diff, i: Int) -> String:
    var s = String("")
    for k in range(len(d.files[i].lines)):
        if k > 0:
            s += String(",")
        s += String(d.files[i].lines[k])
    return s^


def _refused(text: String, want: String) raises:
    var raised = False
    try:
        _ = parse_diff(text)
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e) + String(" lacks ") + want)
    assert_true(raised, String("accepted: ") + text)


def test_modified_with_multiple_hunks() raises:
    var d = parse_diff(String(
        "diff --git a/src/a/x.mojo b/src/a/x.mojo\n"
        "index 1111111..2222222 100644\n"
        "--- a/src/a/x.mojo\n"
        "+++ b/src/a/x.mojo\n"
        "@@ -3 +3 @@ def f():\n"
        "-    old\n"
        "+    new\n"
        "@@ -10,2 +10,3 @@\n"
        "-a\n"
        "-b\n"
        "+a2\n"
        "+b2\n"
        "+c2\n"
    ))
    assert_equal(len(d.files), 1)
    assert_equal(d.files[0].path, "src/a/x.mojo")
    assert_equal(_lines(d, 0), "3,10,11,12")
    assert_equal(len(d.paths), 1)


def test_added_file() raises:
    var d = parse_diff(String(
        "diff --git a/src/a/new.mojo b/src/a/new.mojo\n"
        "new file mode 100644\n"
        "index 0000000..3333333\n"
        "--- /dev/null\n"
        "+++ b/src/a/new.mojo\n"
        "@@ -0,0 +1,3 @@\n"
        "+one\n"
        "+two\n"
        "+three\n"
    ))
    assert_equal(d.files[0].path, "src/a/new.mojo")
    assert_equal(_lines(d, 0), "1,2,3")


def test_deleted_file_adds_no_line_but_names_its_path() raises:
    var d = parse_diff(String(
        "diff --git a/src/a/old.mojo b/src/a/old.mojo\n"
        "deleted file mode 100644\n"
        "index 3333333..0000000\n"
        "--- a/src/a/old.mojo\n"
        "+++ /dev/null\n"
        "@@ -1,2 +0,0 @@\n"
        "-one\n"
        "-two\n"
    ))
    assert_equal(len(d.files), 0)
    assert_equal(len(d.paths), 1)
    assert_equal(d.paths[0], "src/a/old.mojo")


def test_pure_rename() raises:
    var d = parse_diff(String(
        "diff --git a/src/a/x.mojo b/src/b/x.mojo\n"
        "similarity index 100%\n"
        "rename from src/a/x.mojo\n"
        "rename to src/b/x.mojo\n"
    ))
    assert_equal(len(d.files), 0)
    assert_equal(len(d.paths), 2)
    assert_equal(d.paths[0], "src/a/x.mojo")
    assert_equal(d.paths[1], "src/b/x.mojo")


def test_rename_with_edits_goes_to_the_new_path() raises:
    var d = parse_diff(String(
        "diff --git a/src/a/x.mojo b/src/b/y.mojo\n"
        "similarity index 90%\n"
        "rename from src/a/x.mojo\n"
        "rename to src/b/y.mojo\n"
        "index 1111111..2222222 100644\n"
        "--- a/src/a/x.mojo\n"
        "+++ b/src/b/y.mojo\n"
        "@@ -4 +4 @@\n"
        "-x\n"
        "+y\n"
    ))
    assert_equal(d.files[0].path, "src/b/y.mojo")
    assert_equal(_lines(d, 0), "4")


def _paths(d: Diff) -> String:
    var s = String("")
    for i in range(len(d.paths)):
        if i > 0:
            s += String("|")
        s += d.paths[i]
    return s^


def test_binary_and_mode_only_add_nothing_but_name_their_paths() raises:
    # No lines, but each block's path touches its package: a binary file, a
    # mode change, an empty new file, a deleted empty file (none of them has
    # `---`/`+++` lines), and a quoted binary path with a space.
    var d = parse_diff(String(
        "diff --git a/img.png b/img.png\n"
        "index 1111111..2222222 100644\n"
        "Binary files a/img.png and b/img.png differ\n"
        "diff --git a/src/m/blob.bin b/src/m/blob.bin\n"
        "new file mode 100644\n"
        "index 0000000..1111111\n"
        "Binary files /dev/null and b/src/m/blob.bin differ\n"
        "diff --git a/run.sh b/run.sh\n"
        "old mode 100644\n"
        "new mode 100755\n"
        "diff --git a/src/e/empty.mojo b/src/e/empty.mojo\n"
        "new file mode 100644\n"
        "index 0000000..e69de29\n"
        "diff --git a/src/g/gone.txt b/src/g/gone.txt\n"
        "deleted file mode 100644\n"
        "index e69de29..0000000\n"
        "diff --git \"a/src/q/sp ace\\t.bin\" \"b/src/q/sp ace\\t.bin\"\n"
        "Binary files \"a/src/q/sp ace\\t.bin\" and \"b/src/q/sp ace\\t.bin\" differ\n"
    ))
    assert_equal(len(d.files), 0)
    assert_equal(_paths(d), "img.png|src/m/blob.bin|run.sh|src/e/empty.mojo|src/g/gone.txt|src/q/sp ace\t.bin")


def test_header_of_a_rename_with_spaces_names_nothing_itself() raises:
    # Two different unquoted names holding spaces cannot be split; the
    # rename lines name both.
    var d = parse_diff(String(
        "diff --git a/a b/x y b/c d/x y\n"
        "similarity index 100%\n"
        "rename from a b/x y\n"
        "rename to c d/x y\n"
    ))
    assert_equal(_paths(d), "a b/x y|c d/x y")


def test_carriage_return_in_a_hunk_body_is_content() raises:
    # A CRLF file's changed line ends in a carriage return: content, kept.
    var d = parse_diff(String(
        "diff --git a/src/m/x.request b/src/m/x.request\n"
        "--- a/src/m/x.request\n"
        "+++ b/src/m/x.request\n"
        "@@ -1 +1 @@\n"
        "-GET / HTTP/1.1\r\n"
        "+PUT / HTTP/1.1\r\n"
        "@@ -3,0 +4 @@\n"
        "+\r\n"
    ))
    assert_equal(d.files[0].path, "src/m/x.request")
    assert_equal(_lines(d, 0), "1,4")


def test_count_omitted_is_one_and_zero_is_none() raises:
    var d = parse_diff(String(
        "diff --git a/f b/f\n"
        "--- a/f\n"
        "+++ b/f\n"
        "@@ -7 +8 @@\n"
        "-a\n"
        "+b\n"
        "@@ -20,2 +20,0 @@\n"
        "-c\n"
        "-d\n"
    ))
    assert_equal(_lines(d, 0), "8")


def test_c_quoted_path() raises:
    # A space, an octal-escaped UTF-8 e-acute, an escaped quote and a backslash.
    var d = parse_diff(String(
        "diff --git \"a/sp\\303\\251cial \\\"x\\\"\\\\.mojo\" \"b/sp\\303\\251cial \\\"x\\\"\\\\.mojo\"\n"
        "--- \"a/sp\\303\\251cial \\\"x\\\"\\\\.mojo\"\n"
        "+++ \"b/sp\\303\\251cial \\\"x\\\"\\\\.mojo\"\n"
        "@@ -0,0 +1 @@\n"
        "+x\n"
    ))
    assert_equal(d.files[0].path, String("spécial \"x\"\\.mojo"))


def test_unquoted_path_with_tab_and_space() raises:
    var d = parse_diff(String(
        "diff --git a/a b.txt b/a b.txt\n"
        "--- a/a b.txt\t\n"
        "+++ b/a b.txt\t\n"
        "@@ -0,0 +1 @@\n"
        "+x\n"
    ))
    assert_equal(d.files[0].path, "a b.txt")


def test_removed_line_that_looks_like_a_header() raises:
    # A removed line `-- x` reads as `--- x` in the diff: the hunk's counts
    # decide, so it is a removed line, not a header.
    var d = parse_diff(String(
        "diff --git a/f b/f\n"
        "--- a/f\n"
        "+++ b/f\n"
        "@@ -1 +1 @@\n"
        "--- x\n"
        "++++ y\n"
    ))
    assert_equal(_lines(d, 0), "1")


def test_refusals() raises:
    _refused(String("hello\n"), String("diff:1: text before the first"))
    _refused(String("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1,2 @@\n+x\n"), String("the last hunk ends early"))
    _refused(String("diff --git a/f b/f\n--- f\n+++ f\n"), String("lacks the 'a/' prefix"))
    _refused(String("diff --git a/f b/f\n@@ -0,0 +1 @@\n+x\n"), String("adding lines to no file"))
    _refused(String("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -x +1 @@\n"), String("malformed hunk range"))
    _refused(String("diff --git a/f b/f\r\n"), String("diff:1: carriage return outside a hunk body"))
    _refused(String("diff --git a/f b/f\n--- a/f\n+++ b/f\r\n"), String("diff:3: carriage return outside a hunk body"))
    _refused(String("diff --git f f\nold mode 100644\nnew mode 100755\n"), String("diff:1: path 'f' lacks the 'a/' prefix"))
    _refused(String("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1000000001 @@\n"), String("above 10^9"))


def test_errors_name_the_diff_file() raises:
    var raised = False
    try:
        _ = parse_diff(String("hello\n"), String("pr.diff"))
    except e:
        raised = True
        assert_true(String(e).startswith("pr.diff:1: "), String(e))
    assert_true(raised)


def main() raises:
    test_modified_with_multiple_hunks()
    test_added_file()
    test_deleted_file_adds_no_line_but_names_its_path()
    test_pure_rename()
    test_rename_with_edits_goes_to_the_new_path()
    test_binary_and_mode_only_add_nothing_but_name_their_paths()
    test_header_of_a_rename_with_spaces_names_nothing_itself()
    test_carriage_return_in_a_hunk_body_is_content()
    test_count_omitted_is_one_and_zero_is_none()
    test_c_quoted_path()
    test_unquoted_path_with_tab_and_space()
    test_removed_line_that_looks_like_a_header()
    test_refusals()
    test_errors_name_the_diff_file()
    print("test_diff: PASS")
