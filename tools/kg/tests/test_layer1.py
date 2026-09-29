#!/usr/bin/env python3
"""kg Layer 1, pure: the TOML and front-matter subsets, the build-file reader, headers, page and
map rendering, caps, shims and the tree diff -- over in-memory trees, no git, no network.
The `kg` workflow runs it on every pull request."""
import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from kglib import KgError, layer1, tomlsub, frontmatter  # noqa: E402
from kglib.gitio import MemTree, blob_id  # noqa: E402

CONFIG = b'''format = 2
generator = ["tools/kg", "docs/kg.toml"]
shims = ["CLAUDE.md", "AGENTS.md", "GEMINI.md"]
[libraries]
dirs = ["tools/x"]
'''

BUILD = b'''load("//rules:mojo.bzl", "mojo_library")
mojo_library(name = "alpha", srcs = glob(["alpha/**/*.mojo"]), package_dir = "src/alpha",
             test_srcs = ["alpha/t.mojo"])
mojo_library(name = "beta", srcs = [], package_dir = "src/beta/", test_srcs = [])
mojo_library(name = "eta", srcs = ["eta/__init__.mojo", "eta/g.mojo"])
mojo_library(name = "delta", srcs = glob(["delta/**/*.mojo"]))
mojo_library(name = "gen", srcs = [":gen_src"])
mojo_doc_json(name = "alpha_doc", package_dir = "src/alpha")
'''

ALPHA = b'''# a comment before the docstring is allowed
"""`alpha` reads things. It is the first library.

More prose that is not the summary.

Entry points: Reader (reader.mojo), Missing (reader.mojo), Ghost (nofile.mojo), Bare
Key files: reader.mojo, gone.mojo
"""
from .reader import Reader
'''


def files(over=None):
    f = {
        "docs/kg.toml": CONFIG,
        ".buckconfig": b"[cells]\n  komira = .\n  tools = tools\n",
        "src/BUCK": BUILD,
        "src/alpha/__init__.mojo": ALPHA,
        "src/alpha/reader.mojo": b"@value\nstruct Reader:\n    fn read(self): pass\n",
        "src/beta/__init__.mojo": b'"""Beta.\n"""\n',
        "src/eta/__init__.mojo": b'"""Eta does g."""\n',
        "src/delta/__init__.mojo": b'"""Delta."""\n',
        "src/delta/sub/__init__.mojo": b'"""Delta sub."""\n',
        "docs/design/storage/alpha.md": b"---\nstatus: current\ngoverns: [alpha, komira:other]\n---\n# A\n",
        "docs/design/storage/old.md": b"---\nstatus: superseded\ngoverns: [alpha, nosuchlib]\n---\n",
        "docs/record.md": b"# no front matter\n",
        "docs/bad.md": b"---\ngoverns:\n  - alpha\n---\n",
        "tools/x/README.md": b'---\nsummary: "X is a tool."\nkey_files: [x.py]\n---\n# x\n',
        "tools/x/x.py": b"def main(): pass\n",
    }
    for k, v in (over or {}).items():
        if v is None:
            f.pop(k, None)
        else:
            f[k] = v
    return f


def run(f):
    tree = MemTree(f)
    cfg = layer1.load_config(f["docs/kg.toml"])
    model = layer1.derive(tree, cfg)
    return tree, cfg, model, layer1.render(model, cfg)


class Toml(unittest.TestCase):
    def test_subset(self):
        d = tomlsub.loads('a = "x\\ty" # c\nb = [1, true,\n  \'lit\', # c\n]\n[t]\n"q k" = false\n')
        self.assertEqual(d, {"a": "x\ty", "b": [1, True, "lit"], "t": {"q k": False}})

    def test_refusals_name_the_line(self):
        for text, line in (('a = 1\na = 2\n', 2), ('a.b = 1\n', 1), ('a = {x = 1}\n', 1), ('a = """x"""\n', 1),
                           ('a = [[1]]\n', 1), ('\na = "x\n', 2), ('a = 1.5\n', 1), ('[t]\n[t]\n', 2), ('[[t]]\n', 1),
                           ('a = 1 b\n', 1)):
            with self.assertRaises(KgError) as e:
                tomlsub.loads(text)
            self.assertIn("docs/kg.toml:%d:" % line, str(e.exception), text)

    def test_config_refusals(self):
        with self.assertRaisesRegex(KgError, "format"):
            layer1.load_config(b'format = 1\ngenerator = ["g"]\n')
        with self.assertRaisesRegex(KgError, "unknown key"):
            layer1.load_config(b'format = 2\ngenerator = ["g"]\nextra = 1\n')
        with self.assertRaisesRegex(KgError, "generator"):
            layer1.load_config(b'format = 2\ngenerator = []\n')


