# komira_test_npm_modules_ts_jest

The real-tools half of the tests of the `node_modules` rules ([README](../../../../tools/build/node/README.md#node_modules-from-a-package-lockjson),
targets and what they prove: [`komira_test_npm_modules`](../komira_test_npm_modules/README.md)): typescript, jest, ts-jest and
their 270-odd dependencies, laid out from [`package-lock.json`](package-lock.json) and pinned by kpin in
[`pins.lock.bzl`](pins.lock.bzl) (`pins.toml` is empty: there is no tool to pin but npm's). `typecheck`, `jest` and `dist_is_compiled`
build; the planted type error and failing test run against `:modules` in
[`tests//negative/npm_modules`](../../../../tools/build/tests/negative/npm_modules/BUCK).
