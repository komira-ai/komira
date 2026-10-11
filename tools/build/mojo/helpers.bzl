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
"""

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
