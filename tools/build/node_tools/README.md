# node_tools

The program the `node_modules` rules ([`tools/build/node/modules.bzl`](../node/modules.bzl)) run. A Zig tool, as every
build tool under [`tools/build`](../README.md) is, built behind its unit tests; the rules run it directly, with no shell.

```
node_tools assemble <spec.json> <out>   node_modules from a package-lock.json and the pinned tarballs
node_tools run <spec.json> <out>        a program of node_modules run by the pinned node over a copy of a source tree
```

The spec is written by the rule (paths relative to the action's working directory). The contract and the planted
defects are in [the node README](../node/README.md#node_modules-from-a-package-lockjson).

| file | what it holds | its tests |
|---|---|---|
| [`main.zig`](main.zig) | arguments and spec parsing | the farm targets of `komira_test_npm_modules` |
| [`layout.zig`](layout.zig) | the lockfile walk: tarball, integrity, package.json, platform, bundled packages, `.bin`, the report | [`layout_test.zig`](layout_test.zig): nested, aliased, scoped, bundled, platform-specific, install-script and bin cases; every refusal with its message |
| [`unpack.zig`](unpack.zig) | npm's unpacking: first component dropped, links not extracted, modes, no escape | [`unpack_test.zig`](unpack_test.zig) |
| [`sri.zig`](sri.zig) | `sha512-<base64>` | [`sri_test.zig`](sri_test.zig): the empty-file vector |
| [`platform.zig`](platform.zig) | npm's os/cpu/libc test | [`platform_test.zig`](platform_test.zig) |
| [`runner.zig`](runner.zig) | the copy, the link, the environment, the child process | [`runner_test.zig`](runner_test.zig): the environment, the scratch directory, the copy's modes; node itself is run by the targets of `komira_test_npm_modules` |

Test support: [`tartest.zig`](tartest.zig) builds tar and gzip archives in memory.

## node_act

`node_act` is the second program of this directory: the actions of the `node_dist`, `npm_package`, `node_test`, `node_binding_test`, `npm_install_test` and `esbuild_bundle` rules
([`tools/build/node/defs.bzl`](../node/defs.bzl)), which but `npm_install_test`'s were busybox scripts. A Zig tool, built behind its unit tests; no shell.
`:node_act_darwin` is the same sources built for macOS arm64 by the same zig on the linux execution
platform; the macOS Node.js dists and the npm packages' macOS install test (their `act`) run it on a macOS
worker, since they run the macOS `node`.

```
node_act dist --archive <tgz> --out <dir> --top <dir> --version <v> --libs <dir>
node_act dist --archive <tgz> --out <dir> --top <dir> --version <v> --foreign macho-arm64
node_act npm-package --tarball <tgz> --out <dir> --name <n> --version <v> --integrity <sha512-b64> --exe <path|-> --node <dir> --libs <dir> --js <program>
node_act node-test --node <dir> --libs <dir> --out <file> --dir <dir> --script <path> --expect <pass|fail> --error <text> -- <args>...
node_act binding-test --node <dir> --libs <dir> --out <file> --dir <dir> [--cover <path>]... -- <test file>...
node_act install-test --node <dir> --libs <dir> --npm <dir> --out <file> --dir <dir> --install <tgz> [--tarball <tgz>]... -- <test file>...
node_act esbuild-bundle --esbuild <exe> --dir <dir> --entry <path> --out <file> --format <cjs|esm>
```

`dist --foreign macho-arm64` is for an archive built for macOS arm64, which this platform cannot run: it takes no
`--libs` and does not run `bin/node`. It refuses an archive whose `bin/node` does not start with the Mach-O 64-bit
arm64 header (an ELF file, another cputype, a shorter file are named) or whose `include/node/node_version.h` does not
state `<v>` (`NODE_MAJOR_VERSION`, `NODE_MINOR_VERSION` and `NODE_PATCH_VERSION`, each defined as a number).

| file | what it holds | its tests |
|---|---|---|
| [`node_act.zig`](node_act.zig) | the six subcommands, their messages and exit statuses (those of the scripts), the environments node is run in | [`node_act_test.zig`](node_act_test.zig) and `tests//functional/node_act:driver` (a stand-in for node, for an npm package's executable and for esbuild) |
| [`act_util/extract.zig`](../act_util/extract.zig) | `tar -xzf` of the entries below one top directory, kept by a predicate: the archive's modes (executable or 0644), links kept (shared with the python rule) | [`extract_test.zig`](../act_util/extract_test.zig): another top, `..`, links, modes |

`binding-test` with `--cover` (`node_binding_test`'s `covered_srcs`) also has node write an lcov
report of exactly those files, and fails, printing each file's lines and branches hit of found, unless
every one has a record (`<path> is to be covered, and no test loaded it`) and their lines and their
branches together are each at least 99% covered (`the line coverage of the covered sources is <p>% (<h>
of <f> lines), under 99%`, and the same for branches).

`install-test` reads each tarball's package name from its top `package.json` (any top directory, as npm
drops it), writes the project's `package.json` (the `--install` package a `file:` dependency, every other
an override), runs npm, refuses a package its `package-lock.json` marks `hasInstallScript` (`install_test:
npm reports an install script in <path>, and npm install is the only step: a package runs nothing at
install`), and then runs the tests as `binding-test` does, from the project. Its unit tests hold each of
those parts; npm itself runs in `//node:install_test` and the `install_*` cases of `tests//negative/node`.

The `c_shared_lib` rule needs no tool of its own: it runs the pinned zig through `zig_launch`.
