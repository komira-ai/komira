"""The files of every package, for the Markdown link check (//:docs).

A target may name only files of its own package, and a glob stops at a
subpackage, so no one target can hold the repository. Each package holds its
own files in a `doc_tree` target, which also collects the `doc_tree` of each
of its subpackages. The one in the root package so holds every file of the
cell, and //:docs checks the Markdown there.

No BUCK file names a doc_tree. `package_docs()` declares it, once per
package, and every rule and macro a BUCK file calls calls `package_docs()`
first: the komira rules through `declares_docs` where they are defined, and
the prelude rules through the `[buildfile] includes` module (includes.bzl).
The subpackages come from Buck2 (`__internal__.sub_packages()`, which the
prelude's `source_listing` also uses), not from a list, so a subpackage whose
BUCK file declares no doc_tree is an analysis error of its parent's, naming
the missing target, never a package left out.

This module loads nothing, so every rule file can load it.
"""

DocTreeInfo = provider(
    doc = "The files of a doc_tree target and of the doc_tree targets it collects, keyed by their path in the cell.",
    fields = {"files": provider_field(dict[str, Artifact])},
)

def collect_docs(prefix, srcs, packages):
    # A source's short_path is relative to its package.
    files = {prefix + f.short_path: f for f in srcs}
    for p in packages:
        files.update(p[DocTreeInfo].files)
    return files

def _doc_tree_impl(ctx):
    files = collect_docs(ctx.label.package + "/" if ctx.label.package else "", ctx.attrs.srcs, ctx.attrs.packages)
    return [
        DefaultInfo(default_output = ctx.actions.copied_dir("tree", files)),
        DocTreeInfo(files = files),
    ]

doc_tree = rule(
    impl = _doc_tree_impl,
    doc = "The files of one package (`srcs`, all of them: `glob([\"**\"])` stops at a subpackage), and those of the doc_tree targets in `packages` (its subpackages'), staged at their paths in the cell (package path, then the path in the package). Declared by `package_docs()`, never in a BUCK file.",
    attrs = {
        "srcs": attrs.list(attrs.source()),
        "packages": attrs.list(attrs.dep(providers = [DocTreeInfo]), default = []),
    },
)

def docs_checked():
    """Whether this repository checks its Markdown.

    komira's own checkout does: it has the `tests` cell. A repository using
    komira as a cell does not, so there no doc_tree is declared but in the
    cells it names in `[komira] doc_tree_cells` (`declares_doc_trees()`).
    """
    return read_root_config("cells", "tests") != None

def declares_doc_trees():
    """Whether the packages of this BUCK file's cell declare doc_trees.

    In komira's own checkout (`docs_checked()`), every cell but toolchains.
    In a repository using komira as a cell, the cells its root .buckconfig
    names in `[komira] doc_tree_cells` (space-separated; none by default), so
    that its own checks over every file of a cell (the interpreter list,
    interpreter_budget.bzl) have the cell's tree. Never the komira cell
    there: its root package's checks name the `tests` cell, which such a
    repository does not have, and its targets stay those of a checkout that
    lists nothing. Never the toolchains cell: //:docs does not read it (the
    root BUCK says why), and its targets must equal a consuming repository's
    copy's.
    """
    cell = get_cell_name()
    if cell == "toolchains":
        return False
    if docs_checked():
        return True
    cells = (read_root_config("komira", "doc_tree_cells") or "").split()
    if "komira" in cells or "toolchains" in cells:
        fail("[komira] doc_tree_cells names `{}`: list only this repository's own cells".format(
            "komira" if "komira" in cells else "toolchains",
        ))
    return cell in cells

def package_docs():
    """Declares this package's doc_tree, unless it is declared already or its
    cell declares none (`declares_doc_trees()`)."""
    if not declares_doc_trees() or rule_exists("doc_tree"):
        return
    base = "//" + package_name() + "/" if package_name() else "//"
    doc_tree(
        name = "doc_tree",
        srcs = glob(["**"]),
        packages = [base + sub + ":doc_tree" for sub in __internal__.sub_packages()],
        visibility = ["PUBLIC"],
    )

def declares_docs(f):
    """`f`, calling `package_docs()` first: a rule or macro of BUCK files."""
    def call(*args, **kwargs):
        package_docs()
        return f(*args, **kwargs)
    return call
