# =============================================================================
# src/kci_workflow_check/tests/test_workflow_reader.mojo -- the fail-closed
#   workflow reader: what it reads (exactly), and every construct outside its
#   subset, which it answers "cannot tell" for instead of guessing.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_workflow_check import NODE_LIST, NODE_MAP, NODE_SCALAR, read_workflow


comptime _WF: String = (
    "# a comment\n"
    "name: kci\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "        default: \"\"\n"
    "permissions: {}\n"
    "env:\n"
    "  REVISION: ${{ inputs.revision || github.sha }}\n"
    "jobs:\n"
    "  build:\n"
    "    runs-on: [self-hosted, komira-farm]\n"
    "    environment: build # the stage\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          fetch-depth: 0\n"
    "      - name: kci\n"
    "        run: |\n"
    "          kci run --stage build \\\n"
    "            --run-id x\n"
    "\n"
    "          echo \"# not a comment\"\n"
    "  prod:\n"
    "    needs: [build]\n"
    "    environment:\n"
    "      name: prod\n"
    "    steps:\n"
    "    - run: kci run --stage prod\n"
)


def test_reads_the_subset() raises:
    var d = read_workflow(String(_WF))
    assert_equal(d.kind(0), NODE_MAP)
    assert_equal(d.text(d.child(0, String("name"))), String("kci"))
    var on = d.child(0, String("on"))
    assert_equal(len(d.keys(on)), 2)
    var branches = d.child(d.child(on, String("push")), String("branches"))
    assert_equal(d.kind(branches), NODE_LIST)
    assert_equal(d.scalar_or_list(branches)[0], String("main"))
    var rev = d.child(d.child(d.child(on, String("workflow_dispatch")), String("inputs")), String("revision"))
    assert_equal(d.text(d.child(rev, String("default"))), String(""))
    assert_equal(d.kind(d.child(0, String("permissions"))), NODE_MAP)
    assert_equal(
        d.text(d.child(d.child(0, String("env")), String("REVISION"))),
        String("${{ inputs.revision || github.sha }}"),
    )
    var jobs = d.child(0, String("jobs"))
    assert_equal(len(d.keys(jobs)), 2)
    var build = d.child(jobs, String("build"))
    var runs_on = d.scalar_or_list(d.child(build, String("runs-on")))
    assert_equal(runs_on[1], String("komira-farm"))
    assert_equal(d.text(d.child(build, String("environment"))), String("build"))
    var steps = d.items(d.child(build, String("steps")))
    assert_equal(len(steps), 2)
    assert_equal(
        d.text(d.child(steps[0], String("uses"))),
        String("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"),
    )
    assert_equal(d.text(d.child(d.child(steps[0], String("with")), String("fetch-depth"))), String("0"))
    # a literal block scalar, exactly: dedented, the blank line kept, one final newline
    assert_equal(
        d.text(d.child(steps[1], String("run"))),
        String("kci run --stage build \\\n  --run-id x\n\necho \"# not a comment\"\n"),
    )
    var prod = d.child(jobs, String("prod"))
    assert_equal(d.scalar_or_list(d.child(prod, String("needs")))[0], String("build"))
    assert_equal(d.text(d.child(d.child(prod, String("environment")), String("name"))), String("prod"))
    var psteps = d.items(d.child(prod, String("steps")))
    assert_equal(len(psteps), 1)
    assert_equal(d.text(d.child(psteps[0], String("run"))), String("kci run --stage prod"))
    assert_equal(d.kind(d.child(psteps[0], String("run"))), NODE_SCALAR)


