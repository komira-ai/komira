# Hermetic Node.js: the pins

The runtime and the npm packages of the tests' hermetic Node.js
([tools/build/node](../../tools/build/node/README.md)), each pinned by
sha256 and size in [`pins.bzl`](pins.bzl) and fetched like every other
pinned download (`pinned_file`): on a remote-cache hit, nothing is fetched.
Each package is one tarball, unpacked. npm runs in one test alone, the
install test of komira's npm packages (`//node:install_test`), offline.

| target | what |
|---|---|
| `:node` | Node.js 24.21.0 (the 24 LTS line), the `linux-x64` release archive, reduced to `bin/node`, `include/node` and `LICENSE`; `:node[include]` is the Node-API headers |
| `:node_darwin_arm64` | the same release's `darwin-arm64` archive, reduced the same way and never run: it is unpacked on the linux execution platform, and checked to hold a Mach-O 64-bit arm64 `bin/node` and an `include/node/node_version.h` that states 24.21.0; it has no `native_libs` (Darwin's `node` links system libraries only) |
| `:node_runtime` | `:node_darwin_arm64` for a `darwin-arm64` target platform, `:node` for every other: the node a bundle carries (`komira_udf_spike_node_worker`). Actions that run `node` take `:node`, which stays the linux runtime |
| `:native_libs` | `libgcc_s.so.1` and `libstdc++.so.6` (GCC 15.3), unpacked from the conda-forge packages the [platform table](../../tools/build/platforms/table.bzl) pins for the toolchains; every `node` action names their directory in `LD_LIBRARY_PATH` |
| `:<package>` | one npm package unpacked, named without the scope's `@` and with `/` as `_` (`:apache-arrow`, `:esbuild_linux-x64`); its `deps` are the packages it imports at run time |
| `:node_22`, `:node_26` | Node.js 22.23.5 and 26.13.1, the other LTS lines, reduced as `:node` is: the runtimes `//node:install_test` installs and runs the npm packages on, besides `:node`. Node 26's `node` also links `libatomic.so.1`, so its library directory is `:native_libs_atomic`: `:native_libs` and that library, from the same pinned libgcc package |
| `:npm` | the npm CLI 11.20.0, the registry's tarball unpacked (its dependencies are bundled in it), whose `bin/npm-cli.js` the pinned node runs |
| `:npm-<file>.tgz` | each npm package's tarball as downloaded, which `//node:install_test` hands npm; `@types/node` and `undici-types` have only these (npm installs them beside apache-arrow; no test imports them) |

## The pins

