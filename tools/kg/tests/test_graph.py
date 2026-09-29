#!/usr/bin/env python3
"""kg's two graphs: the docs graph (pure) and the Buck2 graph, against real git repositories
with a STUB buck2 (a script that prints a fixed `uquery --json` answer), so no buck2, daemon or
network is needed. Each refusal has a fixture that goes red: a stale docs graph, a planted
dead reference, a Buck2 graph rendered from other inputs, and one whose bytes differ from what
buck2 renders."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from kglib import KgError, docsgraph, graph, layer1  # noqa: E402
from kglib.gitio import MemTree  # noqa: E402
import test_git  # noqa: E402

TOML = b'''format = 2
generator = ["tools/kg", "docs/kg.toml"]
canonical = "docs/index.md"
docs_graph = "docs/kg/docs_graph.json"
[graph]
out = "docs/kg/buck_graph.json"
universe = ["//..."]
config = ["x.y=z"]
'''
BUCKCONFIG = b"[cells]\n  komira = .\n"
BUCK = b'mojo_library(name = "alpha", srcs = ["alpha/__init__.mojo"], test_srcs = ["alpha/t.mojo"])\n'
INDEX = b"# Index\n\n| Authority for | Doc |\n|---|---|\n| Alpha | [alpha.md](alpha.md) |\n"
ALPHA_DOC = b"# Alpha\n\nThe code is in `src/alpha/__init__.mojo`; see [the index](index.md).\n"
UQUERY = {
    "komira//src:alpha": {"buck.type": "mojo_library", "buck.deps": ["toolchains//:mojo"],
                          "srcs": ["komira//src/alpha/__init__.mojo"], "test_srcs": ["komira//src/alpha/t.mojo"]},
    "komira//src:use": {"buck.type": "mojo_test", "buck.deps": ["komira//src:alpha", "toolchains//:mojo"],
                        "srcs": ["komira//src/use.mojo"]},
}
# The stub answers like buck2 would in its cwd: a `.buckconfig.local` there adds the target a
# machine-local key would add, and a stray (untracked) source adds a target that globs it.
STUB = '''#!/usr/bin/env python3
import json, os, sys
if "kill" in sys.argv:
    sys.exit(0)
assert "uquery" in sys.argv and "--json" in sys.argv, sys.argv
ans = json.load(open(os.environ["KG_STUB_ANSWER"]))
if os.path.exists(".buckconfig.local"):
    ans["komira//platforms:local-only"] = {"buck.type": "platform"}
if os.path.exists("src/alpha/stray.mojo"):
    ans["komira//src:stray"] = {"buck.type": "mojo_library", "srcs": ["komira//src/alpha/stray.mojo"]}
with open(os.environ["KG_STUB_CWDS"], "a") as f:
    f.write(os.getcwd() + "\\n")
sys.stdout.write(json.dumps(ans))
'''


def cfg_of(toml=TOML):
    return layer1.load_config(toml)


class DocsGraph(unittest.TestCase):
    def tree(self, over=None):
        f = {"docs/kg.toml": TOML, "docs/index.md": INDEX, "docs/alpha.md": ALPHA_DOC,
             "src/alpha/__init__.mojo": b'"""Alpha."""\n', "README.md": b"# R\n```\n`src/nothing/here.mojo`\n```\n"}
        f.update(over or {})
        return MemTree({k: v for k, v in f.items() if v is not None})

    def test_live_refs_and_canonical_table(self):
        m, probs = docsgraph.derive(self.tree(), cfg_of())
        self.assertEqual(probs, [])
        d = m["docs"]["docs/alpha.md"]
        self.assertEqual(d["refs"], ["docs/index.md", "src/alpha/__init__.mojo"])
        self.assertEqual(d["canonical_for"], ["Alpha"])
        self.assertEqual(d["title"], "Alpha")
        self.assertNotIn("refs", m["docs"]["README.md"])       # a fenced block is not a reference

    def test_planted_dead_references_are_refused(self):
        _, probs = docsgraph.derive(self.tree({"docs/alpha.md": ALPHA_DOC + b"Also [gone](gone.md) and `src/alpha/nope.mojo`.\n"}),
                                    cfg_of())
        self.assertEqual(len(probs), 2, probs)
        self.assertTrue(all("dead reference" in p for p in probs), probs)

    def test_dead_canonical_row_is_refused(self):
        _, probs = docsgraph.derive(self.tree({"docs/alpha.md": None}), cfg_of())
        self.assertTrue(any("canonical row 'Alpha'" in p for p in probs), probs)

    def test_urls_labels_and_placeholders_are_not_paths(self):
        body = b"# X\n[w](https://example.com/a/b) `komira//src:alpha` `src/<id>.md` `docs/*.md` [a](#anchor)\n"
        _, probs = docsgraph.derive(self.tree({"docs/x.md": body}), cfg_of())
        self.assertEqual(probs, [])

    def test_render_is_deterministic(self):
        t = self.tree()
        self.assertEqual(docsgraph.render(docsgraph.derive(t, cfg_of())[0]),
                         docsgraph.render(docsgraph.derive(MemTree(dict(reversed(list(t.files.items())))), cfg_of())[0]))


class BuckGraph(unittest.TestCase):
    def tree(self, over=None):
        f = {"docs/kg.toml": TOML, ".buckconfig": BUCKCONFIG, "src/BUCK": BUCK, "src/alpha/__init__.mojo": b"x",
             "src/alpha/t.mojo": b"t", "docs/index.md": INDEX}
        f.update(over or {})
        return MemTree(f)

    def test_normalize_sorts_and_maps_source_labels_to_paths(self):
        cellmap = layer1.cells(self.tree())
        t = graph.normalize(dict(reversed(list(UQUERY.items()))), cellmap)
        self.assertEqual(list(t), sorted(UQUERY))
        self.assertEqual(t["komira//src:alpha"]["srcs"], ["src/alpha/__init__.mojo"])
        self.assertEqual(t["komira//src:alpha"]["test_srcs"], ["src/alpha/t.mojo"])

    def test_fingerprint_moves_with_build_inputs_and_package_paths_only(self):
        cfg, fp = cfg_of(), graph.fingerprint(self.tree(), cfg_of())
        self.assertEqual(fp, graph.fingerprint(self.tree({"src/alpha/__init__.mojo": b"edited"}), cfg))
        self.assertEqual(fp, graph.fingerprint(self.tree({"docs/new.md": b"# n\n"}), cfg))
        for over in ({"src/BUCK": BUCK + b"\n"}, {"src/alpha/new.mojo": b""}, {"rules/x.bzl": b""},
                     {".buckconfig": BUCKCONFIG + b"\n"}, {"tools/buck2": b"pin"}):
            self.assertNotEqual(fp, graph.fingerprint(self.tree(over), cfg), over)

    def test_queries(self):
        t = graph.normalize(UQUERY, layer1.cells(self.tree()))
        self.assertEqual(graph.deps(t, "alpha", reverse=True)[1], [("komira//src:use", 1)])
        start, welded, tests, gated = graph.tests(t, "src/alpha/__init__.mojo")
        self.assertEqual((welded, tests), ([("komira//src:alpha", "src/alpha/t.mojo")], ["komira//src:use"]))
        self.assertEqual(graph.owner(t, "src/use.mojo"), ["komira//src:use"])
        with self.assertRaises(KgError):
            graph.deps(t, "nope")


class Repo(test_git.Base):
    """The whole loop in a real repository: hooks, `kg graph` with a stub buck2, `kg check`."""

    def make(self):
        r = test_git.make(self.tmp, setup=False)
        stub = os.path.join(self.tmp, "buck2")
        with open(stub, "w") as f:
            f.write(STUB)
        os.chmod(stub, 0o755)
        self.answer = os.path.join(self.tmp, "answer.json")
        self.set_answer(UQUERY)
        self.cwds = os.path.join(self.tmp, "cwds")
        r.env.update(BUCK2=stub, KG_STUB_ANSWER=self.answer, KG_STUB_CWDS=self.cwds)
        r.write("docs/kg.toml", TOML)
        r.write(".buckconfig", BUCKCONFIG)
        r.write("src/BUCK", BUCK)
        r.write("src/alpha/t.mojo", "t\n")
        r.write("docs/index.md", INDEX)
        r.write("docs/alpha.md", ALPHA_DOC)
        r.git("add", "-A")
        r.git("commit", "-q", "--no-verify", "-m", "graph inputs")
        r.kg("setup")
        r.kg("build", "--all")
        r.kg("graph")
        r.git("commit", "-q", "-m", "kg: pages and graphs")
        return r

    def set_answer(self, ans):
        with open(self.answer, "w") as f:
            json.dump(ans, f)

    def test_fresh_after_setup(self):
        r = self.make()
        c = r.fresh("HEAD", "--graph")
        self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        self.assertIn("graph bytes re-derived by buck2", c.stdout)

    def test_stale_docs_graph_is_red(self):
        r = self.make()
        r.write("docs/beta.md", "# Beta\n")
        r.git("add", "docs/beta.md")
        r.git("commit", "-q", "--no-verify", "-m", "a doc, hooks bypassed")
        c = r.fresh()
        self.assertEqual(c.returncode, 1, c.stdout)
        self.assertIn("STALE pages: docs/kg/docs_graph.json", c.stdout)
        r.git("commit", "-q", "--allow-empty", "-m", "any hooked commit repairs it")
        self.assertFresh(r)

    def test_planted_dead_reference_is_refused_by_the_hook_and_red_in_check(self):
        r = self.make()
        r.write("docs/alpha.md", ALPHA_DOC + b"Planted: `src/alpha/missing.mojo`.\n")
        c = r.git("commit", "-q", "-am", "dead ref", ok=False)
        self.assertNotEqual(c.returncode, 0)
        self.assertIn("dead reference `src/alpha/missing.mojo`", c.stderr)
        r.kg("build", "--all", ok=False)
        r.git("commit", "-q", "--no-verify", "-am", "dead ref, hooks bypassed")
        c = r.fresh()
        self.assertEqual(c.returncode, 1, c.stdout)
        self.assertIn("DEAD REFERENCE: docs/alpha.md: dead reference `src/alpha/missing.mojo`", c.stdout)

    def test_buck_graph_from_other_inputs_warns_in_pre_commit_and_is_red_in_check(self):
        r = self.make()
        r.write("src/use.mojo", "u\n")
        r.write("src/BUCK", BUCK + b'mojo_test(name = "use", srcs = ["use.mojo"], deps = [":alpha"])\n')
        r.git("add", "src/use.mojo", "src/BUCK")
        c = r.git("commit", "-q", "-m", "a new target")
        self.assertIn("WARNING: the Buck2 graph is stale", c.stdout + c.stderr)
        c = r.fresh()
        self.assertEqual(c.returncode, 1, c.stdout)
        self.assertIn("STALE Buck2 graph", c.stdout)
        r.kg("graph")
        r.git("commit", "-q", "-m", "kg: graph")
        self.assertFresh(r)

    def test_buck_graph_bytes_that_buck2_does_not_render_are_red(self):
        r = self.make()
        ans = dict(UQUERY)
        ans["komira//src:alpha"] = dict(ans["komira//src:alpha"], **{"buck.deps": []})
        self.set_answer(ans)
        c = r.fresh("HEAD", "--graph")
        self.assertEqual(c.returncode, 1, c.stdout + c.stderr)
        self.assertIn("buck2 renders different bytes", c.stdout)

    def test_working_tree_state_never_reaches_the_graph(self):
        r = self.make()
        committed = r.git("show", "HEAD:docs/kg/buck_graph.json").stdout
        r.write(".buckconfig.local", "[komira_re]\n  mojo_compile_multi_numa_properties = a=b\n")
        r.write("src/alpha/stray.mojo", "s\n")
        r.kg("graph")
        self.assertEqual(r.git("diff", "--cached", "--name-only").stdout, "")
        with open(os.path.join(r.dir, "docs/kg/buck_graph.json")) as f:
            self.assertEqual(f.read(), committed)
        c = r.fresh("HEAD", "--graph")
        self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        with open(self.cwds) as f:
            cwds = f.read().split()
        self.assertTrue(cwds and all(os.path.realpath(d) != os.path.realpath(r.dir) for d in cwds), cwds)
        self.assertFalse([d for d in cwds if os.path.exists(d)], "scratch checkouts are removed")

    def test_check_graph_judges_the_named_commit_not_the_checkout(self):
        r = self.make()
        tip = r.head()
        r.write("src/BUCK", BUCK + b"\n")
        r.git("commit", "-q", "--no-verify", "-am", "a build edit, graph not refreshed")
        c = r.fresh(tip, "--graph")
        self.assertEqual(c.returncode, 0, c.stdout + c.stderr)

    def test_a_cell_outside_the_universe_is_refused(self):
        r = self.make()
        r.write(".buckconfig", BUCKCONFIG + b"  extra = extra\n")
        r.write("extra/BUCK", 'export_file(name = "x")\n')
        r.git("add", ".buckconfig", "extra/BUCK")
        r.git("commit", "-q", "-m", "a new cell")
        c = r.fresh()
        self.assertEqual(c.returncode, 1, c.stdout)
        self.assertIn("cell `extra` is in .buckconfig [cells] but neither in [graph] universe", c.stdout)
        c = r.kg("graph", ok=False)
        self.assertEqual(c.returncode, 2, c.stdout + c.stderr)
        self.assertIn("cell `extra`", c.stderr)
        r.write("docs/kg.toml", TOML.replace(b'universe = ["//..."]', b'universe = ["//..."]\nexclude = ["extra"]'))
        r.git("add", "docs/kg.toml")
        r.git("commit", "-q", "-m", "exclude it")
        r.kg("graph")
        r.git("commit", "-q", "-m", "kg: graph")
        self.assertFresh(r)

    def test_a_pathspec_commit_leaves_no_revert_for_the_next_unhooked_commit(self):
        r = self.make()
        r.write("docs/foo.md", "# Foo\n")
        r.git("add", "docs/foo.md")
        r.git("commit", "-q", "-m", "a doc, pathspec", "docs/foo.md")
        self.assertIn("docs/foo.md", r.git("show", "HEAD:docs/kg/docs_graph.json").stdout)
        self.assertEqual(r.git("diff", "--cached", "--name-only").stdout, "")
        self.assertEqual(r.git("status", "--porcelain").stdout, "")
        r.write("docs/alpha.md", ALPHA_DOC + b"More.\n")
        r.git("commit", "-q", "--no-verify", "-m", "no hook", "docs/alpha.md")
        self.assertIn("docs/foo.md", r.git("show", "HEAD:docs/kg/docs_graph.json").stdout)
        self.assertFresh(r)

    def test_an_empty_answer_is_refused_not_written(self):
        r = self.make()
        self.set_answer({})
        c = r.kg("graph", ok=False)
        self.assertIn("an empty graph is refused", c.stderr)

    def test_hooks_never_run_buck2(self):
        r = self.make()
        r.env["BUCK2"] = os.path.join(self.tmp, "no-such-buck2")
        r.write("docs/alpha.md", ALPHA_DOC + b"More.\n")
        r.git("commit", "-q", "-am", "a doc edit")
        self.assertFresh(r)


if __name__ == "__main__":
    if shutil.which("git") is None:
        print("kg graph selftest: no git on PATH")
        sys.exit(1)
    res = unittest.main(exit=False, verbosity=1).result
    print("kg graph selftest: %d tests, %d failures, %d errors" % (res.testsRun, len(res.failures), len(res.errors)))
    sys.exit(0 if res.testsRun > 0 and res.wasSuccessful() else 1)
