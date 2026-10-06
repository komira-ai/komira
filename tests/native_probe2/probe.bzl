"""native_probe2 rules: EXPERIMENT, never merged. See BUCK.

Every action runs busybox `sh -c` with the busybox applets on PATH and zig
from the Mojo toolchain (`MojoToolchainInfo.link`, the unpacked zig
distribution on linux); nothing is taken from the worker beyond the host
floor (and, in the case actions, the system libcrypto.so.3/libssl.so.3 that
case (c) dlopens on purpose).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

# $0 is busybox. Sets up applets, zig's caches, `set -eu`.
_PRELUDE = """
BB=$0
case "$BB" in /*) ;; *) BB=$PWD/$BB ;; esac
W=$PWD/_probe_w
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

def _c_exe_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output(ctx.label.name)
    ctx.actions.run(
        _sh(tc, '"$1/zig" cc -target x86_64-linux-musl -O2 -static -Wall -Werror "$2" -o "$3"', tc.link, ctx.attrs.src, out.as_output()),
        category = "probe_c_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

_c_exe = rule(impl = _c_exe_impl, attrs = {"src": attrs.source(), "toolchain": _TC})

c_exe = declares_docs(_c_exe)

# aws-lc's util/read_symbols.go skip list, plus __umodti3: the compiler
# builtin :crypto carries (third_party/aws-lc/umodti3.c), which the compiler
# itself calls by that name.
_PREFIX_SCRIPT = """
"$1" armap "$2" | sort -u \\
    | grep -v -E '^(_Z|__x86\\.get_pc_thunk\\.|__real@)' \\
    | grep -v -x -E '__local_stdio_printf_options|__local_stdio_scanf_options|_vscprintf|_vscprintf_l|_vsscanf_l|_xmm|sscanf|vsnprintf|sdallocx|__umodti3' \\
    > "$4"
{
    echo "/* Generated (tests/native_probe2): aws-lc's prefix header for prefix $5. */"
    echo "#ifndef BORINGSSL_PREFIX_SYMBOLS_H"
    echo "#define BORINGSSL_PREFIX_SYMBOLS_H"
    echo "#ifndef BORINGSSL_PREFIX"
    echo "#define BORINGSSL_PREFIX $5"
    echo "#endif"
    echo "#define BORINGSSL_ADD_PREFIX(a, b) BORINGSSL_ADD_PREFIX_INNER(a, b)"
    echo "#define BORINGSSL_ADD_PREFIX_INNER(a, b) a ## _ ## b"
    sed 's/.*/#define & BORINGSSL_ADD_PREFIX(BORINGSSL_PREFIX, &)/' "$4"
    echo "#endif"
} > "$3"
n=$(wc -l < "$4")
[ "$n" -gt 1000 ] || { echo "awslc_prefix_header: only $n symbols read from $2" >&2; exit 1; }
"""

def _prefix_header_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    hdr = ctx.actions.declare_output("boringssl_prefix_symbols.h")
    syms = ctx.actions.declare_output("symbols.txt")
    ctx.actions.run(
        _sh(tc, _PREFIX_SCRIPT, ctx.attrs.tool[RunInfo], ctx.attrs.archive, hdr.as_output(), syms.as_output(), ctx.attrs.prefix),
        category = "awslc_prefix_header",
    )
    return [DefaultInfo(default_output = hdr, sub_targets = {"symbols": [DefaultInfo(default_output = syms)]})]

_awslc_prefix_header = rule(impl = _prefix_header_impl, attrs = {
    "archive": attrs.source(),
    "prefix": attrs.string(),
    "tool": attrs.exec_dep(providers = [RunInfo]),
    "toolchain": _TC,
})

awslc_prefix_header = declares_docs(_awslc_prefix_header)

# $1 zig dir, $2 log, $3 mode (must|log), $4 "--", then zig's arguments.
# mode must: a failed link fails the action (the log goes to stderr).
# mode log: the action always succeeds; LINK_RC= in the log is the result.
_LINK_SCRIPT = """
Z=$1
LOG=$2
MODE=$3
shift 4
mkdir -p "$W/scratch"
rc=0
echo "CMD: zig $*" > "$LOG"
"$Z/zig" "$@" >> "$LOG" 2>&1 || rc=$?
echo "LINK_RC=$rc" >> "$LOG"
if [ "$MODE" = must ] && [ "$rc" != 0 ]; then
    cat "$LOG" >&2
    exit "$rc"
