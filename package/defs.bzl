"""Packaging for Mojo programs: the bundle every package format is made from.

`load("@komira//package:defs.bzl", "mojo_bundle")`

    mojo_bundle(name, binary, version, data = {"share/<path>": <source>})

builds `<name>/`, the program and everything it needs besides glibc and the
kernel, for the target platform (linux x86_64):

    bin/<program>                              launcher (baseline x86-64)
    lib/glibc-hwcaps/<target_cpu>/lib<program>.so   the program
    lib/<runtime libraries>                    Mojo runtime, C++ runtime
    share/...                                  `data`
    VERSION                                    sorted key=value lines
    SHA256SUMS                                 every other file, sorted by path

The launcher checks the CPU's x86-64 level against the level the program was
compiled for (the toolchain's `target_cpu`, the one setting behind the compile
flag, the directory name and the check), refuses with one line naming it when
the CPU is below it, and otherwise loads the program through the loader's
glibc-hwcaps search. Every run path is `$ORIGIN`-relative, so the bundle runs
from wherever it is copied. A program finds its data through
/proc/self/exe: `<dirname>/../share`.

Sub-targets: `[test_launcher]` is the same launcher built with the test hook
(it judges the made-up CPU named by $KOMIRA_TEST_CPU); it is never part of
the bundle. `[launcher]` is the shipped one.
"""

load("@mojo//:download.bzl", "pinned_file")
load("@mojo//:providers.bzl", "MojoProgramInfo")
load("@mojo//:toolchain.bzl", "busybox_sh")

# x86-64 levels: target_cpu -> the level the launcher requires.
_LEVELS = {
    "x86-64-v2": 2,
    "x86-64-v3": 3,
    "x86-64-v4": 4,
}

_CC_TARGET = "x86_64-linux-gnu.2.34"

# What every package format reads from a bundle.
# dir: the bundle directory; name: the program (bin/<name>); platform: e.g.
# linux-x86_64; version: the package version.
BundleInfo = provider(fields = ["dir", "name", "platform", "version"])

_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
T="$PWD/.komira_action"
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

def _launcher(ctx, out_name, program, level, test_hook):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs._zig[DefaultInfo].default_outputs[0]
    src = ctx.attrs._launcher_sources[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(out_name)
    script = _PRELUDE + """
ZIG="$1"; SRC="$2"; OUT="$3"; NAME="$4"; LEVEL="$5"; shift 5
case "$ZIG" in /*) ;; *) ZIG="$PWD/$ZIG" ;; esac
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$ZIG/zig" cc -target {cc_target} -mcpu=baseline -O2 -fno-stack-protector \\
    -Wall -Wextra -Werror -I "$SRC" \\
    "-DKOMIRA_NAME=\\"$NAME\\"" "-DKOMIRA_MIN_LEVEL=$LEVEL" "$@" \\
    -Wl,--enable-new-dtags '-Wl,-rpath,$ORIGIN/../lib' -Wl,--strip-all -Wl,--build-id=none \\
    -o "$OUT" "$SRC/launcher.c"
rm -rf "$T"
test -s "$OUT"
""".replace("{cc_target}", _CC_TARGET)
    ctx.actions.run(
        busybox_sh(bb, script, zig, src, out.as_output(), program, str(level), ["-DKOMIRA_TEST_CPU_HOOK"] if test_hook else []),
        category = "komira_launcher",
        identifier = out_name,
    )
    return out

def _bundle_impl(ctx):
    prog = ctx.attrs.binary[MojoProgramInfo]
    name = prog.name
    if not regex_match("^[A-Za-z0-9_][A-Za-z0-9_.+-]*$", name):
        fail("{}: program name `{}` cannot name bin/{} and lib{}.so".format(ctx.label, name, name, name))
    if prog.target_cpu not in _LEVELS:
        fail("{}: target_cpu `{}` is not an x86-64 level ({})".format(ctx.label, prog.target_cpu, ", ".join(_LEVELS.keys())))
    level = _LEVELS[prog.target_cpu]
    if not regex_match("^[0-9A-Za-z][0-9A-Za-z.+~-]*$", ctx.attrs.version):
        fail("{}: version `{}` is not a plain version string".format(ctx.label, ctx.attrs.version))

    launcher = _launcher(ctx, "launcher/" + name, name, level, False)
    test_launcher = _launcher(ctx, "test_launcher/" + name, name, level, True)

    data_args = []
    for dest, src in sorted(ctx.attrs.data.items()):
        if not regex_match("^share/[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$", dest) or "/../" in dest + "/" or "/./" in dest + "/":
            fail("{}: data path `{}` must be a plain relative path under share/".format(ctx.label, dest))
        data_args.extend([dest, src])

    version_lines = sorted([
        "cpu_levels=" + prog.target_cpu,
        "min_cpu=" + prog.target_cpu,
        "name=" + name,
        "platform=linux-x86_64",
        "version=" + ctx.attrs.version,
    ])
    version = ctx.actions.write(ctx.label.name + ".VERSION", "\n".join(version_lines) + "\n")

    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    script = _PRELUDE + """
OUT="$1"; NAME="$2"; CPU="$3"; LAUNCHER="$4"; SO="$5"; RUNTIME="$6"; VERSION="$7"; shift 7
mkdir -p "$OUT/bin" "$OUT/lib/glibc-hwcaps/$CPU"
cp "$LAUNCHER" "$OUT/bin/$NAME"
cp "$SO" "$OUT/lib/glibc-hwcaps/$CPU/lib$NAME.so"
for f in "$RUNTIME"/*; do cp "$f" "$OUT/lib/"; done
while [ "$#" -gt 0 ]; do
    mkdir -p "$OUT/$(dirname "$1")"
    cp "$2" "$OUT/$1"
    shift 2
done
cp "$VERSION" "$OUT/VERSION"
find "$OUT" -type d -exec chmod 0755 {} +
find "$OUT" -type f -exec chmod 0644 {} +
chmod 0755 "$OUT/bin/$NAME"
cd "$OUT"
find . -type f | sed 's|^\\./||' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done > "$T/sums"
mv "$T/sums" SHA256SUMS
chmod 0644 SHA256SUMS
cd /
rm -rf "$T"
"""
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        busybox_sh(bb, script, out.as_output(), name, prog.target_cpu, launcher, prog.shared, prog.runtime, version, data_args),
        category = "komira_bundle",
    )
    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {
                "launcher": [DefaultInfo(default_output = launcher)],
                "test_launcher": [DefaultInfo(default_output = test_launcher)],
            },
        ),
        BundleInfo(dir = out, name = name, platform = "linux-x86_64", version = ctx.attrs.version),
    ]