def test_scalars_read_exactly() raises:
    var d = read_workflow(
        String(
            "a: x # c\n"
            "b: 'x # y'\n"
            "c: \"a: b\"\n"
            "d: x#y\n"
            "e: ''\n"
            "f: \"\"\n"
            "g:\n"
            "h: []\n"
            "i: [a, b/c, d.e] # c\n"
            "j: {} # c\n"
            "k: -1\n"
            "l: ${{ a == 'b' }}\n"
        )
    )
    assert_equal(d.text(d.child(0, String("a"))), String("x"))
    assert_equal(d.text(d.child(0, String("b"))), String("x # y"))
    assert_equal(d.text(d.child(0, String("c"))), String("a: b"))
    assert_equal(d.text(d.child(0, String("d"))), String("x#y"))
    assert_equal(d.text(d.child(0, String("e"))), String(""))
    assert_equal(d.text(d.child(0, String("f"))), String(""))
    assert_equal(d.text(d.child(0, String("g"))), String(""))
    assert_equal(len(d.items(d.child(0, String("h")))), 0)
    var i = d.scalar_or_list(d.child(0, String("i")))
    assert_equal(len(i), 3)
    assert_equal(i[1], String("b/c"))
    assert_equal(d.kind(d.child(0, String("j"))), NODE_MAP)
    assert_equal(d.text(d.child(0, String("k"))), String("-1"))
    assert_equal(d.text(d.child(0, String("l"))), String("${{ a == 'b' }}"))


def test_a_literal_block_is_read_exactly() raises:
    var d = read_workflow(
        String(
            "s:\n"
            "  - run: | # c\n"
            "\n"
            "      a\n"
            "        b\n"
            "      # c\n"
            "\n"
            "\n"
            "    name: n\n"
            "  - name: m\n"
            "    run: |\n"
            "      x\n"
            "# a comment ends it\n"
            "t: 1\n"
        )
    )
    var s = d.items(d.child(0, String("s")))
    assert_equal(len(s), 2)
    assert_equal(d.text(d.child(s[0], String("run"))), String("\na\n  b\n# c\n"))
    assert_equal(d.text(d.child(s[0], String("name"))), String("n"))
    assert_equal(d.text(d.child(s[1], String("run"))), String("x\n"))
    assert_equal(d.text(d.child(0, String("t"))), String("1"))


def test_plain_is_only_the_plain_form() raises:
    var d = read_workflow(String("a: write\nb: 'write'\nc: \"write\"\nf: [write]\nrun: |\n  write\n"))
    assert_true(d.is_plain(d.child(0, String("a")), String("write")))
    assert_false(d.is_plain(d.child(0, String("a")), String("read")))
    assert_false(d.is_plain(d.child(0, String("b")), String("write")))
    assert_false(d.is_plain(d.child(0, String("c")), String("write")))
    assert_false(d.is_plain(d.child(0, String("run")), String("write")))
    assert_false(d.is_plain(d.child(0, String("run")), String("write\n")))
    var f = d.items(d.child(0, String("f")))
    assert_true(d.is_plain(f[0], String("write")))
    assert_false(d.is_plain(d.child(0, String("f")), String("write")))
    assert_false(d.is_plain(-1, String("write")))


def test_block_is_only_the_block_form() raises:
    var d = read_workflow(String("a: write\nb: 'write'\nc: \"write\"\nrun: |\n  write\n"))
    assert_false(d.is_block(d.child(0, String("a"))))
    assert_false(d.is_block(d.child(0, String("b"))))
    assert_false(d.is_block(d.child(0, String("c"))))
    assert_true(d.is_block(d.child(0, String("run"))))
    assert_false(d.is_block(0))
    assert_false(d.is_block(-1))


def _cannot(text: String, needle: String) raises:
    try:
        _ = read_workflow(text)
    except e:
        var m = String(e)
        if not m.startswith(String("cannot tell: ")) or m.find(needle) < 0:
            raise Error(String("expected 'cannot tell: ...") + needle + String("', got: ") + m)
        return
    raise Error(String("read, expected cannot tell: ") + needle)


