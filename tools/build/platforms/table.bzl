"""The platform table: one row per (os, cpu) komira builds for, and everything else derived from it.

A platform is an (os, cpu) pair. Each row below states, in one place, what a
platform IS: the constraints that name it, the host that selects it, the
`[komira_re]` key of its execution platform's worker property set, how zig
links for it, the CPU floor every compile targets, the object format, what a
built binary loads at run time, the operating-system floor it needs, and
every pinned download its toolchains use (URL, sha256 and size). The detector
(`platforms:host`), the execution platforms (defs.bzl), the toolchains and
the checks that name a platform all read this table; none repeats a row.

Nothing in this file says where an action runs or which worker takes it: a
row names the property KEY, and the value comes from `.buckconfig.local`.

A row declared with `registered = False` is RESERVED: the platform is
designed for and its pins are recorded, but it is not a build key. No
`platform()` target exists for it, no execution platform is registered for
it, a host that looks like it is refused with that reason, and its
`[komira_re]` key is refused if set. Flipping `registered` is the bring-up
change of that platform.

The completeness check at the bottom runs when this file loads, so every
package that reads the table fails to load, naming the row and the pin, the
moment a row is missing one.
"""

# ---- Row vocabulary ----------------------------------------------------------

# `none(reason)`: this platform needs no such pin, stated rather than omitted.
# Allowed only for the roles in `_NONE_ALLOWED`.
def none(reason):
    return {"none": reason}

# `pending(reason)`: this pin is not recorded yet. Allowed only in a row that
# is not `registered`, so nothing a build can reach has one.
def pending(reason):
    return {"pending": reason}

# `image(reference)`: a container image pinned by its digest,
# `<repository>@sha256:<64 lowercase hex>`, pulled by that digest and never by
# a tag. Used by `preflight_image`.
def image(reference):
    return {"image": reference}

# `placeholder(reason)`: an image pin that is NOT recorded yet in a row that is
# registered. Allowed only for `preflight_image`, whose value no build action
# reads: it reaches kci as a flag (--preflight-image), and `preflight_image()`
# hands on `UNPINNED_IMAGE` for it, which kci refuses wherever a DEPLOY_PROBE
# would run. So a placeholder fails closed: no probe runs until the real
# digest replaces it.
def placeholder(reason):
    return {"placeholder": reason}

# The image `preflight_image()` hands on for a placeholder or `none(...)`: a
# well-formed digest reference whose digest is all zeros, on a reserved host
# (RFC 2606), so it is never pulled. kci_validate's PREFLIGHT_UNPINNED_DIGEST
# is that digest.
UNPINNED_IMAGE = "unpinned.invalid/busybox@sha256:" + "0" * 64

# `pin(name, url, sha256, size = <bytes>)`: one sha256-pinned download. `name`
# is the target name of the `pinned_file` that fetches it (an asset name:
# outputs of that target live under it, so renaming one re-keys every action
# that reads it). `size` is the file's length in bytes, required: with it and
# the sha256 buck2 needs no request to the URL unless the remote CAS lacks the
# blob (tools/build/mojo/download.bzl).
def pin(name, url, sha256, executable = False, size = None):
    return {"executable": executable, "name": name, "sha256": sha256, "size": size, "url": url}

# The pinned downloads every registered row must state, by role. `none` is
# allowed where a platform can need nothing (the conda runtime libraries the
# osx-arm64 compiler does not link; the container base of a platform that
# ships no containers; kcov on a platform coverage does not run on).
ASSET_ROLES = [
    "actionlint",
    "busybox",
    "kcov_bzip2",
    "kcov_elfutils",
    "kcov_lzma",
    "kcov_src",
    "kcov_zlib",
    "kcov_zstd",
    "libgcc",
    "libstdcxx",
    "libzlib",
    "llvm_branch_libiconv",
    "llvm_branch_libllvm",
    "llvm_branch_libxml2",
    "llvm_branch_rt",
    "llvm_branch_tools",
    "llvm_branch_zstd",
    "mojo_compiler",
    "pixi",
    "protoc",
    "rust_std",
    "rustc",
    "shellcheck",
    "zig",
]
# kcov, the line coverage tool (tools/build/toolchains/kcov/README.md): its
# source archive and the conda-forge packages holding the static libraries it
# links. Coverage runs on linux-x86_64 only; every other row states `none`.
_KCOV_ROLES = ["kcov_bzip2", "kcov_elfutils", "kcov_lzma", "kcov_src", "kcov_zlib", "kcov_zstd"]
# The LLVM pieces of branch coverage (tools/build/toolchains/llvm_branch/README.md):
# llvm-profdata 23 with the libraries it loads, and the compiler-rt 23 profile
# runtime. linux-x86_64 only, like kcov; every other row states `none`.
_LLVM_BRANCH_ROLES = ["llvm_branch_libiconv", "llvm_branch_libllvm", "llvm_branch_libxml2", "llvm_branch_rt", "llvm_branch_tools", "llvm_branch_zstd"]
_NONE_ALLOWED = ["busybox", "libgcc", "libstdcxx", "libzlib"] + _KCOV_ROLES + _LLVM_BRANCH_ROLES

# Roles whose pin is the executable itself, downloaded with its mode bit set
# and never unpacked: a real pin of one of these must say `executable = True`.
_EXECUTABLE_ROLES = ["busybox", "pixi"]

# Roles every row must pin at one release, read from the `/download/v<version>/`
# segment of the URL: what one platform runs, every other platform runs too.
# pixi defines the environment a release validation installs into, so a Mac
# and the CI runner must use the same pixi.
_ONE_RELEASE_ROLES = ["pixi"]