| package | version | requires | for |
|---|---|---|---|
| node | 24.21.0 | | the runtime of every `node_test` |
| node (darwin-arm64) | 24.21.0 | | the runtime a macOS arm64 bundle carries (`:node_runtime`); not run by an action |
| node | 22.23.5, 26.13.1 | | the other runtimes of `//node:install_test` |
| npm | 11.20.0 | | `//node:install_test`: the npm that installs the built packages |
| @esbuild/linux-x64 | 0.28.2 | | `esbuild_bundle` (esbuild's linux x86_64 executable) |
| apache-arrow | 21.2.0 | flatbuffers, json-with-bigint, tslib | Arrow columns and IPC in JavaScript |
| flatbuffers | 25.9.23 | | apache-arrow (IPC messages) |
| json-with-bigint | 3.5.12 | | apache-arrow |
| tslib | 2.8.1 | | apache-arrow (TypeScript helpers) |
| @types/node | 25.9.9 | undici-types | apache-arrow's `dependencies` (type declarations), installed by npm in `//node:install_test` |
| undici-types | 7.24.6 | | @types/node (type declarations) |

How each was checked when it was pinned:

- **Node.js.** 24.21.0 is the newest release of the 24 line in Node's
  release index (`https://nodejs.org/dist/index.json`), where its `lts` field
  names the line ("Krypton"). The pinned sha256 is the one the release's
  `SHASUMS256.txt` lists for `node-v24.21.0-linux-x64.tar.gz`, and that file's
  signature (`SHASUMS256.txt.asc`) verifies with a release key listed in
  Node's README. The `NODE_DARWIN_ARM64` pin
  is the same release: its sha256 is the one that `SHASUMS256.txt` lists for
  `node-v24.21.0-darwin-arm64.tar.gz` (`bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057`)
  and its size is the `Content-Length` of
  `https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz` (52909993 bytes); the signature of
  `SHASUMS256.txt` was not checked when this archive was added, and `pinned_file` holds the download to the pinned
  sha256 and size. 22.23.5 and 26.13.1 are the newest releases of the 22
  ("Jod") and 26 ("Lithium") lines in the same index, checked the same way.
- **npm.** 11.20.0 is the `npm` the 26.13.1 release lists in that index (the
  npm it bundles). Trusted publishing needs npm 11.5.1 or later under Node
  22.14 or later; its `engines` (`^20.17.0 || >=22.9.0`) admit all three
  runtimes. The pinned `integrity` is the registry's `dist.integrity` for
  that version.
- **npm packages.** Each version is the package's `latest` on the registry
  (`https://registry.npmjs.org/<package>/latest`), and each dependency's
  version satisfies the range apache-arrow's `package.json` gives it. The
  pinned `integrity` is the registry's `dist.integrity`, and the sha256 is
  that of the same bytes. Only the runtime `dependencies` are pinned among
  the packages a test imports: apache-arrow's `@types/node` holds type
  declarations and is not imported. npm installs it, so the install test has
  its tarball and its own dependency's: 25.9.9, the newest 25.x release
  (apache-arrow asks `^25.2.0`) older than four weeks when it was pinned, and
  undici-types 7.24.6, the newest release in its range
  (`>=7.24.0 <7.24.7`). @types/node's tarball names its top directory
  `node v25.9`, not `package`, so it is a download only: `npm_package`
  unpacks `package/`.

The checks the build repeats: `pinned_file` refuses a download whose sha256
or size differs; `npm_package` refuses a tarball whose sha512 differs from
the integrity, or whose `package.json` states another top-level name or
version; `node_dist` refuses a `node` that does not print the pinned
version (for the darwin archive, which no action runs: a `bin/node` that is no
Mach-O arm64 executable, or an `include/node/node_version.h` that states
another version), and the `esbuild_linux-x64` target an `esbuild` that does not.

## Licences

| component | licence (SPDX) | bundled |
|---|---|---|
| Node.js | MIT | its `LICENSE` lists the licences of the code it carries (V8, libuv, OpenSSL, ICU, zlib, llhttp and others: MIT, BSD, Apache-2.0, ICU and similar permissive licences). The GPL text in it is that of build files of ICU (`aclocal.m4`, `config.guess`) under the Autoconf exception, not of code in the binary |
| esbuild (@esbuild/linux-x64) | MIT | the package holds the executable, a `README.md` and `package.json` |
| apache-arrow | Apache-2.0 | a `NOTICE.txt` |
| flatbuffers | Apache-2.0 | |
| json-with-bigint | MIT | |
| tslib | 0BSD | |
| npm | Artistic-2.0 | its bundled dependencies: ISC, MIT, BlueOak-1.0.0, Apache-2.0, BSD-2-Clause, BSD-3-Clause, CC0-1.0 and CC-BY-3.0 (spdx-exceptions' data) |
| @types/node, undici-types | MIT | |
| libgcc_s, libstdc++ | GPL-3.0-or-later WITH GCC-exception-3.1 | |

None is the AGPL. The GNU-licensed code is GCC's runtime libraries, under
the GCC Runtime Library Exception, which komira's own toolchains already use
([toolchains](../../tools/build/toolchains/README.md)).

## Never shipped

The hermetic Node.js is for tests. What keeps it out of every published
package:

- **Visibility.** `:node`, `:node_darwin_arm64`, `:node_runtime` and every npm package are visible only to the
  packages `_TEST_ONLY` in [`BUCK`](BUCK) lists (`:node_22`, `:node_26`,
  `:npm` and the tarballs only to `//node`, `_INSTALL_TEST`): the test-only packages under
  `src/tests` (`//:src_layout` holds that directory to test-only packages) and
  [`node`](../../node/README.md), the addon over libkomira, which is built and
  tested here and not yet shipped. A
  `mojo_bundle`, `conda_package` or any other target elsewhere that names one
  fails analysis with a visibility error, and so does a `node_test` or
  `esbuild_bundle` elsewhere that takes the default runtime or bundler, and a
  `c_shared_lib` elsewhere that names the Node-API headers
  (`:node[include]`). `c_shared_lib` itself names no Node.js target and
  builds from any package. The one exception is the package of test 54's
  planted defects, `tests//negative/node`, which must fail and is in the
  `tests` cell that only komira's own checkout has: it sees `:node`, the
  packages and their downloads there.
- **What a test hands on.** A `node_test`'s only output is its pass marker:
  it provides no runtime, package or library to a target depending on it.
- **What a package holds.** A `conda_package` holds only a `.mojoc` and a
  README (`komira_pack conda-check`,
  [package/README.md](../../tools/build/package/README.md)), which no
  JavaScript file or addon can become.
