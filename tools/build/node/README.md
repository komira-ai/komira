# Hermetic Node.js

[`defs.bzl`](defs.bzl) holds the rules that give tests a hermetic Node.js:
the pinned runtime, npm packages, a test rule, a bundler rule and a rule for
C shared libraries such as Node-API addons. The runtime and the packages are
pinned in [`third_party/node`](../../../third_party/node/README.md); the
tests of all of it are
[`src/tests/helpers/komira_test_node`](../../../src/tests/helpers/komira_test_node/README.md).
This directory is not a Buck2 package: it holds only the rules, which the
BUCK files load as `@komira//tools/build/node:defs.bzl`.

Node.js here is test-only. Nothing built with these rules is shipped
([third_party/node](../../../third_party/node/README.md#never-shipped)).

## Rules

| rule | what it builds |
|---|---|
| `node_dist(name, archive, top, version, native_libs)` | a Node.js release archive (`.tar.gz`, linux-x64) unpacked by busybox `tar` and reduced to `bin/node`, `include/node` (the Node-API headers) and `LICENSE`; npm, npx and corepack are left out. Fails unless that `node` runs and prints `v<version>` (`node_dist: the node in <archive> is <got>, the pin says v<version>`). `native_libs` is a directory whose `lib/` holds the libraries `node` links beyond glibc. The sub-target `[include]` is the header directory. |
| `npm_package(name, package, version, integrity, tarball, exe, deps)` | one npm tarball's `package/` directory. Before unpacking, the tarball's sha512 must equal `integrity`, the registry's `dist.integrity` (`sha512-<base64>`); after, the top-level `"name"` and `"version"` of its `package.json`, parsed by the pinned `node` (`JSON.parse`, as npm reads it), must be the strings `package` and `version` (a nested key, a missing key or a number does not count), and with `exe` (a path in the package), that file must run and print `version`. `deps` are the packages it imports; a closure holding one package at two versions fails analysis. |
| `node_test(name, src, srcs, data, deps, args, expect_error, node)` | runs `src` with the pinned `node` as a build action; its output (`<name>.pass`) exists only if the script passed (exit 0), so building the target is running the test. With `expect_error`, the script passes only if it exits non-zero and its stderr holds that text. `srcs` are staged next to `src` at their package paths and `data` (`{dest: source}`, a build output allowed) at `dest`, so a script finds them through `__dirname`; the closure of the `npm_package` targets in `deps` is staged under `node_modules/<package>` beside the script, where node resolves a bare import (`import ... from 'apache-arrow'`). `args` are the script's arguments (`$(location ...)` expands, relative to the action's working directory). `node` defaults to `komira//third_party/node:node`. |
| `esbuild_bundle(name, entry, srcs, deps, format, out, esbuild)` | `entry` bundled by the pinned esbuild (`--bundle --platform=node`) into one file, `out` (default `<name>.js`), in `format` (`cjs`, the default, or `esm`). `srcs` (JavaScript or TypeScript; esbuild strips the types) are staged next to `entry` at their package paths, and the closure of the `npm_package` targets in `deps` under `node_modules/<package>`. An import of anything else fails the build. A `node_test` runs the bundle as its `src`. |
| `c_shared_lib(name, srcs, headers, include_dirs, copts, out, zig_triple)` | C `srcs` compiled and linked into one shared library by the pinned zig: `zig cc -target <zig_triple> -shared -fPIC -O2 -fvisibility=hidden -Wall -Werror -Wl,-z,undefs`. A symbol the sources use and do not define stays undefined, for the program that loads the library to resolve: a Node-API addon's `napi_*` functions are `node`'s. Only symbols with default visibility are exported (a Node-API module's `napi_register_module_v1`). `headers` are staged with the sources, and their directory is an `-I`; each of `include_dirs` is a directory output, an `-I` (`//third_party/node:node[include]`). `out` defaults to `lib<name>.so`; a Node addon names it `<x>.node`. `zig_triple` defaults to the linux x86_64 row's (its glibc floor, [platform table](../platforms/table.bzl)). |

The macros set `exec_compatible_with` to the linux x86_64 execution
platform: every action runs the linux binaries.

## What an action runs

```
env -i LC_ALL=C TZ=UTC0 HOME=<scratch>/home TMPDIR=<scratch>/tmp \
    LD_LIBRARY_PATH=<native_libs>/lib <dist>/bin/node <staged>/<src> <args>
```

- `node` links `libstdc++.so.6` and `libgcc_s.so.1`. `LD_LIBRARY_PATH` names
  the copies unpacked from the pinned conda-forge packages, so the loader
  finds them before the worker's; glibc comes from the worker (the host
  floor, [toolchains](../toolchains/README.md)). Test `isolation` fails if
  either is mapped from anywhere else.
- `env -i`: the environment is those five variables and nothing else, so no
  `NODE_OPTIONS`, `NODE_PATH` or `PATH` reaches `node`, and `HOME` and
  `TMPDIR` are the action's own scratch directories. `TZ=UTC0` is a POSIX
  rule: local time is UTC, read from no zone file. Node's ICU data is built
  into the binary, so no locale or zone data is read from the worker.
- The script's directory is staged under `buck-out` with its `srcs` and
  `data`; the action's input is that whole directory.
- esbuild (a static executable) runs with an empty environment from the
  staged directory, so the path comments in a bundle are paths in it
  (`main.mjs`, `node_modules/apache-arrow/...`).
- `zig cc` runs with its caches in the action's scratch directory, as in
  `c_exe` ([native](../native/README.md)).

## Tests

What works is tested by
[`src/tests/helpers/komira_test_node`](../../../src/tests/helpers/komira_test_node/README.md).

### Test 54: planted defects

Every target of [`tests//negative/node`](../tests/negative/node/BUCK) must
fail, and [`node_tests.sh`](../tests/node_tests.sh) (run by
`tools/build/tests/run_tests.sh`) requires the text written above each:

| planted defect | what it proves |
|---|---|
| `script_fails`: a `node_test` whose script fails | the target fails, with the script's own error: a `node_test` is a check that can fail |
| `error_not_on_stderr`: `expect_error` text the failing script never prints | `expect_error` requires its text, not only a non-zero exit |
| `error_on_stdout`: the failing script prints the `expect_error` text on stdout only | `expect_error` reads stderr alone |
| `expected_fail_passed`: `expect_error` on a script that passes | `expect_error` requires a non-zero exit |
| `error_other_case`, `error_as_pattern`: the script's message in capitals, and a regular expression it matches (`negative fixture.fails`) | `expect_error` is matched as fixed text, with case |
| `expect_error_empty`, `exe_empty` | analysis refuses an empty `expect_error` (any stderr holds it) and an empty `exe` |
| `src_listed_twice`, `bundle_listed_twice`, `data_is_source`, `data_is_package` | analysis refuses two files staged at one path, `node_modules/<package>` included |
| `version_conflict`, `own_dep` | analysis refuses a closure holding one package at two versions, and a package among its own deps |
| `unresolved_import` | `esbuild_bundle` fails on an import of a file that is not staged |
| `integrity_not_sha512`, `integrity_empty`, `integrity_not_leading` | `npm_package` refuses an integrity that is not `sha512-<base64>`: another algorithm, an empty digest, a valid one after a leading character |
| `integrity_differs`, `integrity_last_byte`, `integrity_repeated_rows` | `npm_package` refuses a tarball whose sha512 differs from the integrity, in every byte or in the last byte only; the integrity is decoded in full even where rows of its bytes repeat (64 zero bytes; the error shows all 128 hex digits) |
| `no_package_json` | `npm_package` refuses a tarball (the Node.js archive, at its own sha512) with no `package/package.json` |
| `name_differs`, `version_differs`, `name_prefix`, `version_prefix` | `npm_package` refuses a `package.json` that states another name or version: one that differs in its last character, one that extends the pin (`tslib2`), and one the pin is a prefix of (`tsli`, `2.8` for tslib 2.8.1) |
| `exe_does_not_run` | `npm_package` refuses an `exe` that does not run |
| `name_nested`, `name_absent`, `version_nested`, `version_number` | `npm_package` reads only the top level of `package.json`: it refuses another top-level name while a nested object holds the pinned one, no top-level name while a nested object and the description hold it, another top-level version while a nested object holds it, and the number `1` for the version `"1"` |
| `nested_distractors` | the pinned top-level name and version pass with other ones nested before and after them: the target fails only at its `exe`, after the `package.json` check |
| `exe_other_version` | `npm_package` refuses an `exe` that runs and prints another version (`bin/echo`, a symlink to `/proc/self/exe`, runs the busybox that executes it as `echo`) |
| `version_differs_node`, `version_prefix_node`, `version_suffix_node` | `node_dist` refuses a `node` that prints another version: `24.20.0`, `24.21` (a prefix of `24.21.0`) and `4.21.0` (a suffix) |
| `not_node`, `no_bin_node`, `no_header`, `header_is_dir`, `node_not_executable` | `node_dist` refuses an archive that is no Node.js release, one with the Node-API header but no `bin/node`, one with `bin/node` but no header, one whose `node_api.h` is a directory, and one whose `bin/node` is not executable |
| `node_does_not_run` | `node_dist` refuses a `bin/node` that exits non-zero (busybox under the name `node`) |
| `warns` | `c_shared_lib` fails on a warning (`-Wall -Werror`) |
| `visibility:node_not_visible`: a `node_test` in the subpackage `tests//negative/node/visibility` ([`visibility.BUCK`](../tests/negative/node/visibility.BUCK), staged as its BUCK file only for this build: it fails analysis, so it must not be loadable for any query over `tests//...`) naming `komira//third_party/node:node` | the runtime is test-only: it is not visible outside the packages `_TEST_ONLY` lists and the planted defects' own package, so the target fails analysis with "is not visible" (it builds if `_TEST_ONLY` is widened to `PUBLIC`, or `_NEGATIVE` to `tests//negative/node/...`) |

The fixtures name the pinned runtime, packages and downloads, which
[`third_party/node/BUCK`](../../../third_party/node/BUCK) makes visible to
that package only where the `tests` cell exists; the archives of
`no_bin_node`, `no_header`, `header_is_dir`, `node_not_executable` and
`node_does_not_run` are built in that package (`stand_in_archive`). The npm
tarballs of `name_nested`, `name_absent`, `version_nested`, `version_number`,
`nested_distractors` and `exe_other_version` are checked in (`package_json/`)
and pinned at their own sha512: a tarball built in the action would carry
the worker's file owner and times, so it would have no fixed digest.

## Limits

- linux x86_64 only: the archive is Node's `linux-x64` build, and the zig
  triple is that row's.
- `c_shared_lib` links C sources only: no archive, shared library or other
  target is linked in.
- `npm_package` runs the pinned `node` to parse `package.json`, so every
  package depends on the runtime.
