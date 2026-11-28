# Installing komira for Node.js

komira's Node.js package is `@komira-ai/komira` on npm. It is written in TypeScript and ships its
type declarations. This page covers installing it, what it needs, the first program, what it does not
do yet, and what to do when something goes wrong. For Python, see
[installing komira for Python](install.md); to build komira from a clone, see
[getting started](getting-started.md).

> **Not on npm yet (specified).** The package is built and tested on every pull request, but no
> release has been published to npm, so the install below does not work yet. The name
> `@komira-ai/komira` is the one the [design](design/typescript_package.md#d1-the-npm-name)
> recommends and can still change before the first release. Until then, this page describes the
> package as the tests run it.

## Install

In a project directory, with Node.js 22.12 or newer and its npm:

```sh
npm install @komira-ai/komira
```

That is the whole install. npm also installs two other packages: `apache-arrow`, the package's peer
dependency, which a query's answer is read as (npm 7 and newer install a missing peer dependency
themselves), and the one platform package that holds the engine for your machine, such as
`@komira-ai/komira-linux-x64-gnu`. The package has no install script and downloads nothing, at
install time or when it runs.

## What it needs

| | |
|---|---|
| platform | **Linux on x86_64**. Linux on arm64 and macOS on Apple silicon have platform packages in the design, but not built yet (specified). There is no Windows package. |
| C library | **glibc 2.35 or newer**, as for the Python wheel: for example Ubuntu 22.04 or newer, Debian 12 or newer and Fedora 36 or newer have it; RHEL 9 (glibc 2.34), Debian 11 and Alpine (musl) do not. `ldd --version` prints yours on its first line. |
| CPU | **x86-64-v3**: AVX2, BMI2 and FMA. Intel CPUs from Haswell on and AMD CPUs from Excavator on have it, except some low-end Pentium, Celeron and Atom models. |
| Node.js | **22.12 or newer** (the package's `engines`): 22.12 is the first Node.js 22 that loads an ES module through `require`. `//node:install_test` installs the package with npm into an empty project and runs it on Node.js 22.23.5, 24.21.0 and 26.13.1; the other tests run on 24.21.0. Deno, Bun and Electron are not supported. |
| apache-arrow | **`^21.2.0`**, the peer dependency npm installs. The tests run 21.2.0. |
| C++ runtime | the system `libstdc++`. Most systems have it; a minimal container image may need the `libstdc++6` package (Debian, Ubuntu) or `libstdc++` (Fedora, RHEL). |

The platform package carries everything else: `komira_addon.node`, a Node-API addon, and `native/`,
the engine `libkomira` as one shared library with its native libraries and the three Mojo runtime
libraries it loads, which are Modular's and come under Modular's licence (the package's
`MODULAR_LICENSE`, beside komira's Apache-2.0 `LICENSE` and `NOTICE`). It needs no Mojo installation and no package of
Modular's.

The package is an ES module with a `.d.ts` for each module. CommonJS code can `require` it on Node.js
22.12 and newer, and TypeScript reads its types with no `@types` package.

## The first program

Save this as `quickstart.mjs` in the project directory:

```js
import { writeFileSync } from "node:fs";

import * as km from "@komira-ai/komira";

console.log(km.version); // the installed version
console.log(km.abiVersion()); // the engine's C ABI version: 1009 is 1.9

// Six days of weather in three cities, as a CSV file.
writeFileSync(
  "weather.csv",
  "city,temp,rain\nOslo,3,1.5\nLima,18,0.0\nOslo,1,2.5\nPune,31,4.0\nLima,20,0.5\nOslo,5,1.0\n",
);

const s = new km.Session();
try {
  // COPY writes it as the Parquet file to query and answers the rows it wrote.
  const copied = await s.sql("COPY (SELECT * FROM read_csv('weather.csv')) TO 'weather.parquet'");
  console.log((await copied.toArrow()).toArray().map((row) => row.toJSON()));
  await s.registerParquet("weather", "weather.parquet");

  // An answer is an apache-arrow Table; a BIGINT reads as a JavaScript bigint.
  const total = await s.sql("SELECT count(*) AS days, sum(rain) AS rain FROM weather");
  console.log((await total.toArrow()).toArray().map((row) => row.toJSON()));

  // A group-by with an aggregate and an order, and the answer's schema.
  const grouped = await s.sql(
    "SELECT city, count(*) AS days, avg(temp) AS mean, max(temp) AS hottest" +
      " FROM weather GROUP BY city ORDER BY city",
  );
  const table = await grouped.toArrow();
  for (const field of table.schema.fields) {
    console.log(`${field.name}: ${field.type}${field.nullable ? "" : " not null"}`);
  }
  for (const row of table) {
    console.log(row.toJSON());
  }

  // Batch by batch, with for await.
  const hot = await s.sql("SELECT city, temp FROM weather WHERE temp > 10 ORDER BY temp DESC");
  const cities = [];
  for await (const batch of hot) {
    cities.push(...batch.getChild("city"));
  }
  console.log(cities);

  // A mistake rejects with a km.KomiraError, naming the file or the place.
  try {
    await s.registerParquet("missing", "no_such_file.parquet");
  } catch (e) {
    if (!(e instanceof km.KomiraError)) throw e;
    console.log(e.message);
  }
  try {
    await s.sql("SELECT city, count(*) FROM weather GROUP city");
  } catch (e) {
    if (!(e instanceof km.KomiraError)) throw e;
    console.log(e.message);
  }
} finally {
  s.close();
}
console.log(s.closed); // true: the session is freed
```

It needs no other file: it writes the six-row CSV file `weather.csv` itself, and the engine turns it
into the Parquet file it queries, `weather.parquet`. Then `node quickstart.mjs` prints:

```text
<version>
1009
[ { Count: 6n } ]
[ { days: 6n, rain: 9.5 } ]
city: Utf8
days: Int64 not null
mean: Float64
hottest: Int64
{ city: 'Lima', days: 2n, mean: 19, hottest: 20n }
{ city: 'Oslo', days: 3n, mean: 3, hottest: 5n }
{ city: 'Pune', days: 1n, mean: 31, hottest: 31n }
[ 'Pune', 'Lima', 'Lima' ]
parquet footer '<cwd>/no_such_file.parquet': no such file, or it cannot be read
parse: SQL syntax error: expected keyword 'by' at line 1, column 42
true
```

`<version>` stands for the version you installed, and `<cwd>` for the project directory: the
relative name `no_such_file.parquet` is resolved against it, and the error names the file komira
looked for. The two lines before `true` are the two mistakes the program makes on purpose; both are a
`km.KomiraError`, and the program prints each message.

The file is `.mjs` so that Node.js runs it as an ES module, with `await` at the top level, whatever
the project's `package.json` says. It uses `try` and `finally` rather than `await using`, which needs
Node.js 24.

This program is [`node/examples/quickstart.mjs`](../node/examples/quickstart.mjs), and what it
prints is [`quickstart.expected`](../node/examples/quickstart.expected). On every pull request,
`//node:quickstart_integration` runs it with `node quickstart.mjs` in a new project directory whose
`node_modules/@komira-ai/komira` is the built package (with its platform package and `apache-arrow`
in the package's own `node_modules`), and compares every line it prints with `quickstart.expected` (the version, the ABI version and the
directory put in). The two blocks above are those files, the second with the ABI version filled in,
and `//node:quickstart_test` fails when they differ.

What each call does:

- `km.version` is the installed version.
- `km.abiVersion()` loads the engine and returns its C ABI version as `major * 1000 + minor`.
  Importing the package loads nothing: the engine is loaded on this call or on the first `Session`,
  `registerParquet` or `sql`.
- `new km.Session(options?)` is one engine context. The options are `threads` and `memoryLimit`
  (bytes), both positive integers; with neither, the engine's defaults. `close()` is synchronous
  and can be called again; any later call on a closed session rejects with a `km.KomiraError`.
  `using` and `await using` close it too, on Node.js 24 and newer.
- `registerParquet(name, path)` reads the Parquet file's footer and registers the file as the table
  `name`. `path` is a string or a `file:` URL; a relative path is resolved against the working
  directory when the call is made, and `~` is not expanded. It returns a promise.
- `sql(query)` runs one SQL statement over the session's tables and resolves with a `km.Result`. A
  syntax error, an unknown table or column, or a construct the engine does not run yet rejects it,
  with the engine's `<step>: <reason>` message. SQL can read a CSV file by its path with
  `read_csv('<path>')`, and `COPY (<query>) TO '<path>'` writes an answer as a Parquet file.
- A `Result` is read once: `toArrow()` resolves with the whole answer as one `apache-arrow` `Table`,
  and `for await` yields its `RecordBatch`es in order instead. An answer still reads after its
  session is closed.
- `km.sql(query)` and `km.registerParquet(name, path)` do the same on a default session, made at the
  first call and never closed.

Every call that takes a table or runs a query returns a promise and runs on a native thread of the
session's own, so the event loop never waits on the engine. The package's
[README](../node/README.md) has the rest.

## What does not work yet

- **Installing from npm**: no release is published yet (above).
- **Other platforms**: Linux on arm64 and macOS on Apple silicon (specified), macOS on Intel,
  Windows, and Linux with musl (Alpine) have no platform package.
- **Older systems**: glibc older than 2.35, CPUs older than x86-64-v3, Node.js older than 22.12.
- **Registering CSV and newline-delimited JSON files by name**: `registerCsv` and `registerNdjson`
  check their arguments and reject with `km.UnsupportedOperation`. `read_csv('<path>')` in the SQL
  text reads a CSV file, as the first program does.
- **DataFrames and plans**: the package runs SQL text only.
- **Cancelling a query**: there is no cancel call.
- **Surviving a crash inside the engine**: an error the engine reports rejects with a
  `km.KomiraError`, but an abort inside the engine ends the Node.js process.
- **UDFs** in JavaScript.

## When something goes wrong

- **`npm error code E404`** for `@komira-ai/komira`: nothing is published yet (above).
- **`km.LibraryLoadError`** with `komira has no native package for ...`: this machine is not one the
  package has a platform package for (Windows, macOS on Intel, Linux with musl).
- **`km.LibraryLoadError`** with `... which holds libkomira for this platform, is not installed`: npm
  left the platform package out, after `npm install --omit=optional` for example, or the
  `node_modules` was copied from another kind of machine. Install `@komira-ai/komira` again on this
  machine, without that option. On Linux arm64 and macOS on Apple silicon the same message means
  their platform packages are not built yet (specified), and installing again does not help.
- **`km.UnsupportedCpuError`**: the CPU lacks a feature of x86-64-v3. The message lists the missing
  flags as `/proc/cpuinfo` spells them. komira raises it before it opens the engine, instead of
  letting the engine stop on an illegal instruction.
- **`km.LibraryLoadError`** naming a library file: the engine could not be loaded, and the message
  names the file and the reason, a missing file of the platform package for example (reinstalling
  it puts it back).
- **`km.KomiraError`** from `registerParquet`: the file is missing, empty, or not a Parquet file the
  engine can read. The message is the engine's, and names the file by its absolute path.
- **`km.KomiraError`** from `sql`: the message starts with the step that refused the statement:
  `parse: ...` is a syntax error and ends with `at line <L>, column <C>`, and `bind: ...` names a
  table or column the session does not have (register it first). The error's `step` is that step,
  and its `code` the engine's named code (`SQL_SYNTAX_ERROR`, `SQL_BIND_ERROR`, ...).
- **A `TypeError` or `RangeError`**: an argument of the wrong type or value, refused before the
  engine is called.

`km.KomiraError` is the base class of every error komira raises on purpose, so
`e instanceof km.KomiraError` catches all of these but the last. Anything else is a bug:
[open an issue](https://github.com/komira-ai/komira/issues) with the version, `node --version`,
`uname -m`, the first line of `ldd --version` and the full message.

## Upgrading and removing

```sh
npm install @komira-ai/komira@latest
npm uninstall @komira-ai/komira
```

Versions are `0.1.<n>`, the Python package's numbering, and a larger `<n>` is a newer release. The
package is pre-alpha: its names can still change from one release to the next.

## Keeping this page true

A pull request that changes what the package does, or what it needs, changes this page, the
[README](../node/README.md) and the [quickstart](../node/examples/quickstart.mjs) with it. The
package's name is `name` in [node/package.json](../node/package.json): `//node:quickstart_test`
fails when this page or the README installs another name, or the quickstart imports one.
