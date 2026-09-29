"""Reading a tree out of git: the index (what the next commit will hold) or a commit.

Only documented commands are used (`ls-files`, `ls-tree`, `cat-file --batch`, `status`,
`diff`, `rev-parse`, `rev-list`, `archive`, `add`, `rm`, `config`). The process
environment is passed through UNCHANGED to every call that reads or writes the index: a
hook runs with `GIT_INDEX_FILE` pointing at the index of the commit being made
(`git commit -a` and `git commit <paths>` both use one that is not `.git/index`), and a
cleared environment would read the wrong index and fail on its lock.
"""
from __future__ import annotations

import hashlib
import os
import subprocess

from . import KgError

REGULAR = ("100644", "100755")


def git(args, cwd, inp=None, check=True, read_only=False):
    """Run git; returns the CompletedProcess. `read_only` sets GIT_OPTIONAL_LOCKS=0 so a
    `status` does not refresh (and lock) the index it is reading."""
    env = dict(os.environ)
    if read_only:
        env["GIT_OPTIONAL_LOCKS"] = "0"
    r = subprocess.run(["git", *args], cwd=cwd, input=inp, capture_output=True, env=env)
    if check and r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace").strip().splitlines()
        raise KgError("git %s failed: %s" % (" ".join(args[:2]), err[0] if err else "exit %d" % r.returncode))
    return r


def out(args, cwd, **kw):
    return git(args, cwd, **kw).stdout.decode("utf-8", "replace").strip()


def object_format(cwd):
    r = git(["config", "--get", "extensions.objectformat"], cwd, check=False, read_only=True)
    return (r.stdout.decode().strip() or "sha1").lower()


def blob_id(data, algo="sha1"):
    h = hashlib.sha256() if algo == "sha256" else hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


class Tree:
    """path -> (mode, object id), plus a batch reader. `unmerged` is the set of paths with
    a conflict stage (index trees only)."""

    def __init__(self, root, entries, unmerged=(), label="index", algo="sha1"):
        self.root, self.entries, self.unmerged, self.label, self.algo = root, entries, set(unmerged), label, algo

    def paths(self):
        return self.entries.keys()

    def oid(self, path):
        e = self.entries.get(path)
        return e[1] if e else None

    def is_file(self, path):
        e = self.entries.get(path)
        return bool(e) and e[0] in REGULAR

    def read(self, paths):
        """{path: bytes} for the regular files among `paths`, in one `cat-file --batch`."""
        want = [p for p in paths if self.is_file(p)]
        if not want:
            return {}
        data = git(["cat-file", "--batch"], self.root,
                   inp="".join(self.entries[p][1] + "\n" for p in want).encode(), read_only=True).stdout
        res, i = {}, 0
        for p in want:
            nl = data.index(b"\n", i)
            head = data[i:nl].split()
            if len(head) != 3:
                raise KgError("git cat-file: object %s for %s is missing" % (self.entries[p][1], p))
            n = int(head[2])
            res[p] = data[nl + 1:nl + 1 + n]
            i = nl + 1 + n + 1
        return res


def index_tree(root):
    ents, unmerged = {}, set()
    for e in git(["ls-files", "-s", "-z"], root, read_only=True).stdout.split(b"\0"):
        if not e:
            continue
        meta, p = e.split(b"\t", 1)
        mode, oid, stage = meta.decode().split()
        p = p.decode("utf-8", "surrogateescape")
        if stage == "0":
            ents[p] = (mode, oid)
        else:
            unmerged.add(p)
    return Tree(root, ents, unmerged, "index", object_format(root))


def commit_tree(root, commit):
    ents = {}
    for e in git(["ls-tree", "-r", "-z", "--full-tree", commit], root, read_only=True).stdout.split(b"\0"):
        if not e:
            continue
        meta, p = e.split(b"\t", 1)
        mode, typ, oid = meta.decode().split()
        if typ == "blob":
            ents[p.decode("utf-8", "surrogateescape")] = (mode, oid)
    return Tree(root, ents, (), commit[:12], object_format(root))


class MemTree(Tree):
    """A tree held in memory ({path: bytes}); the pure tests and `--config` overrides use it."""

    def __init__(self, files, algo="sha1"):
        self.files = dict(files)
        super().__init__(None, {p: ("100644", blob_id(b, algo)) for p, b in self.files.items()}, (), "memory", algo)

    def read(self, paths):
        return {p: self.files[p] for p in paths if p in self.files}
