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
| `node_dist(name, archive, top, version, native_libs)` | a Node.js release archive (`.tar.gz`, linux-x64) unpacked by `node_act dist` (no shell) and reduced to `bin/node`, `include/node` (the Node-API headers) and `LICENSE`; npm, npx and corepack are left out. Fails unless that `node` runs and prints `v<version>` (`node_dist: the node in <archive> is <got>, the pin says v<version>`). `native_libs` is a directory whose `lib/` holds the libraries `node` links beyond glibc. The sub-target `[include]` is the header directory. |
| `npm_package(name, package, version, integrity, tarball, exe, deps)` | one npm tarball's `package/` directory. Before unpacking, the tarball's sha512 must equal `integrity`, the registry's `dist.integrity` (`sha512-<base64>`); after, the top-level `"name"` and `"version"` of its `package.json`, parsed by the pinned `node` (`JSON.parse`, as npm reads it), must be the strings `package` and `version` (a nested key, a missing key or a number does not count), and with `exe` (a path in the package), that file must run and print `version`. `deps` are the packages it imports; a closure holding one package at two versions fails analysis. |
| `node_test(name, src, srcs, data, deps, args, expect_error, node)` | runs `src` with the pinned `node` as a build action; its output (`<name>.pass`) exists only if the script passed (exit 0), so building the target is running the test. With `expect_error`, the script passes only if it exits non-zero and its stderr holds that text. `srcs` are staged next to `src` at their package paths and `data` (`{dest: source}`, a build output allowed) at `dest`, so a script finds them through `__dirname`; the closure of the `npm_package` targets in `deps` is staged under `node_modules/<package>` beside the script, where node resolves a bare import (`import ... from 'apache-arrow'`). `args` are the script's arguments (`$(location ...)` expands, relative to the action's working directory). `node` defaults to `komira//third_party/node:node`. |
| `esbuild_bundle(name, entry, srcs, deps, format, out, esbuild)` | `entry` bundled by the pinned esbuild (`--bundle --platform=node`) into one file, `out` (default `<name>.js`), in `format` (`cjs`, the default, or `esm`). `srcs` (JavaScript or TypeScript; esbuild strips the types) are staged next to `entry` at their package paths, and the closure of the `npm_package` targets in `deps` under `node_modules/<package>`. An import of anything else fails the build. A `node_test` runs the bundle as its `src`. |
| `c_shared_lib(name, srcs, headers, include_dirs, copts, out, zig_triple)` | C `srcs` compiled and linked into one shared library by the pinned zig: `zig cc -target <zig_triple> -shared -fPIC -O2 -fvisibility=hidden -Wall -Werror -Wl,-z,undefs`. A symbol the sources use and do not define stays undefined, for the program that loads the library to resolve: a Node-API addon's `napi_*` functions are `node`'s. Only symbols with default visibility are exported (a Node-API module's `napi_register_module_v1`). `headers` are staged with the sources, and their directory is an `-I`; each of `include_dirs` is a directory output, an `-I` (`//third_party/node:node[include]`). `out` defaults to `lib<name>.so`; a Node addon names it `<x>.node`. `zig_triple` defaults to the linux x86_64 row's (its glibc floor, [platform table](../platforms/table.bzl)). |
| `node_binding_test(name, srcs, data, deps, node)` | runs the test files `srcs` (plain `.mjs` or `.js` files using the built-in `node:test`; no npm install) with the pinned `node --test --test-reporter=tap` as a build action, from the staged directory (`srcs` at their package paths, `data` at its destinations, the `deps` closure under `node_modules/`). The output (`<name>.pass`) exists only if node exited 0 **and** the TAP summary reports tests that all passed, with none skipped or todo and no file standing in as its own test (node reports a file that registers no test as one passing test named by its path). `data` is where a built `.node` addon goes, so the test loads it with `require()`. `node` defaults to `komira//third_party/node:node`. |
| `node_addon(name, srcs, headers, copts, node_include)` | a Node-API addon: `c_shared_lib` named `<name>.node`, compiled against the Node-API headers of the pinned node (`node_include`, default `komira//third_party/node:node[include]`, the `include/node` directory of the same archive as the runtime). |

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

### Planted defects

Every target of [`tests//negative/node`](../tests/negative/node/BUCK) must
fail. The self-test scenario
[`planted_red_builds_node`](../selftest/planted_red_builds_node.zig) requires
each build to fail in an action on the farm, printing the text its row holds;
the analysis refusals (the three rows that say so) are the scenario
[`analysis_refusals_node`](../selftest/analysis_refusals_node.zig), which
requires each one's exact message:

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
| `exe_other_version` | `npm_package` refuses an `exe` that runs and prints another version (`bin/echo`, a 191-byte static program that writes its first argument, as `echo` does) |
| `version_differs_node`, `version_prefix_node`, `version_suffix_node` | `node_dist` refuses a `node` that prints another version: `24.20.0`, `24.21` (a prefix of `24.21.0`) and `4.21.0` (a suffix) |
| `not_node`, `no_bin_node`, `no_header`, `header_is_dir`, `node_not_executable` | `node_dist` refuses an archive that is no Node.js release, one with the Node-API header but no `bin/node`, one with `bin/node` but no header, one whose `node_api.h` is a directory, and one whose `bin/node` is not executable |
| `node_does_not_run` | `node_dist` refuses a `bin/node` that exits non-zero (busybox under the name `node`) |
| `warns` | `c_shared_lib` fails on a warning (`-Wall -Werror`) |
| `binding_fails` | a failing test of a `node_binding_test` fails the target with node's status and its TAP output on stderr |
| `binding_no_test`, `binding_skipped` | node exits 0 for a file that registers no test and for a skipped test; `node_binding_test` still fails, since nothing was checked |
| `binding_addon_missing`, `binding_addon_wrong` | an addon test fails when the addon is not staged (not built), and when the addon is built and loads but returns another number |
| `binding_no_srcs` | analysis refuses a `node_binding_test` of no file |

The fixtures name the pinned runtime, packages and downloads, which
[`third_party/node/BUCK`](../../../third_party/node/BUCK) makes visible to
that package only where the `tests` cell exists; the archives of
`no_bin_node`, `no_header`, `header_is_dir`, `node_not_executable` and
`node_does_not_run` are built in that package (`stand_in_archive`). The npm
tarballs of `name_nested`, `name_absent`, `version_nested`, `version_number`,
`nested_distractors` and `exe_other_version` are checked in (`package_json/`)
and pinned at their own sha512: a tarball built in the action would carry
the worker's file owner and times, so it would have no fixed digest.

## node_modules from a package-lock.json

[`modules.bzl`](modules.bzl) adds the rules a TypeScript project needs: `node_modules` laid out from its
lockfile, and the programs of those packages (`tsc`, `jest`, `cdk`) run over its sources. They are the offline
equivalent of `npm ci --ignore-scripts` followed by `npm test`. They share the other rules' runtime (the pinned
node; nothing inherited from the host, UTC, a scratch `HOME`, no network), but no shell runs: `node_tools`, a Zig
program, lays out the tree and starts node.