# Fields of a row, all required. `assets` is checked role by role.
ROW_FIELDS = [
    "applets",  # the utilities a wrapper script may call: a sorted list, or `none(...)` when a pinned busybox carries them
    "assets",  # pinned downloads, by role (ASSET_ROLES)
    "bundles",  # whether bundles, OCI images and the launcher are products of this platform
    "cache_line_bytes",  # the cache line of this platform's CPUs, for padding that avoids false sharing
    "constraints",  # the `platform()` constraint values; the exec_compatible_with of its tools
    "cpu",  # constraint name of the cpu: `x86_64`, `arm64`
    "features",  # what the platform has that tests select on (a test needing one is compatible only with rows listing it)
    "golden_config_hash",  # the configuration hash of this row's platform: what output paths and action keys carry; `pending(...)` for a row with no platform
    "host",  # what host_info() reports on a machine of this platform: {"os": ..., "arch": ...}
    "object_format",  # `elf` or `macho`
    "oci_base",  # the container base (kwargs of `oci_base`), or `none(...)`
    "os",  # constraint name of the os: `linux`, `macos`
    "os_floor",  # the oldest operating system a built binary runs on
    "preflight_image",  # the DEPLOY_PROBE pre-flight's helper image, busybox's linux/amd64 manifest by digest (`image(...)`); `none(...)` on a platform with no container validation; `placeholder(...)` until recorded
    "page_bytes",  # the smallest virtual-memory page of this platform's default kernel
    "pool",  # the `[komira_re]` property that selects the worker pool serving this row, as a client sets it (`pool=<name>`)
    "re_key",  # `[komira_re]` key of the property set of this platform's execution platform
    "registered",  # True: a build key; False: reserved
    "remote_required",  # remote execution refuses to register without this row's property set
    "runtime_libs",  # what a built binary loads from the toolchain's lib/ (the loader's record)
    "target_cpu",  # the CPU every compile targets, whatever worker runs it
    "target_features",  # extra target features every compile enables
    "unpack_triple",  # zig target of the static tools that unpack archives (they only move bytes)
    "zig_exe_sha256",  # sha256 of the `zig` executable inside the zig archive: what the bootstrap checks after unpacking
    "zig_triple",  # zig target of every link of this platform (`<arch>-<os>-<abi>.<os floor>`)
]

_HEX = "0123456789abcdef"

# What a row's `features` may name. A test that needs one is compatible only
# with the rows listing it (never a run-time skip), and the portable half of
# the behaviour runs everywhere.
FEATURES = ["epoll", "erms", "futex", "kqueue", "neon", "thp", "ulock", "x86_simd"]

# ---- The rows ------------------------------------------------------------------

# Why a row pins no kcov (tools/build/toolchains/kcov/README.md).
_KCOV_NONE = "line coverage is measured on linux-x86_64 only (limits.tsv `coverage-linux-x86-64`)"

# Why a row pins no LLVM branch-coverage pieces (tools/build/toolchains/llvm_branch/README.md).
_LLVM_BRANCH_NONE = "branch coverage is measured on linux-x86_64 only (limits.tsv `coverage-linux-x86-64`)"

