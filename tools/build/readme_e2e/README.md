# readme_e2e

The README e2e of a release: for each package moved to mopm, a check that acts as
a **user of the packaged artifact**. A fresh project installs the package from the
staged set of that release (the package's `.conda` and its closure, nothing else),
and the package's README examples are compiled and run against the installed copy,
with nothing from the source tree on the path. It tests what a user would download.

It sits between two steps of the release flow: *stage* (the set of `.conda` files
that will be published) and *publish*. It differs from the README gate of
`mojo_adopted_library` ([`mojo/adopt.bzl`](../mojo/adopt.bzl)), which compiles the
same examples against the library as the build holds it, inside the build; this one
compiles them against the bytes of the `.conda` file.

## What runs

One build action per package, on the farm, hermetic and offline
([`readme_e2e verify`](verify.zig); the rule is `readme_e2e`, [`defs.bzl`](defs.bzl)):

| phase | what it does | what fails it |
|---|---|---|
| `staged` | reads the staged set's `plan.json`: the package is an `upload` member at the release's version and names its README, which is there | a package the set lacks, a `skip` or `refuse` member, another version, no README |
| `install` | a fresh project (a `mopm.toml` of its own, nothing else) runs `mopm add <package>@=<version> --overlay <staged set>`. The lock it writes names the closure; each locked file must be the staged file byte for byte (sha256 and size, and the plan's) and is unpacked into the project's prefix, `lib/mojo/<name>.mojoc` | mopm refusing the command, a closure the set does not hold, a file that is not the pinned one, a package built for another compiler |
| `link` | only when a package of the closure declares a native library (in its `.mopm.json` or its lock entry): `mopm build --print-cmd --prefix <the unpacked closure>` prints the `mojo build` command mopm would run, and the linker words between `build` and `-o` are added to every compile below, less the `--push-state` and `--pop-state` pairs that bracket mopm's `--no-as-needed` (the toolchain's linker driver is zig's, which refuses them; a stock `mojo build` links through the system C driver). The e2e decides nothing about which library is linked or how: that is mopm's link plan. It only checks that the plan names every library the packages declare | mopm refusing the closure (a library the metadata names is not on disk: `refused (missing_file)`; two owners of one library), a command that is not a `mojo build ... -o` line, a declared library the command leaves out |
| `readme` | the README *the staged set holds* is cut into one program per example by the README examples tool ([`readme_examples`](../readme_examples/BUCK)), with relative links refused as for a README that ships in its package | a refused README, a README with no ```` ```mojo ```` example (it would test nothing) |
| `compile` | each program is built by the pinned Mojo compiler against the prefix's `lib/mojo` and nothing else (and, for a closure with native libraries, linked with the words of `link`) | an example that does not compile or link (an undefined native symbol) |
| `run` | each program is run through the gate that runs every welded test | an example that fails when run |

The target's output is a marker, written only after every phase passed, so a package
that did not pass has no output and fails the build. The last line printed is the
verdict: `PASS <package> <version>: N README example(s) ...` or `FAIL <phase>: ...`.

Nothing of the package's source tree is an input: the packages, the README and the
lock all come from the staged set. A defect that only the packaged artifact has (a
`.mojoc` built from other sources than the tests ran against, a README that names
something the package does not export, a dependency the manifest omits) fails here
and passes the build's own README gate.

### The install step

`mopm sync` installs a lock with pixi, which fetches the Mojo compiler from the
network, so it cannot run in an offline action. The e2e takes the part that is a
user's resolution from mopm, and does the unpacking itself:

* **`mopm add <package>@=<version> --overlay <staged set>`** resolves the closure
  from the staged set and writes `mopm.lock`. `--overlay` is a read-only local
  channel that has priority over the registry for the packages it holds; with a
  fully staged closure it needs no request for an index, repodata or package.
  The command also gets **`--registry <a loopback registry of the e2e's own>`**
  (see "Offline, enforced" below).
* The e2e reads the lock, checks each locked file against the staged file and the
  plan, and unpacks it into the prefix, the layout `mopm sync` leaves in
  `.mopm/.pixi/envs/default` (`lib/mojo/<name>.mojoc` and `<name>.mopm.json`;
  [`conda.zig`](conda.zig) reads a package the way a client does and refuses
  anything outside the paths mopm writes).

**Offline, enforced.** With the production registry (mopm's default) and a closure
the staged set holds entirely, mopm makes no request; with a closure member the set
lacks it would fetch that member from the network, silently on a machine that has
one. So `verify` runs mopm with `--registry` set to a loopback server of its own
([`offline.zig`](offline.zig)) that answers the one thing mopm asks of a registry that
is not the production one (`GET /index/config.json`, which names the channel the lock
records) and refuses every other request with HTTP 403 (`the README e2e is offline`),
remembering it. A package outside the set makes mopm ask for its index, so mopm fails
with the refusal; and `verify` fails on any remembered refusal (phase `install`,
naming each `GET <path>`) even when mopm exited 0, so a mopm that ignored the refusal
cannot pass on a closure it did not take from the set. (An address nothing listens on
would not do: mopm reads the configuration of a registry that is not the production
one, so it could not even lock a fully staged closure.) The scenarios
`closure_member_missing` and `swallowed_refusal` hold both.

**`--overlay` is a mopm option that releases before mopm 0.0.40 do not have.** A
mopm without it answers `add ... --overlay` with its usage text. The e2e does not skip
then: the `install` phase fails, quotes what mopm said and names the option.
`MOPM` in [`release/readme_e2e/packages.bzl`](../../../release/readme_e2e/packages.bzl) names the mopm the e2e
installs with: a pin of `buildrules-pins.toml` (`buildrules mojo sync`) that no package builds with,
so a package's own mopm pin does not move with it. Because the targets pass, the pull request check builds them (`//ci:pr` holds
`verify:all`). The switch is one change and an enforced one: `FIRST_MOPM_WITH_OVERLAY` in
`packages.bzl` names the first mopm that has `--overlay`, and `//:readme_e2e_complete` fails
analysis while a row of `EXCLUDED` ([`ci/rules.bzl`](../ci/rules.bzl)) leaves the e2e out and `MOPM` is that
release or later, and while no such row is there and `MOPM` is older (or the constant is
`None`). The comparison is [`mopm_findings`](guard.bzl); its cases are in
[`cases.bxl`](cases.bxl).

### Members the plan marks `skip`

A plan member's action is `upload` (its bytes are in the set), `skip` (the registry
already holds identical bytes, so the set does not carry them) or `refuse`. `verify`
refuses a `skip` member loudly (phase `staged`: the member is `skip`, not `upload`, so
its bytes are not in the set) rather than testing something else. Under komira's version
scheme every release bumps every package's version together, so every member is an
`upload` and `skip` cannot occur. **If komira ever publishes only the packages that
changed, this policy must be revisited:** a `skip` member's README examples would then
need its published bytes (fetched from the registry or carried in the set), and `verify`
would have to install and test them. The scenario `skipped_member` holds today's behaviour.

The release's targets run the real mopm, the real compiler and the real packages.
[`tests//functional/readme_e2e:komira_hash`](../tests/functional/readme_e2e/BUCK) is the
same pipeline over the real `.conda` of `komira_hash` with the stand-in for `mopm add
--overlay` ([`fake.zig`](fake.zig)) as mopm. It was the proof of everything but mopm's
resolution while the pinned mopm lacked `--overlay`; `//release/readme_e2e/verify:komira_hash`
now covers it, so it stays only as the one target that runs the tool with the stand-in
and a real compiler together, and can be deleted with `standin_mopm` without losing a check.

## The staged set

The directory `verify` installs from is the layout of mopm's staged set
(`spec/staged-set.md` of mopm): `plan.json`, `<subdir>/<file>.conda`, and each
member's README at the path `plan.json` names.

`readme_e2e_staged` writes it from the packages the build made
([`assemble.zig`](assemble.zig)): every member an `upload` with the sha256 and size of
its file, `manifest_sha256` (the sha256 of the `<name>.mopm.json` inside it, which
`mopm pack` prints), its README, in dependency order. A package whose name, version
or file name disagrees with the metadata inside it, or that needs a package the set
lacks, fails the build: the e2e installs offline, so the set holds the whole closure.

`readme_e2e` takes any target whose output is a directory in that layout as its
`staged`. `mopm stage` writes the same directory, and the release flow hands the e2e
that set, the one it publishes, and nothing else changes. There are three sources of
`staged` in the release's targets, and which one a build uses is
`-c komira_release.staged=<which>` ([`verify/BUCK`](../../../release/readme_e2e/verify/BUCK)):

* **`assembled`** (the default): `//release/readme_e2e:staged`, written by
  `readme_e2e_staged` from the packages the build made. The pull request check builds
  the e2e with it. It is the one that can be a build action: `mopm stage` asks the
  registry which versions exist (a request, with no token), and a build action is
  offline, so the real stage cannot run inside the build.
* **`stage`**: `//release/staged_set:set`, the files of the directory of that package,
  where the release workflow's job `mopm-stage` has had `mopm stage --out` write the set
  that `publish --staged` will publish. The files are an input of the build (uploaded to
  the farm) and are not in the repository, so the target is empty in a checkout. The e2e
  then runs on the farm against the real set; against the empty target it fails at
  phase `staged` (no `plan.json`), so a release that did not stage fails.
* **`beta`**: `//release/beta_set:set`, the files of the beta channel as the release workflow's job
  `mopm-e2e-beta` downloaded them after `mopm-publish-beta` (`release_beta_fetch`, which checked each
  file's sha256 and size against the staged plan and wrote the plan, the READMEs and the downloaded
  `.conda` files there; see `docs/ci.md`, "Verifying the beta publish"). The packages carry the version
  of that run, not the one of `packages.bzl`, so `-c komira_release.beta_version=0.1.<n>` is required
  with it. The e2e proves the README examples run on the published bytes; a package's own tests are
  not in its `.conda` and do not run.

Any other value of the option is an error.

The assembled set stays for the pull request check because it is the only one with no
network and no registry state in it: it tests, on every change, that the packages
install and their examples run. The real set tests what will be published.

## The release's targets

* [`//release/readme_e2e:staged`](../../../release/readme_e2e/BUCK): the staged set of every package moved to mopm:
  each package assembles and is the version its entry says.
* [`//release/readme_e2e/verify:<package>`](../../../release/readme_e2e/verify/BUCK): one `readme_e2e` per package.
* **`//release/readme_e2e/verify:all`**: every package. The pull request check builds
  it (it is in `//ci:pr`), and so does the release workflow:
  `./buck2 build komira//release/readme_e2e/verify:all`. It is green
  only when every package of the release passed.

The packages are the list in [`packages.bzl`](../../../release/readme_e2e/packages.bzl), the names of every
`src/<name>/mopm.toml` with its version. **`//:readme_e2e_complete`** is the guard
([`guard.bzl`](guard.bzl)): it fails analysis, naming the package, when a
`src/<name>/mopm.toml` has no entry, or an entry has no `mopm.toml` (the files are
read from the root `doc_tree`, which holds every file of the checkout). A new moved
package needs its line in `packages.bzl` and nothing else. The guard's cases
([`cases.bxl`](cases.bxl)) run in the pull request check:
`./buck2 bxl komira//tools/build/readme_e2e/cases.bxl:run`.

## Tests

Every one is a build action; the tool (`:readme_e2e`) is built only when they pass.

[`unit_test.zig`](unit_test.zig) (`:unit`) holds the package reader (a package is
read; a link, a path outside `lib/`, a name twice, a deflated member, a missing or
truncated payload and garbage are each refused), the plan and lock readers and writers
(round trip; version, duplicate, action and url refusals), the command line, the
source root the compile gets, and the offline registry (it serves its configuration,
refuses and remembers every other request, and answers for no other host), and the native-library helpers
([`native.zig`](native.zig)): the shell words of mopm's printed command, the linker words in it, and the check that a plan
names every library the packages declare (a longer name that merely ends the same way is not the library).

[`scenario.zig`](scenario.zig) runs one scenario per target (`:passes`, ...): it builds
made-up packages ([`fixture.zig`](fixture.zig)), stages them with the real `assemble`,
runs the real `verify` with the stand-ins of [`fake.zig`](fake.zig) as mopm, compiler
and gate and the real README examples tool, and checks the exit status, the verdict
line and what was and was not written.

| scenario | what it proves |
|---|---|
| `passes` | a package whose examples compile and run passes: exit 0, the verdict, the marker, the package unpacked in the prefix |
| `dependency` | the plan lists a dependency first (names sorted the other way), holds each file's hash and README, and installing the dependent unpacks both |
| `compile_error` | an example that does not compile fails the phase `compile`, naming its README line; the one before it passed; no marker |
| `run_error` | an example that fails when run fails the phase `run`, naming its line; not `compile` |
| `missing_package` | a package missing from the staged set fails `staged` and installs nothing |
| `import_outside_closure` | an example that imports a module the installed closure lacks fails `compile` with the compiler's message naming the module, although a module of that name sits in the staged set and the inputs: only the installed copy is on the path |
| `missing_file` | a member whose file is in the plan and not in the set (a lock made from the plan names it) fails `install` with verify's own message, before anything is unpacked |
| `tampered_file` | a file that is not the one a lock pins (lock from the plan's hashes) is refused before it is unpacked |
| `changed_file` | a file changed after staging (lock from the file) is not a file of the plan: refused |
| `closure_member_missing` | a closure member the staged set lacks (a plan with a hole) is asked of the offline registry, which refuses: `install` fails naming the refused `GET /index/...` and mopm's own "HTTP 403"; nothing is unpacked, no marker |
| `swallowed_refusal` | a mopm that ignores the refusal and exits 0 with a lock that leaves the member out still fails `install`: the registry remembered the request |
| `old_mopm`, `old_mopm_usage` | a mopm without `--overlay` (unknown option; the pinned release's usage text) fails `install` loudly, quoting mopm and naming `--overlay`; no marker |
| `wrong_compiler` | a package built for another Mojo than the release's fails `install` |
| `wrong_version` | a release version the set does not hold fails `staged` |
| `skipped_member` | a `skip` member (its bytes are not in the set) fails `staged` (policy: "Members the plan marks `skip`") |
| `no_example` | a README with no example fails `readme` (it would test nothing) |
| `refused_readme`, `relative_link` | a README the examples tool refuses, and one with a relative link, fail `readme` naming the line |
| `assemble_missing_dependency`, `assemble_cycle`, `assemble_wrong_package`, `assemble_link` | the set is not written for a member that needs a package the set lacks, for a cycle, for a file that holds another package, for a package whose payload is a link |
| `native` | a package that ships a static native library: the README calls a symbol only that archive defines, and it compiles and runs, because the compile took the archive from the command `mopm build --print-cmd` printed |
| `native_dependency` | the same when the native belongs to a package the README's package needs |
| `native_missing_archive` | the metadata declares a library and the package lacks the file: `link` fails with mopm's `refused (missing_file)` naming the archive; no example is compiled, no marker |
| `native_unlinked` | a mopm whose command leaves the shipped library out: `link` fails naming the package and the library, before any example is compiled |
| `native_undefined_symbol` | a README that calls a symbol the shipped archive does not define fails `compile` with the linker's message |
| `usage` | a command line that is not one exits 2 with the usage |

The fake mopm answers `build --print-cmd` for static natives only, in mopm's wording and shape; the fake
compiler takes `-Xlinker <archive>` and refuses a `# NATIVE_CALL <symbol>` no linked archive defines. They are
stand-ins of the printing, not of the plan: the plan is mopm's, and the target below runs it.

The tests cell's `//functional/readme_e2e:fixture_native_e2e` runs the whole path with the real things: a
Mojo package that calls a C function (`fixture_native`), the static archive of that function built by the
C toolchain, both packed by the pinned `mopm pack --native`,
installed by the pinned mopm, linked with the command that mopm's
`build --print-cmd` prints, compiled by the pinned compiler and run by the gate. The example calls the C
function, so it passes only if the archive was linked.

The fake compiler accepts a program only if every package it imports is a
`<module>.mojoc` in an `-I` directory, so `passes` and `dependency` also prove that the
installed copy, and only it, is what is compiled against.
