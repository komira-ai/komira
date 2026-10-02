"""The platform table: one row per (os, cpu) komira builds for, and everything else derived from it.

A platform is an (os, cpu) pair. Each row below states, in one place, what a
platform IS: the constraints that name it, the host that selects it, the
`[komira_re]` key of its execution platform's worker property set, how zig
links for it, the CPU floor every compile targets, the object format, what a
built binary loads at run time, the operating-system floor it needs, and
every pinned download its toolchains use (URL and sha256). The detector
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

# `pin(name, url, sha256)`: one sha256-pinned download. `name` is the target
# name of the `pinned_file` that fetches it (an asset name: outputs of that
# target live under it, so renaming one re-keys every action that reads it).
def pin(name, url, sha256, executable = False):
    return {"executable": executable, "name": name, "sha256": sha256, "url": url}

# The pinned downloads every registered row must state, by role. `none` is
# allowed where a platform can need nothing (the conda runtime libraries the
# osx-arm64 compiler does not link; the container base of a platform that
# ships no containers).
ASSET_ROLES = [
    "actionlint",
    "busybox",
    "libgcc",
    "libstdcxx",
    "libzlib",
    "mojo_compiler",
    "protoc",
    "rust_std",
    "rustc",
    "shellcheck",
    "zig",
]
_NONE_ALLOWED = ["busybox", "libgcc", "libstdcxx", "libzlib"]

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

PLATFORMS = {
    "linux-x86_64": {
        "applets": none("the pinned busybox (assets.busybox) carries every applet"),
        "assets": {
            "actionlint": pin(
                "actionlint_1.7.12_linux_amd64.tar.gz",
                "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz",
                "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
            ),
            "busybox": pin(
                "busybox",
                "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox",
                "6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348",
                executable = True,
            ),
            "libgcc": pin(
                "libgcc_15.3.0_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libgcc-15.3.0-h3363355_7.conda",
                "0bb57ee8557aad33317eeb881e3957b6fab776dd75473311c25789fa3a29f792",
            ),
            "libstdcxx": pin(
                "libstdcxx_15.3.0_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-15.3.0-h934c35e_7.conda",
                "0c3dc08bf43357a77297b4449abd0ce1d40a140989f004071e69c04ed13e36bb",
            ),
            "libzlib": pin(
                "libzlib_1.3.1_linux-64.conda",
                "https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.1-hb9d3cd8_2.conda",
                "d4bfe88d7cb447768e31650f06257995601f89076080e76df55e3112d4e47dc4",
            ),
            "mojo_compiler": pin(
                "mojo_compiler_1.0.0_linux-64.conda",
                "https://conda.modular.com/max-nightly/linux-64/mojo-compiler-1.0.0-release.conda",
                "4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3",
            ),
            "protoc": pin(
                "protoc-29.1-linux-x86_64.zip",
                "https://github.com/protocolbuffers/protobuf/releases/download/v29.1/protoc-29.1-linux-x86_64.zip",
                "00c83fe9722d85e96c81b941b29f17a744b33b4ce66e0f18009fd8937de22c60",
            ),
            "rust_std": pin(
                "rust-std-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rust-std-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "285e105d25ebdf501341238d4c0594ecdda50ec9078f45095f793a736b1f1ac2",
            ),
            "rustc": pin(
                "rustc-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rustc-1.85.0-x86_64-unknown-linux-gnu.tar.xz",
                "7436f13797475082cd87aa65547449e01659d6a810b4cd5f8aedc48bb9f89dfb",
            ),
            "shellcheck": pin(
                "shellcheck-v0.11.0.linux.x86_64.tar.xz",
                "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz",
                "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
            ),
            "zig": pin(
                "zig_linux_x86_64.tar.xz",
                "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz",
                "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad",
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
        # digests are the pin.
        "oci_base": {
            "config": "sha256:c31423653c22931f970322b39ef0b1a9395efefa45e4e8d16fc409c286443c0b",
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
            ),
            # macOS has no static busybox: its applets come from the shim
            # tools/build/mojo/darwin/busybox.sh, a fixed list resolved from
            # /bin and /usr/bin.
            "busybox": none("macOS resolves its applets through komira//tools/build/mojo/darwin:busybox.sh, not a pinned binary"),
            "libgcc": none("the osx-arm64 compiler links only the operating system (every load command names @rpath/, /usr/lib or /System)"),
            "libstdcxx": none("the osx-arm64 compiler links only the operating system (every load command names @rpath/, /usr/lib or /System)"),
            "libzlib": none("the osx-arm64 closure takes no conda library: rustc for aarch64-apple-darwin links and runs without one"),
            "mojo_compiler": pin(
                "mojo_compiler_1.0.0_osx-arm64.conda",
                "https://conda.modular.com/max-nightly/osx-arm64/mojo-compiler-1.0.0-release.conda",
                "c52054bc444d851e5c38cc33e790fb011a1080470244aaa59351ac5056d08c59",
            ),
            "protoc": pin(
                "protoc-29.1-osx-aarch_64.zip",
                "https://github.com/protocolbuffers/protobuf/releases/download/v29.1/protoc-29.1-osx-aarch_64.zip",
                "b8fd5976926198a7c4ea5c6eb4bf78959d5faed27bfc618254caa1043f770445",
            ),
            "rust_std": pin(
                "rust-std-1.85.0-aarch64-apple-darwin.tar.xz",
                "https://static.rust-lang.org/dist/rust-std-1.85.0-aarch64-apple-darwin.tar.xz",
                "7da1367209de00e3fb315c0e76658e3605ee2559892d29851a3159ae7ea1ddc5",
            ),
            "rustc": pin(
                "rustc-1.85.0-aarch64-apple-darwin.tar.xz",
                "https://static.rust-lang.org/dist/rustc-1.85.0-aarch64-apple-darwin.tar.xz",
                "2a03e227b57a49d80b43473b6fa2d56ad661ece0d8ffd81f639cd31600d3823e",
            ),
            "shellcheck": pin(
                "shellcheck-v0.11.0.darwin.aarch64.tar.xz",
                "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz",
                "56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79",
            ),
            "zig": pin(
                "zig_macos_aarch64.tar.xz",
                "https://ziglang.org/download/0.12.0/zig-macos-aarch64-0.12.0.tar.xz",
                "294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f",
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
            ),
            # busybox.net publishes no aarch64 binary (its binaries directory
            # holds i686 and x86_64 only); a pinned source build or another
            # extractor is chosen when the platform is brought up.
            "busybox": pending("no upstream aarch64 static busybox exists; the bring-up chooses a pinned source build or the zig-built unpacker"),
            "libgcc": pin(
                "libgcc_15.3.0_linux-aarch64.conda",
                "https://conda.anaconda.org/conda-forge/linux-aarch64/libgcc-15.3.0-h954ee24_7.conda",
                "df096c235cf04e802487602f68dbe60d3ab866a7e59e81ae0458f3596a752700",
            ),
            "libstdcxx": pin(
                "libstdcxx_15.3.0_linux-aarch64.conda",
                "https://conda.anaconda.org/conda-forge/linux-aarch64/libstdcxx-15.3.0-hef695bb_7.conda",
                "70f23347c4e8481ef91a9806a59d50e4a4a96c7c72041d3a0654ed5b12470f3e",
            ),
            "libzlib": pin(
                "libzlib_1.3.1_linux-aarch64.conda",
                "https://conda.anaconda.org/conda-forge/linux-aarch64/libzlib-1.3.1-h86ecc28_2.conda",
                "5a2c1eeef69342e88a98d1d95bff1603727ab1ff4ee0e421522acd8813439b84",
            ),
            "mojo_compiler": pin(
                "mojo_compiler_1.0.0_linux-aarch64.conda",
                "https://conda.modular.com/max-nightly/linux-aarch64/mojo-compiler-1.0.0-release.conda",
                "da1772742c54f1f8f7b883e6338b1fe5de4592f2c882220dcceae623cc661e57",
            ),
            "protoc": pin(
                "protoc-29.1-linux-aarch_64.zip",
                "https://github.com/protocolbuffers/protobuf/releases/download/v29.1/protoc-29.1-linux-aarch_64.zip",
                "1f74a3f3355de7c0666bc125611c13532c2598f853521d0d3e621a5b09f24799",
            ),
            "rust_std": pin(
                "rust-std-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rust-std-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "8af1d793f7820e9ad0ee23247a9123542c3ea23f8857a018651c7788af9bc5b7",
            ),
            "rustc": pin(
                "rustc-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "https://static.rust-lang.org/dist/rustc-1.85.0-aarch64-unknown-linux-gnu.tar.xz",
                "e742b768f67303010b002b515f6613c639e69ffcc78cd0857d6fe7989e9880f6",
            ),
            "shellcheck": pin(
                "shellcheck-v0.11.0.linux.aarch64.tar.xz",
                "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.aarch64.tar.xz",
                "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588",
            ),
            "zig": pin(
                "zig_linux_aarch64.tar.xz",
                "https://ziglang.org/download/0.12.0/zig-linux-aarch64-0.12.0.tar.xz",
                "754f1029484079b7e0ca3b913a0a2f2a6afd5a28990cb224fe8845e72f09de63",
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
            for f in ["config", "layers", "manifest", "manifest_file", "registry", "repository"]:
                if not oci.get(f):
                    out.append("row {}: pin `oci_base` has no `{}`".format(name, f))
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
    """The pin of `role` for row `name`: a dict with name, url, sha256, executable. Fails for `none` and `pending`."""
    a = row(name)["assets"][role]
    if "name" not in a:
        fail("platform {} has no `{}` download: {}".format(name, role, a.get("none") or a.get("pending")))
    return a

def pinned_kwargs(name, role, **extra):
    """kwargs for `pinned_file` that fetch `role` of row `name`; `extra` (visibility, ...) is added."""
    a = asset(name, role)
    kw = {"name": a["name"], "sha256": a["sha256"], "url": a["url"]}
    if a["executable"]:
        kw["executable"] = True
    kw.update(extra)
    return kw

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