PLATFORMS = {
    "linux-x86_64": {
        "applets": none("the pinned busybox (assets.busybox) carries every applet"),
        "assets": {
            "actionlint": pin(
                "actionlint_1.7.12_linux_amd64.tar.gz",
                "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz",
                "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
                size = 2353908,
            ),
            "busybox": pin(
                "busybox",
                "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox",
                "6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348",
                size = 1131168,
                executable = True,
            ),
            # kcov v42 (GPL-2.0): the tag's source archive, and the conda-forge
            # packages of the static libraries it links: libdw.a and libelf.a
            # with their headers, zlib's libz.a and zlib.h, and the
            # decompressors libdw.a calls.
            "kcov_bzip2": pin(
                "bzip2_1.0.8_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/bzip2-1.0.8-hda65f42_10.conda",
                "1a0d382c515ebf55f8ee1f38c8b81bc95af5c2acc42ad53b66bc5df932032f96",
                size = 257808,
            ),
            "kcov_elfutils": pin(
                "elfutils_0.194_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/elfutils-0.194-h849f50c_0.conda",
                "f71eae7dc8ff9392d225d2d529691b2db16289b7d8009646eeb1adf0caf3937b",
                size = 1289929,
            ),
            "kcov_lzma": pin(
                "liblzma-static_5.8.3_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/liblzma-static-5.8.3-ha02ee65_1.conda",
                "237563ec760527207b84338807e49e817ac53c3306e566aecaa4fd4a32530b56",
                size = 125751,
            ),
            "kcov_src": pin(
                "kcov-v42.tar.gz",
                "https://github.com/SimonKagstrom/kcov/archive/refs/tags/v42.tar.gz",
                "2c47d75397af248bc387f60cdd79180763e1f88f3dd71c94bb52478f8e74a1f8",
                size = 259243,
            ),
            "kcov_zlib": pin(
                "zlib_1.3.2_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/zlib-1.3.2-h25fd6f3_3.conda",
                "16080a1c7724f7d25727cdc23c7658e0cec2db52448c1dc0c33467ee2c6e1c62",
                size = 96132,
            ),
            "kcov_zstd": pin(
                "zstd-static_1.5.7_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/zstd-static-1.5.7-hb72f32e_7.conda",
                "62e9e4b9274c2c7028e0bcdf80c254ee95499d4860e7c13d8926485d03b0d27b",
                size = 475941,
            ),
            "libgcc": pin(
                "libgcc_15.3.0_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libgcc-15.3.0-h3363355_7.conda",
                "0bb57ee8557aad33317eeb881e3957b6fab776dd75473311c25789fa3a29f792",
                size = 1042438,
            ),
            "libstdcxx": pin(
                "libstdcxx_15.3.0_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-15.3.0-h934c35e_7.conda",
                "0c3dc08bf43357a77297b4449abd0ce1d40a140989f004071e69c04ed13e36bb",
                size = 5836322,
            ),
            "libzlib": pin(
                "libzlib_1.3.1_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.1-hb9d3cd8_2.conda",
                "d4bfe88d7cb447768e31650f06257995601f89076080e76df55e3112d4e47dc4",
                size = 60963,
            ),
            # The LLVM pieces of branch coverage
            # (tools/build/toolchains/llvm_branch/README.md, licences there):
            # llvm-profdata 23.1.3, libLLVM and the libraries it loads, and the
            # compiler-rt 23.1.3 profile runtime, from conda-forge.
            "llvm_branch_libiconv": pin(
                "libiconv_1.18_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libiconv-1.18-h0cb94f2_3.conda",
                "f943117edb9cd4d9c61cc972eee5a34291dc55ea7a6e9e38da104995841cbcb6",
                size = 789471,
            ),
            "llvm_branch_libllvm": pin(
                "libllvm23_23.1.3_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libllvm23-23.1.3-h474f4eb_0.conda",
                "7ce347e2da1502442d4df406101cfaf429927b7a9410badadd3f147d3cbf2d00",
                size = 45082185,
            ),
            "llvm_branch_libxml2": pin(
                "libxml2-16_2.15.4_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libxml2-16-2.15.4-hbdfff7e_0.conda",
                "b6f96287c408269f5067bb4f7a61693ff5c856152902362964d9807152b9c146",
                size = 565717,
            ),
            "llvm_branch_rt": pin(
                "compiler-rt23_linux-64_23.1.3_noarch.conda",
                "https://conda.anaconda.org/conda-forge/noarch/compiler-rt23_linux-64-23.1.3-h0e38de2_0.conda",
                "7a044f184a5ed44fb905882c25ba950ec7a5b53c8f46ad40cba5c1a079d8d6a3",
                size = 46990831,
            ),
            "llvm_branch_tools": pin(
                "llvm-tools-23_23.1.3_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/llvm-tools-23-23.1.3-h7399f5f_0.conda",
                "2d948bde496207d44846b580ab683157305860edadf3dec1a6860073bfd1b837",
                size = 25434792,
            ),
            "llvm_branch_zstd": pin(
                "zstd_1.5.7_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/zstd-1.5.7-hb78ec9c_7.conda",
                "47d682b9f6d6ec9eb1a6e6c3e75ea6273e899e78fb7fc59f81d39745009fbc60",
                size = 601301,
            ),
            "mojo_compiler": pin(
                "mojo_compiler_1.0.0_linux-64.conda",
                "https://conda.modular.com/max-nightly/linux-64/mojo-compiler-1.0.0-release.conda",
                "4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3",
                size = 68511359,
            ),
            # pixi, the raw static (musl) executable of the release: no archive,
            # nothing to unpack. Release validations install into an environment
            # this pixi defines (//tools/build/toolchains:pixi).
            "pixi": pin(
                "pixi-0.67.2-x86_64-unknown-linux-musl",
                "https://github.com/prefix-dev/pixi/releases/download/v0.67.2/pixi-x86_64-unknown-linux-musl",
                "807eabf195b13d6393b832ecccf93bf59bf784425674a60c7b50b1b84a58367f",
                size = 72538704,
                executable = True,
            ),
            "protoc": pin(
                "protoc-29.1-linux-x86_64.zip",
                "https://github.com/protocolbuffers/protobuf/releases/download/v29.1/protoc-29.1-linux-x86_64.zip",
                "00c83fe9722d85e96c81b941b29f17a744b33b4ce66e0f18009fd8937de22c60",
                size = 3288942,
            ),
            "rust_std": pin(
                "rust-std-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rust-std-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "285e105d25ebdf501341238d4c0594ecdda50ec9078f45095f793a736b1f1ac2",
                size = 27989420,
            ),
            "rustc": pin(
                "rustc-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rustc-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "7436f13797475082cd87aa65547449e01659d6a810b4cd5f8aedc48bb9f89dfb",
                size = 72920412,
            ),
            "shellcheck": pin(
                "shellcheck-v0.11.0.linux.x86_64.tar.xz",
                "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz",
                "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
                size = 2559196,
            ),
            "zig": pin(
                "zig_linux_x86_64.tar.xz",
                "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz",
                "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad",
                size = 45480516,
            ),
        },
        "bundles": True,
        "cache_line_bytes": 64,
        "constraints": [
            "prelude//os/constraints:linux",
            "prelude//cpu/constraints:x86_64",
        ],
        "cpu": "x86_64",
        "features": ["epoll", "erms", "futex", "thp", "x86_simd"],
        "golden_config_hash": "03cc1a891c89e4be",
        "host": {"arch": "x86_64", "os": "linux"},
        "object_format": "elf",
        # The base of oci_base: distroless base-debian12 (glibc, CA certificates,
        # tzdata, a nonroot user, no shell), tag `nonroot`, its linux/amd64 image
        # manifest. The manifest is checked in (a registry serves one only to a
        # client sending an Accept header); every blob is one pinned download. The
        # digests are the pin; the sizes are the manifest's.
        "oci_base": {
            "config": "sha256:c31423653c22931f970322b39ef0b1a9395efefa45e4e8d16fc409c286443c0b",
            "config_size": 3147,
            "layers": [
                "sha256:a5789fc40e828c4e7467626e3f69ec5dea8e5da22fe660db8ae6d16f777b0bbf",
                "sha256:990a9c434e5e0f11549a8d4a41a1991e621b04e30cd63269adbc97b1dc38fd7e",
                "sha256:39dc083afc39bd8dc43d456fe7ff7d39292e593bb2769972c11bb2e5f9119386",
                "sha256:bf7a4185f01524837d19abde915ffde84e64368b250f5b5e9f6f75aea62a11d4",
                "sha256:2780920e5dbfbe103d03a583ed75345306e572ec5a48cb10361f046767d9f29a",
                "sha256:7c12895b777bcaa8ccae0605b4de635b68fc32d60fa08f421dc3818bf55ee212",
                "sha256:3214acf345c0cc6bbdb56b698a41ccdefc624a09d6beb0d38b5de0b2303ecaf4",
                "sha256:52630fc75a18675c530ed9eba5f55eca09b03e91bd5bc15307918bbc1a7e7296",
                "sha256:dd64bf2dd177757451a98fcdc999a339c35dee5d9872d8f4dc69c8f3c4dd0112",
                "sha256:b839dfae01f66e15c6a8b63520557ed315bdfe036342fa7a0c537259f10d7a9a",
                "sha256:dcaa5a89b0ccda4b283e16d0b4d0891cd93d5fe05c6798f7806781a6a2d84354",
                "sha256:96ed2737ae312e0bc637b40783f7c2f23416cb72ca957aa01855f1614278e64b",
                "sha256:235c3625d753c5b8a741210c2e7fb26b47a0d02cf49acc631a38dcf847eedf89",
                "sha256:dc0fb75e565a59a5824baedc9645656d17bc91c4b31332ee179580fa9f60eacd",
            ],
            # The size in bytes of each layer, in the order of `layers`.
            "layer_sizes": [
                83900,
                12481,
                445709,
                29005,
                67,
                188,
                123,
                162,
                80,
                351,
                314,
                143347,
                4951123,
                2506537,
            ],
            "manifest": "sha256:5883c320d81f76c764e114c9ab14054f037bb040907816fc9028d80d9602a7c3",
            "manifest_file": "distroless_base_debian12.manifest.json",
            "registry": "gcr.io",
            "repository": "distroless/base-debian12",
        },
        "os": "linux",
        # glibc 2.34: the floor zig links against (`zig_triple`), so a built
        # binary runs on any host with glibc 2.34 or newer.
        "os_floor": "glibc-2.34",
        "page_bytes": 4096,
        "pool": "pool=mojo-sized",
        # The DEPLOY_PROBE pre-flight's helper image (kci_validate
        # deploy_probe.mojo): busybox, whose `nc -z` checks that the link-local
        # metadata address does not answer from a container. Docker Hub
        # library/busybox tag 1.37.0: the linux/amd64 image manifest's digest,
        # not the multi-arch index's (the index lists every platform; this
        # pins the one image a linux-x86_64 runner pulls).
        "preflight_image": image("docker.io/library/busybox@sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4"),
        "re_key": "linux_x86_64_properties",
        "registered": True,
        "remote_required": True,
        # What a built binary loads, read from the loader's own record of a run
        # (tests//functional/runtime_libs:loader_trace). tools/build/tests/run_tests.sh
        # fails if this list and that record disagree.
        "runtime_libs": [
            "libAsyncRTRuntimeGlobals.so",
            "libKGENCompilerRTShared.so",
            "libMSupportGlobals.so",
            "libgcc_s.so.1",
            "libstdc++.so.6",
        ],
        # x86-64-v3 (AVX2, BMI2, FMA): built binaries and gated tests need a
        # worker, and a deployment host, that implements it.
        "target_cpu": "x86-64-v3",
        "target_features": [],
        "unpack_triple": "x86_64-linux-musl",
        "zig_exe_sha256": "871186494014f9630683fea5780ae89bd1be16bab11f229f08acba08263c799a",
        "zig_triple": "x86_64-linux-gnu.2.34",
    },
    "darwin-arm64": {
        "applets": ["awk", "basename", "cat", "chmod", "cmp", "cp", "cut", "dirname", "env", "expr", "find", "grep", "head", "ln", "ls", "mkdir", "mkfifo", "mktemp", "mv", "printf", "ps", "readlink", "rm", "rmdir", "sed", "sh", "sleep", "sort", "tail", "tee", "test", "touch", "tr", "uname", "wc"],
        "assets": {
            "actionlint": pin(
                "actionlint_1.7.12_darwin_arm64.tar.gz",
                "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
                "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
                size = 2164202,
            ),
            # macOS has no static busybox: its applets come from the shim
            # tools/build/mojo/darwin/busybox.sh, a fixed list resolved from
            # /bin and /usr/bin.
            "busybox": none("macOS resolves its applets through komira//tools/build/mojo/darwin:busybox.sh, not a pinned binary"),
            "kcov_bzip2": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_elfutils": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_lzma": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_src": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_zlib": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_zstd": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "libgcc": none("the osx-arm64 compiler links only the operating system (every load command names @rpath/, /usr/lib or /System)"),
            "libstdcxx": none("the osx-arm64 compiler links only the operating system (every load command names @rpath/, /usr/lib or /System)"),
            "libzlib": none("the osx-arm64 closure takes no conda library: rustc for aarch64-apple-darwin links and runs without one"),
            "llvm_branch_libiconv": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_libllvm": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_libxml2": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_rt": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_tools": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_zstd": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "mojo_compiler": pin(
                "mojo_compiler_1.0.0_osx-arm64.conda",
                "https://conda.modular.com/max-nightly/osx-arm64/mojo-compiler-1.0.0-release.conda",
                "c52054bc444d851e5c38cc33e790fb011a1080470244aaa59351ac5056d08c59",
                size = 61221085,
            ),
            # pixi, the raw executable of the same release as linux-x86_64's.
            "pixi": pin(
                "pixi-0.67.2-aarch64-apple-darwin",
                "https://github.com/prefix-dev/pixi/releases/download/v0.67.2/pixi-aarch64-apple-darwin",
                "46665ae8c164120ad9b22293566fcd5b454cd25ff77f410a77970bb0e47e0622",
                size = 56099104,
                executable = True,
            ),
            "protoc": pin(
                "protoc-29.1-osx-aarch_64.zip",
                "https://github.com/protocolbuffers/protobuf/releases/download/v29.1/protoc-29.1-osx-aarch_64.zip",
                "b8fd5976926198a7c4ea5c6eb4bf78959d5faed27bfc618254caa1043f770445",
                size = 2290879,
            ),
            "rust_std": pin(
                "rust-std-1.85.0-aarch64-apple-darwin.tar.xz",
                "https://static.rust-lang.org/dist/rust-std-1.85.0-aarch64-apple-darwin.tar.xz",
                "7da1367209de00e3fb315c0e76658e3605ee2559892d29851a3159ae7ea1ddc5",
                size = 25447360,
            ),
            "rustc": pin(
                "rustc-1.85.0-aarch64-apple-darwin.tar.xz",
                "https://static.rust-lang.org/dist/rustc-1.85.0-aarch64-apple-darwin.tar.xz",
                "2a03e227b57a49d80b43473b6fa2d56ad661ece0d8ffd81f639cd31600d3823e",
                size = 55016276,
            ),
            "shellcheck": pin(
                "shellcheck-v0.11.0.darwin.aarch64.tar.xz",
                "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz",
                "56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79",
                size = 7245972,
            ),
            "zig": pin(
                "zig_macos_aarch64.tar.xz",
                "https://ziglang.org/download/0.12.0/zig-macos-aarch64-0.12.0.tar.xz",
                "294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f",
                size = 43447724,
            ),
        },
        # Bundles, OCI images and the launcher are Linux server products.
        "bundles": False,
        "cache_line_bytes": 128,
        "constraints": [
            "prelude//os/constraints:macos",
            "prelude//cpu/constraints:arm64",
        ],
        "cpu": "arm64",
        "features": ["kqueue", "neon", "ulock"],
        "golden_config_hash": "7fd7ccfd5d5f8024",
        "host": {"arch": "aarch64", "os": "macos"},
        "object_format": "macho",
        "oci_base": none("OCI images are a Linux product"),
        "os": "macos",
        # The compiler's own minimum OS.
        "os_floor": "macos-11.0",
        "page_bytes": 16384,
        "pool": "pool=darwin-sized",
        "preflight_image": none("container validations run on Linux runners"),
        "re_key": "darwin_arm64_properties",
        "registered": True,
        "remote_required": False,
        # The compiler's three runtime libraries. Everything else a built binary
        # loads (libc++, libSystem, frameworks) is the operating system's.
        "runtime_libs": [
            "libAsyncRTRuntimeGlobals.dylib",
            "libKGENCompilerRTShared.dylib",
            "libMSupportGlobals.dylib",
        ],
        # The first Apple silicon generation, so a built binary runs on every
        # Apple silicon Mac.
        "target_cpu": "apple-m1",
        "target_features": [],
        "unpack_triple": "aarch64-macos",
        "zig_exe_sha256": "c007814ca1128eeceeb9ce4d625be4d0b13d85228bef8a5534aeb6bcfb56a529",
        "zig_triple": "aarch64-macos.11.0",
    },
    # RESERVED. Linux on aarch64: Ampere Altra servers (Neoverse N1) are the
    # main build machines, and a Raspberry Pi must run what they build, so the
    # floor is generic ARMv8-A with outline atomics (the LSE atomics of an
    # Altra are used where the CPU has them, chosen at run time) and run-time
    # dispatch for anything wider. A tuned `neoverse-n1` variant is a later,
    # opt-in addition; it is not this row. Not a build key yet: no platform
    # target, no execution platform, and `linux_arm64_properties` is refused.
    "linux-arm64": {
        "applets": pending("busybox has no upstream aarch64 static binary; the bring-up chooses the applet carrier"),
        "assets": {
            "actionlint": pin(
                "actionlint_1.7.12_linux_arm64.tar.gz",
                "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz",
                "325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
                size = 2111482,
            ),
            # busybox.net publishes no aarch64 binary (its binaries directory
            # holds i686 and x86_64 only); a pinned source build or another
            # extractor is chosen when the platform is brought up.
            "busybox": pending("no upstream aarch64 static busybox exists; the bring-up chooses a pinned source build or the zig-built unpacker"),
            "kcov_bzip2": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_elfutils": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_lzma": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_src": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_zlib": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "kcov_zstd": none(_KCOV_NONE),  # komira-limit:coverage-linux-x86-64
            "libgcc": pin(
                "libgcc_15.3.0_linux-aarch64.conda",
                "https://conda.anaconda.org/conda-forge/linux-aarch64/libgcc-15.3.0-h954ee24_7.conda",
                "df096c235cf04e802487602f68dbe60d3ab866a7e59e81ae0458f3596a752700",
                size = 624560,
            ),
            "libstdcxx": pin(
                "libstdcxx_15.3.0_linux-aarch64.conda",
                "https://conda.anaconda.org/conda-forge/linux-aarch64/libstdcxx-15.3.0-hef695bb_7.conda",
                "70f23347c4e8481ef91a9806a59d50e4a4a96c7c72041d3a0654ed5b12470f3e",
                size = 5519010,
            ),
            "libzlib": pin(
                "libzlib_1.3.1_linux-aarch64.conda",
                "https://conda.anaconda.org/conda-forge/linux-aarch64/libzlib-1.3.1-h86ecc28_2.conda",
                "5a2c1eeef69342e88a98d1d95bff1603727ab1ff4ee0e421522acd8813439b84",
                size = 66657,
            ),
            "llvm_branch_libiconv": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_libllvm": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_libxml2": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_rt": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_tools": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "llvm_branch_zstd": none(_LLVM_BRANCH_NONE),  # komira-limit:coverage-linux-x86-64
            "mojo_compiler": pin(
                "mojo_compiler_1.0.0_linux-aarch64.conda",
                "https://conda.modular.com/max-nightly/linux-aarch64/mojo-compiler-1.0.0-release.conda",
                "da1772742c54f1f8f7b883e6338b1fe5de4592f2c882220dcceae623cc661e57",
                size = 66479788,
            ),
            "pixi": pending("the pixi linux-aarch64 executable is recorded when the platform is brought up"),
            "protoc": pin(
                "protoc-29.1-linux-aarch_64.zip",
                "https://github.com/protocolbuffers/protobuf/releases/download/v29.1/protoc-29.1-linux-aarch_64.zip",
                "1f74a3f3355de7c0666bc125611c13532c2598f853521d0d3e621a5b09f24799",
                size = 3257573,
            ),
            "rust_std": pin(
                "rust-std-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rust-std-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "8af1d793f7820e9ad0ee23247a9123542c3ea23f8857a018651c7788af9bc5b7",
                size = 31001964,
            ),
            "rustc": pin(
                "rustc-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rustc-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "e742b768f67303010b002b515f6613c639e69ffcc78cd0857d6fe7989e9880f6",
                size = 87989012,
            ),
            "shellcheck": pin(
                "shellcheck-v0.11.0.linux.aarch64.tar.xz",
                "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.aarch64.tar.xz",
                "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588",
                size = 6811484,
            ),
            "zig": pin(
                "zig_linux_aarch64.tar.xz",
                "https://ziglang.org/download/0.12.0/zig-linux-aarch64-0.12.0.tar.xz",
                "754f1029484079b7e0ca3b913a0a2f2a6afd5a28990cb224fe8845e72f09de63",
                size = 41849060,
            ),
        },
        "bundles": True,
        "cache_line_bytes": 64,
        "constraints": [
            "prelude//os/constraints:linux",
            "prelude//cpu/constraints:arm64",
        ],
        "cpu": "arm64",
        "features": ["epoll", "futex", "neon", "thp"],
        "golden_config_hash": pending("the platform exists once the row is registered"),
        "host": {"arch": "aarch64", "os": "linux"},
        "object_format": "elf",
        "oci_base": pending("the distroless base-debian12 linux/arm64 manifest and its blobs are recorded when the platform is brought up"),
        "os": "linux",
        "os_floor": "glibc-2.34",
        "page_bytes": 4096,
        "pool": "pool=linux-arm64-sized",
        "preflight_image": pending("busybox's linux/arm64 image manifest digest is recorded when the platform is brought up"),
        "re_key": "linux_arm64_properties",
        "registered": False,  # komira-limit:linux-arm64-unregistered
        "remote_required": False,
        # Measured on the linux-aarch64 compiler package: the same three
        # libraries, and the same NEEDED libstdc++.so.6 and libgcc_s.so.1.
        "runtime_libs": [
            "libAsyncRTRuntimeGlobals.so",
            "libKGENCompilerRTShared.so",
            "libMSupportGlobals.so",
            "libgcc_s.so.1",
            "libstdc++.so.6",
        ],
        "target_cpu": "generic",
        "target_features": ["+outline-atomics"],
        "unpack_triple": "aarch64-linux-musl",
        "zig_exe_sha256": "63eb4d2bd19140feee8fe02b50dc6dd2264567c5d6dae0fb7ccec5150e96ae8a",
        "zig_triple": "aarch64-linux-gnu.2.34",
    },
}

