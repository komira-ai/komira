"""Symbol prefixing of the vendored C libraries (README.md).

`prefix_header` writes the header that renames every global symbol of a C
library, read from the library's unprefixed archive with `elfsyms`.
`prefixed_archive_check` reads the prefixed archive back and fails its build
action unless every symbol it defines carries the prefix; its result is a
`ValidationInfo`. `checked_cxx_library` is the library as other targets use
it: the providers of the prefixed `cxx_library`, with the checks as
dependencies, so Buck2 runs them in every build whose graph holds the
library. `c_exe` builds `elfsyms` itself: one C file, compiled and linked
static (musl) with the pinned zig.

Every action runs under the pinned busybox, and every script and source an
action reads is copied under buck-out first (as in tools/build/lint): a source
file's path differs between a standalone checkout and a repository mounting
komira as a cell, and so would the action's digest.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

_BUSYBOX = "komira//tools/build/toolchains:busybox"

def _staged(ctx, src):
    return ctx.actions.copy_file("_staged/" + src.short_path, src)

def _c_exe_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    script = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_c_exe" ;;
    /*) T="$BUCK_SCRATCH_PATH/c_exe" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/c_exe" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/zig-global" "$T/zig-local" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export PATH ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" cc -target x86_64-linux-musl -O2 -static -Wall -Werror "$2" -o "$3"
rm -rf "$T"
"""
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", script, "sh", bb, zig, _staged(ctx, ctx.attrs.src), out.as_output()),
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
    },
)

c_exe = declares_docs(_c_exe)

def _prefix_header_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    hdr = ctx.actions.declare_output(ctx.attrs.header)
    syms = ctx.actions.declare_output("symbols.txt")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            _staged(ctx, ctx.attrs._script),
            bb,
            ctx.attrs._elfsyms[RunInfo],
            ctx.attrs.archive,
            hdr.as_output(),
            syms.as_output(),
            ctx.attrs.style,
            ctx.attrs.prefix,
            ctx.attrs.strip,
            str(ctx.attrs.min_symbols),
            ctx.attrs.extra_symbols,
        ),
        category = "prefix_header",
    )
    return [DefaultInfo(default_output = hdr, sub_targets = {"symbols": [DefaultInfo(default_output = syms)]})]

_prefix_header = rule(
    impl = _prefix_header_impl,
    doc = "The header renaming every defined global symbol of `archive` (an unprefixed build of the library), plus `extra_symbols`, to its prefixed name; `[symbols]` is the list of the original names, one per line. prefix_header.sh says what each `style` writes.",
    attrs = {
        "archive": attrs.source(doc = "The unprefixed static archive whose symbol table names what to rename."),
        "extra_symbols": attrs.list(attrs.string(), default = [], doc = "Names the library references but does not define (a weak hook a program may define), renamed too."),
        "header": attrs.string(default = "prefix_symbols.h", doc = "The output's file name."),
        "min_symbols": attrs.int(doc = "Fewer names than this fails the action: the archive was not the library."),
        "prefix": attrs.string(),
        "strip": attrs.string(default = "", doc = "style strip: the library's own prefix, replaced by `prefix`."),
        "style": attrs.enum(["boringssl", "strip"]),
        "_busybox": attrs.exec_dep(default = _BUSYBOX),
        "_elfsyms": attrs.exec_dep(default = "komira//tools/build/native:elfsyms", providers = [RunInfo]),
        "_script": attrs.source(default = "komira//tools/build/native:prefix_header.sh"),
    },
)

prefix_header = declares_docs(_prefix_header)

def _check_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            _staged(ctx, ctx.attrs._script),
            bb,
            result.as_output(),
            ctx.attrs._elfsyms[RunInfo],
            ctx.attrs.archive,
            ctx.attrs.prefix,
            str(ctx.attrs.min_defined),
            "|".join(ctx.attrs.allow) if ctx.attrs.allow else "-",
            ctx.attrs.original_names,
        ),
        category = "prefixed_archive_check",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_prefixed_archive_check = rule(
    impl = _check_impl,
    doc = "Fails its build action unless every defined and every weak undefined symbol of `archive` starts with `prefix` (or matches one of `allow`), no undefined symbol is one of `original_names`, and at least `min_defined` defined symbols carry the prefix. archive_check.sh is the check.",
    attrs = {
        "allow": attrs.list(attrs.string(), default = [], doc = "Extended regular expressions; a symbol whose whole name matches one may lack the prefix. Each needs a reason beside it."),
        "archive": attrs.source(doc = "The prefixed static archive."),
        "min_defined": attrs.int(),
        "original_names": attrs.list(attrs.source(), default = [], doc = "Files listing the unprefixed names, one per line (a prefix_header's `[symbols]`)."),
        "prefix": attrs.string(),
        "_busybox": attrs.exec_dep(default = _BUSYBOX),
        "_elfsyms": attrs.exec_dep(default = "komira//tools/build/native:elfsyms", providers = [RunInfo]),
        "_script": attrs.source(default = "komira//tools/build/native:archive_check.sh"),
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