_mojo_bundle = rule(
    impl = _bundle_impl,
    attrs = {
        "binary": attrs.dep(providers = [MojoProgramInfo]),
        # bundle path under share/ -> file
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "toolchains//:busybox"),
        "_launcher_sources": attrs.dep(default = "komira//package/launcher:sources"),
        "_zig": attrs.exec_dep(default = "toolchains//:zig"),
    },
)

def mojo_bundle(**kwargs):
    # Compiling the launcher and copying files: light work.
    _mojo_bundle(exec_compatible_with = ["komira//platforms:light"], **kwargs)

def _level_test_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs._zig[DefaultInfo].default_outputs[0]
    src = ctx.attrs._launcher_sources[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    exe = ctx.actions.declare_output(ctx.label.name)
    script = _PRELUDE + """
ZIG="$1"; SRC="$2"; OUT="$3"; EXE="$4"
case "$ZIG" in /*) ;; *) ZIG="$PWD/$ZIG" ;; esac
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$ZIG/zig" cc -target x86_64-linux-musl -static -mcpu=baseline -O2 -Wall -Wextra -Werror \\
    -I "$SRC" -o "$EXE" "$SRC/level_test.c"
rc=0
"$EXE" > "$OUT" || rc=$?
cat "$OUT" >&2
rm -rf "$T"
exit "$rc"
"""
    ctx.actions.run(busybox_sh(bb, script, zig, src, out.as_output(), exe.as_output()), category = "launcher_level_test")
    return [DefaultInfo(default_output = out, sub_targets = {"bin": [DefaultInfo(default_output = exe)]})]

# Builds and runs level_test.c (remotely): the launcher's level function
# against made-up CPUs. Building it fails on any wrong level. [bin] is the
# static test program: checks/glibc_level.sh runs it on a host and compares
# its level for the host's CPU with the host's glibc loader. (Not done here: a
# build action must not read the worker's /lib64, and its cached result would
# not measure the next worker anyway.)
launcher_level_test = rule(
    impl = _level_test_impl,
    attrs = {
        "_busybox": attrs.exec_dep(default = "toolchains//:busybox"),
        "_launcher_sources": attrs.dep(default = "komira//package/launcher:sources"),
        "_zig": attrs.exec_dep(default = "toolchains//:zig"),
    },
)

# ---- package formats over a bundle ------------------------------------------
#
# Each format is a file (or directory) made from the bundle by komira_pack
# (package/pack/komira_pack.zig), a static tool run remotely with no shell and
# no network. The rules only produce files; publishing them is someone else's
# job.

def _bundle_tarball_impl(ctx):
    b = ctx.attrs.bundle[BundleInfo]
    out = ctx.actions.declare_output("{}-{}-{}.tar.gz".format(b.name, b.version, b.platform))
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pack[RunInfo],
            "tar",
            "--bundle",
            b.dir,
            "--prefix",
            "{}-{}/".format(b.name, b.version),
            "--out",
            out.as_output(),
        ),
        category = "komira_pack_tar",
    )
    return [DefaultInfo(default_output = out)]

_bundle_tarball = rule(
    impl = _bundle_tarball_impl,
    attrs = {
        "bundle": attrs.dep(providers = [BundleInfo]),
        "_pack": attrs.exec_dep(default = "komira//package:komira_pack", providers = [RunInfo]),
    },
)

def bundle_tarball(**kwargs):
    """`<name>-<version>-<platform>.tar.gz`: the bundle under `<name>-<version>/`.

    Entries sorted, mtime 0, uid/gid 0, modes 0755/0644; the same bundle
    gives the same bytes.
    """
    _bundle_tarball(exec_compatible_with = ["komira//platforms:light"], **kwargs)