fi
exit 0
"""

def _native_shared_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    log = ctx.actions.declare_output("link.log")
    link = [
        "c++",
        "-target",
        tc.cc_target,
        "-shared",
        "-Wl,-soname," + ctx.attrs.soname,
    ] + ctx.attrs.link_flags
    if ctx.attrs.version_script:
        link.append(cmd_args(ctx.attrs.version_script, format = "-Wl,--version-script,{}"))
    link += ["-Wl,--whole-archive"] + ctx.attrs.archives + ["-Wl,--no-whole-archive"]
    if ctx.attrs.expect_failure:
        args = link + ["-o", "_probe_w/scratch/" + ctx.attrs.soname]
        ctx.actions.run(_sh(tc, _LINK_SCRIPT, tc.link, log.as_output(), "log", "--", args), category = "native_link_case")
        return [DefaultInfo(default_output = log)]
    so = ctx.actions.declare_output(ctx.attrs.soname)
    args = link + ["-o", so.as_output()]
    ctx.actions.run(_sh(tc, _LINK_SCRIPT, tc.link, log.as_output(), "must", "--", args), category = "native_link")
    return [DefaultInfo(default_output = so, sub_targets = {"log": [DefaultInfo(default_output = log)]})]

_native_shared = rule(impl = _native_shared_impl, attrs = {
    "archives": attrs.list(attrs.source()),
    # True: the link is expected to fail (the duplicate-symbol case); the
    # output is the log, and the action succeeds either way.
    "expect_failure": attrs.bool(default = False),
    "link_flags": attrs.list(attrs.string(), default = []),
    "soname": attrs.string(),
    "toolchain": _TC,
    "version_script": attrs.option(attrs.source(), default = None),
})

native_shared = declares_docs(_native_shared)

_ELF_REPORT_SCRIPT = """
T=$1
OUT=$2
MAP=$3
shift 3
: > "$OUT"
grep -E '^ +komira_[A-Za-z0-9_]+;' "$MAP" | tr -d ' ;' | sort > "$W/listed.txt"
echo "VERSION SCRIPT lists $(wc -l < "$W/listed.txt") names" >> "$OUT"
for f in "$@"; do
    echo "=================== $(basename "$f")" >> "$OUT"
    echo "SIZE_BYTES $(wc -c < "$f")" >> "$OUT"
    "$T" dynsym "$f" > "$W/d.txt"
    grep -E '^(SONAME|NEEDED|RUNPATH|RPATH|FLAGS|SYMBOLIC)' "$W/d.txt" >> "$OUT" || true
    echo "EXPORTED (DEF, non-LOCAL): $(grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | wc -l)" >> "$OUT"
    echo "EXPORTED not komira_*: $(grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | awk '{print $5}' | grep -v '^komira_' | wc -l)" >> "$OUT"
    echo "UNDEFINED: $(grep '^UND' "$W/d.txt" | wc -l)" >> "$OUT"
    grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | awk '{print $5}' | sort > "$W/exp.txt"
    echo "LISTED BUT NOT EXPORTED: $(comm -23 "$W/listed.txt" "$W/exp.txt" | tr '\\n' ' ')" >> "$OUT"
    echo "EXPORTED BUT NOT LISTED (first 40): $(comm -13 "$W/listed.txt" "$W/exp.txt" | head -40 | tr '\\n' ' ')" >> "$OUT"
    echo "--- undefined" >> "$OUT"
    grep '^UND' "$W/d.txt" | awk '{print $5}' | sort | tr '\\n' ' ' >> "$OUT"
    echo >> "$OUT"
    echo "--- exported" >> "$OUT"
    grep '^DEF' "$W/d.txt" | grep -v ' LOCAL ' | sort -k5 >> "$OUT"
done
"""

def _elf_report_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("elf_report.txt")
    ctx.actions.run(_sh(tc, _ELF_REPORT_SCRIPT, ctx.attrs.tool[RunInfo], out.as_output(), ctx.attrs.version_script, ctx.attrs.libs), category = "elf_report")
    return [DefaultInfo(default_output = out)]

_elf_report = rule(impl = _elf_report_impl, attrs = {
    "libs": attrs.list(attrs.source()),
    "tool": attrs.exec_dep(providers = [RunInfo]),
    "toolchain": _TC,
    "version_script": attrs.source(),
})

elf_report = declares_docs(_elf_report)

def _native_probe2_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    files = {
        "lib/libkomira_native.so": ctx.attrs.shared,
        "lib/libkomira_native.so.1": ctx.attrs.shared,
        "lib/libkomira_native_leaky.so": ctx.attrs.leaky,
        "lib/libkomira_native_leaky.so.1": ctx.attrs.leaky,
    }
    for name, pkg in ctx.attrs.mojoc.items():
        files["lib/mojo/{}.mojoc".format(name)] = pkg
    prefix = ctx.actions.copied_dir("prefix", files)
    srcs = ctx.actions.copied_dir("consumers", {s.basename: s for s in ctx.attrs.consumers})
    wd_idle = str(tc.watchdog_idle_secs) if tc.watchdog_idle_secs != None else "300"
    wd_sample = str(tc.watchdog_sample_secs) if tc.watchdog_sample_secs != None else "30"
    logs = []
    subs = {}
    for case in ctx.attrs.cases:
        log = ctx.actions.declare_output("logs/{}.log".format(case))
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
                prefix,
                srcs,
                tc.runtime,
                ctx.attrs.tool[RunInfo],
                case,
                log.as_output(),
            ),
            category = "native_probe2",
            identifier = case,
        )
        logs.append(log)
        subs[case] = [DefaultInfo(default_output = log)]
    report = ctx.actions.declare_output("report.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", "-c", "out=$1; shift; \"$0\" cat \"$@\" > \"$out\"", tc.busybox, report.as_output(), ctx.attrs.extra_logs, logs),
        category = "native_probe2_report",
    )
    subs["prefix"] = [DefaultInfo(default_output = prefix)]
    return [DefaultInfo(default_output = report, sub_targets = subs)]

_native_probe2 = rule(impl = _native_probe2_impl, attrs = {
    "cases": attrs.list(attrs.string()),
    "consumers": attrs.list(attrs.source()),
    # Logs put at the head of the report (the link logs, the export report).
    "extra_logs": attrs.list(attrs.source(), default = []),
    "leaky": attrs.source(),
    # .mojoc name in lib/mojo -> the mojo_library producing it.
    "mojoc": attrs.dict(attrs.string(), attrs.source()),
    "script": attrs.source(),
    "shared": attrs.source(),
    "tool": attrs.exec_dep(providers = [RunInfo]),
    "toolchain": _TC,
})

native_probe2 = declares_docs(_native_probe2)
