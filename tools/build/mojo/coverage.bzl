"""Coverage builds of mojo_library: the switch, and the debug link directory.

`-c komira.coverage=true` (default false) gives every mojo_library on
linux-x86_64 one more binary per `test_srcs` entry: the test compiled at -O0
with line tables, linked through a link directory that keeps the debug info
and rewrites the action's directories out of it (`komira//tools/build/coverage/kcov`, README.md). They
are `[coverage][bin][<test>]`; `[coverage]` is all of them. Nothing else
depends on them yet: the package and its tests are what they are with the
switch off, action for action.

The macro reads `[komira] coverage` from the buckconfig of the cell its
BUCK file is in: `-c` and a global buckconfig reach every cell, a cell's own
`.buckconfig` only that cell (tools/build/mojo/README.md, Coverage builds).

The switch is read here, in the macro, and only sets the `coverage_debug`
attribute: a buckconfig value is not part of the configuration, so it moves
no output path and no action key, and with the switch off the attribute is
absent and analysis is what it was before it existed. On a target platform
other than linux-x86_64 the attribute is None (the `select` below), so the
library builds as with the switch off.

Scope: a library's `test_srcs`. A README's examples, `mojo_test`,
`mojo_shared_lib` drivers and generated test sources get no coverage binary.
"""

# The link directory of every coverage build (cov_link_dir, kcov/defs.bzl):
# one target, so the paths of zig's C runtime sources that the debug info
# names are the same for every library.
_COVERAGE_LINK = "komira//tools/build/coverage/kcov:cov_link"

COVERAGE_ATTRS = {
    # A cov_link_dir: set by the mojo_library macro when coverage is on (see
    # coverage_kwargs); None otherwise. A BUCK file in the komira cell may
    # not set it.
    "coverage_debug": attrs.option(attrs.exec_dep(), default = None),
}

def coverage_on():
    """Whether `[komira] coverage` is `true`. `false` or unset is off; any
    other value fails, naming it, so a typo never turns coverage off."""
    v = read_config("komira", "coverage", "false").strip()
    if v not in ("true", "false"):
        fail("[komira] coverage = {}: it must be `true` or `false` (default false); it turns on the coverage build of every mojo_library (tools/build/mojo/README.md, Coverage builds)".format(repr(v)))
    return v == "true"

def coverage_kwargs(kwargs):
    """Sets `coverage_debug` in a mojo_library's `kwargs` when coverage is on.

    A fixture in the `tests` cell may pass `coverage_debug` itself (a
    cov_link_dir): its library then has coverage binaries whatever the switch
    says, linked through the directory it names, so a test can plant a
    defective tool. Anywhere else passing it is refused.
    """
    name = kwargs.get("name", "mojo_library")
    link = kwargs.get("coverage_debug")
    if link != None:
        if get_cell_name() != "tests":
            fail("{}: `coverage_debug` is set by mojo_library from `[komira] coverage`; do not pass it".format(name))
    elif coverage_on():
        link = _COVERAGE_LINK
    else:
        return
    kwargs["coverage_debug"] = select({
        "komira//tools/build/package:is_linux_x86_64": link,
        "DEFAULT": None,
    })

def coverage_link_dir(ctx):
    """The link directory of this library's coverage builds, what
    mojo_wrapper.sh takes as <zig_dir>, or None when coverage is off."""
    link = ctx.attrs.coverage_debug
    return link[DefaultInfo].default_outputs[0] if link != None else None
