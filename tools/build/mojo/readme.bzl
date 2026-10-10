"""Which library of a BUCK file takes the package's README.md (mojo_library's `readme`).

A library takes its directory's README.md: the README's ```mojo examples run
as its welded `[tests][readme]` test and its conda package installs the file
(defs.bzl, _readme_gate; tools/build/package/conda.bzl). A BUCK file that
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
