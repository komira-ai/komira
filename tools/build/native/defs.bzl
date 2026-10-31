"""Symbol prefixing of the vendored C libraries (README.md).

`prefix_header` writes the header that renames every global symbol of a C
library, read from the library's unprefixed archive with `elfsyms`.
`prefixed_archive_check` reads the prefixed archive back and fails its build
action unless every symbol it defines carries the prefix; its result is a
`ValidationInfo`. Both actions run `prefix_tool` (Zig, src/), which runs
`elfsyms`; neither runs a shell. `checked_cxx_library` is the library as other targets use
it: the providers of the prefixed `cxx_library`, with the checks as
dependencies, so Buck2 runs them in every build whose graph holds the
library. `c_exe` builds `elfsyms` itself: one C file, compiled and linked
static (musl) with the pinned zig.

`c_exe` runs the pinned zig through `zig_launch` (no shell), and the source it
compiles is copied under buck-out first (as in tools/build/lint): a source
file's path differs between a standalone checkout and a repository mounting
komira as a cell, and so would the action's digest.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

_BUSYBOX = "komira//tools/build/toolchains:busybox"

def _staged(ctx, src):
    return ctx.actions.copy_file("_staged/" + src.short_path, src)

def _c_exe_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    # zig_launch (no shell) gives zig a scratch directory for its caches and
    # HOME, and the busybox applets as PATH.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._zig_launch[RunInfo],
            "zig",
            "--busybox",
            bb,
            "--zig",
            zig,
            "--",
            "cc",
            "-target",
            "x86_64-linux-musl",
            "-O2",
            "-static",
            "-Wall",
            "-Werror",
            _staged(ctx, ctx.attrs.src),
            "-o",
            out.as_output(),
        ),
        category = "c_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

_c_exe = rule(
    impl = _c_exe_impl,
    doc = "One C file built into a static x86_64 Linux (musl) executable with the pinned zig.",
    attrs = {
        "busybox": attrs.dep(default = _BUSYBOX),
        "src": attrs.source(),
        "zig": attrs.dep(default = "komira//tools/build/toolchains:zig"),
        "_zig_launch": attrs.exec_dep(default = "komira//tools/build/mojo:zig_launch", providers = [RunInfo]),
    },
)

c_exe = declares_docs(_c_exe)

def _prefix_header_impl(ctx):
    hdr = ctx.actions.declare_output(ctx.attrs.header)
    syms = ctx.actions.declare_output("symbols.txt")
    more = ["--strip", ctx.attrs.strip] if ctx.attrs.strip else []
    for name in ctx.attrs.extra_symbols:
        more.extend(["--extra", name])
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "header",
        "--elfsyms",
        ctx.attrs._elfsyms[RunInfo],
        "--archive",
        ctx.attrs.archive,
        "--header",
        hdr.as_output(),
        "--symbols",
        syms.as_output(),
        "--style",
        ctx.attrs.style,
        "--prefix",
        ctx.attrs.prefix,
        "--min",
        str(ctx.attrs.min_symbols),
        more,
    )
    ctx.actions.run(cmd, env = salted(), category = "prefix_header")
    return [DefaultInfo(default_output = hdr, sub_targets = {"symbols": [DefaultInfo(default_output = syms)]})]

_prefix_header = rule(
    impl = _prefix_header_impl,
    doc = "The header renaming every defined global symbol of `archive` (an unprefixed build of the library), plus `extra_symbols`, to its prefixed name; `[symbols]` is the list of the original names, one per line. `prefix_tool header` writes it (src/prefix.zig says what each `style` writes).",
    attrs = {
        "archive": attrs.source(doc = "The unprefixed static archive whose symbol table names what to rename."),
        "extra_symbols": attrs.list(attrs.string(), default = [], doc = "Names the library references but does not define (a weak hook a program may define), renamed too."),
        "header": attrs.string(default = "prefix_symbols.h", doc = "The output's file name."),
        "min_symbols": attrs.int(doc = "Fewer names than this fails the action: the archive was not the library."),
        "prefix": attrs.string(),
        "strip": attrs.string(default = "", doc = "style strip: the library's own prefix, replaced by `prefix`."),
        "style": attrs.enum(["boringssl", "strip"]),
        "_elfsyms": attrs.exec_dep(default = "komira//tools/build/native:elfsyms", providers = [RunInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/native:prefix_tool", providers = [RunInfo]),
    },
)

prefix_header = declares_docs(_prefix_header)

def _check_impl(ctx):
    result = ctx.actions.declare_output("validation.json")
    more = []
    for pattern in ctx.attrs.allow:
        more.extend(["--allow", pattern])
    for names in ctx.attrs.original_names:
        more.extend(["--names", names])
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "check",
        "--elfsyms",
        ctx.attrs._elfsyms[RunInfo],
        "--archive",
        ctx.attrs.archive,
        "--result",
        result.as_output(),
        "--prefix",
        ctx.attrs.prefix,
        "--min",
        str(ctx.attrs.min_defined),
        more,
    )
    ctx.actions.run(cmd, env = salted(), category = "prefixed_archive_check", identifier = ctx.label.name)
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_prefixed_archive_check = rule(
    impl = _check_impl,
    doc = "Fails its build action unless every defined and every weak undefined symbol of `archive` starts with `prefix` (or matches one of `allow`), no undefined symbol is one of `original_names`, and at least `min_defined` defined symbols carry the prefix. `prefix_tool check` is the check.",
    attrs = {
        "allow": attrs.list(attrs.string(), default = [], doc = "Names that may lack the prefix: a whole symbol name, or a name's beginning followed by `*` (`_Z*`, every C++ name). Each needs a reason beside it."),
        "archive": attrs.source(doc = "The prefixed static archive."),
        "min_defined": attrs.int(),
        "original_names": attrs.list(attrs.source(), default = [], doc = "Files listing the unprefixed names, one per line (a prefix_header's `[symbols]`)."),
        "prefix": attrs.string(),
        "_elfsyms": attrs.exec_dep(default = "komira//tools/build/native:elfsyms", providers = [RunInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/native:prefix_tool", providers = [RunInfo]),
    },
)

prefixed_archive_check = declares_docs(_prefixed_archive_check)

def _checked_impl(ctx):
    return ctx.attrs.lib.providers

_checked_cxx_library = rule(
    impl = _checked_impl,
    doc = "The C/C++ library `lib`, every provider of it unchanged, gated by `checks`: targets returning a `ValidationInfo`, which Buck2 runs in every build whose graph holds this target.",
    attrs = {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "lib": attrs.dep(),
    },
)

checked_cxx_library = declares_docs(_checked_cxx_library)
