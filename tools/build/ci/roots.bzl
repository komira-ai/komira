"""The committed roots of the check set: one empty file per root, named by its label.

`//ci:pr` (ci/BUCK) depends on every root of the check set (ci_graph.bzl `roots`). A
target's `deps` are literal labels and no rule can query the graph, so the roots are
committed, each as one empty file of the `ci` package:

    ci/roots/<cell>/<package>:<name>        a root Buck2 cannot run as a test
    ci/test_roots/<cell>/<package>:<name>   a root Buck2 runs as a test (`buck2 test //ci:pr`)

The path under its tree is the label with its `//` written as `/`:
`komira//src/avro:avro_conda` is `ci/roots/komira/src/avro:avro_conda`, and `komira//:top`
(the root package) is `ci/roots/komira/:top`.

Why one file per root: a pull request that adds a root adds its file, and one whose new
target depends on an old root deletes the old root's file. No file holds the rows of two
roots, so two pull requests that change different roots change different paths, and git
merges them with no conflict in either order. Where both change the same path they make the
same change (both delete a root their new targets depend on), which git also merges. A file
never stands where another file's directory would: only the last part of a path holds a `:`
(a package path holds none), so the file `src/a:b` and the directory `src/a/b/` of the
package `src/a/b` differ.

`ci/BUCK` reads the files with a glob (`labels_of`), and `guard.bxl` lists them with
`ctx.fs`, so no list names the files and there is no loader to edit.
"""

# The two trees, relative to the `ci` package (ci/BUCK globs them) and to the cell (the
# generator writes and the guard lists `ci/<tree>/...`).
ROOTS_DIR = "roots"
TEST_ROOTS_DIR = "test_roots"
PACKAGE_DIR = "ci"

def root_path(label):
    """`cell//package:name` -> `cell/package:name`, the file's path under its tree."""
    cell, rest = label.split("//", 1)
    return cell + "/" + rest

def root_label(path):
    """The label of the file at `path` under its tree (the inverse of `root_path`), or ""
    when `path` is not one: it has no cell directory, its last part holds no `:` or more
    than one, its target name is empty, or a directory of it holds a `:`."""
    parts = path.split("/")
    if len(parts) < 2 or not parts[0]:
        return ""
    for p in parts[:-1]:
        if not p or ":" in p:
            return ""
    last = parts[-1]
    if last.count(":") != 1 or last.endswith(":"):
        return ""
    return parts[0] + "//" + "/".join(parts[1:])

def root_files(root_labels, test_labels):
    """path (relative to the cell) -> "" of every file the roots need: `ci/test_roots/...`
    for each root of `test_labels`, `ci/roots/...` for every other root of `root_labels`."""
    tests = {l: True for l in test_labels}
    out = {}
    for l in root_labels:
        tree = TEST_ROOTS_DIR if l in tests else ROOTS_DIR
        out["{}/{}/{}".format(PACKAGE_DIR, tree, root_path(l))] = ""
    return out

def labels_of(paths, tree):
    """The sorted labels of the files `paths` of `tree` (as a glob in the `ci` package returns
    them: `<tree>/<cell>/<package>:<name>`). A path that names no label is left out: it builds
    nothing, and `guard.bxl:check` fails naming it."""
    out = []
    for p in paths:
        label = root_label(p.removeprefix(tree + "/"))
        if label:
            out.append(label)
    return sorted(out)
