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

A weekly GitHub Action would run `update`, and open a pull request when it exits 0 with a changed file, or an issue
when it exits 3. That workflow is not added yet; `update` is the command it would run. The pull-request check would
run `check`, with `--previous` on the lock of the base commit.

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

- TLS 1.3 only (the Zig 0.12 standard library client implements nothing older): `update` fails with `TlsInitializationFailed` against a server or route that answers TLS 1.2. The weekly job runs on GitHub runners, which reach registries over TLS 1.3.
- `https` only. `http` only to `127.0.0.1` or `localhost`, and only with `--allow-http-loopback` (the tests' registry).
- A `user@` in the authority is refused (`http://127.0.0.1@evil.example/` names one host and connects to another).
- Redirects are followed up to five, each re-checked; a relative `Location` is refused.
- Status 200 only; a body shorter than its `Content-Length` is an error, not a pin; downloads are capped
  (`--max-bytes`, default 1 GiB) and hashed as they stream, never held in memory.

Not in v0: a minimum age for a new version (no registry date is read), per-request timeouts, and a Cargo.lock or
`mopm.lock` reader. TLS is the Zig standard library's; the tests reach only loopback, so a real registry over TLS is
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
