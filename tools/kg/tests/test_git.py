#!/usr/bin/env python3
"""kg's hooks and verbs against REAL git repositories in a temporary directory: one failing
fixture per hook rule. Each repository gets a copy of tools/kg and the real .githooks
wrappers, and `kg setup` enables them. Needs git >= 2.25 and `python3` on PATH (the hooks
exec it). The `kg` workflow runs it on every pull request."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
KG_SRC = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(KG_SRC))
HOOKS = ("pre-commit", "pre-push")

TOML = b'format = 2\ngenerator = ["tools/kg", "docs/kg.toml"]\n'


def _git_version():
    m = re.search(r"(\d+)\.(\d+)", subprocess.run(["git", "--version"], capture_output=True, text=True).stdout)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


GIT = _git_version()
BUILD = (b'mojo_library(name = "alpha", srcs = ["alpha/__init__.mojo"], test_srcs = ["alpha/t.mojo"])\n'
         b'mojo_library(name = "beta", srcs = ["beta/__init__.mojo"])\n')


class Repo:
    def __init__(self, base, name="work"):
        self.dir = os.path.join(base, name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(HOME=os.path.join(base, "home"), XDG_CACHE_HOME=os.path.join(base, "cache"),
                        GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="kg test", GIT_AUTHOR_EMAIL="kg@example.invalid",
                        GIT_COMMITTER_NAME="kg test", GIT_COMMITTER_EMAIL="kg@example.invalid",
                        PYTHONDONTWRITEBYTECODE="1")
        os.makedirs(self.env["HOME"], exist_ok=True)

    def run(self, *args, ok=True, inp=None, env=None):
        e = dict(self.env)
        e.update(env or {})
        r = subprocess.run(list(args), cwd=self.dir, capture_output=True, text=True, input=inp, env=e)
        if ok and r.returncode != 0:
            raise AssertionError("%s -> %d\n%s%s" % (" ".join(args), r.returncode, r.stdout, r.stderr))
        return r

    def git(self, *a, **kw):
        return self.run("git", *a, **kw)

    def kg(self, *a, **kw):
        return self.run(sys.executable, "-B", "tools/kg/kg.py", *a, **kw)

    def write(self, path, data):
        full = os.path.join(self.dir, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())

    def head(self):
        return self.git("rev-parse", "HEAD").stdout.strip()

    def fresh(self, commit="HEAD", *extra):
        return self.kg("check", "--commit", commit, *extra, ok=False)

    def remote(self):
        bare = os.path.join(os.path.dirname(self.dir), "remote.git")
        subprocess.run(["git", "init", "-q", "--bare", bare], check=True, env=self.env)
        self.git("remote", "add", "origin", bare)


def make(base, name="work", setup=True):
    r = Repo(base, name)
    os.makedirs(r.dir)
    r.git("init", "-q")
    r.git("symbolic-ref", "HEAD", "refs/heads/main")      # `init -b` needs git 2.28; kg's floor is 2.25
    shutil.copytree(KG_SRC, os.path.join(r.dir, "tools", "kg"),
                    ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc"))
    os.makedirs(os.path.join(r.dir, ".githooks"))
    for h in HOOKS:
        dst = os.path.join(r.dir, ".githooks", h)
        shutil.copyfile(os.path.join(ROOT, ".githooks", h), dst)
        os.chmod(dst, 0o755)
    r.write("docs/kg.toml", TOML)
    r.write(".gitattributes", "docs/libraries/*.md merge=binary linguist-generated=true\n")
    r.write("src/BUCK", BUILD)
    r.write("src/alpha/__init__.mojo", '"""Alpha, version one."""\n')
    r.write("src/beta/__init__.mojo", '"""Beta."""\n')
    r.write("docs/design/storage/alpha.md", "---\nstatus: current\ngoverns: [alpha]\n---\n# alpha\n")
    r.git("add", "-A")
    r.git("commit", "-q", "-m", "initial, no pages")
    if setup:
        r.kg("setup")
        r.kg("build", "--all")
        r.git("commit", "-q", "-m", "kg: pages")
    return r


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="kgtest")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def assertFresh(self, r, commit="HEAD"):
        c = r.fresh(commit)
        self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        self.assertIn("FRESH", c.stdout)

    def assertStale(self, r, commit="HEAD"):
        c = r.fresh(commit)
        self.assertEqual(c.returncode, 1, c.stdout + c.stderr)
        self.assertIn("STALE pages", c.stdout)
        return c.stdout


class Setup(Base):
    def test_setup_enables_hooks_and_self_checks(self):
        r = make(self.tmp)
        self.assertEqual(r.git("config", "--get", "core.hooksPath").stdout.strip(), ".githooks")
        s = r.kg("status")
        self.assertIn("core.hooksPath=.githooks; dry pre-commit", s.stdout)
        self.assertFresh(r)

    def test_setup_refuses_a_foreign_hooks_path(self):
        r = make(self.tmp, setup=False)
        r.git("config", "core.hooksPath", "/elsewhere/hooks")
        s = r.kg("setup", ok=False)
        self.assertEqual(s.returncode, 1)
        self.assertIn("already '/elsewhere/hooks'", s.stderr)
        self.assertEqual(r.git("config", "--get", "core.hooksPath").stdout.strip(), "/elsewhere/hooks")

    def test_setup_refuses_an_unconfigured_tree(self):
        r = make(self.tmp, setup=False)
        r.git("rm", "-q", "docs/kg.toml")
        s = r.kg("setup", ok=False)
        self.assertEqual(s.returncode, 1)
        self.assertIn("no docs/kg.toml", s.stderr)
        self.assertEqual(r.git("config", "--get", "core.hooksPath", ok=False).stdout.strip(), "")

    def test_status_fails_without_hooks(self):
        r = make(self.tmp, setup=False)
        s = r.kg("status", ok=False)
        self.assertEqual(s.returncode, 1)
        self.assertIn("run `python3 tools/kg/kg.py setup`", s.stdout)


class PreCommit(Base):
    def test_every_commit_form_is_fresh(self):
        r = make(self.tmp)
        r.write("src/alpha/__init__.mojo", '"""Alpha, version two."""\n')
        r.git("add", "src/alpha/__init__.mojo")
        r.git("commit", "-q", "-m", "plain")
        self.assertIn(b"Alpha, version two.", r.git("show", "HEAD:docs/libraries/alpha.md").stdout.encode())
        self.assertFresh(r)
        r.write("src/alpha/__init__.mojo", '"""Alpha, version three."""\n')
        r.git("commit", "-q", "-m", "pathspec", "src/alpha/__init__.mojo")
        self.assertFresh(r)
        # The pathspec form commits from a temporary index; the hook's output must reach the
        # real index too, or it holds a staged revert of that output.
        self.assertEqual(r.git("diff", "--cached", "--name-only").stdout, "")
        self.assertEqual(r.git("status", "--porcelain").stdout, "")
        r.write("src/beta/__init__.mojo", '"""Beta, two."""\n')
        r.git("commit", "-q", "-a", "-m", "all")
        self.assertFresh(r)
        r.write("src/beta/__init__.mojo", '"""Beta, three."""\n')
        r.git("add", "src/beta/__init__.mojo")
        r.git("commit", "-q", "--amend", "--no-edit")
        self.assertFresh(r)

    def test_a_removed_library_loses_its_page(self):
        r = make(self.tmp)
        r.write("src/BUCK", BUILD.splitlines(True)[0])
        r.git("commit", "-q", "-a", "-m", "drop beta")
        self.assertNotIn("docs/libraries/beta.md", r.git("ls-files", "docs/libraries").stdout)
        self.assertFresh(r)

    def test_generator_changes_outside_the_commit_are_refused(self):
        r = make(self.tmp)
        before = r.head()
        with open(os.path.join(r.dir, "tools/kg/kglib/layer1.py"), "a") as f:
            f.write("# an unstaged generator edit\n")
        r.write("src/beta/__init__.mojo", '"""Beta, two."""\n')
        r.git("add", "src/beta/__init__.mojo")
        c = r.git("commit", "-q", "-m", "x", ok=False)
        self.assertNotEqual(c.returncode, 0)
        self.assertIn("the generator has changes that are not in this commit (tools/kg/kglib/layer1.py)", c.stderr)
        self.assertEqual(r.head(), before)
        r.git("add", "tools/kg/kglib/layer1.py")
        r.git("commit", "-q", "-m", "with the generator")
        self.assertFresh(r)
        r.write("tools/kg/kglib/extra.py", "# untracked\n")
        c = r.git("commit", "-q", "--allow-empty", "-m", "y", ok=False)
        self.assertIn("tools/kg/kglib/extra.py", c.stderr)

    def test_no_verify_is_stale_and_the_next_commit_repairs_it(self):
        r = make(self.tmp)
        r.write("src/alpha/__init__.mojo", '"""Alpha, bypassed."""\n')
        r.git("commit", "-q", "-a", "--no-verify", "-m", "bypass")
        out = self.assertStale(r)
        self.assertIn("docs/libraries/alpha.md", out)
        self.assertIn('build --all && git commit -m "kg: refresh pages" -- docs/libraries', out)
        r.write("src/beta/__init__.mojo", '"""Beta, later."""\n')
        r.git("commit", "-q", "-a", "-m", "later")
        self.assertFresh(r)

    def test_the_one_fix_without_hooks(self):
        r = make(self.tmp)
        r.write("src/BUCK", BUILD.splitlines(True)[0])
        r.write("src/alpha/__init__.mojo", '"""Alpha, hookless."""\n')
        r.git("commit", "-q", "-a", "--no-verify", "-m", "stale")
        self.assertStale(r)
        r.git("config", "core.hooksPath", "/dev/null")
        r.kg("build", "--all")
        r.git("commit", "-q", "-m", "kg: refresh pages", "--", "docs/libraries")
        self.assertFresh(r)
        self.assertNotIn("beta.md", r.git("ls-files", "docs/libraries").stdout)


class PrePush(Base):
    def test_push_rules(self):
        r = make(self.tmp)
        r.remote()
        p = r.git("push", "-q", "origin", "main")
        self.assertIn("refs/heads/main: kg check", p.stdout + p.stderr)
        r.write("src/alpha/__init__.mojo", '"""Alpha, stale push."""\n')
        r.git("commit", "-q", "-a", "--no-verify", "-m", "stale")
        p = r.git("push", "-q", "origin", "main", ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("STALE pages: docs/libraries/README.md, docs/libraries/alpha.md", p.stdout + p.stderr)
        r.git("tag", "t1")
        p = r.git("push", "-q", "origin", "t1")
        self.assertIn("refs/tags/t1 skipped (not a branch)", p.stdout + p.stderr)
        r.write("src/beta/__init__.mojo", '"""Beta, fixed."""\n')
        r.git("commit", "-q", "-a", "-m", "fix")
        r.git("push", "-q", "origin", "main")
        p = r.git("push", "-q", "origin", "main:other")
        self.assertIn("refs/heads/other skipped (already on a remote-tracking ref)", p.stdout + p.stderr)
        p = r.git("push", "-q", "origin", ":other")
        self.assertIn("refs/heads/other skipped (a delete)", p.stdout + p.stderr)

    def test_a_tip_without_kg_toml_is_skipped_not_refused(self):
        # A branch cut before kg was configured: kg cannot judge its tree, so refusing it would
        # block that push forever.
        r = make(self.tmp)
        r.remote()
        r.git("push", "-q", "origin", "main")
        r.git("checkout", "-q", "-b", "prekg")
        r.git("rm", "-q", "docs/kg.toml")
        r.git("commit", "-q", "-m", "a tree kg does not configure")
        p = r.git("push", "-q", "origin", "prekg", ok=False)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("refs/heads/prekg skipped (no docs/kg.toml at that tip)", p.stdout + p.stderr)

    def test_a_problem_in_the_pushed_change_is_refused(self):
        # Pushing onto an existing remote tip judges the change since that tip (base = the
        # remote's sha): a size-cap problem it introduces is refused, not merely counted.
        r = make(self.tmp)
        r.remote()
        r.git("push", "-q", "origin", "main")
        r.write("src/alpha/__init__.mojo", '"""' + "long " * 100 + '"""\n')
        r.git("commit", "-q", "-a", "-m", "a long summary")
        self.assertFresh(r)                       # the pages are fresh; only the cap is broken
        p = r.git("push", "-q", "origin", "main", ok=False)
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("PROBLEM in this change: src/alpha/__init__.mojo: summary is 499 characters (cap 400)",
                      p.stdout + p.stderr)


class Merges(Base):
    # git 2.25 rebases with the apply (am) backend by default; 2.26 switched to merge. Both are
    # driven explicitly on every git, and the state directory proves which one ran.
    def test_a_rebase_stopped_on_a_page_is_fixed_by_kg_fix__merge_backend(self):
        self._rebase_stopped_on_a_page(["-m"], "rebase-merge")

    def test_a_rebase_stopped_on_a_page_is_fixed_by_kg_fix__apply_backend(self):
        self._rebase_stopped_on_a_page(["--apply"] if GIT >= (2, 26) else [], "rebase-apply")

    def _rebase_stopped_on_a_page(self, flags, state):
        r = make(self.tmp)
        r.git("checkout", "-q", "-b", "side")
        r.write("src/alpha/__init__.mojo", '"""Alpha, from the side branch."""\n')
        r.git("commit", "-q", "-a", "-m", "side header")
        r.git("checkout", "-q", "main")
        r.write("docs/design/storage/alpha.md", "---\nstatus: superseded\ngoverns: [alpha]\n---\n# alpha\n")
        r.git("commit", "-q", "-a", "-m", "main doc status")
        r.git("checkout", "-q", "side")
        reb = r.git("rebase", *flags, "main", ok=False)
        self.assertNotEqual(reb.returncode, 0, "the page must conflict, not compose")
        self.assertTrue(os.path.isdir(os.path.join(r.dir, ".git", state)), "git %d.%d did not stop in %s: %s"
                        % (GIT + (state, reb.stdout + reb.stderr)))
        self.assertIn("docs/libraries/alpha.md", r.git("diff", "--name-only", "--diff-filter=U").stdout)
        f = r.kg("fix")
        self.assertIn("kg fix: 1 page(s) rebuilt", f.stdout)
        r.git("-c", "core.editor=true", "rebase", "--continue")
        self.assertFresh(r)
        page = r.git("show", "HEAD:docs/libraries/alpha.md").stdout
        self.assertIn("from the side branch", page)
        self.assertIn("(superseded)", page)

    def test_fix_refuses_while_a_source_is_unmerged(self):
        r = make(self.tmp)
        r.git("checkout", "-q", "-b", "side")
        r.write("src/alpha/__init__.mojo", '"""Alpha, side."""\n')
        r.git("commit", "-q", "-a", "-m", "side")
        r.git("checkout", "-q", "main")
        r.write("src/alpha/__init__.mojo", '"""Alpha, main."""\n')
        r.git("commit", "-q", "-a", "-m", "main")
        self.assertNotEqual(r.git("merge", "-q", "side", ok=False).returncode, 0)
        f = r.kg("fix", ok=False)
        self.assertEqual(f.returncode, 1)
        self.assertIn("resolve these first, then run kg fix again: src/alpha/__init__.mojo", f.stderr)


class Check(Base):
    def test_the_commit_is_judged_by_its_own_generator(self):
        r = make(self.tmp)
        lp = os.path.join(r.dir, "tools/kg/kglib/layer1.py")
        with open(lp) as f:
            src = f.read()
        with open(lp, "w") as f:
            f.write(src.replace("(page format %d). Do not edit.", "(page format %d). EDITED GENERATOR."))
        self.assertFresh(r)                       # the committed generator, extracted into the cache
        c = r.fresh("HEAD", "--pinned")           # control: the working tree's generator disagrees
        self.assertEqual(c.returncode, 1, c.stdout)
        gens = os.path.join(r.env["XDG_CACHE_HOME"], "komira-kg", "generators")
        self.assertEqual(len(os.listdir(gens)), 1)

    def test_problems_block_only_the_change_that_makes_them(self):
        r = make(self.tmp)
        parent = r.head()
        r.write("src/alpha/__init__.mojo", '"""' + "long " * 100 + '"""\n')
        r.git("commit", "-q", "-a", "-m", "a long summary")
        c = r.fresh("HEAD", "--base", parent)
        self.assertEqual(c.returncode, 1, c.stdout)
        self.assertIn("PROBLEM in this change: src/alpha/__init__.mojo: summary is 499 characters (cap 400) (library alpha)", c.stdout)
        self.assertFresh(r)                       # without a base it is counted, not refused
        r.write("src/beta/__init__.mojo", '"""Beta, unrelated."""\n')
        r.git("commit", "-q", "-a", "-m", "unrelated")
        c = r.fresh("HEAD", "--base", "HEAD~1")
        self.assertEqual(c.returncode, 0, c.stdout)


if __name__ == "__main__":
    v = subprocess.run(["git", "--version"], capture_output=True, text=True)
    print("kg git selftest: %s" % (v.stdout.strip() or "NO GIT ON PATH -- refusing"))
    if v.returncode != 0:
        sys.exit(1)
    res = unittest.main(exit=False, verbosity=1).result
    n = res.testsRun
    print("kg git selftest: %d tests, %d failures, %d errors" % (n, len(res.failures), len(res.errors)))
    sys.exit(0 if n > 0 and res.wasSuccessful() else 1)
