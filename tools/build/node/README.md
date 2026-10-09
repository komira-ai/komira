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
| `npm_package(name, package, version, integrity, tarball, exe, deps)` | one npm tarball's `package/` directory. Before unpacking, the tarball's sha512 must equal `integrity`, the registry's `dist.integrity` (`sha512-<base64>`); after, its `package.json` must state `package` as `"name"` and `version` as `"version"`, and with `exe` (a path in the package), that file must run and print `version`. `deps` are the packages it imports; a closure holding one package at two versions fails analysis. |
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

## Limits

- linux x86_64 only: the archive is Node's `linux-x64` build, and the zig
  triple is that row's.
- `c_shared_lib` links C sources only: no archive, shared library or other
  target is linked in.
- `npm_package` reads the name and version from `package.json` by text, with
  whitespace removed: a nested `"name"` or `"version"` with the same value
  would also match.