# ---- Completeness ----------------------------------------------------------------

def _pin_refusal(row_name, role, a, registered):
    if type(a) != "dict":
        return "row {}: pin `{}` is not a pin, `none(...)` or `pending(...)`: {}".format(row_name, role, repr(a))
    if "none" in a:
        if role not in _NONE_ALLOWED:
            return "row {}: pin `{}` is `none(...)`, which only {} may be".format(row_name, role, ", ".join(_NONE_ALLOWED))
        if not a["none"]:
            return "row {}: pin `{}` is `none` with no reason".format(row_name, role)
        return None
    if "pending" in a:
        if registered:
            return "row {}: pin `{}` is pending, but the row is registered: a registered row has every pin".format(row_name, role)
        if not a["pending"]:
            return "row {}: pin `{}` is `pending` with no reason".format(row_name, role)
        return None
    for f in ["name", "sha256", "url"]:
        if not a.get(f):
            return "row {}: pin `{}` has no `{}`".format(row_name, role, f)
    sha = a["sha256"]
    if len(sha) != 64 or [c for c in sha.elems() if c not in _HEX]:
        return "row {}: pin `{}`: sha256 is not 64 lowercase hex digits: `{}`".format(row_name, role, sha)
    if not a["url"].startswith("https://"):
        return "row {}: pin `{}`: url is not https: `{}`".format(row_name, role, a["url"])
    if role in _EXECUTABLE_ROLES and a.get("executable") != True:
        return "row {}: pin `{}` is an executable, but is not pinned with `executable = True`".format(row_name, role)
    if role in _ONE_RELEASE_ROLES and _release_version(a["url"]) == None:
        return "row {}: pin `{}`: url names no release (`/download/v<version>/`): `{}`".format(row_name, role, a["url"])
    if type(a.get("size")) != "int" or a["size"] <= 0:
        return "row {}: pin `{}` has no positive `size`: {}".format(row_name, role, repr(a.get("size")))
    return None

