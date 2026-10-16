"""Packaging for Mojo programs: the bundle every package format is made from.

`load("@komira//tools/build/package:defs.bzl", "mojo_bundle")`

    mojo_bundle(name, binary, version, data = {"share/<path>": <source>}, program = None)

builds `<name>/`, the program and everything it needs besides glibc and the
kernel, for the target platform (linux x86_64):

    bin/<program>                              launcher (baseline x86-64)
    bin/<helper>                               the binary's `helpers`, if any
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
/proc/self/exe: `<dirname>/../share`. `program` names the program in the
bundle (`bin/<program>`, `lib<program>.so`); by default it is the name of the
`binary` target.

Sub-targets: `[test_launcher]` is the same launcher built with the test hook
(it judges the made-up CPU named by $KOMIRA_TEST_CPU); it is never part of
the bundle. `[launcher]` is the shipped one. `[kcov_guard]` is the output of
the kcov guard over the bundle (kcov_guard.bzl): built with the bundle, and an
input of `bundle_tarball` and `oci_image`, so no format packs a bundle that
holds kcov.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/mojo:download.bzl", "pinned_file")
load("@komira//tools/build/mojo:providers.bzl", "MojoProgramInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load(":kcov_guard.bzl", "KcovGuardInfo", "kcov_guard")

# x86-64 levels: target_cpu -> the level the launcher requires.
_LEVELS = {
    "x86-64-v2": 2,
    "x86-64-v3": 3,
    "x86-64-v4": 4,
}

_CC_TARGET = "x86_64-linux-gnu.2.34"

# What every package format reads from a bundle.
# dir: the bundle directory; kcov_guard: the output of the kcov guard over it
# (kcov_guard.bzl), an input of every action that packs `dir`; name: the
# program (bin/<name>); platform: e.g. linux-x86_64; version: the package
# version.
BundleInfo = provider(fields = ["dir", "kcov_guard", "name", "platform", "version"])

def _launcher(ctx, out_name, program, level, test_hook):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs._zig[DefaultInfo].default_outputs[0]
    src = ctx.attrs._launcher_sources[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(out_name)
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
            _CC_TARGET,
            "-mcpu=baseline",
            "-O2",
            "-fno-stack-protector",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            src,
            '-DKOMIRA_NAME="' + program + '"',
            "-DKOMIRA_MIN_LEVEL=" + str(level),
            ["-DKOMIRA_TEST_CPU_HOOK"] if test_hook else [],
            "-Wl,--enable-new-dtags",
            "-Wl,-rpath,$ORIGIN/../lib",
            "-Wl,--strip-all",
            "-Wl,--build-id=none",
            "-o",
            out.as_output(),
            cmd_args(src, format = "{}/launcher.c"),
        ),
        category = "komira_launcher",
        identifier = out_name,
    )
    return out

def _bundle_impl(ctx):
    prog = ctx.attrs.binary[MojoProgramInfo]
    # `program` names the program in the bundle (bin/<program>,
    # lib<program>.so); by default the binary target's name.
    name = ctx.attrs.program or prog.name
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
        data_args.append(cmd_args("--file", dest, src))
    # The binary's `helpers` (tools/build/mojo/helpers.bzl): bin/<helper>,
    # mode 0755, beside the launcher.
    for helper, src in sorted(prog.helpers.items()):
        if helper == name:
            fail("{}: helper `{}` has the program's name; bin/{} is the launcher".format(ctx.label, helper, name))
        data_args.append(cmd_args("--file", "bin/" + helper, src))

    version_lines = sorted([
        "cpu_levels=" + prog.target_cpu,
        "min_cpu=" + prog.target_cpu,
        "name=" + name,
        "platform=linux-x86_64",
        "version=" + ctx.attrs.version,
    ])
    version = ctx.actions.write(ctx.label.name + ".VERSION", "\n".join(version_lines) + "\n")

    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pkg_act[RunInfo],
            "bundle",
            "--out",
            out.as_output(),
            "--name",
            name,
            "--cpu",
            prog.target_cpu,
            "--launcher",
            launcher,
            "--so",
            prog.shared,
            "--runtime",
            prog.runtime,
            "--version",
            version,
            data_args,
        ),
        category = "komira_bundle",
    )
    # No file of the bundle is kcov (kcov_guard.bzl): built with the bundle,
    # and an input of each format that packs it.
    guarded = kcov_guard(ctx, ctx.attrs._kcov_guard, ctx.label.name, [[".", out]])
    return [
        DefaultInfo(
            default_output = out,
            other_outputs = [guarded],
            sub_targets = {
                "kcov_guard": [DefaultInfo(default_output = guarded)],
                "launcher": [DefaultInfo(default_output = launcher)],
                "test_launcher": [DefaultInfo(default_output = test_launcher)],
            },
        ),
        BundleInfo(dir = out, kcov_guard = guarded, name = name, platform = "linux-x86_64", version = ctx.attrs.version),
    ]

_mojo_bundle = rule(
    impl = _bundle_impl,
    attrs = {
        "binary": attrs.dep(providers = [MojoProgramInfo]),
        # bundle path under share/ -> file
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # the program's name in the bundle; None: the binary's
        "program": attrs.option(attrs.string(), default = None),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_kcov_guard": attrs.exec_dep(default = "komira//tools/build/package:kcov_guard", providers = [KcovGuardInfo]),
        "_launcher_sources": attrs.dep(default = "komira//tools/build/package/launcher:sources"),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
        "_zig": attrs.exec_dep(default = "komira//tools/build/toolchains:zig"),
        "_zig_launch": attrs.exec_dep(default = "komira//tools/build/mojo:zig_launch", providers = [RunInfo]),
    },
)

def mojo_bundle(**kwargs):
    # Compiling the launcher and copying files, with linux x86_64 tools.
    _mojo_bundle(exec_compatible_with = LINUX_X86_64, **kwargs)

def _level_test_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs._zig[DefaultInfo].default_outputs[0]
    src = ctx.attrs._launcher_sources[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    exe = ctx.actions.declare_output(ctx.label.name)
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
            "-static",
            "-mcpu=baseline",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            src,
            "-o",
            exe.as_output(),
            cmd_args(src, format = "{}/level_test.c"),
        ),
        env = rerun_env(ctx),
        category = "launcher_level_test_build",
    )
    # The program's report is shown whatever it decided; the target is red
    # when it exits non-zero.
    ctx.actions.run(
        cmd_args(ctx.attrs._pkg_act[RunInfo], "level-run", out.as_output(), exe),
        env = rerun_env(ctx),
        category = "launcher_level_test",
    )
    return [DefaultInfo(default_output = out, sub_targets = {"bin": [DefaultInfo(default_output = exe)]}), rerun_info(ctx)]

# Builds and runs level_test.c (remotely): the launcher's level function
# against made-up CPUs. Building it fails on any wrong level. [bin] is the
# static test program: tools/build/tests/functional/glibc_level.sh runs it on a host and compares
# its level for the host's CPU with the host's glibc loader. (Not done here: a
# build action must not read the worker's /lib64, and its cached result would
# not measure the next worker anyway.)
launcher_level_test_rule = rule(
    impl = _level_test_impl,
    attrs = {
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_launcher_sources": attrs.dep(default = "komira//tools/build/package/launcher:sources"),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
        "_zig": attrs.exec_dep(default = "komira//tools/build/toolchains:zig"),
        "_zig_launch": attrs.exec_dep(default = "komira//tools/build/mojo:zig_launch", providers = [RunInfo]),
    } | RERUN_ATTRS,
)

# ---- package formats over a bundle ------------------------------------------
#
# Each format is a file (or directory) made from the bundle by komira_pack
# (tools/build/package/pack/komira_pack.zig), a static tool run remotely with no shell and
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
            # Packed only after the kcov guard passed over the bundle.
            hidden = [b.kcov_guard],
        ),
        category = "komira_pack_tar",
    )
    return [DefaultInfo(default_output = out)]

_bundle_tarball = rule(
    impl = _bundle_tarball_impl,
    attrs = {
        "bundle": attrs.dep(providers = [BundleInfo]),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
    },
)

def bundle_tarball(**kwargs):
    """`<name>-<version>-<platform>.tar.gz`: the bundle under `<name>-<version>/`.

    Entries sorted, mtime 0, uid/gid 0, modes 0755/0644; the same bundle
    gives the same bytes.
    """
    _bundle_tarball(exec_compatible_with = LINUX_X86_64, **kwargs)

# manifest: the base image manifest (linux/amd64); manifest_digest: its pinned
# digest (komira_pack checks it); config: its config blob; layers: its layer
# blobs, in manifest order.
OciBaseInfo = provider(fields = ["config", "layers", "manifest", "manifest_digest"])

# layout: an image's OCI layout directory; layers: its `[layers]` file.
OciImageInfo = provider(fields = ["layout", "layers"])

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

def _is_digest(d):
    return type(d) == "string" and regex_match("^sha256:[0-9a-f]{64}$", d)

def oci_base_refusals(manifest, config, layers, layer_sizes):
    """Why `oci_base` refuses these pins: a list of messages, empty when it accepts them.

    The image is pinned by digest only: `manifest`, `config` and each of
    `layers` must be a `sha256:<64 hex>` digest, so a tag (`debian:12`,
    `nonroot`, `latest`) or a reference holding one is refused; there is no
    tag field. The same check `oci_base` fails on, callable from a load-time
    case.
    """
    out = []
    for what, d in [("manifest", manifest), ("config", config)]:
        if not _is_digest(d):
            out.append("{} `{}` is not a sha256:<64 hex> digest (a base is pinned by digest, never by tag)".format(what, d))
    if not layers:
        out.append("no layers")
    for i, d in enumerate(layers):
        if not _is_digest(d):
            out.append("layer {} `{}` is not a sha256:<64 hex> digest (a base is pinned by digest, never by tag)".format(i, d))
    if len(layer_sizes) != len(layers):
        out.append("{} layers but {} layer_sizes".format(len(layers), len(layer_sizes)))
    return out

def _sha256_of(digest):
    return digest[len("sha256:"):]

def oci_base(name, registry, repository, manifest, manifest_file, config, config_size, layers, layer_sizes, visibility = None):
    """A base image pinned by digest: the manifest in the repo, one pinned download per blob.

    `manifest` is the digest of the single-platform (linux/amd64) image
    manifest and `manifest_file` its bytes, checked in: a registry serves a
    manifest only to a client that sends an Accept header, and the build's
    downloader sends none. komira_pack refuses unless the file hashes to
    `manifest`. `config` and `layers` are the digests the manifest names, in
    order; each URL names its digest and each download is checked against it,
    so the base cannot change without this declaration changing. komira_pack
    also refuses unless the manifest names exactly these blobs. `config_size`
    and `layer_sizes` are the blobs' sizes in bytes, as the manifest states
    them, so the downloads need no request to the registry while the remote
    cache holds them.
    """
    refusals = oci_base_refusals(manifest, config, layers, layer_sizes)
    if refusals:
        fail("oci_base {}: {}".format(name, "; ".join(refusals)))
    base_url = "https://{}/v2/{}/".format(registry, repository)
    pinned_file(
        name = name + "_config",
        url = base_url + "blobs/" + config,
        sha256 = _sha256_of(config),
        size_bytes = config_size,
    )
    layer_targets = []
    for i, d in enumerate(layers):
        pinned_file(
            name = "{}_layer_{}".format(name, i),
            url = base_url + "blobs/" + d,
            sha256 = _sha256_of(d),
            size_bytes = layer_sizes[i],
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

# dir: a directory to lay at / in an image; kcov_guard: the guard's output
# over it; name, version: what the image's history and tag say.
OciTreeInfo = provider(fields = ["dir", "kcov_guard", "name", "version"])

def _oci_tree_impl(ctx):
    args = []
    for prefix, dep in sorted(ctx.attrs.bundles.items()):
        b = dep[BundleInfo]
        # komira-limit:image-linux-x86-64-only
        if b.platform != "linux-x86_64":
            fail("{}: a {} bundle; only linux-x86_64 (linux/amd64) is supported".format(ctx.label, b.platform))
        args.extend(["--bundle", cmd_args(prefix, b.dir, delimiter = "=")])
    for path, src in sorted(ctx.attrs.files.items()):
        args.extend(["--file", cmd_args(path, src, delimiter = "=")])
    if not regex_match("^[0-9A-Za-z][0-9A-Za-z.+~-]*$", ctx.attrs.version):
        fail("{}: version `{}` is not a plain version string".format(ctx.label, ctx.attrs.version))

    # The paths are refused by the Zig tool (komira_oci tree: none may be
    # inside another, each must be plain); a refused tree fails this action.
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    ctx.actions.run(
        cmd_args(ctx.attrs._oci[RunInfo], "tree", "--out", out.as_output(), args),
        category = "komira_oci_tree",
    )
    # No file of the tree is kcov (kcov_guard.bzl): read by the guard, which
    # oci_image waits for.
    guarded = kcov_guard(ctx, ctx.attrs._kcov_guard, ctx.label.name, [[".", out]])
    return [
        DefaultInfo(default_output = out, other_outputs = [guarded]),
        OciTreeInfo(dir = out, kcov_guard = guarded, name = ctx.label.name, version = ctx.attrs.version),
    ]

_oci_tree = rule(
    impl = _oci_tree_impl,
    attrs = {
        # path in the tree, ending in / -> a bundle copied there whole
        "bundles": attrs.dict(attrs.string(), attrs.dep(providers = [BundleInfo]), default = {}),
        # path in the tree -> a file copied there
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "version": attrs.string(),
        "_kcov_guard": attrs.exec_dep(default = "komira//tools/build/package:kcov_guard", providers = [KcovGuardInfo]),
        "_oci": attrs.exec_dep(default = "komira//tools/build/package/oci:komira_oci", providers = [RunInfo]),
    },
)

def oci_tree(**kwargs):
    """A directory laid at / in an image: bundles and files at paths, none inside another.

    `bundles` maps a path ending in / to a bundle copied there whole;
    `files` maps a path to a file. Modes are 0755 for directories and files
    with an exec bit, else 0644. A path that is not plain, or is inside
    another, fails the build (`komira_oci tree`, oci/README.md). The kcov
    guard reads every file of the tree, and `oci_image(tree = ...)` packs it
    only after the guard passed.
    """
    _oci_tree(exec_compatible_with = LINUX_X86_64, **kwargs)

def _oci_image_impl(ctx):
    if (ctx.attrs.bundle == None) == (ctx.attrs.tree == None):
        fail("{}: name exactly one of `bundle` and `tree`".format(ctx.label))
    if (ctx.attrs.tree == None) != (ctx.attrs.entrypoint == None):
        fail("{}: `entrypoint` goes with `tree`, and only with it".format(ctx.label))
    if ctx.attrs.entrypoint != None and (len(ctx.attrs.entrypoint) < 2 or not ctx.attrs.entrypoint.startswith("/")):
        fail("{}: entrypoint `{}` is not an absolute path".format(ctx.label, ctx.attrs.entrypoint))
    if ctx.attrs.bundle != None:
        b = ctx.attrs.bundle[BundleInfo]
        # komira-limit:image-linux-x86-64-only
        if b.platform != "linux-x86_64":
            fail("{}: an image of a {} bundle; only linux-x86_64 (linux/amd64) is supported".format(ctx.label, b.platform))
        # komira_pack (zig): the bundle at /opt/<name>/.
        tool, category = [ctx.attrs._pack[RunInfo], "oci", "--bundle", b.dir], "komira_pack_oci"
        name, version, guard, platform = b.name, b.version, b.kcov_guard, b.platform
        # The release member is the bundle's program.
        member, member_from = b.name, "the bundle's program"
    else:
        t = ctx.attrs.tree[OciTreeInfo]
        # komira_oci (zig): the tree at /.
        bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
        tool = [ctx.attrs._oci[RunInfo], "image", "--tree", t.dir, "--entrypoint", ctx.attrs.entrypoint, "--busybox", bb]
        category = "komira_oci_image"
        # oci_tree takes only linux-x86_64 bundles, and the image is linux/amd64.
        name, version, guard, platform = t.name, t.version, t.kcov_guard, "linux-x86_64"
        # The release member is the image, not the tree (one tree can make
        # several images): the last segment of its repository, as written.
        member = ctx.attrs.repository.split("/")[-1]
        member_from = "the last segment of the repository"
    if not regex_match("^[a-z0-9]+([._/-][a-z0-9]+)*$", ctx.attrs.repository):
        fail("{}: repository `{}` is not an image repository name".format(ctx.label, ctx.attrs.repository))
    base = ctx.attrs.base[OciBaseInfo]
    layout = ctx.actions.declare_output(ctx.label.name + ".oci", dir = True)
    archive = ctx.actions.declare_output(ctx.label.name + ".docker.tar")
    digest = ctx.actions.declare_output(ctx.label.name + ".digest")
    layer_list = ctx.actions.declare_output(ctx.label.name + ".layers")
    layer_args = []
    for l in base.layers:
        layer_args.extend(["--layer", l])
    ctx.actions.run(
        cmd_args(
            tool,
            "--name",
            name,
            "--version",
            version,
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
            # Packed only after the kcov guard passed over the bundle or tree.
            hidden = [guard],
        ),
        category = category,
    )
    # The layer list, read from the manifest by komira_oci, which refuses
    # an Entrypoint that is not a 0755 regular file of the added layer: on
    # the default output, so no image builds without it.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._oci[RunInfo],
            "layers",
            "--layout",
            layout,
            "--busybox",
            ctx.attrs._busybox[DefaultInfo].default_outputs[0],
            "--out",
            layer_list.as_output(),
        ),
        category = "oci_layers",
    )
    # [release]: the layout plus kci's artifact manifest, the directory a
    # BUILD step copies into the release set (`--out <release_dir>/<name>`).
    # The manifest is written from the digest the image action wrote, in the
    # bytes kci's `render_artifact_manifest` writes (src/kci_artifact_manifest):
    # type OCI, the member name (the bundle's program for a bundle image, the
    # repository's last segment for a tree image), `file` the layout
    # directory, `sha256` the image manifest digest's hex. kci's
    # `verify_member` reads it back over the real hello_image and
    # hello_root_image (src/kci_release_set/tests/test_oci_member.mojo).
    manifest = ctx.actions.declare_output(ctx.label.name + ".release_manifest.json")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._pkg_act[RunInfo],
            "oci-release-manifest",
            "--out",
            manifest.as_output(),
            "--digest",
            digest,
            "--name",
            member,
            "--version",
            version,
            "--platform",
            platform,
            "--file",
            layout.basename,
            "--label",
            str(ctx.label.raw_target()),
            "--repo",
            ctx.attrs.repository,
            "--from",
            member_from,
        ),
        category = "oci_release_manifest",
    )
    release = ctx.actions.copied_dir(ctx.label.name + ".release", {
        "manifest.json": manifest,
        layout.basename: layout,
    })
    return [
        DefaultInfo(
            default_output = layout,
            other_outputs = [layer_list],
            sub_targets = {
                "digest": [DefaultInfo(default_output = digest)],
                "docker_archive": [DefaultInfo(default_output = archive)],
                "layers": [DefaultInfo(default_output = layer_list)],
                "release": [DefaultInfo(
                    default_output = release,
                    sub_targets = {"manifest": [DefaultInfo(default_output = manifest)]},
                )],
            },
        ),
        OciImageInfo(layout = layout, layers = layer_list),
    ]

# The artifact manifest of an image (`oci_image[release]`) is written by
# `pkg_act oci-release-manifest` (tools/build/package/act/misc.zig): compact
# JSON in the key order of kci's `render_artifact_manifest`, one trailing
# newline. It refuses, naming the reason, a digest that is not `sha256:<64
# lowercase hex>`, and a member name that is not a kci artifact name
# ([a-z][a-z0-9_]*: the release set keys members by it), naming the image, its
# repository and where the name came from. The name is refused, never
# rewritten: a repository whose last segment has a hyphen or a dot
# (`komira/oci-check`) is a valid image but has no `[release]`. The version and
# the layout's name are plain (mojo_bundle, oci_tree and buck2 refuse anything
# else), so nothing needs escaping.

_oci_image = rule(
    impl = _oci_image_impl,
    attrs = {
        "base": attrs.dep(providers = [OciBaseInfo], default = "komira//tools/build/toolchains:distroless_base"),
        "bundle": attrs.option(attrs.dep(providers = [BundleInfo]), default = None),
        "entrypoint": attrs.option(attrs.string(), default = None),
        "repository": attrs.string(),
        "tree": attrs.option(attrs.dep(providers = [OciTreeInfo]), default = None),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_oci": attrs.exec_dep(default = "komira//tools/build/package/oci:komira_oci", providers = [RunInfo]),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
        "_pkg_act": attrs.exec_dep(default = "komira//tools/build/package:pkg_act", providers = [RunInfo]),
    },
)

def oci_image(**kwargs):
    """An OCI image: the base's layers plus one layer, the bundle at /opt/<name>/ or a tree at /.

    `bundle`: the layer holds the bundle at /opt/<name>/, entrypoint
    /opt/<name>/bin/<name> (written by `komira_pack oci`). `tree` (an
    `oci_tree`) with `entrypoint`: the layer holds the tree at /, and the
    entrypoint, an absolute path, must be a regular file of the tree with
    mode 0755 (refused otherwise; written by `komira_oci image`).
    The default output is an OCI image layout directory (`index.json` names
    it `<repository>:<version>`). `[docker_archive]` is the same as one tar
    plus a Docker `manifest.json`, which `docker load` reads; `[digest]`
    holds the manifest digest; `[layers]` the digest of each layer of the
    manifest, one per line, in order. `[release]` is what a release set
    holds: the layout and kci's artifact manifest (`manifest.json`: type
    OCI, name the bundle's program for a `bundle` image and the last segment
    of `repository` for a `tree` image, `file` the layout directory,
    `sha256` the hex of `[digest]`); `[release][manifest]` is that manifest
    alone. A name that is not a kci artifact name ([a-z][a-z0-9_]*, so no
    hyphen or dot) fails building `[release]`, naming the image and its
    repository; it is never rewritten. Nothing is pushed.
    """
    _oci_image(exec_compatible_with = LINUX_X86_64, **kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
bundle_tarball = declares_docs(bundle_tarball)
launcher_level_test = declares_docs(launcher_level_test_rule)
mojo_bundle = declares_docs(mojo_bundle)
oci_base = declares_docs(oci_base)
oci_image = declares_docs(oci_image)
oci_tree = declares_docs(oci_tree)
