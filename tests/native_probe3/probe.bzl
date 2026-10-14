"""native_probe3 rules: PROBE, never merged (docs/design/native_packaging.md, "probe 3").

Every action runs the pinned busybox `sh` with zig from the Mojo toolchain
(`MojoToolchainInfo.link`); a case action also runs the Mojo compiler, through
mojo_wrapper.sh for `mojo build`, and as an installed `<env>/bin/mojo` for
`mojo run` (see case.sh). Nothing is taken from the worker beyond the host
floor, except what a case loads on purpose: the system OpenSSL (IR1, IR2) and
the image's own codec copies (DL, DL-MISS).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo", "MojoToolchainInfo")

_PRELUDE = """
BB=$0
case "$BB" in /*) ;; *) BB=$PWD/$BB ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") W=$PWD/_probe_w ;;
    /*) W=$BUCK_SCRATCH_PATH/probe ;;
    *) W=$PWD/$BUCK_SCRATCH_PATH/probe ;;
esac
"$BB" mkdir -p "$W/bin" "$W/zg" "$W/zl" "$W/home"
"$BB" --install -s "$W/bin"
PATH=$W/bin
ZIG_GLOBAL_CACHE_DIR=$W/zg
ZIG_LOCAL_CACHE_DIR=$W/zl
HOME=$W/home
export PATH ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
set -eu
"""

_TC = attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo])

def _sh(tc, script, *args):
    return cmd_args(tc.busybox, "sh", "-c", _PRELUDE + script, tc.busybox, *args)

# $1 zig dir, $2 log, $3 out, then zig's arguments. A failed link fails the
# action with the log on stderr; a good one leaves the log (the command line).
_LINK_SCRIPT = """
Z=$1
LOG=$2
shift 2
rc=0
echo "CMD: zig $*" > "$LOG"
"$Z/zig" "$@" >> "$LOG" 2>&1 || rc=$?
echo "LINK_RC=$rc" >> "$LOG"
if [ "$rc" != 0 ]; then
    cat "$LOG" >&2
    exit "$rc"
fi
"""

def _native_so_impl(ctx):
    """One library's shared object, linked as the design's "How each shared library is linked" says."""
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    so = ctx.actions.declare_output(ctx.attrs.soname)
    log = ctx.actions.declare_output(ctx.attrs.soname + ".link.log")
    args = [
        "c++" if ctx.attrs.cxx else "cc",
        "-target",
        tc.cc_target,
        "-shared",
        "-Wl,-soname," + ctx.attrs.soname,
        "-Wl,-Bsymbolic",
        "-Wl,--gc-sections",
        "-Wl,-z,defs",
        cmd_args(ctx.attrs.version_script, format = "-Wl,--version-script,{}"),
    ]
    if ctx.attrs.runpath_origin:
        args += ["-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN"]
    args += ["-Wl,--whole-archive"] + ctx.attrs.archives + ["-Wl,--no-whole-archive"]
    # A komira owner this one needs: named by path, so DT_NEEDED is its SONAME.
    args += ctx.attrs.needed
    args += ["-o", so.as_output()]
    ctx.actions.run(_sh(tc, _LINK_SCRIPT, tc.link, log.as_output(), args), category = "probe3_native_link", identifier = ctx.attrs.soname)
    return [DefaultInfo(default_output = so, sub_targets = {"log": [DefaultInfo(default_output = log)]})]

_native_so = rule(impl = _native_so_impl, attrs = {
    "archives": attrs.list(attrs.source()),
    "cxx": attrs.bool(default = False),
    "needed": attrs.list(attrs.source(), default = []),
    "runpath_origin": attrs.bool(default = False),
    "soname": attrs.string(),
    "toolchain": _TC,
    "version_script": attrs.source(),
})

native_so = declares_docs(_native_so)

# komira_log's holder shim compiled a second time with its twelve accessors
# exported (design option A): the hidden attribute is rewritten to default.
_LOG_JIT_SCRIPT = """
Z=$1
SRC=$2
OUT=$3
CCT=$4
MAP=$5
mkdir -p "$W/src"
sed 's/__attribute__((visibility("hidden")))/__attribute__((visibility("default")))/' "$SRC" > "$W/src/holder_jit.c"
n=$(grep -c 'visibility("default")' "$W/src/holder_jit.c")
[ "$n" -ge 1 ] || { echo "log_holder_jit: the hidden attribute was not found in $SRC" >&2; exit 1; }
"$Z/zig" cc -target "$CCT" -O2 -fPIC -shared -Wl,-soname,libkomira_log_holder_jit.so.1 -Wl,-z,defs \\
    "-Wl,--version-script,$MAP" "$W/src/holder_jit.c" -o "$OUT"
"""

def _log_jit_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("libkomira_log_holder_jit.so.1")
    ctx.actions.run(_sh(tc, _LOG_JIT_SCRIPT, tc.link, ctx.attrs.src, out.as_output(), tc.cc_target, ctx.attrs.version_script), category = "probe3_log_jit")
    return [DefaultInfo(default_output = out)]

_log_jit = rule(impl = _log_jit_impl, attrs = {
    "src": attrs.source(),
    "toolchain": _TC,
    "version_script": attrs.source(),
})

log_jit = declares_docs(_log_jit)

def _env_impl(ctx):
    """The installed environment, as files: lib/ (the owners' .so.1, the holder
    archive and JIT object), lib/mojo/ (every .mojoc of the consumers' closures),
    nort/ (http_core's .so without DT_RUNPATH, for B3) and codecs/ (the
    conda-forge codec libraries, for DL)."""
    files = {}
    for so in ctx.attrs.libs:
        files["lib/" + so.basename] = so
    for name, a in ctx.attrs.lib_files.items():
        files["lib/" + name] = a
    for name, a in ctx.attrs.nort.items():
        files["nort/" + name] = a
    files["codecs"] = ctx.attrs.codecs
    seen = {}
    for dep in ctx.attrs.mojo:
        for pkg in dep[MojoInfo].pkgs.traverse():
            if pkg == None:
                continue
            key = "lib/mojo/" + pkg.basename
            if key in seen and seen[key] != pkg:
                fail("two different packages named {}".format(pkg.basename))
            seen[key] = pkg
            files[key] = pkg
    env = ctx.actions.copied_dir("env", files)
    return [DefaultInfo(default_output = env)]

_env = rule(impl = _env_impl, attrs = {
    "codecs": attrs.source(),
    "lib_files": attrs.dict(attrs.string(), attrs.source(), default = {}),
    "libs": attrs.list(attrs.source()),
    "mojo": attrs.list(attrs.dep(providers = [MojoInfo])),
    "nort": attrs.dict(attrs.string(), attrs.source(), default = {}),
})

probe_env = declares_docs(_env)

def _case_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    if ctx.attrs.expect == "fail" and not ctx.attrs.fail_signature:
        fail("{}: a must-fail case names its failure signature".format(ctx.label.name))
    srcs = ctx.actions.copied_dir("consumers", {s.basename: s for s in ctx.attrs.consumers})
    log = ctx.actions.declare_output(ctx.label.name + ".log")
    wd_idle = str(tc.watchdog_idle_secs) if tc.watchdog_idle_secs != None else "300"
    wd_sample = str(tc.watchdog_sample_secs) if tc.watchdog_sample_secs != None else "30"
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            ctx.attrs.script,
            tc.busybox,
            tc.wrapper,
            tc.compiler,
            tc.link,
            tc.cc_target,
            tc.target_cpu,
            wd_idle,
            wd_sample,
            ctx.attrs.env,
            srcs,
            tc.runtime,
            ctx.attrs.tool[RunInfo],
            ctx.attrs.case,
            ctx.attrs.expect,
            log.as_output(),
            ctx.attrs.fail_rc,
            ctx.attrs.fail_signature,
        ),
        category = "native_probe3",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = log)]

_case = rule(impl = _case_impl, attrs = {
    "case": attrs.string(),
    "consumers": attrs.list(attrs.source()),
    "env": attrs.source(),
    # pass: the action fails unless the case passed.
    # fail: the action fails unless the case failed, its run phase exited
    # fail_rc ("any": unchecked) and every fail_signature ERE matches a line of
    # the run phase (what the program or `mojo run` printed, and the
    # LOADED_FROM verdicts; never the pre-run listings). See case.sh.
    "expect": attrs.enum(["pass", "fail"]),
    "fail_rc": attrs.string(default = "any"),
    "fail_signature": attrs.list(attrs.string(), default = []),
    "script": attrs.source(),
    "tool": attrs.exec_dep(providers = [RunInfo]),
    "toolchain": _TC,
})

probe_case = declares_docs(_case)

def _report_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("report.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", "-c", "out=$1; shift; \"$0\" cat \"$@\" > \"$out\"", tc.busybox, out.as_output(), ctx.attrs.logs),
        category = "native_probe3_report",
    )
    return [DefaultInfo(default_output = out)]

_report = rule(impl = _report_impl, attrs = {
    "logs": attrs.list(attrs.source()),
    "toolchain": _TC,
})

probe_report = declares_docs(_report)

# $1 elfsyms, $2 out, then the files.
_ELF_SCRIPT = """
T=$1
OUT=$2
shift 2
: > "$OUT"
for f in "$@"; do
    echo "=================== $(basename "$f")" >> "$OUT"
    "$T" dynsym "$f" > "$W/d.txt"
    grep -E '^(SONAME|NEEDED|RUNPATH|RPATH|FLAGS|SYMBOLIC)' "$W/d.txt" >> "$OUT" || true
    echo "EXPORTED: $(grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | wc -l)" >> "$OUT"
    echo "EXPORTED not komira_: $(grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | awk '{print $5}' | grep -v '^komira_' | tr '\\n' ' ')" >> "$OUT"
    echo "EXPORTED komira_awslc_: $(grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | awk '{print $5}' | grep -c '^komira_awslc_' || true)" >> "$OUT"
    echo "UNDEFINED strong: $(grep '^UND' "$W/d.txt" | grep -v ' WEAK ' | awk '{print $5}' | grep -v '^$' | sort | tr '\\n' ' ')" | cut -c1-3000 >> "$OUT"
    echo "UNDEFINED weak: $(grep '^UND' "$W/d.txt" | grep ' WEAK ' | awk '{print $5}' | sort | tr '\\n' ' ')" >> "$OUT"
done
"""

def _elf_report_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("elf_report.txt")
    ctx.actions.run(_sh(tc, _ELF_SCRIPT, ctx.attrs.tool[RunInfo], out.as_output(), ctx.attrs.libs), category = "probe3_elf_report")
    return [DefaultInfo(default_output = out)]

_elf_report = rule(impl = _elf_report_impl, attrs = {
    "libs": attrs.list(attrs.source()),
    "tool": attrs.exec_dep(providers = [RunInfo]),
    "toolchain": _TC,
})

elf_report = declares_docs(_elf_report)