def _is_digest_reference(ref):
    # `<repository>@sha256:<64 lowercase hex>`: one `@`, a repository before it.
    if type(ref) != "string" or ref.count("@") != 1:
        return False
    repo, digest = ref.split("@")
    if not repo or [c for c in repo.elems() if c in " \t\"'\\"]:
        return False
    return digest.startswith("sha256:") and len(digest) == 71 and not [c for c in digest[7:].elems() if c not in _HEX]

def _preflight_image_refusal(name, v, registered):
    if type(v) != "dict" or len(v) != 1:
        return "row {}: `preflight_image` is not `image(...)`, `placeholder(...)`, `none(...)` or `pending(...)`: {}".format(name, repr(v))
    kind = v.keys()[0]
    if kind == "image":
        if not _is_digest_reference(v["image"]):
            return "row {}: `preflight_image` is not pinned by digest, <repository>@sha256:<64 lowercase hex>: {}".format(name, repr(v["image"]))
        if v["image"] == UNPINNED_IMAGE:
            return "row {}: `preflight_image` is the placeholder image; write `placeholder(reason)`".format(name)
        return None
    if kind not in ("placeholder", "none", "pending") or not v[kind]:
        return "row {}: `preflight_image` is `{}` with no reason, or not a kind the table knows".format(name, kind)
    if kind == "pending" and registered:
        return "row {}: `preflight_image` is pending, but the row is registered: use `placeholder(...)` until the digest is recorded".format(name)
    return None