def test_cannot_tell() raises:
    _cannot(String("jobs:\n\tbuild: x\n"), String("line 2: a TAB"))
    _cannot(String("a: x\t\n"), String("a TAB"))
    _cannot(String("# a\tcomment\na: 1\n"), String("a TAB"))
    _cannot(String("a: 1\r\n"), String("a carriage return"))
    _cannot(String("a: ") + chr(1) + String("\n"), String("a control character"))
    _cannot(String("a: &x 1\n"), String("anchor"))
    _cannot(String("a: 1\nb: *x\n"), String("anchor, alias or tag"))
    _cannot(String("a: !!str 1\n"), String("anchor, alias or tag"))
    _cannot(String("l:\n  - &a x\n"), String("anchor, alias or tag"))
    _cannot(String("a: {b: c}\n"), String("flow mapping"))
    _cannot(String("a: {} x\n"), String("flow mapping"))
    _cannot(String("a: [b, [c]]\n"), String("flow list"))
    _cannot(String("a: ['b']\n"), String("flow list item"))
    _cannot(String("a: [b, ]\n"), String("an empty item"))
    _cannot(String("a: [b\n"), String("not closed"))
    _cannot(String("a: [b] c\n"), String("text after a flow list"))
    _cannot(String("---\na: 1\n"), String("document marker"))
    _cannot(String("a: 1\n---\nb: 2\n"), String("document marker"))
    _cannot(String("a: 1\n...\n"), String("document marker"))
    _cannot(String("%YAML 1.2\na: 1\n"), String("a directive"))
    _cannot(String("a: 1\na: 2\n"), String("key 'a' repeated"))
    _cannot(String("a: 1\nA: 2\n"), String("key 'A' repeated"))
    _cannot(String("a: 'b\n"), String("not closed"))
    _cannot(String("a:\n  b: 1\n    c: 2\n"), String("continues the value"))
    _cannot(String("a:\n  b:\n    c: 2\n   d: 1\n"), String("indented in a way"))
    _cannot(String("? a\n: b\n"), String("complex key"))
    _cannot(String("  a: 1\n"), String("first line is indented"))
    _cannot(String(""), String("empty"))
    _cannot(String("a b: 1\n"), String("not `key: value`"))
    _cannot(String("a : 1\n"), String("not `key: value`"))
    _cannot(String("a: b: c\n"), String("in a plain scalar"))
    _cannot(String("a: b:\n"), String("in a plain scalar"))
    _cannot(String("a: @b\n"), String("reserved indicator"))
    _cannot(String("a: `b\n"), String("reserved indicator"))
    _cannot(String("a: ,b\n"), String("flow indicator"))
    _cannot(String("a: - b\n"), String("an indicator"))
    _cannot(String("a: ? b\n"), String("an indicator"))
    _cannot(String("l:\n  - - a\n"), String("an indicator"))
    _cannot(String("l:\n  -  a\n"), String("one space after"))
    # quoted keys, escaped or not; merge keys in any form
    _cannot(String("\"a\\x62\": 1\n"), String("a quoted key"))
    _cannot(String("'a': 1\n"), String("a quoted key"))
    _cannot(String("l:\n  - \"a\": 1\n"), String("a quoted key"))
    _cannot(String("a:\n  b: 1\n  <<:\n    c: 2\n"), String("merge key"))
    _cannot(String("a:\n  b: 1\n  <<: *x\n"), String("merge key"))
    _cannot(String("l:\n  - <<:\n      c: 2\n"), String("merge key"))
    # a key the rules read, in another case
    _cannot(String("On:\n  push:\n"), String("key 'On' is the key 'on' in another case"))
    _cannot(String("j:\n  RUN: x\n"), String("in another case"))
    # bytes outside printable ASCII; a YAML 1.1 line break even in a comment
    _cannot(String("a: ") + chr(0xE9) + String("\n"), String("outside printable ASCII"))
    _cannot(String("# x") + chr(0x85) + String("a: 1\nb: 1\n"), String("a YAML 1.1 line break"))
    _cannot(String("# x") + chr(0x2028) + String("a: 1\nb: 1\n"), String("a YAML 1.1 line break"))
    _cannot(String("# x") + chr(0x2029) + String("a: 1\nb: 1\n"), String("a YAML 1.1 line break"))
    _cannot(chr(0xFEFF) + String("a: 1\n"), String("outside printable ASCII"))
    _cannot(String("# ") + chr(0xFEFF) + String("\na: 1\n"), String("byte order mark"))


def test_a_comment_may_hold_other_utf8() raises:
    var d = read_workflow(String("# ") + chr(0x26D4) + String(" dry run\na: 1\n"))
    assert_equal(d.text(d.child(0, String("a"))), String("1"))


