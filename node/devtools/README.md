# node/devtools

The TypeScript compiler (`typescript` 5.9.3) and Node.js's types (`@types/node` 20.19.43, with
`undici-types`) that check and compile the Node.js package in [`node/`](../README.md): `//node:typecheck`
and `//node:dist` run `tsc` from the `node_modules` that [`BUCK`](BUCK) lays out with `npm_modules`
([tools/build/node](../../tools/build/node/README.md#node_modules-from-a-package-lockjson)). Nothing here
is shipped, and the package's own [`package.json`](../package.json) names none of it.

- [`package.json`](package.json) and [`package-lock.json`](package-lock.json): the versions, which npm owns.
- [`pins.lock.bzl`](pins.lock.bzl): each tarball's URL, sha256 and size, which kpin writes
  ([tools/build/kpin](../../tools/build/kpin/README.md)); [`pins.toml`](pins.toml) is empty, since
  there is no tool to pin but npm's. After a change to the lockfile:

  ```
  ./buck2 run komira//tools/build/kpin -- lock --pins node/devtools/pins.toml --lock node/devtools/pins.lock.bzl --npm node/devtools/package-lock.json
  ```

  `kpin-update.yml` lists this lock in `KPIN_SETS`.
