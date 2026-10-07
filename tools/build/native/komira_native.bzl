"""libkomira_native.so.1: komira's one shared library of C (README.md, "One shared library").

`komira_native` links every `shared` C archive komira's Mojo packages call
(each declared with a `NativeArchiveInfo`, defs.bzl) into one shared object,
exporting exactly the names the Mojo code passes to `external_call`, and
checks the result as a validation of the same target:

1. native_exports.sh reads the archives' symbols (`elfsyms symtab`) and the
   callers' sources and writes the export list and the version script (and
   fails on two owners of a symbol, a called name nothing defines, ...);
2. native_link.sh links them (--whole-archive, -Bsymbolic, --gc-sections,
   -z defs, the version script), with the Mojo toolchain's zig and target, so
   the library and the programs linking it agree on glibc;
3. native_check.sh reads the result back (`elfsyms dynsym`): every export is
   komira_* and the exports are exactly the list, the SONAME, NEEDED and
   -Bsymbolic are as they must be;
4. native_callsite_check.sh reads the call sites again with `callsites`, a
   tokenizer sharing nothing with step 1's scan, and requires the exports to
   be exactly the names it finds that the archives define: a name step 1
   misses, and so leaves out of both its list and the script, is caught here.

`komira_native_run_test` runs Mojo programs against the library the way a
conda environment holds it (native_run.sh: `mojo run` with `-l`, a built
program with run path `$ORIGIN/../lib`, the system OpenSSL dlopened after
ours, and ours dlopened after it),
and is a validation too: a `checked_cxx_library` (defs.bzl) of the library
with the run test as its check is the target others name.

Every script runs under the pinned busybox and is copied under buck-out first
(as in defs.bzl), so the action digests are the same in a standalone checkout
and in a repository mounting komira as a cell.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load(":defs.bzl", "NativeArchiveInfo")

_BUSYBOX = "komira//tools/build/toolchains:busybox"
_ELFSYMS = "komira//tools/build/native:elfsyms"
_TOOLCHAIN = "toolchains//:mojo"

# What a NEEDED entry of the library may be: glibc's own libraries.
_NEEDED = "libc\\.so\\.6|libm\\.so\\.6|libpthread\\.so\\.0|ld-linux-x86-64\\.so\\.2"

def _staged(ctx, src):
    return ctx.actions.copy_file("_staged/" + src.short_path, src)

def _declared(ctx, deps, kind, attr):
    out = []
    for d in deps:
        info = d[NativeArchiveInfo]
        if info.kind != kind:
            fail("{}: {} is declared `{}` ({}); `{}` takes only `{}` archives".format(
                ctx.label,
                d.label.raw_target(),
                info.kind,
                info.reason,
                attr,
                kind,
            ))
        out.append((d.label.raw_target(), info.archive))
    return out

def _komira_native_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    if tc.os != "linux":
        fail("{}: libkomira_native is built for linux only (an ELF version script and SONAME)".format(ctx.label))
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    elfsyms = ctx.attrs._elfsyms[RunInfo]
    shared = _declared(ctx, ctx.attrs.archives, "shared", "archives")
    per_library = _declared(ctx, ctx.attrs.per_library, "per_library", "per_library")
    callers = []
    for d in ctx.attrs.callers:
        subs = d[DefaultInfo].sub_targets
        if "src" not in subs:
            fail("{}: caller {} has no [src] sub-target (not a mojo_library?)".format(ctx.label, d.label.raw_target()))
        callers.append((d.label.raw_target(), subs["src"][DefaultInfo].default_outputs[0]))

    exports = ctx.actions.declare_output("exports.txt")
    script = ctx.actions.declare_output(ctx.attrs.soname + ".map")
    report = ctx.actions.declare_output("exports_report.txt")
    args = [bb, "sh", _staged(ctx, ctx.attrs._exports_sh), bb, elfsyms, exports.as_output(), script.as_output(), report.as_output()]
    for label, a in shared:
        args += ["--shared", label, a]
    for label, a in per_library:
        args += ["--per-library", label, a]
    for label, src in callers:
        args += ["--caller", label, src]
    ctx.actions.run(cmd_args(args), category = "native_exports")

    so = ctx.actions.declare_output(ctx.attrs.soname)
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            _staged(ctx, ctx.attrs._link_sh),
            bb,
            tc.link,
            tc.cc_target,
            ctx.attrs.soname,
            script,
            so.as_output(),
            [a for _, a in shared],
        ),
        category = "native_link",
    )
    link_name = ctx.attrs.soname.rsplit(".so.", 1)[0] + ".so"
    dev = ctx.actions.symlink_file(link_name, so)

    result = ctx.actions.declare_output("export_check.json")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            _staged(ctx, ctx.attrs._check_sh),
            bb,
            result.as_output(),
            elfsyms,
            so,
            ctx.attrs.soname,
            exports,
            script,
            _NEEDED,
        ),
        category = "native_export_check",
    )
    calls_result = ctx.actions.declare_output("callsite_check.json")
    calls_args = [bb, "sh", _staged(ctx, ctx.attrs._callsite_check_sh), bb, calls_result.as_output(), elfsyms, ctx.attrs._callsites[RunInfo], so]
    for _, a in shared:
        calls_args += ["--shared", a]
    for _, src in callers:
        calls_args += ["--caller", src]
    ctx.actions.run(cmd_args(calls_args), category = "native_callsite_check")
    return [
        DefaultInfo(
            default_output = so,
            other_outputs = [dev],
            sub_targets = {
                "callsite_check": [DefaultInfo(default_output = calls_result)],
                "check": [DefaultInfo(default_output = result)],
                "exports": [DefaultInfo(default_output = exports, other_outputs = [report])],
                "link": [DefaultInfo(default_output = dev)],
                "report": [DefaultInfo(default_output = report)],
                "version_script": [DefaultInfo(default_output = script)],
            },
        ),
        ValidationInfo(validations = [
            ValidationSpec(name = "export_check", validation_result = result),
            ValidationSpec(name = "callsite_check", validation_result = calls_result),
        ]),
    ]

_komira_native = rule(
    impl = _komira_native_impl,
    doc = "libkomira_native.so.1 (`soname`), and its link name beside it (`[link]`): every `archives` archive linked whole, exporting exactly the `external_call` names of the `callers`' sources that those archives define (`[exports]`, `[version_script]`, `[report]`). The export check (`[check]`, native_check.sh) and the call-site check (`[callsite_check]`, native_callsite_check.sh) are validations of this target.",
    attrs = {
        "archives": attrs.list(attrs.dep(providers = [NativeArchiveInfo]), doc = "The C archives in the library: each must declare kind `shared` (a native_archive, or a checked_cxx_library with native_kind)."),
        "callers": attrs.list(attrs.dep(), doc = "The mojo_library packages whose `external_call` names the library answers: every package that calls a name an archive defines. Their sources are read from `[src]`; their tests are not."),
        "per_library": attrs.list(attrs.dep(providers = [NativeArchiveInfo]), default = [], doc = "The C archives Mojo code calls that are kept out (kind `per_library`): their names are not exported, and the closed-world check accepts them as defined."),
        "soname": attrs.string(),
        "_busybox": attrs.exec_dep(default = _BUSYBOX),
        "_callsite_check_sh": attrs.source(default = "komira//tools/build/native:native_callsite_check.sh"),
        "_callsites": attrs.exec_dep(default = "komira//tools/build/native:callsites", providers = [RunInfo]),
        "_check_sh": attrs.source(default = "komira//tools/build/native:native_check.sh"),
        "_elfsyms": attrs.exec_dep(default = _ELFSYMS, providers = [RunInfo]),
        "_exports_sh": attrs.source(default = "komira//tools/build/native:native_exports.sh"),
        "_link_sh": attrs.source(default = "komira//tools/build/native:native_link.sh"),
        "_toolchain": attrs.toolchain_dep(default = _TOOLCHAIN, providers = [MojoToolchainInfo]),
    },
)

komira_native = declares_docs(_komira_native)

_CASES = ["R1", "B1", "IR1", "IR2"]

def _run_test_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    lib = ctx.attrs.lib[DefaultInfo]
    so = lib.default_outputs[0]
    files = {
        "lib/" + so.basename: so,
        "lib/" + lib.sub_targets["link"][DefaultInfo].default_outputs[0].basename: so,
    }
    for name, pkg in ctx.attrs.mojoc.items():
        files["lib/mojo/{}.mojoc".format(name)] = pkg
    prefix = ctx.actions.copied_dir("prefix", files)
    srcs = ctx.actions.copied_dir("programs", {s.basename: s for s in ctx.attrs.srcs})
    wd_idle = str(tc.watchdog_idle_secs) if tc.watchdog_idle_secs != None else "300"
    wd_sample = str(tc.watchdog_sample_secs) if tc.watchdog_sample_secs != None else "30"
    script = _staged(ctx, ctx.attrs._run_sh)
    logs = []
    subs = {}
    if not ctx.attrs.cases:
        fail("{}: no cases: a run test that runs nothing checks nothing".format(ctx.label))
    for case in ctx.attrs.cases:
        if case not in _CASES:
            fail("{}: unknown case `{}` (native_run.sh has {})".format(ctx.label, case, ", ".join(_CASES)))
        log = ctx.actions.declare_output("logs/{}.log".format(case))
        ctx.actions.run(
            cmd_args(
                tc.busybox,
                "sh",
                script,
                tc.busybox,
                tc.wrapper,
                tc.compiler,
                tc.link,
                tc.cc_target,
                tc.target_cpu,
                wd_idle,
                wd_sample,
                prefix,
                srcs,
                tc.runtime,
                ctx.attrs._elfsyms[RunInfo],
                case,
                log.as_output(),
            ),
            category = "native_run_test",
            identifier = case,
        )
        logs.append(log)
        subs[case] = [DefaultInfo(default_output = log)]
    result = ctx.actions.declare_output("run_test.json")
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            "-c",
            'printf \'{"version": 1, "data": {"status": "success", "message": "cases %s passed"}}\\n\' "$2" > "$1"',
            "native_run_test",
            result.as_output(),
            " ".join(ctx.attrs.cases),
            hidden = logs,
        ),
        category = "native_run_test_result",
    )
    return [
        DefaultInfo(default_outputs = logs, sub_targets = subs | {"prefix": [DefaultInfo(default_output = prefix)]}),
        ValidationInfo(validations = [ValidationSpec(name = "run_test", validation_result = result)]),
    ]

_komira_native_run_test = rule(
    impl = _run_test_impl,
    doc = "Runs `srcs` (Mojo programs) against `lib` (a komira_native target) laid out as a conda environment holds it, one action per case of native_run.sh; each fails its action unless its program prints RESULT PASS. The result is a validation of this target.",
    attrs = {
        "cases": attrs.list(attrs.string(), doc = "Cases of native_run.sh: R1, B1, IR1, IR2."),
        "lib": attrs.dep(doc = "A komira_native target."),
        "mojoc": attrs.dict(attrs.string(), attrs.source(), default = {}, doc = "Import name -> a mojo_library: the packages the programs import, installed as lib/mojo/<name>.mojoc."),
        "srcs": attrs.list(attrs.source(), doc = "The programs and the modules they import, staged in one directory."),
        "_elfsyms": attrs.exec_dep(default = _ELFSYMS, providers = [RunInfo]),
        "_run_sh": attrs.source(default = "komira//tools/build/native:native_run.sh"),
        "_toolchain": attrs.toolchain_dep(default = _TOOLCHAIN, providers = [MojoToolchainInfo]),
    },
)

komira_native_run_test = declares_docs(_komira_native_run_test)
