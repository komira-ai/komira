"""A remote action that records what the worker provides.

Everything it inspects outside its own inputs is host state; the report is
the evidence behind the host floor documented in tools/build/toolchains/README.md.
"""

load("@mojo//:providers.bzl", "MojoToolchainInfo")
load("@mojo//:toolchain.bzl", "busybox_sh")

_SCRIPT = """
BB="$1"; TC="$2"; OUT="$3"
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
T="$PWD/.komira_action"; "$BB" mkdir -p "$T/bin"; "$BB" --install -s "$T/bin"; PATH="$T/bin"
{
  echo "== inherited environment"; env | sort
  echo "== host paths"
  for p in /bin/sh /usr/bin/python3 /usr/bin/zstd /usr/bin/unzip /usr/bin/xz /usr/bin/sed /usr/bin/cc; do
    if [ -e "$p" ]; then echo "present $p"; else echo "absent  $p"; fi
  done
  echo "== /etc/os-release"; cat /etc/os-release 2>&1 | grep -E '^(ID|VERSION_ID)=' || true
  echo "== dynamic loader view of bin/mojo"
  /lib64/ld-linux-x86-64.so.2 --list "$TC/bin/mojo" 2>&1 | sed 's/ (0x[0-9a-f]*)//' || echo "loader failed rc=$?"
  echo "== CLOSURE_MANIFEST"; cat "$TC/CLOSURE_MANIFEST"
  echo "== nproc $(nproc)"
} > "$OUT" 2>&1
rm -rf "$T"
"""

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("report.txt")
    ctx.actions.run(busybox_sh(tc.busybox, _SCRIPT, tc.compiler, out.as_output()), category = "re_probe")
    return [DefaultInfo(default_output = out)]

re_probe = rule(impl = _impl, attrs = {"toolchain": attrs.toolchain_dep(providers = [MojoToolchainInfo])})
