"""Which library of a BUCK file takes the package's README.md (mojo_library's `readme`).

A library takes its directory's README.md: the README's ```mojo examples run
as its welded `[tests][readme]` test and its conda package installs the file
(readme_gate below; tools/build/package/conda.bzl). A BUCK file that
declares one library needs to say nothing. One that declares several says
which of them the README is about, with the macro's `readme` keyword:

    readme omitted   the README.md of the directory if there is one (one
                     library: nothing to say)
    readme = True    the README.md of the directory, refused if there is none
    readme = False   no README: no `[tests][readme]`, none in the conda package

A README attached to a library that does not reach what it imports fails
that library's `[tests][readme]` compile, and a README attached to several
ships in each of their packages, so a package of several libraries gives
`readme = False` to every library its README is not about.

This module loads nothing, so defs.bzl can load it.
"""

# The README examples tool, a Zig executable: no Mojo library, so any
# package, its own included, may hold a README.
_README_TOOL = "komira//tools/build/readme_examples:tool"

def readme_kwargs(kwargs):
    """Replaces the macro's `readme` keyword in `kwargs` by the rule's
    `readme` (the README.md source) and `readme_tool` attributes, or by
    neither when the library takes no README."""
    name = kwargs.get("name", "mojo_library")
    if "readme_tool" in kwargs:
        fail("{}: `readme_tool` is set by mojo_library with the README; do not pass it".format(name))
    want = kwargs.pop("readme", None)
    if want != None and type(want) != "bool":
        fail("{}: `readme` takes True, False or nothing (the package's README.md, if any), not {}".format(name, repr(want)))
    if want == False:
        return
    found = glob(["README.md"])
    if not found:
        if want == True:
            fail("{}: `readme = True` and //{} holds no README.md".format(name, package_name()))
        return
    kwargs["readme"] = found[0]
    kwargs["readme_tool"] = _README_TOOL

# ---- The gate -----------------------------------------------------------------
#
# A library whose package holds a README.md runs the README's ```mojo
# examples as one more welded test, `[tests][readme]`: the docs cannot rot.
# The macro passes the README (declaring is gating: a README is declared by
# existing; a library of a several-library package can refuse it with
# `readme = False`, readme_kwargs above) and the tool, //tools/build/readme_examples:tool, whose
# `generate` writes one program per example, `readme_<import name>_<line>.mojo`
# (and the runner of them all, which coverage builds), into a directory, and
# the README line of each example to `examples`. The convention (what an
# example is, its two modes, hidden lines, the refusals) is in that package
# and in README.md here.
#
# Whether a README holds an example is in its bytes, which analysis cannot
# read, so a dynamic action reads `examples`: for each example it compiles
# that example's program alone against the UNGATED package and runs it
# through gate_runner.sh exactly as a `test_srcs` entry, labelled
# `<target>:README.md:<line>`, and the marker joins their markers; with none
# it compiles and runs nothing, and the marker records that no example
# exists (never a PASS line). A refused README (an info string such as
# `mojo skip`, a stray hidden-lines comment) fails `generate`, naming
# README.md:<line>.

def readme_gate(ctx, tc, import_name, ungated_tset, link_tail, env_args, ships, readme_test, owner = False):
    """(marker, generated directory, examples file, objects directory) of
    the README's examples, or None without a README. With `owner` (the library
    lists a C library among its `deps`: native_facts.bzl `c_direct`), the
    objects directory holds each example's program as an
    object file, `readme_<import name>_<line>.o`, whose undefined symbols
    are the C it calls: `[tests][readme][objects]`, which the library's own
    shared library reads for its README check (tools/build/native/shared.bzl,
    `readme_calls`). It is empty for any other library and with no example.
    `ships`: the library's conda package installs the README, so a
    relative link in it is refused.
    `link_tail`: the link arguments of the library's C closure (defs.bzl's
    _link_tail); `readme_test`: defs.bzl's dynamic action that builds and
    runs each example (it needs defs.bzl's _build_executable)."""
    readme = ctx.attrs.readme
    if readme == None:
        if ctx.attrs.readme_tool != None:
            fail("{}: readme_tool is set and readme is not".format(ctx.label))
        return None
    if ctx.attrs.readme_tool == None:
        fail("{}: readme is set and readme_tool is not; the mojo_library macro sets both".format(ctx.label))
    src = ctx.actions.declare_output("tests/readme/src", dir = True)
    examples = ctx.actions.declare_output("tests/readme/examples")
    ctx.actions.run(
        cmd_args(
            ctx.attrs.readme_tool[RunInfo],
            "generate",
            "--readme",
            readme,
            "--display",
            (ctx.label.package + "/" + readme.short_path) if ctx.label.package else readme.short_path,
            "--package",
            import_name,
            "--links",
            "refuse" if ships else "allow",
            "--out-dir",
            src.as_output(),
            "--examples",
            examples.as_output(),
        ),
        category = "mojo_readme_generate",
    )
    marker = ctx.actions.declare_output("tests/readme.passed")
    objects = ctx.actions.declare_output("tests/readme/objects", dir = True)
    ctx.actions.dynamic_output_new(readme_test(
        label = ctx.label,
        gate_label = "{}:{}".format(ctx.label.raw_target(), readme.short_path),
        examples = examples,
        package = import_name,
        src = src,
        marker = marker.as_output(),
        objects = objects.as_output(),
        owner = owner,
        tc = tc,
        closure = ungated_tset,
        opt_level = ctx.attrs.test_optimization_level,
        link_tail = link_tail,
        env_args = env_args,
    ))
    return marker, src, examples, objects
