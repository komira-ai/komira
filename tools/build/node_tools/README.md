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

`node_act` is the second program of this directory: the actions of the `node_dist`, `npm_package`, `node_test` and `esbuild_bundle` rules
([`tools/build/node/defs.bzl`](../node/defs.bzl)), which were busybox scripts. A Zig tool, built behind its unit tests; no shell.

```
node_act dist --archive <tgz> --out <dir> --top <dir> --version <v> --libs <dir>
node_act npm-package --tarball <tgz> --out <dir> --name <n> --version <v> --integrity <sha512-b64> --exe <path|-> --node <dir> --libs <dir> --js <program>
node_act node-test --node <dir> --libs <dir> --out <file> --dir <dir> --script <path> --expect <pass|fail> --error <text> -- <args>...
node_act esbuild-bundle --esbuild <exe> --dir <dir> --entry <path> --out <file> --format <cjs|esm>
```

| file | what it holds | its tests |
|---|---|---|
| [`node_act.zig`](node_act.zig) | the four subcommands, their messages and exit statuses (those of the scripts), the environments node is run in | [`node_act_test.zig`](node_act_test.zig) and `tests//functional/node_act:driver` (a stand-in for node, for an npm package's executable and for esbuild) |
| [`act_util/extract.zig`](../act_util/extract.zig) | `tar -xzf` of the entries below one top directory, kept by a predicate: the archive's modes (executable or 0644), links kept (shared with the python rule) | [`extract_test.zig`](../act_util/extract_test.zig): another top, `..`, links, modes |

The `c_shared_lib` rule needs no tool of its own: it runs the pinned zig through `zig_launch`.
