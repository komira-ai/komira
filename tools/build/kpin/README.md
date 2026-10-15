# kpin

`kpin` turns the versions people write into the URL, sha256 and size the build pins, in a generated lock that
`pinned_file` consumes. It is a Zig tool, built behind its unit tests like every tool under
[`tools/build`](../README.md).

- People edit versions: `pins.toml` for things with no lockfile of their own (toolchains, release binaries), and the
  native lockfile where there is one (`package-lock.json`, lockfileVersion 3).
- `kpin` writes `pins.lock.bzl`: per file, the URL, the sha256 and the size. Nobody edits it.
- The build never runs `kpin`. `lock` and `check` are offline; `update` is the only command that opens a socket, and
  it runs on a developer box or a scheduled runner.

A hash that changes for a version the lock already holds is an **alarm**: `kpin` exits 3 and writes nothing.
Regenerating never makes it go away.

## Commands

| command | network | what it does |
|---|---|---|
| `kpin lock` | no | Writes the lock from `pins.toml`, the `package-lock.json` files and the lock on disk. A file with no hash yet is an error ("run `kpin update`"), never a guess. |
| `kpin check` | no | Exits 1 if the lock is not byte for byte what `lock` would write (stale, or hand-edited), 3 if a hash changed for a locked version. With `--previous FILE` (the lock of the merge base) also exits 3 if the lock's own hash for a (name, version, file) differs from the base's. |
| `kpin cargo` | no | Cargo.lock, `cargo metadata` and an overrides table in, a `.bzl` of `crates_io_library` targets out (below). |
| `kpin update` | **yes** | Moves versions (pins with a `latest_url`), fetches what the lock lacks, computes sha256 and size, rewrites `pins.toml` and the lock together. Writes nothing if anything is wrong. |

Flags: `--pins FILE` (default `tools/build/pins/pins.toml`), `--lock FILE` (default `tools/build/pins/pins.lock.bzl`),
`--npm FILE` (repeatable), `--previous FILE` (`check`), and for `update`: `--verify`, `--only NAME`, `--max-bytes N`,
`--allow-http-loopback`. Exit codes: 0 ok, 1 failed, 2 usage, 3 alarm.

Run it from the repository root:

```sh
./buck2 run komira//tools/build/kpin -- lock
./buck2 run komira//tools/build/kpin -- check --previous /path/to/the/lock/of/the/merge/base
./buck2 run komira//tools/build/kpin -- update          # the weekly job's command
./buck2 run komira//tools/build/kpin -- update --verify # re-fetch everything: the republish detector
```

The weekly job is [`kpin-update.yml`](../../../.github/workflows/kpin-update.yml) (below). The pull-request check
runs `check`, with `--previous` on the lock of the base commit.

## Cargo

`kpin cargo` turns a Cargo workspace into Buck2 targets, so a crate from crates.io builds with the pinned rustc.
As with the native lockfiles, Cargo resolves (with a network, on a developer box, outside the build) and `kpin` only
reads. Inputs, all committed:

| input | flag | what kpin takes from it |
|---|---|---|
| `Cargo.lock` (version 3 or 4) | `--cargo-lock` | the sha256 of every `.crate` |
| `cargo metadata --format-version 1 --locked --filter-platform <triple>`, trimmed (it records the triple) | `--metadata`, `--target` | the packages linked into the workspace's members (normal edges only: build- and dev-dependencies are not), the features Cargo resolved for each, dependency names (a name that is not the dependency's library name becomes `renamed_deps`), library names and roots, proc-macros, and which crates have a build script |
| `<name>-<version>.crate <bytes>` lines, written by `kpin update` from its own verified download of each linked `.crate` | `--sizes` | `size`, which `pinned_file` requires |
| overrides | `--overrides` | what a build script decides for the pinned compiler |
| the pinned compiler | `--rustc` | which compiler the overrides must have been derived for |