def _release_version(url):
    # `.../download/v0.67.2/<file>` -> `0.67.2`; None when the URL has no such segment.
    parts = url.split("/")
    for i in range(len(parts) - 2):
        if parts[i] == "download" and parts[i + 1].startswith("v") and len(parts[i + 1]) > 1:
            return parts[i + 1][1:]
    return None

def _hex_refusal(name, field, v, n):
    if type(v) != "string" or len(v) != n or [c for c in v.elems() if c not in _HEX]:
        return "row {}: `{}` is not {} lowercase hex digits: {}".format(name, field, n, repr(v))
    return None

def _pow2(v):
    return type(v) == "int" and v > 0 and v & (v - 1) == 0

def _shape_refusals(name, row):
    """The refusals of the fields that are not pins: applets, the sizes, features, the golden hash, the pool, the zig digest."""
    out = []
    registered = row["registered"]
    applets = row["applets"]
    if type(applets) == "dict":
        if "none" in applets and not applets["none"]:
            out.append("row {}: `applets` is `none` with no reason".format(name))
        elif "pending" in applets and (registered or not applets["pending"]):
            out.append("row {}: `applets` is pending, but the row is registered, or with no reason".format(name))
        elif "none" not in applets and "pending" not in applets:
            out.append("row {}: `applets` is a dict that is neither `none(...)` nor `pending(...)`".format(name))
    elif type(applets) != "list" or not applets or applets != sorted(applets) or len({a: 1 for a in applets}) != len(applets):
        out.append("row {}: `applets` must be a non-empty sorted list without duplicates, or `none(...)`".format(name))
    for f in ["cache_line_bytes", "page_bytes"]:
        if not _pow2(row[f]) or row[f] < 16:
            out.append("row {}: `{}` is not a power of two of at least 16: {}".format(name, f, repr(row[f])))
    feats = row["features"]
    if type(feats) != "list" or feats != sorted(feats) or len({f: 1 for f in feats}) != len(feats):
        out.append("row {}: `features` must be a sorted list without duplicates".format(name))
    else:
        for f in feats:
            if f not in FEATURES:
                out.append("row {}: feature `{}` is not one of {}".format(name, f, ", ".join(FEATURES)))
    g = row["golden_config_hash"]
    if type(g) == "dict":
        if "pending" not in g or not g["pending"] or registered:
            out.append("row {}: `golden_config_hash` is a dict that is not `pending(reason)` of an unregistered row".format(name))
    else:
        r = _hex_refusal(name, "golden_config_hash", g, 16)
        if r:
            out.append(r)
    if not registered and type(g) != "dict":
        out.append("row {}: `golden_config_hash` is recorded, but the row has no platform: use `pending(...)`".format(name))
    if registered and type(g) == "dict":
        out.append("row {}: a registered row has a platform, so `golden_config_hash` is its hash, not pending".format(name))
    pool = row["pool"]
    if type(pool) != "string" or not pool.startswith("pool=") or len(pool) <= len("pool="):
        out.append("row {}: `pool` must be `pool=<name>`: {}".format(name, repr(pool)))
    r = _hex_refusal(name, "zig_exe_sha256", row["zig_exe_sha256"], 64)
    if r:
        out.append(r)
    return out

