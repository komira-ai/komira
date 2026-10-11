"""The loader-closure check of a toolchain distribution (README.md).

`loader_closure_check` runs the Zig tool `loader_closure` against one
directory in a build action and returns a `ValidationInfo`: red, the build
of every target that depends on it fails. The tool reads the ELF files of the
directory; it runs none of them.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _check_impl(ctx):
    out = ctx.actions.declare_output("validation.json")
    roots = []
    for r in ctx.attrs.roots:
        roots.extend(["--root", r])
    floor = ["--glibc-floor", ctx.attrs.glibc_floor_minor] if ctx.attrs.glibc_floor_minor else []
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[DefaultInfo].default_outputs[0],
            "--prefix",
            ctx.attrs.prefix[DefaultInfo].default_outputs[0],
            "--out",
            out.as_output(),
            roots,
            floor,
        ),
        category = "loader_closure",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = out),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = out)]),
    ]

_loader_closure_check = rule(
    impl = _check_impl,
    doc = "Runs `loader_closure` against the directory `prefix`: every program's PT_INTERP is the system loader, every DT_NEEDED that is not glibc's resolves inside the prefix through a DT_RPATH, no run path entry leads outside it, no glibc name is found inside it, and, with `glibc_floor_minor`, no ELF file names a GLIBC_2.<n> above the floor. Fails the build otherwise.",
    attrs = {
        "glibc_floor_minor": attrs.option(attrs.string(), default = None, doc = "<n> of the floor GLIBC_2.<n>; no floor check when unset."),
        "prefix": attrs.exec_dep(doc = "The distribution: a directory output."),
        "roots": attrs.list(attrs.string(), default = [], doc = "Paths in `prefix` that must be dynamically linked programs. Every program of the prefix is checked; these only make sure the ones that matter are there."),
        "_tool": attrs.exec_dep(default = "komira//tools/build/toolchains/loader_closure:loader_closure"),
    },
)

loader_closure_check = declares_docs(_loader_closure_check)
