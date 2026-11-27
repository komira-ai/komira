"""The hermetic Node.js of the tests: the runtime (linux-x64, and darwin-arm64 for a macOS target) and the npm packages, each pinned twice.

Read by this package's BUCK, which declares the downloads and the unpacked
targets, and by the tests that hold the runtime to its pin
(src/tests/helpers/komira_test_node). Every file is pinned by sha256 and size
(`pinned_file`, checked when it is fetched). The Node archive's sha256 is the
one its release's signed `SHASUMS256.txt` lists; each npm tarball also carries
the registry's `dist.integrity` (`sha512-<base64>`), which `npm_package`
checks again before it unpacks the tarball. `license` is the SPDX expression
README.md records (Licences); `deps` are the packages a package imports at run
time, by `name`.

`NODE` is the runtime of every node rule; `NODE_LINES` are the other Node.js
lines, and `NPM_CLI` the npm program, that the install test of the npm
packages (//node:install_test) runs; `NPM_INSTALL_ONLY` are packages npm
installs there that no test imports.
"""

NODE = {
    "name": "node",
    # Node 24, an LTS line ("Krypton"), released 2026-09-07; the
    # newest 24.x release in nodejs.org's release index (dist/index.json).
    "version": "24.21.0",
    "archive": "node-v24.21.0-linux-x64.tar.gz",
    "top": "node-v24.21.0-linux-x64",
    "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.gz",
    "sha256": "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff",
    "size": 58088022,
    "license": "MIT",
}

# The same release's darwin-arm64 archive, for the node of a macOS target
# platform (BUCK, `node_runtime`). Its sha256 is the one the same release's
# signed `SHASUMS256.txt` lists for `node-v24.21.0-darwin-arm64.tar.gz`; the
# size is the archive's Content-Length. It is never run by an action (the
# execution platform is linux): `node_dist` checks its `bin/node` is a Mach-O
# arm64 executable and that `include/node/node_version.h` states `version`.
NODE_DARWIN_ARM64 = {
    "name": "node_darwin_arm64",
    "version": NODE["version"],
    "archive": "node-v24.21.0-darwin-arm64.tar.gz",
    "top": "node-v24.21.0-darwin-arm64",
    "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz",
    "sha256": "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
    "size": 52909993,
    "license": "MIT",
}
# The other Node.js lines the installed npm packages are tested on
# (//node:install_test): the 22 and 26 LTS lines, the newest release of each
# in nodejs.org's release index (dist/index.json), linux-x64. Each is its own
# target, named by `name`, visible only to that test; `native_libs` is the
# directory of the libraries its `node` links beyond glibc (third_party/node/BUCK).
NODE_LINES = [
    {
        "name": "node_22",
        # Node 22 ("Jod"), maintenance LTS, released 2026-11-11.
        "version": "22.23.5",
        "archive": "node-v22.23.5-linux-x64.tar.gz",
        "top": "node-v22.23.5-linux-x64",
        "url": "https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-x64.tar.gz",
        "sha256": "c54118104acc524633b5abe106bbf44a53126ec8b4e5fa105cb92b5d7de8a1a1",
        "size": 56856114,
        "license": "MIT",
        "native_libs": ":native_libs",
    },
    {
        "name": "node_26",
        # Node 26 ("Lithium"), active LTS, released 2026-11-10.
        "version": "26.13.1",
        "archive": "node-v26.13.1-linux-x64.tar.gz",
        "top": "node-v26.13.1-linux-x64",
        "url": "https://nodejs.org/dist/v26.13.1/node-v26.13.1-linux-x64.tar.gz",
        "sha256": "518674de2b621728a5e4486f5fb3b7d2900bb3cc4aa97969edaa463db99f9778",
        "size": 62904977,
        "license": "MIT",
        # Node 26's binary also links libatomic.so.1 (its NEEDED), which the
        # build workers do not have.
        "native_libs": ":native_libs_atomic",
    },
]

def _npm(name, version, url, sha256, size, integrity, license, deps = [], exe = None):
    return {
        "deps": deps,
        "exe": exe,
        "file": "npm-" + url.rsplit("/", 1)[1],
        "integrity": integrity,
        "license": license,
        "name": name,
        "sha256": sha256,
        "size": size,
        "url": url,
        "version": version,
    }

