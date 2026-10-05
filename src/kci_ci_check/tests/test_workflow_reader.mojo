# =============================================================================
# src/kci_ci_check/tests/test_workflow_reader.mojo -- the restricted
#   workflow reader: what it reads, and every construct it answers "cannot
#   tell" for instead of guessing.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_ci_check import NODE_LIST, NODE_MAP, NODE_SCALAR, read_workflow


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
    "    runs-on: [self-hosted, 'komira-farm']\n"
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
    var script = d.text(d.child(steps[1], String("run")))
    assert_true(script.find(String("kci run --stage build \\")) >= 0)
    assert_true(script.find(String("echo \"# not a comment\"")) >= 0)
    var prod = d.child(jobs, String("prod"))
    assert_equal(d.scalar_or_list(d.child(prod, String("needs")))[0], String("build"))
    assert_equal(d.text(d.child(d.child(prod, String("environment")), String("name"))), String("prod"))
    var psteps = d.items(d.child(prod, String("steps")))
    assert_equal(len(psteps), 1)
    assert_equal(d.text(d.child(psteps[0], String("run"))), String("kci run --stage prod"))
    assert_equal(d.kind(d.child(psteps[0], String("run"))), NODE_SCALAR)


def test_plain_is_only_the_plain_form() raises:
    var d = read_workflow(
        String("a: write\nb: 'write'\nc: \"write\"\nd: |-\n  write\ne: >\n  write\nf: [write, 'write']\n")
    )
    assert_true(d.is_plain(d.child(0, String("a")), String("write")))
    assert_false(d.is_plain(d.child(0, String("a")), String("read")))
    assert_false(d.is_plain(d.child(0, String("b")), String("write")))
    assert_false(d.is_plain(d.child(0, String("c")), String("write")))
    assert_false(d.is_plain(d.child(0, String("d")), String("write")))
    assert_false(d.is_plain(d.child(0, String("e")), String("write")))
    var f = d.items(d.child(0, String("f")))
    assert_true(d.is_plain(f[0], String("write")))
    assert_false(d.is_plain(f[1], String("write")))
    assert_false(d.is_plain(d.child(0, String("f")), String("write")))
    assert_false(d.is_plain(-1, String("write")))


def test_block_is_only_the_block_form() raises:
    var d = read_workflow(
        String("a: write\nb: 'write'\nc: \"write\"\nd: |-\n  write\ne: >\n  write\nf: |+\n  write\n")
    )
    assert_false(d.is_block(d.child(0, String("a"))))
    assert_false(d.is_block(d.child(0, String("b"))))
    assert_false(d.is_block(d.child(0, String("c"))))
    assert_true(d.is_block(d.child(0, String("d"))))
    assert_true(d.is_block(d.child(0, String("e"))))
    assert_true(d.is_block(d.child(0, String("f"))))
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
    _cannot(String("jobs:\n\tbuild: x\n"), String("TAB"))
    _cannot(String("a: &x 1\n"), String("anchor"))
    _cannot(String("a: 1\nb: *x\n"), String("anchor, alias or tag"))
    _cannot(String("a: !!str 1\n"), String("anchor, alias or tag"))
    _cannot(String("a: {b: c}\n"), String("flow mapping"))
    _cannot(String("a: [b, [c]]\n"), String("nested flow"))
    _cannot(String("a: 1\n---\nb: 2\n"), String("second document"))
    _cannot(String("a: 1\n...\n"), String("document end"))
    _cannot(String("a: 1\na: 2\n"), String("key 'a' repeated"))
    _cannot(String("a: 'b\n"), String("not closed"))
    _cannot(String("a:\n  b: 1\n    c: 2\n"), String("indented in a way"))
    _cannot(String("? a\n: b\n"), String("complex key"))
    _cannot(String("  a: 1\n"), String("first line is indented"))
    _cannot(String("a: |2\n  x\n"), String("block scalar header"))
    _cannot(String(""), String("empty"))
    # a double-quoted KEY decodes escapes as a value does: `"id\x2dtoken"` is `id-token`
    _cannot(String("\"a\\x62\": 1\n"), String("escape in a double-quoted key"))
    _cannot(String("l:\n  - \"a\\x62\": 1\n"), String("escape in a double-quoted key"))
    # a merge key `<<` in any form (block, flow, alias), and in a list item's mapping
    _cannot(String("a:\n  b: 1\n  <<:\n    c: 2\n"), String("merge key"))
    _cannot(String("l:\n  - <<:\n      c: 2\n"), String("merge key"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