def table_refusals(table):
    """Every way `table` is incomplete or inconsistent, as sentences naming the row and the pin; [] when it is complete."""
    out = []
    if not table:
        return ["the platform table has no row"]
    keys = {}
    pools = {}
    hosts = {}
    for name in sorted(table):
        row = table[name]
        missing = [f for f in ROW_FIELDS if f not in row]
        for f in missing:
            out.append("row {}: missing field `{}`".format(name, f))
        extra = [f for f in row if f not in ROW_FIELDS]
        for f in extra:
            out.append("row {}: unknown field `{}`".format(name, f))
        if missing:
            continue
        if name != "{}-{}".format(row["os"] if row["os"] != "macos" else "darwin", row["cpu"]):
            out.append("row {}: named for neither its os nor its cpu (`{}`, `{}`)".format(name, row["os"], row["cpu"]))
        want = ["prelude//os/constraints:" + row["os"], "prelude//cpu/constraints:" + row["cpu"]]
        if row["constraints"] != want:
            out.append("row {}: constraints are {}, expected {} from its os and cpu".format(name, row["constraints"], want))
        if row["object_format"] not in ("elf", "macho"):
            out.append("row {}: object_format `{}` is neither `elf` nor `macho`".format(name, row["object_format"]))
        for f in ["target_cpu", "zig_triple", "unpack_triple", "os_floor", "re_key"]:
            if not row[f]:
                out.append("row {}: `{}` is empty".format(name, f))
        if not row["runtime_libs"]:
            out.append("row {}: `runtime_libs` is empty".format(name))
        if sorted(row["host"].keys()) != ["arch", "os"]:
            out.append("row {}: `host` must name exactly `os` and `arch`".format(name))
        if row["re_key"] in keys:
            out.append("row {}: `re_key` `{}` is also row {}'s".format(name, row["re_key"], keys[row["re_key"]]))
        keys[row["re_key"]] = name
        if row["pool"] in pools:
            out.append("row {}: `pool` `{}` is also row {}'s".format(name, row["pool"], pools[row["pool"]]))
        pools[row["pool"]] = name
        hk = "{} {}".format(row["host"].get("os"), row["host"].get("arch"))
        if hk in hosts:
            out.append("row {}: `host` {} is also row {}'s".format(name, hk, hosts[hk]))
        hosts[hk] = name
        if type(row["registered"]) != "bool":
            out.append("row {}: `registered` is not a bool".format(name))
            continue
        out.extend(_shape_refusals(name, row))
        oci = row["oci_base"]
        if type(oci) != "dict":
            out.append("row {}: `oci_base` is not a pin, `none(...)` or `pending(...)`".format(name))
        elif "none" in oci:
            if row["bundles"]:
                out.append("row {}: bundles are a product of this row, but `oci_base` is none".format(name))
        elif "pending" in oci:
            if row["registered"]:
                out.append("row {}: pin `oci_base` is pending, but the row is registered".format(name))
        else:
            for f in ["config", "config_size", "layer_sizes", "layers", "manifest", "manifest_file", "registry", "repository"]:
                if not oci.get(f):
                    out.append("row {}: pin `oci_base` has no `{}`".format(name, f))
            sizes = [oci.get("config_size")] + (oci.get("layer_sizes") or [])
            if [z for z in sizes if type(z) != "int" or z <= 0] or len(oci.get("layer_sizes") or []) != len(oci.get("layers") or []):
                out.append("row {}: pin `oci_base`: `config_size` and each of `layer_sizes` must be a positive size, one per layer".format(name))
        r = _preflight_image_refusal(name, row["preflight_image"], row["registered"])
        if r:
            out.append(r)
        for role in ASSET_ROLES:
            if role not in row["assets"]:
                out.append("row {}: missing pin `{}`".format(name, role))
                continue
            r = _pin_refusal(name, role, row["assets"][role], row["registered"])
            if r:
                out.append(r)
        for role in row["assets"]:
            if role not in ASSET_ROLES:
                out.append("row {}: unknown pin `{}`".format(name, role))
    for role in _ONE_RELEASE_ROLES:
        versions = {}
        for name in sorted(table):
            a = table[name].get("assets", {}).get(role)
            if type(a) == "dict" and a.get("url"):
                v = _release_version(a["url"])
                if v != None:
                    versions.setdefault(v, []).append(name)
        if len(versions) > 1:
            out.append("pin `{}` names more than one release: {}".format(
                role,
                "; ".join(["{} in {}".format(v, ", ".join(versions[v])) for v in sorted(versions)]),
            ))
    return out

