"""coverage_census: the coverage census's doc, rendered at build time, and its floors' check.

The census data lives in the packages: each package's `coverage_floor.tsv`
(its floor) and `coverage_census.tsv` (what the census measured of its
libraries). `tree` is the root package's doc_tree, which holds every file of
the cell at its path (tools/build/lint/doc_tree.bzl), so the target finds
every package's two files with no list to keep: each file under `src/` with
one of those two names. A fixture names its files in `files` instead
({repository path: file}). Two actions:

- `census_files assemble` (census_files.zig) checks each file (a floor file
  holds exactly one row, of its own directory; a census file's rows are of
  its own directory) and writes the census and the floors as two files,
  `[census]` and `[floors]`.
- `census.sh check` renders the doc (the ranked table, `<name>.md`), the
  target's default output: `./buck2 build //:coverage_census --show-output`.
  The doc is a build output and is never committed, so a change to one
  package's coverage touches nothing outside its directory. It renders the
  floors into scratch and fails the build (a validation) unless the floors
  are exactly what it renders: every floor is at least what the census
  measured, every library package of the census has a floor and no other
  package has one. A validation result must be the one output of its
  action, so the result is a copy of what check wrote. A refusal of
  `assemble` fails the build too.

census.md.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "DocTreeInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

_NAMES = ("coverage_floor.tsv", "coverage_census.tsv")

def _census_files(ctx):
    if ctx.attrs.files != None:
        return ctx.attrs.files
    tree = ctx.attrs.tree[DocTreeInfo].files
    return {p: f for p, f in tree.items() if p.startswith("src/") and p.rpartition("/")[2] in _NAMES}

def _coverage_census_impl(ctx):
    if (ctx.attrs.files == None) == (ctx.attrs.tree == None):
        fail("{}: give exactly one of `tree` and `files`".format(ctx.label.raw_target()))
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    staged = ctx.actions.copied_dir("packages", _census_files(ctx))
    census = ctx.actions.declare_output("assembled/census.tsv")
    ratchet = ctx.actions.declare_output("assembled/ratchet.tsv")
    ctx.actions.run(
        cmd_args(ctx.attrs._census_files[RunInfo], "assemble", staged, census.as_output(), ratchet.as_output()),
        category = "coverage_census_assemble",
    )
    doc = ctx.actions.declare_output(ctx.label.name + ".md")
    checked = ctx.actions.declare_output("check/validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, "check", bb, census, ratchet, checked.as_output(), doc.as_output()),
        category = "coverage_census",
    )
    result = ctx.actions.copy_file("validation.json", checked)
    return [
        DefaultInfo(default_output = doc, sub_targets = {
            "census": [DefaultInfo(default_output = census)],
            "floors": [DefaultInfo(default_output = ratchet)],
            "validation": [DefaultInfo(default_output = result)],
        }),
        ValidationInfo(validations = [ValidationSpec(name = "coverage_census", validation_result = result)]),
    ]

_coverage_census_rule = rule(
    impl = _coverage_census_impl,
    doc = "Renders the census doc from every package's coverage_census.tsv and coverage_floor.tsv (found in `tree`, or named in `files`) and fails the build unless the floors are what census.sh renders. See census.bzl.",
    attrs = {
        "files": attrs.option(attrs.dict(attrs.string(), attrs.source()), default = None, doc = "A fixture's files, {repository path: file}, instead of `tree`."),
        "tree": attrs.option(attrs.dep(providers = [DocTreeInfo]), default = None, doc = "The root package's doc_tree: every file of the cell."),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_census_files": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage:census_files"),
        "_script": attrs.source(default = "komira//tools/build/coverage:census.sh"),
    },
)

def coverage_census(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _coverage_census_rule(**kwargs)