class FrontMatter(unittest.TestCase):
    def test_parse(self):
        fm = frontmatter.parse(b'---\ntitle: "a: b" # c\ngoverns: [x, "y, z"]\nstatus: current\n---\nbody\n', "d.md")
        self.assertEqual(fm, {"title": "a: b", "governs": ["x", "y, z"], "status": "current"})
        self.assertIsNone(frontmatter.parse(b"# no\n", "d.md"))

    def test_refusals(self):
        for body in (b"---\ngoverns:\n  - x\n---\n", b"---\na: 1\n", b"---\na: 1\na: 2\n---\n",
                     b"---\na: [x, [y]]\n---\n", b"---\na: [x\n---\n", b'---\na: "x\n---\n'):
            with self.assertRaises(KgError, msg=body):
                frontmatter.parse(body, "d.md")


class Pages(unittest.TestCase):
    def test_libraries_and_labels(self):
        tree, cfg, model, pages = run(files())
        self.assertEqual(sorted(model.libs), ["alpha", "beta", "delta", "eta", "x"])
        a = pages["docs/libraries/alpha.md"].decode()
        self.assertTrue(a.startswith(layer1.GENERATED + "\n# alpha\n`alpha` reads things. It is the first library.\n"))
        self.assertIn("- Buck2: `komira//src:alpha` · welded tests: its `test_srcs` run when it is built (`kg tests komira//src:alpha`)", a)
        self.assertIn("- Buck2: `komira//src:beta` · no welded tests", pages["docs/libraries/beta.md"].decode())
        self.assertIn("- Dir: `src/eta/`", pages["docs/libraries/eta.md"].decode())
        self.assertIn("- Dir: `src/delta/`", pages["docs/libraries/delta.md"].decode())
        self.assertTrue(any("1 library rule(s)" in n for n in model.notes), model.notes)

    def test_declared_names_resolve_or_say_so(self):
        a = run(files())[3]["docs/libraries/alpha.md"].decode()
        self.assertIn("- Entry points: `Reader` (reader.mojo) · `Missing` (reader.mojo) (unresolved) · "
                      "`Ghost` (nofile.mojo) (unresolved) · `Bare` (unresolved)", a)
        self.assertIn("- Key files: reader.mojo, gone.mojo (missing)", a)

    def test_governing_docs(self):
        tree, cfg, model, pages = run(files())
        a = pages["docs/libraries/alpha.md"].decode()
        self.assertIn("- Designs: [alpha](../design/storage/alpha.md) (current) · "
                      "[old](../design/storage/old.md) (superseded)", a)
        self.assertTrue(any("1 `governs:` entry" in n for n in model.notes), model.notes)
        self.assertEqual([p for _, p, _ in model.problems], ["docs/bad.md"])

    def test_directory_library(self):
        x = run(files())[3]["docs/libraries/x.md"].decode()
        self.assertIn("X is a tool.\n- Buck2: no package\n- Dir: `tools/x/`\n- Key files: x.py\n", x)
        x = run(files({"tools/x/BUCK": b""}))[3]["docs/libraries/x.md"].decode()
        self.assertIn("- Buck2: `tools//x`", x)

    def test_map(self):
        m = run(files())[3]["docs/libraries/README.md"].decode().splitlines()
        self.assertEqual(m[0], layer1.GENERATED)
        self.assertIn("- [alpha](alpha.md) — `alpha` reads things. · alpha", m)
        long = ("é" * 300).encode()
        m = run(files({"src/beta/__init__.mojo": b'"""' + long + b'"""'}))[3]["docs/libraries/README.md"]
        for line in m.decode().splitlines():
            self.assertLessEqual(len(line.encode()), layer1.MAP_LINE_CAP, line)

    def test_deterministic_and_order_free(self):
        f = files()
        p1 = run(f)[3]
        p2 = run(dict(reversed(list(f.items()))))[3]
        self.assertEqual(p1, p2)

    def test_collisions_refused_then_qualified(self):
        f = files({"src/other/BUCK": b'mojo_library(name = "a2", package_dir = "src/other/alpha")\n'})
        with self.assertRaisesRegex(KgError, r"'alpha' is claimed by 2 directories .*\[ids\]"):
            run(f)
        f["docs/kg.toml"] = CONFIG + b'[ids]\n"src/other/alpha" = "other_alpha"\n'
        self.assertIn("other_alpha", run(f)[2].libs)
        f = files({"src/two/BUCK": b'mojo_library(name = "a3", package_dir = "src/alpha")\n'})
        with self.assertRaisesRegex(KgError, "already the library komira//src:alpha"):
            run(f)

    def test_unreadable_build_is_refused(self):
        with self.assertRaisesRegex(KgError, r"src/bad/BUCK:1: kg cannot read"):
            run(files({"src/bad/BUCK": b"mojo_library(name = \n"}))

    def test_caps(self):
        f = files({"src/beta/__init__.mojo": ('"""' + "w " * 250 + '\n\nEntry points: ' +
                                                ", ".join("E%d" % i for i in range(14)) + '\n"""').encode()})
        tree, cfg, model, pages = run(f)
        b = pages["docs/libraries/beta.md"].decode().splitlines()[2]
        self.assertEqual(len(b), layer1.SUMMARY_CAP)
        self.assertTrue(b.endswith("…"))
        msgs = [m for lib, p, m in model.problems if lib == "beta"]
        self.assertEqual(len(msgs), 2, msgs)
        self.assertEqual(pages["docs/libraries/beta.md"].decode().count("(unresolved)"), layer1.NAMES_CAP)
        many = {"docs/d%02d_%s.md" % (i, "x" * 40): b"---\ngoverns: [eta]\n---\n" for i in range(40)}
        f = files()
        f.update(many)
        model = run(f)[2]
        self.assertTrue(any(lib == "eta" and "page is" in m for lib, p, m in model.problems))

    def test_blob_id_is_gits(self):
        self.assertEqual(blob_id(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a")

    def test_diff(self):
        f = files()
        tree, cfg, model, pages = run(f)
        f.update(pages)
        f["docs/libraries/stray.md"] = b"x"
        f["docs/libraries/alpha.md"] = b"edited by hand"
        t2 = MemTree(f)
        changed, removed = layer1.diff(t2, pages, cfg)
        self.assertEqual((changed, removed), (["docs/libraries/alpha.md"], ["docs/libraries/stray.md"]))
        t2.unmerged.add("docs/libraries/beta.md")
        t2.unmerged.add("docs/libraries/gone.md")
        changed, removed = layer1.diff(t2, pages, cfg)
        self.assertIn("docs/libraries/beta.md", changed)
        self.assertIn("docs/libraries/gone.md", removed)


class Shims(unittest.TestCase):
    BODY = b"Map: docs/libraries/README.md. `python3 tools/kg/kg.py check`, `python3 tools/kg/kg.py ask`.\n"

    def probs(self, **over):
        f = files({"CLAUDE.md": b"@DEVELOPMENT.md\n" + self.BODY, "AGENTS.md": b"Read DEVELOPMENT.md first\n" + self.BODY,
                   "GEMINI.md": b"Read DEVELOPMENT.md first\n" + self.BODY})
        f.update({k.replace("_DOT_", "."): v for k, v in over.items()})
        f = {k: v for k, v in f.items() if v is not None}
        return layer1.check_shims(MemTree(f), layer1.load_config(f["docs/kg.toml"]))

    def test_agree(self):
        self.assertEqual(self.probs(), [])

    def test_refusals(self):
        self.assertTrue(any("differ after line 1" in p for p in self.probs(GEMINI_DOT_md=b"x\nother\n")))
        self.assertTrue(any("bytes (cap 600)" in p for p in self.probs(AGENTS_DOT_md=b"x\n" + b"y" * 700)))
        self.assertTrue(any("not a kg verb" in p for p in self.probs(
            CLAUDE_DOT_md=b"@DEVELOPMENT.md\n" + self.BODY + b"python3 tools/kg/kg.py frobnicate\n")))
        self.assertTrue(any("GEMINI.md is missing" in p for p in self.probs(GEMINI_DOT_md=None)))


if __name__ == "__main__":
    r = unittest.main(exit=False, verbosity=1).result
    n = r.testsRun
    print("kg layer1 selftest: %d tests, %d failures, %d errors" % (n, len(r.failures), len(r.errors)))
    sys.exit(0 if n > 0 and r.wasSuccessful() else 1)