NPM = [
    # esbuild's linux x86_64 binary (a static Go executable), the package the
    # `esbuild` npm package installs on that platform; `exe` must print the
    # version.
    _npm(
        "@esbuild/linux-x64",
        "0.28.2",
        "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.28.2.tgz",
        "9573bb2233aab0f9ea7647d5cca9726113cc1768de61d66b17267f4db84488f6",
        4741809,
        "sha512-4xTZr1FUmSoQW4XIWmit3tzQrUTZM+N3P0XV8xROKYF50XfI7xeO90+1bZvNwxIufQ9hDQVRJH5YhgPVF8A/HQ==",
        "MIT",
        exe = "bin/esbuild",
    ),
    _npm(
        "apache-arrow",
        "21.2.0",
        "https://registry.npmjs.org/apache-arrow/-/apache-arrow-21.2.0.tgz",
        "dd63a3a4c380eddeb00c718740414ff33c4ded015c8720798afdfcc61b5dac41",
        1019102,
        "sha512-Hxe6Agq26gQOM954qpzYSllJBPJl+e16U5CkfuMUhLrNba+5nKkttIVlflaovN6oaTratqMGAO8H5u/aNhmHWQ==",
        "Apache-2.0",
        deps = ["flatbuffers", "json-with-bigint", "tslib"],
    ),
    _npm(
        "flatbuffers",
        "25.9.23",
        "https://registry.npmjs.org/flatbuffers/-/flatbuffers-25.9.23.tgz",
        "484129ef89da43decec3d004810863a70fad9b2aa6df6246602e58d9ba207d26",
        50936,
        "sha512-MI1qs7Lo4Syw0EOzUl0xjs2lsoeqFku44KpngfIduHBYvzm8h2+7K8YMQh1JtVVVrUvhLpNwqVi4DERegUJhPQ==",
        "Apache-2.0",
    ),
    _npm(
        "json-with-bigint",
        "3.5.12",
        "https://registry.npmjs.org/json-with-bigint/-/json-with-bigint-3.5.12.tgz",
        "608af3ce68ceba88a6cec4cdbd2fb35f1ac219a3b038f995344d0881b73b86ae",
        20336,
        "sha512-uwbF/wSSuOgC7qqlq27Xp5B6a2MHVug3t0idZdTqu0JnlFvgJuH7ju+KAk/J06C7GfhoYy2gnb9wz2INqcne7w==",
        "MIT",
    ),
    _npm(
        "tslib",
        "2.8.1",
        "https://registry.npmjs.org/tslib/-/tslib-2.8.1.tgz",
        "66f635d5eeabae44807534976913a102cf615b9a045368359c9f79ae6ee2119e",
        18477,
        "sha512-oJFu94HQb+KVduSUQL7wnpmqnfmLsOA/nAh6b6EH0wCEoK0/mPeXU6c3wKDV83MkOuHPRHtSXKKU99IBazS/2w==",
        "0BSD",
    ),
]

# The npm CLI, the registry's tarball of the `npm` package (its dependencies
# are bundled in it), run by the pinned node: the one npm of the repository,
# for //node:install_test alone. 11.20.0 is the npm that Node 26.13.1 ships;
# trusted publishing needs npm 11.5.1 or later under Node 22.14 or later
# (docs/design/typescript_package.md, section 4).
NPM_CLI = _npm(
    "npm",
    "11.20.0",
    "https://registry.npmjs.org/npm/-/npm-11.20.0.tgz",
    "d1a92f40e6c407b84c3a00c3cf978a10b24fd42f153c527e2016cef7bb34a483",
    3004748,
    "sha512-dF3EDFwbYN+N5RUip+ZYDe0NeURK5BgqKOcvT1iNtUYhTMTl0FwWhBuXrS7KtXyduqyTMS5aaQaregnHDAxNgw==",
    "Artistic-2.0",
)

# The packages npm installs beside apache-arrow that no test imports: its
# `@types/node` dependency and that package's own. Only their tarballs are
# targets (an install test hands them to npm); @types/node's tarball has no
# package/ directory (its top is `node v25.9`), which npm_package requires.
NPM_INSTALL_ONLY = [
    _npm(
        "@types/node",
        "25.9.9",
        "https://registry.npmjs.org/@types/node/-/node-25.9.9.tgz",
        "fb7f3d16a84ea47e898159a010c1cfba3266de74b42528f0bf99584c2309accb",
        437812,
        "sha512-b4e2xxj/yMeT2hNlD6x7zNFiQK2Dlmkb9CQ6v3/1G2RezKN4YS2lcEv8lzGm1mhs4f2lM4yNAMI/zUDBZBBt7w==",
        "MIT",
        deps = ["undici-types"],
    ),
    _npm(
        "undici-types",
        "7.24.6",
        "https://registry.npmjs.org/undici-types/-/undici-types-7.24.6.tgz",
        "2abf595a86b87dd22951218848ec4ad89c018db0e656716dc04b8b2f9290a0f4",
        28510,
        "sha512-WRNW+sJgj5OBN4/0JpHFqtqzhpbnV0GuB+OozA9gCL7a993SmU+1JBZCzLNxYsbMfIeDL+lTsphD5jN5N+n0zg==",
        "MIT",
    ),
]

def npm_target(name):
    """The target name of an npm package: its name without the scope's `@`, `/` as `_` (`@esbuild/linux-x64` -> `esbuild_linux-x64`)."""
    return (name[1:] if name.startswith("@") else name).replace("/", "_")
