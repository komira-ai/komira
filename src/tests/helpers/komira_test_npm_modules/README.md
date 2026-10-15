# komira_test_npm_modules

The tests of the `node_modules` rules ([`tools/build/node/modules.bzl`](../../../../tools/build/node/modules.bzl),
[README](../../../../tools/build/node/README.md#node_modules-from-a-package-lockjson)): a lockfile laid out
as `npm ci --ignore-scripts` would lay it out, and the node programs that run over it. Every target is a build
action on the farm; building it runs it. The package has no Mojo library.

This package is a lockfile of seven small packages whose tarballs are checked in
([`tarballs/`](tarballs)), so no download is involved. [`komira_test_npm_modules_ts_jest`](../komira_test_npm_modules_ts_jest/BUCK) is the real
thing: typescript, jest, ts-jest and their 270-odd dependencies, pinned by kpin
([`pins.lock.bzl`](../komira_test_npm_modules_ts_jest/pins.lock.bzl)).

| target | what it proves | the defect it catches |
|---|---|---|
| `:layout` ([`check_layout.js`](check_layout.js)) | A nested `node_modules` (fx-a sees its own fx-b 2.0.0, the top level has 1.0.0), an alias, a scoped package whose tarball has no `package/` directory, and a bundled dependency each resolve as npm would install them; the install script did not run; a symlink entry of a tarball was not extracted; an optional package for darwin is not installed; `.bin/fx-a` is a relative link to an executable file and plain files are not executable; the assembly's report names the skipped package and the install script not run | a layout that flattens nested versions, runs install scripts, follows tarball links, installs other platforms' packages or loses `.bin` |
| `:bin_runs` | The `.bin` link runs as a program under the pinned node and the program finds its nested dependency | a `.bin` link that does not resolve, or an executable bit lost |
| `:synth` | `cdk_synth` passes `synth --quiet --no-version-reporting --no-notices`, the context as `-c key=value`, and the environment it was given and no other (the stand-in `aws-cdk` fails unless it gets them), and the `cdk.out` it wrote is the program's own scratch | a macro that drops the context or the flags that keep the real command line off the network, or an environment that leaks in |
| `komira_test_npm_modules_ts_jest:typecheck` | `tsc --noEmit -p tsconfig.json` over a copy of the sources with the locked typescript, `@types/node` and `@types/jest` | a node_modules tree missing the types |
| `komira_test_npm_modules_ts_jest:jest` | `jest --ci --maxWorkers=2` with ts-jest compiles and runs a test, with its cache in the copy (`.jest-cache`), `node_modules` linked in the working directory | a tree jest cannot resolve from, or a cache directory it cannot write |
| `komira_test_npm_modules_ts_jest:dist_is_compiled` (`:dist`) | `tsc_build`'s target is the directory the compiler wrote, and another target can stage it (`data`) and load the JavaScript | an `out_dir` that is not exported, or one staged at the wrong path |

The defects the rules refuse are the planted builds of
[`tests//negative/npm_modules`](../../../../tools/build/tests/negative/npm_modules/BUCK): scenario
[`planted_red_builds_npm_modules`](../../../../tools/build/selftest/planted_red_builds_npm_modules.zig).

## The fixtures

`tarballs/*.tgz` were made with `tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner` and
`gzip -n -9` from the directories named in each package's `package.json`; the lockfile and
[`fixtures.bzl`](fixtures.bzl) (the `NPM` table kpin would write: the URLs are placeholders no build
fetches) hold their sha512 and sha256. `komira_test_npm_modules_ts_jest/package-lock.json` is the part of a service's lockfile that
jest, ts-jest and typescript need.
