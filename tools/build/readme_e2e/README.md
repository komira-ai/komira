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
| `install` | a fresh project (a `mopm.toml` of its own, nothing else) runs `mopm add <package>@=<version> --overlay <staged set>`. The lock it writes names the closure; each locked file must be the staged file byte for byte (sha256 and size, and the plan's) and is unpacked into the project's prefix, `lib/mojo/<name>.mojoc` | mopm refusing the command, a closure the set does not hold, a file that is not the pinned one, a package built for another compiler, one that ships a native library (the e2e links none) |
| `readme` | the README *the staged set holds* is cut into one program per example by the README examples tool ([`readme_examples`](../readme_examples/BUCK)), with relative links refused as for a README that ships in its package | a refused README, a README with no ```` ```mojo ```` example (it would test nothing) |
| `compile` | each program is built by the pinned Mojo compiler against the prefix's `lib/mojo` and nothing else | an example that does not compile |
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
  channel that has priority over the registry for the packages it holds; with the
  default registry and a fully staged closure it needs no network.
* The e2e reads the lock, checks each locked file against the staged file and the
  plan, and unpacks it into the prefix, the layout `mopm sync` leaves in
  `.mopm/.pixi/envs/default` (`lib/mojo/<name>.mojoc` and `<name>.mopm.json`;
  [`conda.zig`](conda.zig) reads a package the way a client does and refuses
  anything outside the paths mopm writes).

**`--overlay` is a mopm option that the pinned release does not have yet.** A mopm
without it answers `add ... --overlay` with its usage text. The e2e does not skip
then: the `install` phase fails, quotes what mopm said and names the option, so
`./buck2 build komira//release/readme_e2e/verify:all` is red until `MOPM` in
[`release/readme_e2e/packages.bzl`](../../../release/readme_e2e/packages.bzl) names a mopm release that has
`--overlay` (bump the pins with `buildrules mojo sync`). That is the whole switch.
Until then, the pull request check does not build those targets
(`EXCLUDED` in [`ci/rules.bzl`](../ci/rules.bzl)); remove that row when the pin moves.
The flip is one change and an enforced one: `FIRST_MOPM_WITH_OVERLAY` in `packages.bzl`
names the first mopm that has `--overlay` (`None` until one does), and
`//:readme_e2e_complete` fails analysis while the row is present and `MOPM` is that
release or later, and while the row is absent and `MOPM` is older (or the constant is
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

What is proven today, with the real compiler and the real packages, is everything but
mopm's resolution: [`tests//functional/readme_e2e:komira_hash`](../tests/functional/readme_e2e/BUCK)
runs the pipeline over the real `.conda` of `komira_hash` with a stand-in for `mopm add
--overlay` ([`fake.zig`](fake.zig)) and passes.

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
`staged`. `mopm stage` writes the same directory, so the release flow can hand the
e2e the set it will publish (`staged = <that target>`) and nothing else changes.

## The release's targets

* [`//release/readme_e2e:staged`](../../../release/readme_e2e/BUCK): the staged set of every package moved to mopm.
  It builds today, so the pull request check builds it: each package assembles and
  is the version its entry says.
* [`//release/readme_e2e/verify:<package>`](../../../release/readme_e2e/verify/BUCK): one `readme_e2e` per package.
* **`//release/readme_e2e/verify:all`**: every package. The release workflow builds
  this one target: `./buck2 build komira//release/readme_e2e/verify:all`. It is green
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
(round trip; version, duplicate, action and url refusals), the command line, and the
source root the compile gets.

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
| `old_mopm`, `old_mopm_usage` | a mopm without `--overlay` (unknown option; the pinned release's usage text) fails `install` loudly, quoting mopm and naming `--overlay`; no marker |
| `wrong_compiler` | a package built for another Mojo than the release's fails `install` |
| `wrong_version` | a release version the set does not hold fails `staged` |
| `skipped_member` | a `skip` member (its bytes are not in the set) fails `staged` (policy: "Members the plan marks `skip`") |
| `no_example` | a README with no example fails `readme` (it would test nothing) |
| `refused_readme`, `relative_link` | a README the examples tool refuses, and one with a relative link, fail `readme` naming the line |
| `assemble_missing_dependency`, `assemble_cycle`, `assemble_wrong_package`, `assemble_link` | the set is not written for a member that needs a package the set lacks, for a cycle, for a file that holds another package, for a package whose payload is a link |
| `usage` | a command line that is not one exits 2 with the usage |

The fake compiler accepts a program only if every package it imports is a
`<module>.mojoc` in an `-I` directory, so `passes` and `dependency` also prove that the
installed copy, and only it, is what is compiled against.