`kpin cargo --metadata raw.json --target <triple> --trim out.json` writes the form that is committed: only what kpin
reads, with the machine's paths replaced by constant ones (`cargo metadata` names the registry cache of whoever ran
it), and the platform it was filtered for recorded. `cargo metadata` output does not say what it was filtered for, so
kpin cannot see it in raw output: the trim step, run right after `cargo metadata --filter-platform <triple>`, records
the triple, and `kpin cargo` refuses raw metadata, metadata recorded for another triple, and trimmed metadata with an
edge that names another triple (which an unfiltered run would have). Trimming is idempotent. It also drops the edges `cargo metadata` lists for an optional dependency that nothing
enabled: a crate that says `alloc = ["ring?/alloc"]` (a weak feature) makes the metadata name `ring` among its
dependencies although `ring` is not compiled and `cargo tree` does not show it (the AWS-LC build of `rustls-webpki`,
`jiff`'s `defmt`, `serde_with`'s `schemars` are such). kpin follows every normal edge, so a kept phantom edge would
build a crate and run its build script for nothing. An edge is kept when a normal declaration of the dependency in the
manifest is not optional, or a feature Cargo enabled for the crate switches it on (`dep:name` or a strong `name/feature`
entry); metadata without the manifests' declarations keeps every edge.

### Where Cargo runs

Resolution, Cargo itself (`cargo update`, `cargo metadata`, which read the registry index and may download), runs only
on a GitHub runner or on a contributor's own machine, never in a build action and never on the farm. Builds only read the
committed files. The runner does it weekly, in [`kpin-update.yml`](../../../.github/workflows/kpin-update.yml) (the
`KPIN_CARGO_SETS` lines; `workflow_dispatch` takes `cargo_update`, off to regenerate from the Cargo.lock as committed):
refresh Cargo.lock, make and trim the metadata, `kpin update --no-pins --cargo-lock .. --metadata .. --sizes .. --target ..`,
then `kpin cargo --previous-lock <the base's Cargo.lock>` and the pull request carries all of it. A Cargo.lock checksum
that differs from the base's for a crate version already locked is an alarm (exit 3), as is a download whose sha256 is not
the one Cargo.lock pins. The overrides are never written by the job: a person re-derives them (a build script with no entry
fails the job, naming the crate).

### Sizes

`pinned_file` needs a size, and neither Cargo.lock nor `cargo metadata` carries one. `kpin update` fetches each crate the
build links (the set `kpin cargo` emits; build- and dev-only crates are not fetched) from `--crates-base`
(default `https://static.crates.io/crates`) as `<base>/<name>/<name>-<version>.crate`, hashes it as it streams, refuses it
unless its sha256 is Cargo.lock's (an alarm), and writes the size. Crates already in the sizes file are not fetched again
unless `--verify` (which alarms on a different size). `--no-pins` skips `pins.toml` and the lock. `lock`, `check` and
`cargo` stay offline.