```
load("@komira//tools/build/node:modules.bzl", "cdk_synth", "jest_test", "npm_modules", "tsc_check")
load(":pins.lock.bzl", "NPM")        # written by `kpin lock` / `kpin update` from package-lock.json

npm_modules(name = "modules", lockfile = "package-lock.json", npm = NPM)
tsc_check(name = "typecheck", modules = ":modules", srcs = glob(["bin/**", "lib/**", "test/**", "tsconfig.json"]))
jest_test(name = "test", modules = ":modules", srcs = glob([...]))
```

| rule or macro | what it builds |
|---|---|
| `npm_modules(name, lockfile, npm, tarballs)` | The `node_modules` directory of `lockfile` (lockfileVersion 3). `npm` is the `NPM` table of the kpin lock: the macro declares one `pinned_file` per entry (sha256 and size from the lock) unless `tarballs` ({`name@version`: label}) names the files. The assembly ([`node_tools`](../node_tools/README.md), a Zig program: no shell, no node) checks, per package: a tarball exists for it; the lock's `sri512` equals the lockfile's `integrity`; the tarball's sha512 equals it; the unpacked `package.json` states the locked name and version. It unpacks at the path the lockfile gives (nested `node_modules` included, the first path component of the tarball dropped, as npm does), files `0644` or `0755` when the tarball marks them executable, links in the tarball not extracted, and creates `.bin/<cmd>` relative links (the target made executable) in the `node_modules` directory that holds each package. An optional package whose `os`, `cpu` or `libc` excludes linux x64 (fsevents) is skipped; a non-optional one fails. Bundled packages (`inBundle`) come from their parent's tarball and must be there. **No install script runs.** The tree holds `.komira-node-modules.json`: the count of packages, the install scripts not run and what was skipped. |
| `node_tree_test(name, program, modules, srcs, data, args, env, tools)` | Runs `program` (a path in the package, e.g. `node_modules/.bin/tsc`) with the pinned node and `args`, in a copy of `srcs` (staged at their path in the cell) and `data` ({destination from the cell root: source}, a build output allowed) with `modules` linked in as the package's own `node_modules`; the working directory is the package. The environment is exactly `LC_ALL=C TZ=UTC0`, `HOME` and `TMPDIR` in the action's scratch, `PATH` (the pinned node's `bin`, then a directory of the `tools` links: `{"bzip2": "komira//tools/build/toolchains:busybox"}` makes `bzip2` run busybox's applet; no other command is there), `LD_LIBRARY_PATH` (its C++ runtime) and `env`; the host's is never inherited. The target `<name>.pass` exists only if the program exited 0. Sibling packages' files a test reads by relative path (`../access/x.json`) are `data` at their cell path. |
| `node_tree_build(name, program, ..., out_dir)` | The same, and the target is the directory `out_dir` of the package after the program passed. |
| `tsc_check(name, modules, srcs, data, project)` | `tsc --noEmit -p <project>`. |
| `tsc_build(name, modules, srcs, data, project, out_dir)` | `tsc -p <project>`; the target is `out_dir` (`dist`). |
| `jest_test(name, modules, srcs, data, config, max_workers)` | `jest --ci --maxWorkers=<max_workers> --cacheDirectory=.jest-cache --watchman=false --config <config>`; the cache is in the scratch copy, and a run that finds no test fails. `max_workers` defaults to 2: ts-jest workers reach about 1.6 GB each. |
| `cdk_synth(name, modules, srcs, app, data, context, env)` | `cdk synth --quiet --app <app> --output cdk.out --no-version-reporting --no-notices` with `context` as `-c key=value`. There is no `npx`, so `app` is the command of cdk.json with `node node_modules/.bin/ts-node ...` for `npx ts-node ...`. `env` is the account and region of the test (`CDK_DEFAULT_ACCOUNT`, `CDK_DEFAULT_REGION`); a context lookup would need AWS and fails. |