def test_every_block_scalar_but_a_literal_run_is_cannot_tell() raises:
    for h in ["|-", "|+", ">", ">-", ">+", "|2", "|1-", ">2"]:
        _cannot(String("run: ") + String(h) + String("\n  x\n"), String("a block scalar other than a literal"))
    _cannot(String("a: |\n  x\n"), String("only a `run:` value may be a literal block scalar"))
    _cannot(String("l:\n  - |\n    x\n"), String("only a `run:` value"))
    _cannot(String("run: |\n"), String("an empty block scalar"))
    _cannot(String("run: |\na: 1\n"), String("an empty block scalar"))
    _cannot(String("j:\n  run: |\n      x\n     y\n"), String("indented less than its first line"))
    _cannot(String("run: |\n  x\n  \nb: 1\n"), String("a line of spaces only"))
    _cannot(String("run: |\n  ") + chr(0x85) + String("\n"), String("outside printable ASCII"))
    # a `#` line inside a block scalar is content, not a comment
    _cannot(String("run: |\n  # ") + chr(0x26D4) + String("\n"), String("line 2: a character outside printable ASCII"))


def test_a_quoted_scalar_has_no_escape_and_ends_on_its_line() raises:
    # `''` is an escaped quote: YAML would carry `'x''` on to the next line
    _cannot(String("a: 'x''\n"), String("an escaped quote"))
    _cannot(String("a: 'it''s'\n"), String("an escaped quote"))
    _cannot(String("a: ''''\n"), String("an escaped quote"))
    _cannot(String("a: 'x'' # c\n"), String("an escaped quote"))
    _cannot(String("l:\n  - 'x''\n"), String("an escaped quote"))
    _cannot(String("a: \"x\\\"y\"\n"), String("an escape (a backslash)"))
    _cannot(String("a: \"x\\\n  y\"\n"), String("an escape (a backslash)"))
    _cannot(String("a: \"x\n  y\"\n"), String("not closed on its line"))
    _cannot(String("a: 'x\n  y'\n"), String("not closed on its line"))
    _cannot(String("a: x\n  y\n"), String("continues the value"))
    _cannot(String("l:\n  - x\n    y\n"), String("continues the value"))


def test_text_after_a_quoted_scalar_close_is_cannot_tell() raises:
    _cannot(String("a: 'x' y\n"), String("text after a quoted scalar's close"))
    _cannot(String("a: 'x' 'y'\n"), String("text after a quoted scalar's close"))
    _cannot(String("a: \"x\" y\n"), String("text after a quoted scalar's close"))
    _cannot(String("a: \"x\"y\"\n"), String("text after a quoted scalar's close"))
    _cannot(String("a: 'x'#y\n"), String("text after a quoted scalar's close"))


def test_items_of_no_node_and_of_a_scalar_are_none() raises:
    var d = read_workflow(String("a: x\nb: [y]\n"))
    assert_equal(len(d.items(-1)), 0)
    assert_equal(len(d.items(d.child(0, String("a")))), 0)
    assert_equal(len(d.items(d.child(0, String("b")))), 1)


def test_a_bare_dash_is_an_empty_item() raises:
    # `-` alone (YAML's null item) reads as an empty scalar, as `key:` does
    var d = read_workflow(String("a:\n  -\n  - x\n"))
    var items = d.items(d.child(0, String("a")))
    assert_equal(len(items), 2)
    assert_equal(d.kind(items[0]), NODE_SCALAR)
    assert_equal(d.text(items[0]), String(""))
    assert_equal(d.text(items[1]), String("x"))


def test_a_list_at_its_keys_indentation_ends_at_the_next_key() raises:
    var d = read_workflow(String("a:\n- x\n- y\nb: 1\n"))
    assert_equal(d.scalar_or_list(d.child(0, String("a")))[1], String("y"))
    assert_equal(d.text(d.child(0, String("b"))), String("1"))
    assert_equal(len(d.keys(0)), 2)


def test_what_breaks_a_block_is_cannot_tell() raises:
    # a line between a list's dash column and its items' content column: no
    # open block holds it (the top-level list, where nothing encloses the
    # list to say so)
    _cannot(String("- a: 1\n b: 2\n"), String("line 2: a line indented in a way no open block holds"))
    # a list item inside a mapping
    _cannot(String("a:\n  b: 1\n  - c\n"), String("line 3: a list item where a mapping key was expected"))
    # the top level is a mapping: a list there, ended or not, is not one
    _cannot(String("- a\nb: 1\n"), String("line 2: a line outside the top-level mapping"))
    _cannot(String("- a\n"), String("line 1: the top level is not a mapping"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