The output is a `def crates():` of `crates_io_library(...)` calls (sorted; a crate linked in two versions is
`name-version`) with `features`, `cfgs`, `env = cargo_pkg_env(...)` (the `CARGO_PKG_*` variables), `deps`,
`renamed_deps`, `proc_macro`/`proc_macro_extern`, `native_deps` and `patch`
([the Rust rules](../rust/README.md#cargo-crates)). `--check` writes nothing and exits 1 unless `--cargo-out` is exactly
that text, naming the first line that differs. [`cargo.bzl`](cargo.bzl)'s `kpin_cargo` runs both in a build: its output
is the generated file, and a validation of the target runs `--check` against the committed one, so a hand edit, a stale
file or a changed input is a red build. The compiler comes from the Rust toolchain, so a compiler bump is red until the
overrides are re-derived.

### Overrides

A build script runs code to learn about the compiler and the target. Nothing here runs one, so its answer for the pinned
compiler is written down, per crate and version:

```json
{
 "rustc": "1.99.0",
 "crates": {
  "proc-macro2 1.0.106": {"class": "a", "why": "...", "cfgs": ["wrap_proc_macro"]},
  "serde 1.0.229": {"class": "b", "why": "...", "env": {}, "patch": {"copy": ["src"], "sub": [], "add": []}},
  "aws-lc-sys 0.23.1": {"class": "c", "why": "...", "native_deps": ["komira//third_party/aws-lc:crypto[static-pic]"], "patch": {}}
 }
}
```

| class | the script | entry |
|---|---|---|
| `a` | only emits cfgs or `cargo:` metadata | `cfgs`, `env` |
| `b` | writes files the crate includes | `patch` (`sub` with a checked `count`, `add`) |
| `c` | builds native code | `native_deps` (a komira target replaces it), usually a `patch` |
| `m` | no script, but the source needs an env or an edit | any |

`rustc` is the compiler the entries were derived for; the cfgs and files are per compiler, so another compiler is an
error ("re-derive each entry"). Refused, naming the crate: a build script with no entry; an entry for a crate that is not
linked, at another version, or has no script (class `m` excepted); a class the entry does not fit (`a` with a patch,
`b` without one, `c` without `native_deps`); an unknown key (a typo is not ignored); no `why`; a patch path with `..`.
Also refused: a crate from git, a path or another registry, a missing or malformed checksum, a missing size, a feature
or name outside the character set, a Cargo.lock older than version 3, and metadata made with `--no-deps`.

## The weekly update

`.github/workflows/kpin-update.yml` runs every Monday and on `workflow_dispatch`, on a GitHub-hosted runner with no
farm and no credential beyond the default `GITHUB_TOKEN` (`contents: write`, `pull-requests: write`). It builds
`kpin` with the pinned buck2 and zig (its unit tests run first, as in any build), then for each lock listed in the
workflow's `KPIN_SETS` runs `kpin update` and `kpin check --previous <the lock as checked out>`. A `pins.lock.bzl`
in the tree that `KPIN_SETS` does not list fails the job, so a new lock is covered the day it is added.

| result | what the job does |
|---|---|
| nothing changed | green; says so in the run summary |
| a pin moved or a hash was added, exit 0 | pushes a new branch `kpin/weekly-<run id>` (a plain push, never a force-push), opens a pull request from it, then closes every older open `kpin/weekly-*` pull request with a comment linking the new one and deletes its branch |
| exit 3 (an alarm) from `update` or from `check --previous` | fails, with an error annotation; pushes nothing, opens nothing |
| exit 1 or 2 | fails; pushes nothing |

A manual run of another ref does the update and the checks and stops before the branch. `workflow_dispatch` takes
`verify`, which adds `update --verify`, the republish detector.

Two things the job cannot do for itself:

- The repository setting "Allow GitHub Actions to create and approve pull requests" must be on, or opening the
  pull request fails (the branch is pushed, the job fails with the compare URL, and the older weekly pull requests stay open).
- **A pull request opened with `GITHUB_TOKEN` starts no other workflow**, so `pr / check` does not run on it. A
  maintainer starts it by pushing an empty commit to its branch or by closing and reopening the pull request,
  and merges when it is green. (A personal access token or a GitHub App would remove the step; neither is used.)

Tried on a runner before this was merged (a throwaway branch, the workflow on a push): kpin builds there with no
farm; `update` fetches over TLS 1.3 from `ziglang.org`, `github.com` (with its redirect) and `files.pythonhosted.org`;
and it **fails with `TlsInitializationFailed`** against `registry.npmjs.org` (which answers TLS 1.2 only: OpenSSL's
`-tls1_3` and curl's `--tlsv1.3` are refused with "protocol version") and against `nodejs.org` (TLS 1.3, a Sectigo RSA
chain; the Zig 0.12 client does not get through it). So a lock that lacks an npm tarball or a nodejs.org file cannot
be completed by `update` until the fetcher changes; the job fails loudly (exit 1) and opens nothing. What no test here
can prove, and the first scheduled run does: that the pull request can be opened (the repository setting above).

## pins.toml

A subset of TOML: `[table]` headers, `key = "string"`, `key = 123`, `#` comments. No escapes, arrays or inline
tables; a file using one is refused with its line number. Unknown keys are errors (a typo is not ignored).

```toml
[zig]
version        = "0.12.0"
url            = "https://ziglang.org/download/{version}/zig-{platform}-{version}.tar.xz"
latest_url     = "https://api.example.org/zig/latest"   # optional, with latest_field
latest_field   = "tag_name"                              # a dotted path to a string in that JSON
version_prefix = "v"                                     # optional: stripped from what latest_field holds

[zig.platform.linux-x86_64]                              # one table per file the pin has; `any` for one file
[zig.platform.macos-aarch64]
token  = "macos-aarch64"                                 # optional: what {platform} becomes (default: the id)
sha256 = "..."                                           # optional, with size: a hash you supply (a bootstrap)
size   = 45480516
```

| key | meaning |
|---|---|
| `[name]` | A pin. Lower-case letters, digits, `-`, `_`. |
| `version` | The version. People edit this line. |
| `url` | A template; `{version}` and `{platform}` are the only placeholders; `http(s)` URL of a plain character set. |
| `latest_url`, `latest_field` | Both or neither. `update` reads the newest version from that JSON document and moves `version` to it if it is greater. Versions compare as dotted numbers (`1.10.0` > `1.9.0`); anything with a letter in it (`2.0.0-rc1`) is never proposed. |
| `[name.platform.id]` | One file of the pin. At least one. |
| `token` | Text for `{platform}` in `url`; defaults to the id. |
| `sha256`, `size` | Both or neither. Normally absent: `update` computes them and they live in the lock. A hash written here is checked against the bytes (`update`) and against the lock (`lock`, `check`). |

The version line is the only thing `update` ever edits in `pins.toml`; comments and everything else are kept byte for byte.

## package-lock.json

npm owns the versions (`npm install`, `npm update`); `kpin` follows the lockfile. Each package with a `resolved` URL
and a `sha512-...` integrity becomes one tarball, keyed `name@version`, once however many places in the tree name it.
Several `--npm` files merge; one `name@version` with two different integrities is an error. Refused, with the
package and the reason: another lockfileVersion, a missing `resolved`/`integrity`, a `sha1-` or `sha256-` integrity,
a URL that is not `https`. Links, bundled entries, and local entries outside `node_modules` (workspace members, link targets) have no tarball and are skipped; a `node_modules` entry with no `resolved` is still refused.

npm's integrity is a sha512. The farm's content store and `pinned_file` key on sha256, so `kpin update` fetches
each tarball once, **checks its sha512 against `package-lock.json`** (a tarball that differs is an error, nothing
is pinned), and records the sha256 and size next to the integrity. `lock` and `check` never fetch.

## pins.lock.bzl

Starlark, written by `kpin`, deterministic (entries sorted by name, then platform; one rendering). Every string
passed a strict character set before it was written (no quote, backslash, whitespace or control character), so a
value from a registry is never code in the build graph. The reader accepts exactly this shape.

```python
KPIN_LOCK_VERSION = 1

PINS = {
    "zig": {
        "version": "0.12.0",
        "files": {
            "linux-x86_64": {
                "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz",
                "sha256": "c7ae866b...045cad",
                "size": 45480516,
            },
        },
    },
}

NPM = {
    "left-pad@1.3.0": {
        "name": "left-pad",
        "version": "1.3.0",
        "url": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz",
        "sri512": "sha512-3a81oZ...",   # what package-lock.json says (npm's hash)
        "sha256": "ba7816bf...",        # what the farm's CAS and pinned_file key on
        "size": 3,
    },
}
```

[`pins.bzl`](pins.bzl) reads it:

| function | returns |
|---|---|
| `pin_kwargs(PINS, pin, platform, **extra)` | `{"url", "sha256", "size_bytes"}` plus `extra`, for `pinned_file(**...)`. |
| `pin_version(PINS, pin)`, `pin_size(PINS, pin, platform)` | The version; the size in bytes. |
| `npm_kwargs(NPM, "name@version", **extra)` | `{"url", "sha256", "size_bytes"}` plus `extra`. |

A missing name fails analysis with the names that exist. `pinned_file` requires `size_bytes`, so both pass the lock's size.

## The alarm, and what it covers

The lock is keyed by (name, version, file). The inputs and the lock on disk are compared per key:

| situation | result |
|---|---|
| new version, or a key the lock lacks | `update` fetches and pins it; `lock` says "run `kpin update`" |
| same version, same hash | nothing |
| same version, `pins.toml` or `package-lock.json` now states other bytes | **alarm** (`lock`, `check`, `update`) |
| same version, `update --verify` fetches other bytes than the lock holds | **alarm**; the old bytes stay pinned |
| same version, the lock's own hash differs from the merge base's (`check --previous`) | **alarm** (catches a hand-edited lock, which is otherwise self-consistent) |

Without `--previous`, `check` cannot tell a lock whose hash was edited by hand from a lock `update` wrote, because
for a `pins.toml` file nothing else states the hash. That is trust on first use: the lock's hash comes from the
bytes the first `update` fetched, so the first lock of a new pin needs a human to read it. The pull-request check
passes the base's lock to `--previous`.

## The network

All of it is [`fetch.zig`](fetch.zig), behind a `Fetcher` interface (`get(url, sink)`); `update` takes one, and
nothing else in `kpin` can open a socket. Policy, enforced on every request and every redirect hop:

- TLS 1.3 only (the Zig 0.12 standard library client implements nothing older): `update` fails with `TlsInitializationFailed` against a server or route that answers TLS 1.2. Of the hosts tried from a GitHub runner, `registry.npmjs.org` answers TLS 1.2 only, and `nodejs.org` fails the handshake (see "The weekly update").
- `https` only. `http` only to `127.0.0.1` or `localhost`, and only with `--allow-http-loopback` (the tests' registry).
- A `user@` in the authority is refused (`http://127.0.0.1@evil.example/` names one host and connects to another).
- Redirects are followed up to five, each re-checked; a relative `Location` is refused.
- Status 200 only; a body shorter than its `Content-Length` is an error, not a pin; downloads are capped
  (`--max-bytes`, default 1 GiB) and hashed as they stream, never held in memory.

Not in v0: a minimum age for a new version (no registry date is read), per-request timeouts, and a `mopm.lock` reader. TLS is the Zig standard library's; the tests reach only loopback, so a real registry over TLS is
proven by the first scheduled run, not by this package's tests.

## Tests

Each is a welded `zig_test`; the `kpin` executable is built only when all pass. A test names the defect it catches.

| test file | what it proves |
|---|---|
| `toml_test.zig` | The subset parses; each unsupported construct is refused with its line number. |
| `pins_test.zig` | The schema (sorted pins, token default, both-or-neither keys, template placeholders); every refusal; `setVersion` edits one line and keeps the rest byte for byte. |
| `lockfmt_test.zig` | The rendering equals the committed golden `example.lock.bzl` (which Buck2 also loads: `selftest.bzl`); it does not depend on build order; a quote, backslash, newline, space, wrong-length hash or a sha512 where a sha256 goes is refused; the reader refuses what `render` would not write. |
| `npm_test.zig` | Names from the path or `name`; scoped names; dedupe and order independence; every refusal (sha1, non-https, version 2, quotes in names); two lockfiles that disagree. |
| `resolve_test.zig` | Hashes carry over from the lock; a new version does not inherit the old hash; every alarm case; `compareToPrevious`. |
| `update_test.zig` | `update` through the real HTTP client against a registry on loopback: sha256, size and sha512 of known bytes; a tarball that is not what `package-lock.json` says; nothing re-fetched without `--verify`; republished bytes are an alarm and nothing is written; a newer version moves `pins.toml`; 404, truncated and oversize downloads; redirect policy; `urlAllowed`. |
| `cargo_update_test.zig` | `update` for Cargo through the real client on loopback: sizes from the downloaded bytes, sorted, only linked crates; nothing re-fetched without `--verify`; a crate whose bytes are not Cargo.lock's sha256 (alarm, nothing written); a size that moved (alarm); a missing crate; the flags; the sizes it wrote are the ones `kpin cargo` emits. |
| `cargo_test.zig` | `kpin cargo`: the golden output of a fixture workspace (renames, two versions of one crate, a proc-macro, a library named unlike its package, classes a, b and c, an escaped patch); build- and dev-dependencies not emitted; every refusal above; trimming; the command on real files (a hand-edited output caught by `--check` with its line, a refused input writing nothing, the stamp only on success). |
| `main_test.zig` | The commands end to end on real files: usage errors, offline `lock`/`check`, a stale lock, a version bump without `update`, a hand-edited hash against `--previous` (3), a changed integrity (3), output independent of lockfile order, `update` leaving the files untouched on an alarm. |

Planted mutants, each built red on the farm and then removed: `check` not comparing the lock to what the inputs
produce (stale lock accepted); the npm integrity comparison and `compareToPrevious` disabled (changed hash for an
unchanged version accepted); the sort removed from the lock renderer and from the lockfile merge (non-deterministic
order); the sha256 taken from the sha512 digest (sha512/sha256 mixup); `update` not checking the tarball against
`package-lock.json`, and not alarming on a re-fetched file that changed.

## Files

`main.zig` (arguments, the three commands), `pins.zig` and `toml.zig` (pins.toml), `npm.zig` (package-lock.json),
`resolve.zig` (the offline core), `lockfmt.zig` (the lock: model, rendering, reader), `update.zig`, `fetch.zig`,
`valid.zig` (the character sets), `diag.zig`. Test support: `fixtures.zig`, `registry.zig` (the loopback registry).