`node` (the test macros) defaults to `komira//third_party/node:node`, which only the test-only packages see. A repository that
uses komira as a cell declares its own `node_dist` (rules are loaded once per cell, so a provider of
komira's own load is not the consuming repository's: upstream facebook/buck2#683) and passes it as `node =`.

Limits: linux x86_64 only; a package with an install script that does something other than build a native
addon works only if it needs no script (the lockfile's `hasInstallScript` entries are listed in the report); a
dependency from git or a file path has no tarball and kpin refuses it.

### Planted defects of the node_modules rules

Every target of [`tests//negative/npm_modules`](../tests/negative/npm_modules/BUCK) must fail, printing the text its
row in scenario [`planted_red_builds_npm_modules`](../selftest/planted_red_builds_npm_modules.zig) holds:

| planted defect | what it proves |
|---|---|
| `package_not_pinned` | a lockfile package with no tarball in the pinned lock is an error naming the package |
| `pinned_lock_disagrees` | the pinned lock's sri512 is held to the lockfile's integrity |
| `tarball_bytes_differ` | a tarball whose bytes have another sha512 than the lockfile's integrity is refused |
| `package_json_differs` | a tarball whose package.json states another name or version is refused |
| `bundled_missing`, `other_os_not_optional` | a bundled package its parent lacks, and a non-optional package for another os, are refused |
| `program_absent`, `synth_wrong_context`, `synth_no_env`, `tool_not_declared` | a program node_modules lacks, a failing program, an environment variable the target does not set, and a command the target did not name in `tools` (the host's commands are not on PATH) fail the target |
| `out_dir_not_written` | an `out_dir` the program never wrote fails |
| `type_error`, `jest_fails`, `jest_finds_nothing` | a type error, a failing test and a run that finds no test each fail |

## Limits

- linux x86_64 only: the archive is Node's `linux-x64` build, and the zig
  triple is that row's.
- macOS needs three things: a pin of Node's `darwin-arm64` archive (and `darwin-x64` for Intel) in
  [`third_party/node/pins.bzl`](../../../third_party/node/pins.bzl) with its sha256 from the release's signed
  `SHASUMS256.txt`; a `node_dist` over it (the archive's `bin/node` and `include/node` have the same layout, and the
  Darwin `node` links only system libraries, so `native_libs` is empty there); and the macOS rows of the
  [platform table](../platforms/table.bzl) as the execution platform and `zig_triple` (`aarch64-macos`), which
  `node_addon` takes from the table instead of the linux row. The macros fix the linux x86_64 execution platform
  today. A macOS addon also links with `-undefined dynamic_lookup`, since `c_shared_lib` passes `-z undefs` (an ELF
  flag) only on linux.
- `c_shared_lib` links C sources only: no archive, shared library or other
  target is linked in.
- `npm_package` runs the pinned `node` to parse `package.json`, so every
  package depends on the runtime.
