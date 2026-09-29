"""The glibc loader's own record of what the compiler loads.

Runs one real compile through the real wrapper, then the built binary through
the real `launch.sh`, both with `LD_DEBUG=libs`, and reports every file the
loader mapped and initialized in each (`compile init <file>`, `run init
<file>`), with the toolchain directory written as `<toolchain>`.
tools/build/checks/run_checks.sh reads the report; it is a diagnostic output, not part of any build.
"""

load("@mojo//:providers.bzl", "MojoToolchainInfo")
load("@mojo//:toolchain.bzl", "busybox_sh")

_SCRIPT = """
BB="$1"; WRAPPER="$2"; LAUNCHER="$3"; TC="$4"; ZIG="$5"; CCT="$6"; CPU="$7"; SRC="$8"; OUT="$9"; REPORT="${10}"
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
D="$PWD/.komira_ldtrace"
"$BB" mkdir -p "$D/bin"; "$BB" --install -s "$D/bin"; PATH="$D/bin"
mkdir "$D/compile" "$D/run"
crc=0
LD_DEBUG=libs LD_DEBUG_OUTPUT="$D/compile/ld" \\
    "$BB" sh "$WRAPPER" "$BB" "$TC" "$ZIG" "$CCT" -- build --target-cpu "$CPU" "$SRC" -o "$OUT" || crc=$?
rrc=-
if [ "$crc" = 0 ]; then
    rrc=0
    LD_DEBUG=libs LD_DEBUG_OUTPUT="$D/run/ld" "$BB" sh "$LAUNCHER" "$BB" "$TC" "$OUT" > "$D/stdout" || rrc=$?
fi
# `calling init: <file>` is printed once per object the loader mapped and
# initialized, so these lines name files actually loaded, never a file only tried.
inits() {
  cat "$D/$1"/ld.* 2> /dev/null | grep 'calling init: ' | sed "s|.*calling init: |$1 init |; s|$PWD/$TC/|<toolchain>/|" | sort -u
}
{
  echo "compile rc=$crc"
  echo "run rc=$rrc"
  inits compile
  inits run
} > "$REPORT"
rm -rf "$D"
[ "$crc" = 0 ] && [ "$rrc" = 0 ]
"""

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    exe = ctx.actions.declare_output("hello")
    report = ctx.actions.declare_output("loader_report.txt")
    ctx.actions.run(
        busybox_sh(
            tc.busybox,
            _SCRIPT,
            tc.wrapper,
            tc.launcher,
            tc.compiler,
            tc.zig,
            tc.cc_target,
            tc.target_cpu,
            ctx.attrs.src,
            exe.as_output(),
            report.as_output(),
        ),
        category = "compiler_loader_trace",
    )
    return [DefaultInfo(default_output = report)]

compiler_loader_trace = rule(impl = _impl, attrs = {
    "src": attrs.source(),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
})
