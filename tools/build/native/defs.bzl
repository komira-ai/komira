"""Symbol prefixing of the vendored C libraries (README.md).

`prefix_header` writes the header that renames every global symbol of a C
library, read from the library's unprefixed archive. `prefixed_archive_check`
reads the prefixed archive back and fails its build action unless every
symbol it defines carries the prefix; its result is a `ValidationInfo`. Both
actions run `prefix_tool` (Zig, src/), which reads the archive itself (a
System V archive of ELF objects or a BSD archive of Mach-O objects, with
native_elf.zig and native_macho.zig); neither runs a shell.
`checked_cxx_library` is the library as other targets use it: the providers
of the prefixed `cxx_library`, with the checks as dependencies, so Buck2 runs
them in every build whose graph holds the library. When the library only
re-exports another `cxx_library` (`archive`), its `[static-pic]` sub-target is
that library's archive; every other provider is unchanged.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

def _prefix_header_impl(ctx):
    hdr = ctx.actions.declare_output(ctx.attrs.header)
    syms = ctx.actions.declare_output("symbols.txt")
    more = ["--strip", ctx.attrs.strip] if ctx.attrs.strip else []
    for name in ctx.attrs.extra_symbols:
        more.extend(["--extra", name])
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "header",
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
        "_tool": attrs.exec_dep(default = "komira//tools/build/native:prefix_tool", providers = [RunInfo]),
    },
)

prefixed_archive_check = declares_docs(_prefixed_archive_check)

def _checked_impl(ctx):
    providers = ctx.attrs.lib.providers
    if ctx.attrs.archive == None:
        return providers
    info = ctx.attrs.archive[DefaultInfo]
    if "static-pic" not in info.sub_targets:
        fail("{}: archive {} has no [static-pic] archive (not a cxx_library with sources?)".format(ctx.label, ctx.attrs.archive.label.raw_target()))
    own = ctx.attrs.lib[DefaultInfo]
    subs = {name: [sub[DefaultInfo]] for name, sub in own.sub_targets.items()}
    subs["static-pic"] = [info.sub_targets["static-pic"][DefaultInfo]]
    return [DefaultInfo(
        default_outputs = own.default_outputs,
        other_outputs = own.other_outputs,
        sub_targets = subs,
    )] + [p for p in providers if not isinstance(p, DefaultInfo)]

_checked_cxx_library = rule(
    impl = _checked_impl,
    doc = "The C/C++ library `lib`, gated by `checks`; every provider of it is unchanged except, when `archive` is set, the `[static-pic]` sub-target of its DefaultInfo, which is `archive`'s. `checks` are targets returning a `ValidationInfo`, which Buck2 runs in every build whose graph holds this target.",
    attrs = {
        "archive": attrs.option(attrs.dep(), default = None, doc = "The cxx_library whose `[static-pic]` archive is this library's, when `lib` only re-exports it (it has no sources of its own): the result's `[static-pic]` is that archive."),
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "lib": attrs.dep(),
    },
)

checked_cxx_library = declares_docs(_checked_cxx_library)
