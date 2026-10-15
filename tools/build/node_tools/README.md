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
