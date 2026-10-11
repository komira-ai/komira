# Hermetic Node.js: the pins

The runtime and the npm packages of the tests' hermetic Node.js
([tools/build/node](../../tools/build/node/README.md)), each pinned by
sha256 and size in [`pins.bzl`](pins.bzl) and fetched like every other
pinned download (`pinned_file`): on a remote-cache hit, nothing is fetched.
npm never runs; each package is one tarball, unpacked.

| target | what |
|---|---|
| `:node` | Node.js 24.21.0 (the 24 LTS line), the `linux-x64` release archive, reduced to `bin/node`, `include/node` and `LICENSE`; `:node[include]` is the Node-API headers |
| `:native_libs` | `libgcc_s.so.1` and `libstdc++.so.6` (GCC 15.3), unpacked from the conda-forge packages the [platform table](../../tools/build/platforms/table.bzl) pins for the toolchains; every `node` action names their directory in `LD_LIBRARY_PATH` |
| `:<package>` | one npm package unpacked, named without the scope's `@` and with `/` as `_` (`:apache-arrow`, `:esbuild_linux-x64`); its `deps` are the packages it imports at run time |

## The pins

| package | version | requires | for |
|---|---|---|---|
| node | 24.21.0 | | the runtime of every `node_test` |
| @esbuild/linux-x64 | 0.28.2 | | `esbuild_bundle` (esbuild's linux x86_64 executable) |
| apache-arrow | 21.2.0 | flatbuffers, json-with-bigint, tslib | Arrow columns and IPC in JavaScript |
| flatbuffers | 25.9.23 | | apache-arrow (IPC messages) |
| json-with-bigint | 3.5.12 | | apache-arrow |
| tslib | 2.8.1 | | apache-arrow (TypeScript helpers) |

How each was checked when it was pinned:

- **Node.js.** 24.21.0 is the newest release of the 24 line in Node's
  release index (`https://nodejs.org/dist/index.json`), where its `lts` field
  names the line ("Krypton"). The pinned sha256 is the one the release's
  `SHASUMS256.txt` lists for `node-v24.21.0-linux-x64.tar.gz`, and that file's
  signature (`SHASUMS256.txt.asc`) verifies with a release key listed in
  Node's README. Node 26 is not an LTS line yet.
- **npm packages.** Each version is the package's `latest` on the registry
  (`https://registry.npmjs.org/<package>/latest`), and each dependency's
  version satisfies the range apache-arrow's `package.json` gives it. The
  pinned `integrity` is the registry's `dist.integrity`, and the sha256 is
  that of the same bytes. Only the runtime `dependencies` are pinned:
  apache-arrow's `@types/node` holds type declarations and is not imported.

The checks the build repeats: `pinned_file` refuses a download whose sha256
or size differs; `npm_package` refuses a tarball whose sha512 differs from
the integrity, or whose `package.json` states another top-level name or
version; `node_dist` refuses a `node` that does not print the pinned
version, and the `esbuild_linux-x64` target an `esbuild` that does not.

## Licences

| component | licence (SPDX) | bundled |
|---|---|---|
| Node.js | MIT | its `LICENSE` lists the licences of the code it carries (V8, libuv, OpenSSL, ICU, zlib, llhttp and others: MIT, BSD, Apache-2.0, ICU and similar permissive licences). The GPL text in it is that of build files of ICU (`aclocal.m4`, `config.guess`) under the Autoconf exception, not of code in the binary |
| esbuild (@esbuild/linux-x64) | MIT | the package holds the executable, a `README.md` and `package.json` |
| apache-arrow | Apache-2.0 | a `NOTICE.txt` |
| flatbuffers | Apache-2.0 | |
| json-with-bigint | MIT | |
| tslib | 0BSD | |
| libgcc_s, libstdc++ | GPL-3.0-or-later WITH GCC-exception-3.1 | |

None is the AGPL. The GNU-licensed code is GCC's runtime libraries, under
the GCC Runtime Library Exception, which komira's own toolchains already use
([toolchains](../../tools/build/toolchains/README.md)).

## Never shipped

The hermetic Node.js is for tests. What keeps it out of every published
package:

- **Visibility.** `:node` and every npm package are visible only to the
  packages `_TEST_ONLY` in [`BUCK`](BUCK) lists, all test-only packages under
  `src/tests` (`//:src_layout` holds that directory to test-only packages). A
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
