"""`helpers` of a `mojo_binary`: programs it runs, shipped beside it.

    mojo_binary(name = "kci", ..., helpers = {"readme_examples": "//tools/build/readme_examples:tool"})

Each entry names a file and the target whose default output it is (an
executable, e.g. a `zig_exe`). The binary's runnable directory (`[runnable]`)
holds it beside the binary as `<name>`, and a `mojo_bundle` of the binary
holds it as `bin/<name>`, mode 0755, beside the launcher; in both the binary
finds it in the directory of its own executable (/proc/self/exe). The target
is built with its own gate (a `zig_exe`'s welded `unit_tests`), so a helper
that failed its tests is never shipped. A name is a plain file name, never
`lib` (the runtime libraries' directory) or the binary's own name.

    mojo_helper_check(name, binary, helper, args, files = {})

runs the copy of `helper` in `binary`'s `[runnable]` directory, from there,
as a build action with no shell, so the target builds only when that copy is
there and starts. `args` are its arguments: an argument that is a key of
`files` is that file, and `{out}` at the start of one is the action's output
directory (so `{out}/x` is a file in it); the helper must write that
directory.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "TOOL_EXEC")
load(":providers.bzl", "MojoProgramInfo", "MojoRunnableInfo")

HELPER_ATTRS = {
    # file name beside the binary -> the target whose default output it is
    "helpers": attrs.dict(attrs.string(), attrs.dep(), default = {}),
}

def helper_files(ctx, binary_name):
    """{file name: artifact} of `ctx`'s `helpers`; {} for a rule without
    them (mojo_test). Fails on a name that is not a plain file name, is
    `lib`, or is the binary's."""
    if not hasattr(ctx.attrs, "helpers"):
        return {}
    out = {}
    for name, dep in ctx.attrs.helpers.items():
        if not regex_match("^[A-Za-z0-9_][A-Za-z0-9_.+-]*$", name) or name in ("lib", binary_name):
            fail("{}: helpers: `{}` cannot name a file beside the binary `{}` (a plain file name, not `lib` or the binary's)".format(ctx.label.raw_target(), name, binary_name))
        out[name] = dep[DefaultInfo].default_outputs[0]
    return out

def _check_impl(ctx):
    helper = ctx.attrs.helper
    if helper not in ctx.attrs.binary[MojoProgramInfo].helpers:
        fail("{}: `{}` is not one of the helpers of {}".format(ctx.label.raw_target(), helper, ctx.attrs.binary.label.raw_target()))
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    argv = []
    for a in ctx.attrs.args:
        if a in ctx.attrs.files:
            argv.append(ctx.attrs.files[a])
        elif a.startswith("{out}"):
            argv.append(cmd_args(out.as_output(), format = "{}" + a[len("{out}"):]))
        else:
            argv.append(a)
    # The copy in the runnable directory, not the helper's own target: a
    # binary that lost its copy fails here.
    run_dir = ctx.attrs.binary[MojoRunnableInfo].run_dir
    ctx.actions.run(cmd_args(run_dir.project(helper), argv), category = "mojo_helper_check")
    return [DefaultInfo(default_output = out)]

_mojo_helper_check = rule(
    impl = _check_impl,
    attrs = {
        "args": attrs.list(attrs.string()),
        "binary": attrs.dep(providers = [MojoRunnableInfo, MojoProgramInfo]),
        # argument -> the file it stands for
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "helper": attrs.string(),
    },
)

def _mojo_helper_check_macro(**kwargs):
    _mojo_helper_check(exec_compatible_with = TOOL_EXEC, **kwargs)

mojo_helper_check = declares_docs(_mojo_helper_check_macro)