# manifest: the base image manifest (linux/amd64); manifest_digest: its pinned
# digest (komira_pack checks it); config: its config blob; layers: its layer
# blobs, in manifest order.
OciBaseInfo = provider(fields = ["config", "layers", "manifest", "manifest_digest"])

def _oci_base_impl(ctx):
    def one(d):
        return d[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(),
        OciBaseInfo(
            config = one(ctx.attrs.config),
            layers = [one(d) for d in ctx.attrs.layers],
            manifest = ctx.attrs.manifest,
            manifest_digest = ctx.attrs.manifest_digest,
        ),
    ]

_oci_base = rule(
    impl = _oci_base_impl,
    attrs = {
        "config": attrs.dep(),
        "layers": attrs.list(attrs.dep()),
        "manifest": attrs.source(),
        "manifest_digest": attrs.string(),
    },
)

def _sha256_of(digest):
    if not regex_match("^sha256:[0-9a-f]{64}$", digest):
        fail("`{}` is not a sha256:<64 hex> digest".format(digest))
    return digest[len("sha256:"):]

def oci_base(name, registry, repository, manifest, manifest_file, config, layers, visibility = None):
    """A base image pinned by digest: the manifest in the repo, one pinned download per blob.

    `manifest` is the digest of the single-platform (linux/amd64) image
    manifest and `manifest_file` its bytes, checked in: a registry serves a
    manifest only to a client that sends an Accept header, and the build's
    downloader sends none. komira_pack refuses unless the file hashes to
    `manifest`. `config` and `layers` are the digests the manifest names, in
    order; each URL names its digest and each download is checked against it,
    so the base cannot change without this declaration changing. komira_pack
    also refuses unless the manifest names exactly these blobs.
    """
    base_url = "https://{}/v2/{}/".format(registry, repository)
    _sha256_of(manifest)
    pinned_file(
        name = name + "_config",
        url = base_url + "blobs/" + config,
        sha256 = _sha256_of(config),
    )
    layer_targets = []
    for i, d in enumerate(layers):
        pinned_file(
            name = "{}_layer_{}".format(name, i),
            url = base_url + "blobs/" + d,
            sha256 = _sha256_of(d),
        )
        layer_targets.append(":{}_layer_{}".format(name, i))
    _oci_base(
        name = name,
        config = ":" + name + "_config",
        layers = layer_targets,
        manifest = manifest_file,
        manifest_digest = manifest,
        visibility = visibility,
    )

def _oci_image_impl(ctx):
    b = ctx.attrs.bundle[BundleInfo]
    if b.platform != "linux-x86_64":
        fail("{}: an image of a {} bundle; only linux-x86_64 (linux/amd64) is supported".format(ctx.label, b.platform))
    if not regex_match("^[a-z0-9]+([._/-][a-z0-9]+)*$", ctx.attrs.repository):
        fail("{}: repository `{}` is not an image repository name".format(ctx.label, ctx.attrs.repository))
    base = ctx.attrs.base[OciBaseInfo]
    layout = ctx.actions.declare_output(ctx.label.name + ".oci", dir = True)
    archive = ctx.actions.declare_output(ctx.label.name + ".docker.tar")
    digest = ctx.actions.declare_output(ctx.label.name + ".digest")
    layer_args = []
    for layer in base.layers:
        layer_args.extend(["--layer", layer])
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pack[RunInfo],
            "oci",
            "--bundle",
            b.dir,
            "--name",
            b.name,
            "--version",
            b.version,
            "--repo",
            ctx.attrs.repository,
            "--manifest",
            base.manifest,
            "--manifest-digest",
            base.manifest_digest,
            "--config",
            base.config,
            layer_args,
            "--out",
            layout.as_output(),
            "--archive",
            archive.as_output(),
            "--digest",
            digest.as_output(),
        ),
        category = "komira_pack_oci",
    )
    return [DefaultInfo(
        default_output = layout,
        sub_targets = {
            "digest": [DefaultInfo(default_output = digest)],
            "docker_archive": [DefaultInfo(default_output = archive)],
        },
    )]

_oci_image = rule(
    impl = _oci_image_impl,
    attrs = {
        "base": attrs.dep(providers = [OciBaseInfo], default = "toolchains//:distroless_base"),
        "bundle": attrs.dep(providers = [BundleInfo]),
        "repository": attrs.string(),
        "_pack": attrs.exec_dep(default = "komira//package:komira_pack", providers = [RunInfo]),
    },
)

def oci_image(**kwargs):
    """An OCI image of a bundle: the base's layers plus the bundle at /opt/<name>/.

    The default output is an OCI image layout directory (`index.json` names
    it `<repository>:<version>`). `[docker_archive]` is the same as one tar
    plus a Docker `manifest.json`, which `docker load` reads; `[digest]`
    holds the manifest digest. Nothing is pushed.
    """
    _oci_image(exec_compatible_with = ["komira//platforms:light"], **kwargs)