def _refuse_incomplete():
    refusals = table_refusals(PLATFORMS)
    if refusals:
        fail("tools/build/platforms/table.bzl is incomplete:\n  " + "\n  ".join(refusals))

_refuse_incomplete()

# ---- Reading the table --------------------------------------------------------------

_PLATFORMS_PACKAGE = "komira//tools/build/platforms:"

def row(name):
    """The row named `name` (`linux-x86_64`, ...)."""
    if name not in PLATFORMS:
        fail("no platform row `{}`; the table has {}".format(name, ", ".join(sorted(PLATFORMS))))
    return PLATFORMS[name]

def registered_names():
    """The registered rows' names, linux-x86_64 first.

    Order is registration order: a target stating no execution constraint gets
    the first execution platform, so linux-x86_64 comes first and every
    platform added later must never become the first match of an action that
    states no os.
    """
    first = [n for n in sorted(PLATFORMS) if n == "linux-x86_64" and PLATFORMS[n]["registered"]]
    return first + [n for n in sorted(PLATFORMS) if n != "linux-x86_64" and PLATFORMS[n]["registered"]]

def reserved_names():
    """The rows declared but not yet a build key, sorted."""
    return [n for n in sorted(PLATFORMS) if not PLATFORMS[n]["registered"]]

def label(name):
    """The label of the platform of row `name`: also the label of its execution platform."""
    return _PLATFORMS_PACKAGE + name

def constraints(name):
    """The constraint values of row `name`, a fresh list."""
    return list(row(name)["constraints"])

def asset(name, role):
    """The pin of `role` for row `name`: a dict with name, url, sha256, size, executable. Fails for `none` and `pending`."""
    a = row(name)["assets"][role]
    if "name" not in a:
        fail("platform {} has no `{}` download: {}".format(name, role, a.get("none") or a.get("pending")))
    return a

def preflight_image(name):
    """The pre-flight helper image of row `name`, for --preflight-image: its digest reference, or
    `UNPINNED_IMAGE` (which kci refuses wherever a DEPLOY_PROBE would run) for a placeholder, `none` or `pending`."""
    v = row(name)["preflight_image"]
    return v.get("image") or UNPINNED_IMAGE

def pinned_kwargs(name, role, **extra):
    """kwargs for `pinned_file` that fetch `role` of row `name`; `extra` (visibility, ...) is added."""
    a = asset(name, role)
    kw = {"name": a["name"], "sha256": a["sha256"], "size_bytes": a["size"], "url": a["url"]}
    if a["executable"]:
        kw["executable"] = True
    kw.update(extra)
    return kw

def release_version(name, role):
    """The release of `role`'s pin in row `name`, read from its URL (`.../download/v0.67.2/...` -> `0.67.2`)."""
    v = _release_version(asset(name, role)["url"])
    if v == None:
        fail("platform {}: the `{}` pin's url names no release: {}".format(name, role, asset(name, role)["url"]))
    return v

def by_target_os(role):
    """For `select()`: each registered row's os constraint -> `:<name of its pinned_file of role>`.

    A tool chosen by this map comes from the row of the target platform, which
    is the client's own row unless `--target-platforms` names another.
    """
    out = {}
    rows = {}
    for n in registered_names():
        key = "prelude//os/constraints:" + PLATFORMS[n]["os"]
        if key in rows:
            fail("rows {} and {} share the os `{}`: `{}` cannot be chosen by os alone".format(rows[key], n, PLATFORMS[n]["os"], role))
        rows[key] = n
        out[key] = ":" + asset(n, role)["name"]
    return out

def os_floor_version(name):
    """The version of row `name`'s `os_floor` (`macos-11.0` -> `11.0`)."""
    return row(name)["os_floor"].split("-", 1)[1]

def zig_strip_prefix(name):
    """The directory a row's zig archive unpacks into (`zig-linux-x86_64-0.12.0`): its URL's file name without `.tar.xz`."""
    return asset(name, "zig")["url"].split("/")[-1][:-len(".tar.xz")]

def host_row(host):
    """The registered row whose host `host` (a `host_info()`) is, or None."""
    for n in registered_names():
        if _host_is(host, PLATFORMS[n]["host"]):
            return n
    return None

def _host_is(host, want):
    oses = {"linux": host.os.is_linux, "macos": host.os.is_macos}
    arches = {"aarch64": host.arch.is_aarch64, "x86_64": host.arch.is_x86_64}
    return oses.get(want["os"], False) and arches.get(want["arch"], False)

def host_refusal(host):
    """Why no row matches `host` (a `host_info()`), or None when one does."""
    if host_row(host) != None:
        return None
    for n in reserved_names():
        if _host_is(host, PLATFORMS[n]["host"]):
            return ("this host is {}, which komira reserves a row for but does not build for yet: " +
                    "no `{}` platform exists and `[komira_re] {}` is refused if set. " +
                    "Build for a registered platform with --target-platforms ({}), " +
                    "on a remote-execution service.").format(
                n,
                n,
                PLATFORMS[n]["re_key"],
                ", ".join([label(r) for r in registered_names()]),
            )
    return ("no platform row matches this host (os {}, arch {}). The rows are {}. " +
            "Use a remote-execution service and name the platform to build for with " +
            "--target-platforms.").format(
        "linux" if host.os.is_linux else ("macos" if host.os.is_macos else "other"),
        "x86_64" if host.arch.is_x86_64 else ("aarch64" if host.arch.is_aarch64 else "other"),
        ", ".join(sorted(PLATFORMS)),
    )
