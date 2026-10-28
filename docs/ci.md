# Continuous integration

A pull request from a branch of this repository runs ONE check: `pr / check`,
the one job `check` of [`.github/workflows/pr.yml`](#pryml-the-pull-requests-check),
a workflow of its own, on a GitHub-hosted runner that reaches the build farm
over a tailnet. The runner is
a thin buck2 client: it checks the repository out and asks the farm to build
and test the targets the change reaches ([pr.yml](#pryml-the-pull-requests-check)).
Nothing is compiled on the runner.

| event | runs |
|---|---|
| push to `main` | [`release.yml`](#releaseyml-the-release): builds the release set and publishes the mopm packages to the prod registry, on every push (no schedule, no switch); when that run ends, [`main_red.yml`](#main_redyml-the-main-red-alert) |
| pull request from a branch of this repository | `pr / check`; and `coverage`, informational, not required ([below](#coverageyml-the-pull-requests-coverage-not-a-gate)) |
| pull request from a fork | nothing: no farm job runs ([below](#pull-requests-from-forks)) |
| manual (`workflow_dispatch`) | [`release.yml`](#releaseyml-the-release), on the chosen ref, with a reason |
| weekly (schedule) and manual | [`kpin-update.yml`](../tools/build/kpin/README.md#the-weekly-update): updates the pins and opens one pull request; no farm, and its pull request does not start `pr / check` by itself. A manual run with `real_hosts` instead checks kpin against the real registries |

There is no separate static or lint job, and no other pull request check
that can block a merge: the `coverage` workflow only reports. The scheduled
runs are the [build-system self-tests](#build-system-self-tests), which are not
the gate, and the weekly [`kpin-update.yml`](../tools/build/kpin/README.md#the-weekly-update),
which opens a pull request and gates nothing.
`ci.yml` and its check `ci / build` no longer exist. The whole-repository
`//...` build they ran on every push to `main` is not run by any workflow now;
a pull request's check builds and tests the targets the change affects, and
`//ci:pr`, the aggregate of every check, holds every check target of the graph
(a guard fails when one is left out), so a change to any target is built
by the check.

## What the check builds

The build is the gate: building a target runs the tests welded to it and to its
dependencies, so the check points at build targets and nothing else. What a
build of the whole repository covers, and so what the affected targets add up to:

1. **`./buck2 build //...`** builds every target of the komira cell on the
   farm. That is more than compiling:
   - A Mojo library or binary that declares `tests = [...]` cannot build
     unless those tests pass, and it builds only on dependencies whose own
     welded tests passed
     ([tools/build/mojo/README.md](../tools/build/mojo/README.md)). So
     building a release target tests every unit it depends on, then the
     target itself.
   - The lints are validations of the targets they guard
     ([tools/build/lint/defs.bzl](../tools/build/lint/defs.bzl)): shellcheck
     over every shell script, the test scripts of
     [tools/build/tests](../tools/build/tests/README.md) included (their
     own cell, reached through `//:tests_lints`); actionlint over the
     workflows; every `uses:` pinned to a commit SHA; every push to `main`
     in a concurrency group of its own; no remote-execution endpoint in a
     committed file; and every relative link and anchor in the repository's
     Markdown resolving (`//:docs`, a `markdown_docs` target). The lint of
     the scripts the Mojo and Rust rules run
     is reached through their toolchains, so no Mojo or Rust target builds
     while one of those scripts has a finding. The linters are pinned
     downloads, run on the farm like any other action.
2. **`./buck2 test //...`** runs the standalone tests (`mojo_test` and
   friends).
3. **`./buck2 build --keep-going tests//functional/...`** builds every
   positive target of the `tests` cell, which `//...` does not reach (it is a
   cell of its own so that `//...` holds no target that fails by design). A
   target there that does not build fails the check; the targets that must fail
   are `tests//negative`, built as `expect_red`s by the
   [self-tests](#build-system-self-tests) and not by this one. Every target of `tests//functional` is meant to build, so nothing
   there is excluded: a probe or fixture that is expected to fail belongs in
   `tests//negative`.
A contributor runs the same three commands on any client. A green local
`./buck2 build //... && ./buck2 test //...` is the whole-repository form of
what `pr / check` proves for the targets a change affects, dead Markdown links included (`//:docs`).

Publishing is not part of the check. The release workflow
[release.yml](#releaseyml-the-release) has no `pull_request` trigger: a pull
request never starts it and never shows a skipped release job.

## The runner

A GitHub-hosted `ubuntu-24.04` virtual machine, fresh for every job, so nothing
from one job survives into the next. It holds `git`, and what
[`./buck2`](../buck2) needs: `sh`, `curl`, `zstd` and `sha256sum`.
The self-tests also need `readelf` and `objdump`, and `docker` for the image
run leg of the format test (skipped without it). Its JSON, tar and Mach-O
reads are a Mojo tool,
[`//tools/build/inspect:inspect`](../tools/build/inspect/inspect.mojo), built
on the farm like any other target.

### How it reaches the farm

The first step of each farm job is the local action
[`.github/actions/farm-connect`](../.github/actions/farm-connect/action.yml).
It does three things, in this order:

1. **Joins the tailnet** as a node tagged `tag:ci`
   (`tailscale/github-action`). The credential is workload identity
   federation: the job asks GitHub for an OIDC token and Tailscale trusts
   tokens whose subject is this repository, so no Tailscale secret is stored
   anywhere. The tailnet policy lets `tag:ci` reach the farm's nodes on the
   one port of the remote-execution service and nothing else.
2. **Refuses to go on unless the farm answers** on that port, retrying for a
   minute. buck2 with no farm configured builds on the machine it runs on, so
   a job that cannot reach the farm must fail, not quietly build on the runner.
3. **Writes the farm's machine buckconfig**, `~/.buckconfig.d/farm.buckconfig`
   (buck2 reads `~/.buckconfig.d/` and `/etc/buckconfig.d/`): the
   `[buck2_re_client]` addresses, instance name, `tls` and
   `execution_concurrency_limit`, and `linux_x86_64_properties` under
   `[komira_re]`. Developers put the same keys in their own gitignored
   `.buckconfig.local` ([DEVELOPMENT.md](../DEVELOPMENT.md)). Optional
   inputs add the rest: `darwin-properties` with `darwin-macos-hosts` (both or
   neither) write `darwin_arm64_properties` and `darwin_macos_hosts`;
   `macos-library-dirs` (only with `darwin-properties`; absolute directories
   separated by `:` or spaces) writes `macos_library_dirs`; `tls`
   (`false` by default) and `tls-ca-certs`, the absolute path of a PEM CA file
   on the runner, only with `tls: true`, write `tls` and `tls_ca_certs`.
   A user buckconfig is read before the repository's own, so a key the
   repository's `.buckconfig` (or a file it includes) sets wins over the one
   written here.

Every input is checked before the tailnet is joined: an empty required
input, a value holding a line break, half of the macOS pair, a macOS set equal
to the linux one, `tls` other than `true` or `false`, and a CA file that is not
an absolute path to a readable file are refused. `//:farm_connect_cases` runs
those checks and the writer from `action.yml`'s own scripts and compares the
buckconfig written whole. It also reads every workflow and holds each step
that uses the action to `tls: ${{ vars.FARM_TLS || 'false' }}` under its
`with:`: a caller that dropped `tls` would connect in plain text whatever
`FARM_TLS` says.

A job that calls it needs `permissions: id-token: write` (to ask GitHub for the
token) next to `contents: read`, and nothing else: the job reads no secret, holds
no cloud role and names no GitHub Environment. The token is useful for the
tailnet and for nothing else that trusts this repository.

**The farm's endpoint is in no committed file.** It arrives as these
repository variables (Settings > Secrets and variables > Actions > Variables):

| variable | what it holds |
|---|---|
| `TS_CLIENT_ID`, `TS_AUDIENCE` | the Tailscale trust credential's client id and audience (identifiers, not secrets) |
| `FARM_ADDRESS` | the remote-execution service as a URL with its port |
| `FARM_INSTANCE` | its instance name |
| `FARM_LINUX_X86_64_PROPERTIES` | the worker property set of the linux x86_64 actions |
| `FARM_TLS` | `true` when the service serves REAPI over TLS; unset or empty means `false`. Each workflow passes it as farm-connect's `tls`, so the address and its transport change together |

Variables are not masked, and a job's logs are public. The action masks the
address, and the address is one reachable only from inside the tailnet, so
printing it would still disclose nothing usable. `//:no_endpoint` keeps an
endpoint out of every committed buckconfig, workflow and local action.

The connection is checked on every farm-connected run: the action's
`refuse unless the farm answers` step fails the job before any build when the
farm's port does not answer.

Give CI its own remote-execution instance name, a sub-instance such as
`<prefix>/ci`, so its action-cache entries are kept apart from developers' on a
service that keys the cache by instance (Buildbarn does; a cache tier that
ignores instance names, such as bazel-remote without
`--enable_ac_key_instance_mangling`, does not).

### Running a buck2 command on the farm

The local action
[`.github/actions/buck2-farm`](../.github/actions/buck2-farm/action.yml) runs
one `./buck2` command (build, test or bxl) and fails its step unless buck2
succeeded and no action ran locally. It is two lines: buck2's output is tee'd to
a file, and the built tool `//tools/build/ci:assert_remote`
([`assert_remote.zig`](../tools/build/ci/assert_remote/assert_remote.zig)) reads
the file. The tool fails when a `Commands:` summary line says `local:` anything
but `0`, when the log ends a failed run (`BUILD FAILED`, `BXL FAILED`), or when
there is no summary line although the run used the network. A run that executed
no action (everything cached, or a query-only bxl script) prints no summary line
at all, only `Network: up 0B  down 0B`, and passes on that line. `build` and
`bxl` print the same summary. The caller builds the tool first and passes its
path as `assert-remote`. The cases are recorded buck2 output
(`//tools/build/ci:assert_remote_unit`) and the action's own two lines run over
it (`//:buck2_farm_cases`).

## Pull requests from forks

A fork's pull request gets no OIDC token and no repository variables
(GitHub withholds them from `pull_request` runs of forks), so it cannot join the
tailnet and has no farm address. Remote execution also runs the commands a
build describes, so running a stranger's build would be running its code on the
farm's workers. Therefore:

- The job `check` of `pr.yml` is **skipped** for a fork's pull request:
  `if: github.event.pull_request.head.repo.full_name == github.repository`.
  No other job or workflow runs for it, so a fork's pull request has no check at all; the
  repository's only merger reads the change and runs the farm build from a
  branch of this repository.
- ⚠ A skipped job counts as passed for a required status check. Do not rely on
  the `pr / check` check alone to merge a fork's change: read it, push it to a branch
  of this repository, and merge that run's green farm build.
- **Reading the change is the review.** Read the whole change, `.github/`,
  `tools/` and every `BUCK` and `.bzl` file included, before pushing it to a
  branch: the workflow, the rules and the lint scripts all run from that
  branch's tree, and anyone who can push a branch can run code on the farm.
- The workflows use `pull_request` only. There is no `pull_request_target`
  workflow here, on purpose: it runs with the base repository's token, and
  checking the fork's code out under it, then joining the tailnet, would hand
  the farm to the code.
- A job's token is read-only (`permissions: contents: read`) and the checkout
  does not keep it (`persist-credentials: false`).

## What farm access means

An action can run any command on a worker. On a typical Buildbarn
deployment, unless the service is hardened, that command runs with the
worker's privileges, on the worker's network, next to the shared storage: it
can write action-cache entries for any instance directly to storage, and
tamper with files a worker shares between actions. Denying action-cache
writes at the client-facing endpoint does not stop that, because the action
does not come through that endpoint. Joining the tailnet by a hosted runner does not
change this; deciding whose code runs does: only pushes to this repository.

What closes the rest is on the service side, for the farm operator to apply:
authenticate the storage and scheduler servers so only worker identities can
write the action cache or register as workers; run actions as a non-root user
with no write access to the worker's shared cache; restrict the workers'
network so an action cannot reach storage or the scheduler; deny
action-cache writes at the client-facing endpoint. Until then, treat an
approved run as able to affect every build that uses the same service.

## What a farm test action can do

`./buck2 test //src/tests/helpers/komira_test_minio:farm_capability_probe`
([the probe](../src/tests/helpers/komira_test_minio/tests/farm_capability_probe.mojo)) tries,
inside one test action (on the farm, a Linux worker; with no farm
configured, the client, like any other standalone test), each thing an
end-to-end test of a real server needs, and prints one
`FARM-CAPABILITY <name> key=value ...` line per capability. The first four
rows are required: the test fails, naming the capability, when one is
missing. The rest are reported and never fail it.

The probe watches the workers only when it runs: the PR check runs it when
its targets (`//src/tests/helpers/komira_test_minio/...`) are affected, that is, when a PR
touches `komira_test_minio` or one of its dependencies. Anyone can run it on
demand with the command above. A test result is not cached, so each run is a
fresh probe.

A passing test's output is not shown (the gate runner prints a test's log
only when it fails), so the values below were read from two farm runs on
2026-10-05, each with one capability broken on purpose in the probe: one ran
setpriv without `--pdeathsig` (the `pdeathsig` check went red), the other
connected to the wrong port (the `loopback` check went red). Every other line
in each run is what the worker did; the broken row's value comes from the
other run.

| capability | observed | enables |
|---|---|---|
| `child_reap` (required): start `sleep 30` through `komira_supervisor`, stop it, reap it | alive after 300 ms, died of SIGTERM (15), a second reap finds no child | any test that runs its own server process (the embedded MinIO of `komira_test_minio`) |
| `loopback` (required): bind 127.0.0.1 port 0, connect, accept, move one byte | all three yes | a client and a server talking over 127.0.0.1 in one action |
| `pdeathsig` (required): `/usr/bin/setpriv --pdeathsig KILL`, parent SIGKILLed | setpriv present; the child died with its parent; the control child, started without setpriv, outlived its parent | a server that dies with the test (`die_with_parent` in `komira_test_minio/process.mojo`), so a killed test leaves no process behind |
| `disk_1gib` (required): write 1 GiB under `TEST_TMPDIR`, read the size back, delete it | written and deleted, in 0.7 and 0.85 s; 749 and 835 GiB available in the two runs | tests that write large data (object store contents) |
| `uid` (reported): the current uid; `setpriv --reuid --regid --clear-groups` to a non-root `/etc/passwd` entry | the action runs as uid 0; the drop to `nobody` (65534) works; `nobody` cannot create a file in `TEST_TMPDIR` | a server that refuses to run as root (PostgreSQL), given a directory the dropped user can reach |
| `egress` (reported): TCP connect to `conda.modular.com:443` | connects | the install-path test (a package install from Modular's channel) |
| `tmpdir_outside_checkout` (reported): no directory from `TEST_TMPDIR` up to `/` holds `.git` or `.buckconfig` | outside: six levels walked to `/`, no marker | the install-path test, whose scratch must be outside any checkout |

`tmpdir_outside_checkout` is reported, not required: the gate runner
([`gate mojo`](../tools/build/run/README.md)) makes `TEST_TMPDIR`
under the action's working directory, which for an action run on the client
(no farm configured) is inside the checkout, so a required check would fail
there for that reason rather than for a missing capability (derived from the
code; no client run was made). The install-path
test needs the same walk and must refuse to run when it finds a checkout.

## Build-system self-tests

[`tools/build/tests/run_tests.sh`](../tools/build/tests/README.md) tests what a
build does not: where actions ran, cache identity across checkouts,
analysis-time refusals, a `buck2 run` from a fresh clone, targets that must
fail by design (the `tests` cell), and the `./buck2` bootstrap. It is one shell
script of numbered cases, takes well over an hour, and is **not the gate**: the
gate is `pr / check`. It runs in its own workflow,
[`build_system_selftests.yml`](../.github/workflows/build_system_selftests.yml),
on a daily schedule and on demand, never on a push or a pull request, with
the same farm connection and the same job permissions as `pr / check`. Two runs never
overlap. It needs a Linux x86_64 client and refuses any other (exit 2).
The workflow puts the platform table's pinned pixi on `PATH` (built as
`//tools/build/toolchains:pixi`, so buck2 keeps it only at the pin's sha256)
and runs the script with `--require-install`: the conda install cases (33a,
33b) then fail, never skip, when pixi or the network is missing.

Run it by hand on a branch of this repository:

```sh
gh workflow run build_system_selftests.yml --ref <branch>
```

or locally with `tools/build/tests/run_tests.sh`.

**Direction.** The script is being dissolved into the gate, slice by slice
([build_selftests.md](design/build_selftests.md), whose inventory says where
each check goes). Slice 2 moved what needed no new tool: the run check of a
binary with `expected_stdout` is a validation of the binary; the greens that
sat in `tests//negative` or needed `buck2 test` moved to `tests//functional`
or the komira cell; sub-targets and the greens of `tests//negative` and
`tests//src` that must build are named by `target_suite`s
(`//:tests_greens`); the case actions refuse a short report; and the rows the
check already built are gone from the script.
Slice 3 added the scenarios: `buck2 test` targets under
[`tools/build/selftest`](../tools/build/selftest/README.md) that drive buck2
from outside, each inner build on the farm. They are targets of the aggregate `//ci:pr`, which a widened
change (one under `tools/build/`, say) selects, and `pr.yml` runs the
package's graph checks with their BXL script. The analysis-time refusals, where targets execute and the
unconfigured query through the prelude's select moved there.

## release.yml: the release

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds the
conda packages that `release/artifacts.textproto` declares, as one release set,
with Buck2 targets on the farm. It runs no kci. It is written by hand.
**The release set itself publishes to no channel**: the job `release` builds the
set, so a push to `main` still proves the release builds, keeps what it built as
a workflow artifact, and holds no publishing credential and no channel. The
libraries moved to mopm are published by mopm's own jobs: to prod, continuously, on every
push to `main` (this workflow publishes to no beta registry; [below](#the-mopm-jobs); see
[releases](releases.md)). Its job
`release` (the mopm jobs, for the packages moved to mopm, are
[below](#the-mopm-jobs)) is on a GitHub-hosted runner (`ubuntu-24.04`) joined to the farm by
[`farm-connect`](#how-it-reaches-the-farm), in the environment `build`, with
`contents: read` and `id-token: write` (for the tailnet only). Triggers: a push
to `main` that is not documentation only (`docs/**`, `**.md`: the stamp does not
count them either), and a manual run with a required `reason`, nothing else. A
pull request never starts it.

Two checks of kci's build stage are not made here: that every package's
requirements are inside the set (requirement closure), and the refusal of a
duplicate key in a JSON file. Neither is enforced until mopm's publish path
re-creates them; the header of
[`set_json.zig`](../release/ci/release_lib/set_json.zig) lists what was dropped.

Each Buck2 step is the [`buck2-farm`](#running-a-buck2-command-on-the-farm)
action, which fails the step unless buck2 succeeded and no action ran on the
runner; the programs those builds made are then run as binaries, never through
`buck2 run`:

| step | what it does |
|---|---|
| the guard, [`//release/ci:check_release_ref`](../release/ci/check_release_ref.zig) | decides from the run's facts (flags, never environment variables) and two answers of git whether the run builds a release: a push to `main`, of a commit on `main`'s history (`refs/remotes/origin/main`), or a manual run; the checkout's HEAD is the commit the run started on; the ref is not `main` in another case (any other event, a `schedule` included, is refused: the workflow has none); a manual run (break-glass) has a reason of 1 to 200 bytes on one line, which is the first line of the job summary (`BREAK-GLASS: <ref> <commit> by <actor>: <reason>`); a push of a commit without `release/artifacts.textproto` has nothing to release and is skipped (a warning and a summary line, `release=false`, the later steps do not run), a manual run of one is refused. A manual run releases the commit it was started on: there is no revision input. Cases: [`//release/ci/tests:test_release`](../release/ci/tests/test_release.zig), run as a build action of the program. |
| the stamp, `release_json stamp` | the build number (the first-parent commit count of the stamp's commit), the stamp's commit (the newest first-parent commit that touches more than `docs`, `*.md` and `.github`) and its commit time in milliseconds, from git in the full-history checkout; refused for a shallow clone, a HEAD that is not the revision and modified tracked files. The rule is `tools/build/package/release_version.sh`'s. |
| the release set, [`//release:release_set`](../release/release_set.bzl) built with the stamp (`-c komira.package_stamp`, `komira.package_commit`, `komira.package_timestamp_ms`) and the revision and run (`komira.release_revision`, `komira.release_run_id`, `komira.release_attempt`) | every package the artifacts file declares (`<lib>_conda[release]`), the metapackage `komira_all` over them (the packer's `conda-meta`, as an action of the farm), and `release.json` and `set_hash.txt`. One build action holds the set to the artifacts file (the library names, their order, the metapackage's arguments), and `release_json write` checks every package (a directory of exactly the manifest, the package and its metadata, no symlink; the manifest's name, platform, subdir and sha256; the metadata's agreement, size and `stamped`) before it writes `release.json` (format `kci.release_set` major 2, byte-compatible with what kci's build stage wrote: the revision, the platform, `produced_by`, the members and the set hash, whose text is [`set_json.zig`](../release/ci/release_lib/set_json.zig)'s header). Built without a stamp (the pull request's check builds `//release:release_set` as part of `//ci:pr`), the same checks run over the unstamped packages, minus `stamped`, and no release directory is produced. |
| the artifact | the release directory (the packages, `release.json`, `set_hash.txt`) leaves the job as one workflow artifact named `release-<commit>`, kept 14 days; the job summary has one line with the set hash. |

One release at a time: a push to `main` is in the concurrency group `release-main` with
`cancel-in-progress: false`, so a running release is never cancelled and two pushes never
publish to prod at once (both would stage against the registry's current state). GitHub keeps at
most one pending run per group, and a newer run replaces only a pending run, which never started
(the newest pushed revision wins; main moves forward only, so it carries the older one's
changes). **Known behaviour:** a run that is pending behind a running release when another push
arrives is cancelled (it shows as cancelled, with no summary), and its run number is never
published: the versions skip it (`0.1.<n>` is followed by `0.1.<n+2>`), and the next run publishes the
then-current `main`. Nothing is half-done, because the replaced run never started. A manual run is in
`release-ref-<ref name>`. The run that ends is what
[`main_red.yml`](#main_redyml-the-main-red-alert) watches.

The release machine file, [`release/machine.textproto`](../release/machine.textproto),
and `kci` itself are not part of the release now: no workflow runs either, and no
workflow is held to the machine file. The file stays for kci's own tests until
kci is removed from this repository.

### The mopm jobs

The libraries moved to mopm (every `src/<name>` that has a `mopm.toml`, built
with buildrules' `mojo_package`, which gives each a `:lib` and a `:conda`) go
to the mopm registry (`prod`) as one group, apart from the release set, **continuously: every
push to `main` publishes**. The steps are **build, stage, try, publish**, and the publish is itself
three steps (stage, test, commit). There is no beta publish from this workflow, no schedule and no
variable that switches the publish on or off. The list is
[`packages.bzl`](../release/readme_e2e/packages.bzl), which
`//:readme_e2e_complete` holds to the `src/` directories that have a
`mopm.toml`, in both directions; [`//release:mopm_artifacts`](../release/mopm_artifacts.bzl)
builds each package's `:lib` (the `.mojoc`, which exists only once the tests
passed) into `linux-64/<name>.mojoc`. Six jobs of `release.yml` carry the
steps (a documentation-only push does not start the workflow, so it publishes nothing):

| job | when | what it does |
|---|---|---|
| `mopm-stage` | every push to `main`, and a manual run (which sends nothing either) | on the farm (environment `build`, the farm's tailnet token only; it reads no registry token). **Build:** the one mopm the README e2e installs with (`toolchains//:mopm_0_0_81`, `MOPM` of `packages.bzl`) and `//release:mopm_artifacts`. **Version:** `release_beta_version --workspace-root src --version 0.1.<run number>` gives every member the version of this run (below, "The version of every release"). **Stage:** `mopm stage --workspace-root src --artifacts <built> --compiler 1.0.0 --out release/staged_set --registry prod` packs every member from its built `.mojoc`, asks the registry (a read, no token) which versions it holds and writes the staged set S (`plan.json`, each `.conda`, each README: mopm's `spec/staged-set.md`). A version the registry holds with other bytes, or has yanked, fails the step. **Try:** `./buck2 build -c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on the farm: every package's README examples are compiled and run as a user of the `.conda` files of S (see the e2e's [README](../tools/build/readme_e2e/README.md)). Then `mopm publish --staged S --registry prod --dry-run`: the plan is validated and every file hashed against it, nothing is sent and no token is read. It uploads S and that mopm as a workflow artifact (a day) for the next job. |
| `prod-stage` | after `release` and `mopm-stage`, **only on a push to `main`** (a manual run skips all five prod jobs before they start; there is no other switch) | in the environment `prod`, with `contents: read` and `id-token: write`, no farm and no secret. It downloads the set `mopm-stage` kept and runs `mopm publish --staged S --registry prod --oidc --no-commit`: the registry opens a group, holds every file in quarantine, and nothing is visible. It keeps the directory, now with `state.json` (the group), as the artifact `mopm-prod-staged-<sha>`, even when the step failed. |
| `prod-test` | after `prod-stage`, on a push to `main` | in the environment `build` (the farm's; `id-token: write` for the tailnet join only), with **no registry identity and no secret**. It downloads the directory `prod-stage` kept, checks every file against `plan.json` (`release_staged_verify verify`: sha256 and size), writes `release/staged_set` from the files that matched and from nothing else, and runs `-c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on the farm. |
| `prod-commit` | after `prod-test`, on a push to `main` | in the environment `prod`, with `contents: read` and `id-token: write`. The same command without `--no-commit`, on the same directory with its `state.json`, after a fresh OIDC exchange: the same group is committed and the job waits until it is visible. It keeps `plan.json`, `state.json` and `report.json` as `mopm-prod-committed-<sha>`. |
| `prod-abort` | after `prod-stage`, `prod-test` and `prod-commit`, when one of them failed or the run was cancelled, on a push to `main` and with a `prod-stage` that was not skipped | in the environment `prod`, same permissions: `mopm publish --staged S --registry prod --oidc --abort` ends the open group and gives its place back. |
| `prod-smoke` | after `prod-commit`, on a push to `main` | no environment, no identity, no secret, no farm: `release_staged_verify smoke` downloads the published files from the prod channel and compares each with the plan. On a difference it prints the `mopm yank --group <id> ...` command for a human and fails; it yanks nothing. |

**Why `mopm stage` is a step of the job and not a build action.** It asks the
registry which versions exist, and an action is offline. So the farm takes the
set it wrote as an input: `//release/staged_set:set` is the files
of the directory `release/staged_set/` (`mopm stage --out` writes them there; they
are not in the repository, `.gitignore`), and
[`//release/readme_e2e/verify`](../release/readme_e2e/verify/BUCK) installs from
it only under `-c komira_release.staged=stage`. Without that flag the targets
install from `//release/readme_e2e:staged`, the set the build assembles from the
packages it made (same layout, `skip` and `refuse` members aside): hermetic, so
the pull request check builds it, on every change, with no network. The release
job tries the real set; the pull request check tries the assembled one.

The cases of `mopm stage` and `mopm publish --staged` are mopm's. What this
repository holds to is the e2e's own cases
([`tools/build/readme_e2e`](../tools/build/readme_e2e/README.md)) and the
completeness of the list.

#### The prod publish

The five `prod-*` jobs publish the set `mopm-stage` tried to the prod registry as one group, on every push to
`main` and with no switch, in three steps that the registry keeps apart: **stage** (upload, nothing visible), **test** (on the bytes the registry holds),
**commit** (visible all at once). `prod-stage` needs `release` and `mopm-stage`: the set it stages is the one
the README e2e of `mopm-stage` passed on, at the version of this run (below), so a release build or an e2e
that failed stops the run before anything is staged in prod. There is no beta stage in front of prod. `//:release_workflow_cases` holds the job graph, the gates, the
environments, the permissions, the commands and the order of the test's steps, and that no beta job and no schedule exists.

1. **`prod-stage`** runs `mopm publish --staged S --registry prod --oidc --no-commit`. The registry creates a
   group, mopm uploads every file, and the run ends 0 with the outcome `staged`: the group is `open`, the
   registry holds the bytes in quarantine, where nothing reads them, and no package is in the API, the
   index or the channel. `state.json` in S names the group.
2. **`prod-test`** reads S as `prod-stage` kept it. `release_staged_verify verify`
   ([source](../tools/build/ci/release_beta_fetch/release_staged_verify.zig),
   `//tools/build/ci:release_staged_verify`) refuses a plan it cannot check (the rules of
   `release_beta_fetch`: every member an `upload` with its files and README, plain paths, a lowercase
   sha256, a file below 64 MiB), compares every file with the plan and names every one that differs
   (missing, another size, another hash), and only then writes `release/staged_set` from the bytes it
   hashed: `state.json`, `report.json` and any file the plan does not name never reach the e2e. Then the
   README e2e of every package runs on the farm against that directory, as `mopm-stage` ran it on the set
   before the upload.
3. **`prod-commit`** runs the same command without `--no-commit`. The directory is the artifact of
   `prod-stage`, `state.json` is in it, so mopm asks for the same group (the group is a function of the
   caller and the set; `plan_sha256` in the state refuses a directory whose plan changed), finds every file
   held, commits and waits until the group is `visible`. The identity token of `prod-stage` was used once,
   so this job makes its own exchange.
4. **`prod-abort`** runs only when the stage, the test or the commit failed or the run was cancelled. It
   ends the open group (`--abort`: it reads `plan.json` and `state.json`, none of the files), which gives
   the actor's place among its open groups back at once; otherwise the registry expires the group after
   twelve hours. It `needs` all three jobs that can fail because `failure()` looks only at the jobs a job
   depends on: a test that failed would not reach an abort that needed `prod-stage` alone. A directory
   without `state.json` means the stage failed before it asked for a group, and the step says there is
   nothing to end. A group that was already committed is not ended: mopm refuses and says to yank it.
5. **`prod-smoke`** runs once the group is visible. `release_staged_verify smoke` reads the prod index
   (`https://api.mopm.dev/index/config.json`, whose `stage` must be `prod` and whose `channel_url` must be
   exactly `https://conda.mopm.dev/`), downloads `<channel_url><subdir>/<filename>` for every file of the
   plan (https, no redirect followed) and compares each file's sha256 and size with the plan, trying up to
   five times 30 seconds apart because the channel's cache can lag a commit by a minute. On failure it
   prints the exact `mopm yank --group <id> --registry prod --reason ...` for the group in `state.json`;
   a person decides whether to run it.

**The identity.** No job holds a registry token and the environment `prod` holds no secret. The three jobs
that talk to the registry run in the environment `prod` and exchange the job's GitHub OIDC token; the
registry trusts this repository's `release.yml`, run on `main` from a push, in the environment `prod`, and
lets that identity act for the owner of the packages (the names are owned by the maintainers' account, not
by the repository). `prod-test` is in the environment `build`, whose identity the registry does not trust,
and runs nothing that reads a token.

**What this proves.** The files the registry holds in quarantine, which it copies when the group is
committed, are the files of S: the registry pinned each sha256 when it opened the group, and `prod-test`
hashed the same directory against the same plan. The README examples of every package ran on exactly those
bytes before anything was committed, and after the commit the channel serves bytes whose sha256 and size
are the plan's.

**What it does not prove.**
- The registry's own verdict: a group can still end `rejected` after the tests passed (the commit job
  fails and the group frees its versions); the tests do not read what the registry stored.
- The registry's derived outputs (repodata, the sparse index) are not read: `prod-smoke` compares the
  files themselves. `mopm add <package> --registry prod` from a clean machine is not exercised.
- A package's own unit tests are not in the `.conda`: they ran when its `.mojoc` was built.
- Native libraries are loaded as the packages say; no job installs a package from the registry and
  loads its native dependencies.
- A plan member that is not an `upload` (a version the registry already holds) makes the README e2e and
  `release_staged_verify` refuse the set; a release publishes only a set of new versions, which is why every
  run gives the members the version `0.1.<run number>` (below).

**Needs a mopm with `--no-commit` and `--abort`.** The jobs run the mopm that `mopm-stage` built: the pin
`MOPM` in [`packages.bzl`](../release/readme_e2e/packages.bzl) (`toolchains//:mopm_0_0_81` in the
`mopm-stage` job). The first mopm release with both flags is 0.0.66, so the pin has them; a later move of
the pin must keep them, in the same change as the toolchain entry the job builds.

#### Before the first release

This is the one-time setup of the registry, outside this repository. It is done for komira's packages on
`prod`; it is listed because a repository that copies this workflow must do the same before its first push.
There is no variable that turns the publish on or off, so a push before the registry is ready fails at
the first request that is refused and changes nothing, but that must not be the way it is found out. In
this order:

1. On the registry, the package names exist under the maintainers' publishing account (a personal account the
   maintainers designate, not an organization owner): that account claims the name of every package in
   [`packages.bzl`](../release/readme_e2e/packages.bzl) (every `src/` directory with a `mopm.toml`) on `prod`.
   Ownership is a registry record, not something `mopm.toml` can express.
2. The registry's group publish is live on `prod` for that account, and the registry trusts this
   repository's `release.yml`, run on `main` from a push, in the environment `prod`, as a CI publisher of
   the owner. Without it the exchange is refused (`oidc_not_trusted`) and nothing is created. The registry's
   trust should match the ref, the `job_workflow_ref` and the event (`push`), not the environment alone.
3. The GitHub environment `prod` deploys only from `main` (selected branches, `main` only). The
   OIDC subject the registry sees names the environment, and a workflow on any branch can declare the same
   environment, so the environment's branch rule is what keeps a branch out; each job's `if` is a second lock,
   and `==` on `github.ref` compares ignoring case.
4. The pinned mopm has `--no-commit` and `--abort` (above).
5. The versions: nothing to set. Each release carries the version `0.1.<run number>` (next section), so no
   version has to be reserved.

The prod jobs start only on a push to `main`: a manual run builds and stages and publishes nothing.

**Prod only on a push: a release without a push is not supported.** A manual run never reaches the
environment `prod` (it is break-glass and publishes nothing). To release, merge to `main`: the push is the
release, and its version is its run number.

#### The version of every release

A registry creates a (name, version) pair once, and a mopm version is exactly `MAJOR.MINOR.PATCH`:
`+b123`, `-b123`, `.post123` and `.dev123` are not versions. A registry that holds a version with other
bytes refuses the set (`mopm stage` fails, and the README e2e refuses a plan member that is not an
`upload`), so a fixed version in `mopm.toml` would let only the first release through. So every push to
`main` gives each member of the checkout of `mopm-stage` the version
`0.1.<github.run_number>` before `mopm stage`, and the set that is staged, tested and committed in prod
has exactly those versions. The number stays inside the
`>=0.1,<0.2` the packages ask of each other, sorts above `0.1.0`, and the newest push is the newest
version. A run that was replaced while pending (above) used a number that is never published, so the
published versions can skip numbers. The README e2e of `mopm-stage` and `prod-test` is told the number with
`-c komira_release.beta_version=0.1.<run number>` (the name is from when a beta publish took it; it is
optional with `staged=stage`, and the tool and the option keep their names so the labels and action keys do
not move). Nothing is committed or pushed back: the
rewritten files exist only on the runner of `mopm-stage`, and `mopm.toml` in the repository keeps its own version.

[`release_beta_version`](../tools/build/ci/release_beta_version/release_beta_version.zig)
(`//tools/build/ci:release_beta_version`, built and run by `mopm-stage`) takes `--workspace-root <dir> --version 0.1.<n>`. `mopm stage` reads
each version from `mopm.toml` when it runs, and the `.mojoc` files the build made carry none, so the
rewrite before the stage is all the packages need: the artifacts are not rebuilt. It edits the text of
each member's manifest (found the way `mopm stage` finds them) and keeps every other byte:

- `[package] version` becomes the new version;
- in `[dependencies]` and `[dev-dependencies]`, a requirement on another member with an exact
  comparator `=X.Y.Z` (a string, an inline table's `version`, or `[dependencies.<name>]`'s `version`)
  gets the new number, because `mopm stage` checks each requirement against the member's version.
  Every other comparator (`^0.1`, `>=0.1, <0.2`, `~0.1.0`, `0.1`, `*`, `=0.1`) accepts every `0.1.x`
  and is kept; `mopm stage` itself refuses a range that does not accept the new version.

It writes nothing and fails when the version is not `0.1.<PATCH>` (digits, no leading zeros, no
suffix), a member's version is not in `0.1.x`, two members share a name, a requirement on a member is
not comparators it can read or pins a number the member does not have, or a manifest holds a
multi-line string or a dependency line it cannot read. Running it again with the same version changes
nothing. Its cases (`//tools/build/ci:release_beta_version_unit`) run on scratch workspaces, and
`//:release_workflow_cases` holds the placement: the rewrite is in `mopm-stage`,
before the stage, with the run number, and the e2e of `mopm-stage` and `prod-test` is given the same number.

#### The plan reader and the registry client

[`release_beta_fetch.zig`](../tools/build/ci/release_beta_fetch/release_beta_fetch.zig) holds what
`release_staged_verify` shares with the old beta check: the plan reader (it refuses a plan it cannot
check: no member, a member that is not an `upload`, a path that leaves its directory, a malformed
sha256, a file above 64 MiB, a name listed twice, two paths of the set that collide, in any letter case)
and the https client that reads a registry's index and files with no redirect followed. It is no longer
built as a program of its own (the beta job that ran it is gone); its cases
(`//tools/build/ci:release_beta_fetch_unit`) run against a registry in memory and a socket on
loopback, and cover a changed byte, another size, a missing package, an index of another stage, and
a redirect.

> **Removed: publishing.** The rest of this page, from "Continuous
> auto-promotion" to "GitHub settings the release relies on", describes the
> publishing stages (`beta`, `beta_validate`, `prod`) of the retired workflow
> `kci.yml` (replaced by `release.yml`, above), which ran `kci`, and the
> channels they published to. Every mention of `kci.yml` there is that
> workflow, deleted; `release.yml` has none of its stages, environments or
> gates. It is kept as the description of what kci's publish machinery
> enforces (the rules are still tested, against a fixture pair in
> `src/kci_workflow_check/tests/data`) until kci itself is retired. Read it as
> history, not as what a push to `main` does today.

### Continuous auto-promotion

A push to `main` IS the release: `build` -> `beta` -> `beta_validate` -> `prod`,
with no manual step. `prod` starts only when `beta` and `beta_validate` both
succeeded in the same run (no job-level `if:` names `always()`, so GitHub's
implicit `success()` holds). A push that touches only documentation
(`docs/**`, `**.md`) starts no run: `release_version.sh` does not count those
files either, so the build number would not move (rule R17 holds the two
lists equal). A push that changes nothing a package carries (a `.github`-only
push) rebuilds the same bytes under the same name and build number, and each
channel answers NOOP (exit 0).

- **Only a push to `main` reaches `beta` or `prod`.** A manual run of `main` is
  break-glass like any other manual run and stops at `build`. The `beta`,
  `beta_validate` and `prod` jobs' `if:` each carries `github.event_name == 'push' && github.ref ==
  'refs/heads/main'` (rule R15). ⚠ GitHub compares strings IGNORING CASE, so
  that `if:` also passes for a branch named `MAIN`: it is defence in depth,
  not the lock. The locks are, in order: the `prod` environment's
  deployment branches (`main` only); a repository ruleset that refuses
  creating or updating any branch or tag that is `main` in another case
  (see [GitHub settings](#github-settings-the-release-relies-on)); and the
  `prod` job's third step, `only a push to main reaches this job`, which
  compares `GITHUB_EVENT_NAME` and `GITHUB_REF` byte for byte in shell (rule
  R21). At start-up under GitHub Actions kci refuses the same (exit 3,
  `KCI-E-NOT-ON-MAIN`): a run that is not a push to `refs/heads/main`, a ref
  that is `main` in another case (for every stage), a revision that is not
  the pushed commit (`GITHUB_SHA`), and one that is not on
  `refs/remotes/origin/main`'s history (asked by its FULL name: git resolves
  `origin/main` to a TAG of that name first, and `actions/checkout` with
  `fetch-depth: 0` fetches every tag). History git cannot read (a shallow
  clone, no `refs/remotes/origin/main`) is exit 5, never a pass.
- **The revision is checked by the workflow, before anything built from
  it.** Every release job starts with `actions/checkout` at `REVISION` and
  then the step `the revision this run releases` (rule R21, byte for byte):
  `REVISION` is a full commit id, and on every run that can publish (a push,
  and every manual run that is not a dry run) it IS `GITHUB_SHA`, the commit
  the run started on. Only a manual DRY run may name another `revision`, on
  `GITHUB_SHA`'s history. On a run of `main` this file is `main`'s own, so a
  manual run of `main` whose `revision` input names an unmerged commit is
  refused there, before the farm-connect action, `./buck2` or `kci` (all of
  which are that revision's own code, and could leave any in-kci check out)
  run; kci refuses the same at start-up (exit 3,
  `KCI-E-BREAK-GLASS-REVISION`; `KCI-E-BREAK-GLASS-REASON` is for the reason
  only: missing, blank, or over 200 bytes). No
  release job, and no step of one, has `continue-on-error:` (R21): a failed
  check, publish or validation never reads as a success.
- **A push is never a dry run.** `DRY_RUN` is set once, in the workflow's
  `env:`, to `${{ github.event_name == 'workflow_dispatch' &&
  inputs.dry_run }}`, and no job or step sets its own; `--plan` appears in
  a release job only as `if [ "$DRY_RUN" = true ]; then set -- --plan; fi`
  (rule R22). So `beta_validate` validates FOR REAL on every push: a `beta_validate`
  that ran `--plan` on a push (the earlier `github.event_name !=
  'workflow_dispatch' || inputs.dry_run`) would let `prod` publish what
  nothing installed. A release job's script also names `DRY_RUN` only in
  that line and in the revision check (no shell assignment, no `export`),
  and names `GITHUB_ENV` nowhere: a line a step writes there sets a
  variable for every later step of its job, over the workflow's `env:`
  (a `with: script:` calling `exportVariable` is refused the same way).
  Those are lint rules a script could spell around. **The lock is kci**,
  which on a push is built from `main`: it refuses `--plan` on a push to
  `refs/heads/main` for every stage (exit 3, `KCI-E-PLAN-ON-RELEASE`), and
  its result carries a `set_hash` only for a run that is not `--plan`, that
  ended SUCCEEDED or NOOP, and, when it selects validations, whose every
  validation VALIDATED and SUCCEEDED. `beta_validate`'s `validated_set_hash`
  comes from that field, so a dry run, a failed run or a SUPERSEDED run
  (exit 0) hands `prod` nothing, and `prod` refuses an empty hash.
- **A failed DEPLOY step stops the run, and nothing rolls it back.** `kci
  run` stops at the first step that does not end SUCCEEDED or NOOP. A DEPLOY
  step that ends FAILED or PARTIAL leaves its cell exactly as the failed
  apply left it: kci does not unwind what landed, and a later step of the
  stage (a DEPLOY step into another cell included) has no row and never
  runs. The job exits non-zero (4 or 6), so no job that `needs:` it starts,
  and the run's result carries no `set_hash`, so the next stage, which
  refuses an empty hash, could not start from it either. The recovery is a
  fixed revision pushed to `main`: its apply completes what the failed one
  left `pending`. `--rollback-on-failure`, which would re-apply the failed
  cell at its last known-good revision, needs a per-cell deployed-revision
  record that kci does not have yet, so kci refuses the flag on every stage,
  with or without `--plan`, before it reads anything (exit 2,
  `KCI-E-USAGE`, no RUNNING record).
- **Queued runs: one release at a time, newest push wins.** A PUSH to `main`
  is in the concurrency group `kci-release-main` (rule R16 holds the group
  text byte for byte). A running release is never cancelled. GitHub keeps at
  most one PENDING run per group: a newer queued run cancels the pending one
  and takes its place (when it is QUEUED, before it runs anything), so the
  newest push wins and queued pushes coalesce. That is safe because `main`
  only moves forward: the newer push carries the older one's changes, and
  `prod`'s summary lists them (`carried to prod`: every first-parent commit
  of `main` after the channel's previous build, which is the highest build
  number `komira-ai/prod` lists below this release's, of ANY name and
  version, so a run that was replaced, or never started, is reported by the
  run that released its commit). A run replaced while pending also shows as **cancelled** in
  the Actions list, with no summary. No manual run is in that group, so none
  can replace a pending release, whatever revision it names: a dry run is in
  `kci-plan-<run id>` (it writes nothing), any other manual run in
  `kci-ref-<ref name>`. A pull request's runs are one group per pull request
  (a newer push cancels the older check).
  - ⚠ **A RE-RUN of an old PUSH run of `main` is a push run** and joins
    `kci-release-main`: it can replace a pending release, and then releases
    an older revision (prod refuses it, `KCI-E-SUPERSEDED`, or answers
    NOOP). Never re-run an old run of `main` while a release is pending. If
    one did replace a pending push, re-run the newest cancelled run of
    `main`. A re-run of a MANUAL run is a manual run, and a re-run of any
    run uses that run's own `kci.yml` and `kci`: see
    [Re-runs of runs from before auto-promotion](#re-runs-of-runs-from-before-auto-promotion-a-ceo-action).
  - `prod`'s last step says when `main` has moved past the revision it ran
    for (`prod: main is at <tip>, past <revision>: a newer run is pending, or
    was replaced or cancelled; if none is queued, re-run the newest
    cancelled run of main`), counting only commits a push would release (not
    `docs/**` or `**.md`). It says so on a FAILED job too, after the
    `prod: FAILED` line: a re-run of an old run that replaced a newer
    pending release is then refused at `prod` (`KCI-E-SUPERSEDED`), and this
    line is what names the newer release to re-run (the step has no `exit`,
    rule R20, and writes neither `GITHUB_ENV` nor `DRY_RUN`, rule R22).
  - ⚠ **A push GitHub does not start a run for is not reported by itself.**
    GitHub's path filter reads at most the first 300 changed files of a
    push; when the files that matter are past them, the workflow may not
    run (GitHub's documentation, "workflow syntax", `paths`). So a large,
    mostly-documentation merge that also touches code can be skipped. The
    next push that does start a release carries it, and its `carried to
    prod` list names the commit; until then nothing says it waits.
- **Never backward.** `prod` publishes a release only when its revision
  descends from what `prod` already holds. Two refusals, both exit 3,
  `KCI-E-SUPERSEDED`, read anonymously from the channel's listing, before
  any upload (a dry run too):
  - **By number.** A build number lower than ANY build `komira-ai/prod`
    lists, of any name and any version, or an EQUAL number with another
    build string (`h<8 hex>` of another commit: a consumer cannot order two
    builds of one number). That holds across a version bump (a new compiler
    version re-versions every package) and for a name `prod` never listed.
  - **By history.** The commit that the channel's NEWEST build names (the
    `h<8 hex>` of its highest build number) must be on the release
    revision's history (`git rev-list <revision>`). Numbers alone cannot say
    it: the build number counts FIRST-PARENT commits, so when `main` moves
    to a merge whose first parent is a branch, the new tip can carry a LOWER
    number than an older tip it contains; a late re-run of that older tip
    would then be "higher" than what `prod` holds, and would publish it,
    taking the branch's changes back out. A history git cannot list (a
    shallow clone, no `RUNNER_TEMP`) is exit 5, never a pass.

  The rule is the run's, not the stage's: a push to `main` holds `beta` to
  it too, where it counts every build in `beta` (beta is not a `break_glass`
  stage, so no break-glass build reaches its channel; for a `break_glass`
  stage kci counts only the channel's MAIN-LINE builds, those whose
  `h<8 hex>` is a commit on `main`'s freshly fetched history). Before refusing, kci asks
  git whether the release revision is on the history of the commit the
  channel's newest build names (`git rev-parse --verify`, then `git
  merge-base --is-ancestor`): when it is, a newer release is already in the
  channel and the run stops SUPERSEDED, exit 0, nothing uploaded and no set
  hash handed on. A prefix git cannot resolve to one commit, or a shallow
  clone, is exit 5.

  Only a late re-run of an old run reaches either, since the group
  serialises live runs. A re-run of the same release is NOOP (or finishes a
  partial publish). Rolling back
  is a revert on `main`, released forward as the next build number.
- **The prod line.** Every release job ends with the step `the prod line`
  (`if: always()`, rule R20), which writes one plain line to the job summary
  and to the log: `prod: SKIPPED (<job> <status>: exit <n>)` when that job
  did not succeed, `prod: SKIPPED (nothing to release)`, `prod: SKIPPED
  (break-glass: a workflow_dispatch of <ref> builds only; beta and prod run on
  a push to main)` from `build`, or, from `beta_validate`, `prod: NEXT (runs automatically; it waits only while the prod
  environment has a required reviewer)`. `prod`'s own `kci run` writes
  `promoted to prod: <names> <build>` or `promoted to prod: nothing new
  (<build> already there)` and the commits it carried; its last step writes
  `prod: FAILED (...)` when the job failed, and, whether it failed or not,
  the `main is at ...` line above. Whether `prod` is paused is not read by any job (it would need
  `actions: read`, which no job holds); the environment's page says so.

### Re-runs of runs from before auto-promotion: a CEO action

GitHub runs a re-run against the original run's `GITHUB_SHA` and
`GITHUB_REF`, so it uses `kci.yml` exactly as committed at that commit
(GitHub's documentation, "Re-running workflows and jobs"), and a run can be
re-run for up to 30 days. "Re-run failed jobs" also reuses the run's own
`kci-release-<revision>` artifact, so its `kci` binary too (kept 14 days;
"Re-run all jobs" rebuilds it from the same commit). Every `kci.yml` on
`main` before this one runs `prod` on `if: github.event_name ==
'workflow_dispatch'`, and the `kci` of those commits has no
`KCI-E-SUPERSEDED` and no `KCI-E-PLAN-ON-RELEASE` check. So a re-run of a
MANUAL run of `main` started before this file merged is a way into `prod`
that is not a push to `main`, and can publish an older build there. Its
`gamma` job (the old stage's, publishing to the old channel `komira-ai/gamma`
until M3 removes that channel's publishers) also runs in the environment
`gamma` from a manual run, with no break-glass reason and no reviewer. Neither `kci.yml` nor `kci` can refuse
it: the re-run runs neither of them as they are now.

The runs, read on 2026-10-05 (`gh api
repos/komira-ai/komira/actions/workflows/kci.yml/runs -f
event=workflow_dispatch`; the only two such runs of `kci.yml`):

| run | ref, commit | started | what a re-run reaches |
|---|---|---|---|
| `37239801770` | `main`, `6e843fe6e` | 2026-10-04 22:22Z | `prod` (its `prod` job printed `PUBLISH: the release is written to komira-ai/prod` and was cancelled in `kci run --stage prod`) |
| `37238572861` | `main`, `6e843fe6e` | 2026-10-04 22:04Z | `gamma` in the environment `gamma`, then `prod` |

**Any manual run of `main` started before this file merges adds a row.**
Every PUSH run before it ran a `kci.yml` whose `prod` job is manual-only
(checked for all 45 push runs of `kci.yml` on 2026-10-05), so re-running
one never reaches `prod`.

**The action (CEO), before or when this merges: delete those runs.** It is
the only action that closes this. List every manual run of `kci.yml` on
`main` started before the merge, and delete each one (Actions -> the run ->
"Delete workflow run", or `gh run delete <id>`). A deleted run cannot be
re-run:

    gh run list --workflow kci.yml --event workflow_dispatch --branch main --limit 100
    gh run delete 37239801770
    gh run delete 37238572861

Do not start a manual run of `main` between the deletion and the merge; if
one is started, delete it too.

A required reviewer on `prod` is NOT a hold for these runs. A re-run of
`37238572861` runs its old `gamma` job, which names the environment `gamma`
on a manual run; its ref is `refs/heads/main`, so `gamma`'s branch rule
(`main` only) lets it in, and it reaches the gamma publisher with no
break-glass job, no `gamma-breakglass` reviewer and no recorded reason (the
old `kci` has no reason check). A reviewer on `prod` alone leaves that open
until 30 days after the last such run (for the two above, until
2026-11-04). Until every such run is deleted, gamma without break-glass, and
prod by a re-run, both stay open.

### Pausing promotion to prod

**Pausing promotion to prod.** Settings -> Environments -> `prod` -> Required
reviewers: add a reviewer, and confirm **Allow administrators to bypass
configured protection rules** is UNCHECKED on `prod` (by default it is
checked, and then a repository administrator can force a waiting prod job
to proceed with no approval; the pause would bind everyone but
administrators). Every prod job from then on waits for approval;
build, beta and beta_validate still run for the revision being released. Because
a release holds the `kci-release-main` group until its prod job ends, a
waiting prod job also holds back later pushes: at most one newer run waits as
pending (newer pushes replace it). **To resume**, remove the reviewer AND
approve or reject the job already waiting (removing the reviewer does not
release a job that is already waiting). Rejecting it lets the pending, newest
run proceed. A waiting job expires after 30 days; the release artifact after
14, so approve within 14 days or reject. No code change and no PR is needed.
Deployment branches for `prod` stay "Selected: main" whether paused or not:
that setting is what keeps break-glass out of prod.

The two side effects of a pause, in short: later pushes queue behind the
waiting `prod` job (only the newest one stays pending), and the waiting job
must itself be approved or rejected after the reviewer is removed.

### Break-glass: a manual run builds only

Every manual run (`workflow_dispatch`, of a branch or of `main`) is
BREAK-GLASS: it builds its revision on the farm and PUBLISHES NOTHING. `build`
is the machine file's only `break_glass` stage; `beta` and `prod` are not, so
three things keep a manual run out of their channels: each of their jobs'
`if:` carries `github.event_name == 'push' && github.ref ==
'refs/heads/main'` (rule R15, which the retired welded test `test_repo_kci_yml` held
for `beta` and `beta_validate` with one refused mutation per conjunct), each
job's step `only a push to main reaches this job` compares the event and
`GITHUB_REF` byte for byte (rule R21), and kci refuses a stage without
`break_glass` on any run but a push to `main` (exit 3, `KCI-E-NOT-ON-MAIN`).
No break-glass environment exists or is named (no `beta-breakglass`): to
publish a fix to `beta`, merge it to `main`. The input `reason` is required;
it reaches kci only through each job's `env:` (`--context reason=...`), never
inside a `run:` script (rule R18; nor in a `with: script:`, and no step's or
job's `name:` holds any expression at all), and kci refuses a break-glass run
without one, with one that is only whitespace, or with one over 200 bytes once
trimmed (exit 3, `KCI-E-BREAK-GLASS-REASON`). A break-glass run that is not a
dry run builds the commit it started on: a `revision` input is for a dry run
only, on the history of that commit (kci refuses any other, exit 3,
`KCI-E-BREAK-GLASS-REVISION`). Every job's summary of such a run starts
`BREAK-GLASS: <ref> <revision> by <actor>: <reason>`.

**What is the lock, and what is not.** A pull request's run uses the
pull request's own `kci.yml`, and a run of a branch (a manual run, or a push
to a branch whose own `kci.yml` adds it as a push trigger) uses that
branch's own `kci.yml` and builds that branch's own `kci`. Anyone with
write access can make either one. So NOTHING in `kci.yml` or in kci can stop
such a run from naming an environment and asking for an identity token. The
locks are GitHub's settings: `prod` deploys only from `main` (a job naming it
from a pull request's merge ref or another branch is rejected before it
starts, and GitHub's identity token for a job in an environment names only
the environment, so the environment's branch rule is what stands between a
branch and the channel's trusted publisher). ⚠ **The environment `beta` has
no deployment branch rule (the project owner's choice), so a branch whose own
`kci.yml` drops the `if:` and the step can publish that branch to
`komira-ai/beta` with no recorded reason.** `beta` is a test channel
(consumers install from `prod`, which a branch cannot reach); setting `beta`'s
deployment branches to `main` only would close it.

### GitHub settings the release relies on

None of these is in the repository; each is a setting an administrator
makes, and the release is only as safe as they are. ⚠ The environment `beta`
has NO deployment branch rule (the project owner's choice): `kci.yml`'s `if:`,
its push-to-main step and kci keep a run of an unmodified `kci.yml` out of
`komira-ai/beta`, and nothing keeps a branch's own modified copy out
([Break-glass](#break-glass-a-manual-run-builds-only)). The ruleset row is
NOT set yet.

The old channel `komira-ai/gamma` received the releases before the stage
`beta` replaced the stage `gamma` (the staged pipeline's M2,
[staged_pipeline.md](design/staged_pipeline.md), section e3). No workflow
names it, `gamma-breakglass` or the old stage any more; its trusted
publishers (whichever the host holds for `environment:gamma` and
`environment:gamma-breakglass`) stay until M3 removes them, and the channel itself until M4. Until M3, a job in the
environment `gamma` or `gamma-breakglass` can still publish to it.

⚠ **Administrators bypass a reviewer by default.** GitHub's documentation
("Managing environments for deployment"): "By default, administrators can
bypass the protection rules and force deployments to specific
environments"; its 2023-03-01 changelog adds that an administrator can
"bypass all protection rules on a given environment ... and force the
pending jobs referencing the environment to proceed". So with the box
**Allow administrators to bypass configured protection rules** checked (the
default), a repository administrator can force a paused `prod` job with no
second person's approval. Uncheck it on `prod`. The bypass forces a PENDING
job; a job a deployment branch rule refuses is not pending, and GitHub
matches that rule against the run's `GITHUB_REF` (`refs/pull/<n>/merge` for
a pull request), so the `main`-only rule on `prod` holds either
way. **Residual with every setting applied:** an administrator can re-check
the box or change any setting here; these settings bind runs, not the
administrators who own them (GitHub's audit log records the change).

The ruleset row stays open until it is VERIFIED. GitHub's ruleset
documentation does not say whether its pattern matching is case-sensitive.
If it is not, "except the branch `main`" also excepts `MAIN`, and the rule
blocks nothing. Until a check passes, `prod`'s case-variant exposure stays
OPEN: the `prod` job's `if:` compares ignoring case, a branch's own
`kci.yml` can drop the shell check, and whether `prod`'s branch rule `main`
matches `MAIN` is undocumented. The check: after creating the ruleset, try
to create a branch named `MAIN` (for example `git push origin
HEAD:refs/heads/MAIN`); it must be refused.

| setting | value | what it locks |
|---|---|---|
| environment `prod`, deployment branches | Selected: `main` | only `main` publishes to prod (already set) |
| environment `prod`, administrator bypass | **Allow administrators to bypass configured protection rules UNCHECKED** | a pause ([Pausing promotion to prod](#pausing-promotion-to-prod)) holds administrators too |
| manual runs of `main` started before this file merged (`37239801770`, `37238572861`, and any later one) | deleted, before or when this merges (the only closing action: a reviewer on `prod` leaves the old `gamma` job, environment `gamma` on a manual run of `main`, open) | a re-run of one runs the OLD `kci.yml` (gamma as `gamma` and prod on any manual run) and the old `kci`, which nothing here can refuse ([Re-runs of runs from before auto-promotion](#re-runs-of-runs-from-before-auto-promotion-a-ceo-action)) |
| environment `beta`, deployment branches | none (the project owner's choice; `main` only would lock it) | nothing: a branch's own modified `kci.yml` can publish to beta ([Break-glass](#break-glass-a-manual-run-builds-only)) |
| prefix.dev `komira-ai/beta`, trusted publisher | `komira-ai/komira`, `kci.yml`, environment `beta` only | only a job in the environment `beta` publishes to beta (set) |
| prefix.dev `komira-ai/gamma`, trusted publishers | removed (M3, after the first green release to beta) | the old channel takes nothing more |
| prefix.dev `komira-ai/prod`, trusted publisher | `komira-ai/komira`, `kci.yml`, environment `prod` only | (already set) |
| repository ruleset, then VERIFIED | block creating and updating branches and tags matching `[Mm][Aa][Ii][Nn]` except the branch `main`, and the tag `main`. Then try to create the branch `MAIN`: it must be refused | no ref that is `main` in another case exists, so GitHub's case-insensitive `if:` and concurrency comparisons cannot be fooled by one (whether the environment branch rule `main` matches `MAIN` is undocumented). Until the check passes, prod's case-variant exposure is OPEN |

- **One command.** kci has exactly one command, `kci run --stage S`. There is
  no `kci build`, `kci publish` or `kci ci check`. `kci run` also takes
  `--only step:<name>` / `--only validation:<name>` (repeatable) to run a
  selection; such a run is recorded with `scope: SELECTIVE` and its last
  stderr line says `-- not a full run`. `--only step:<name>` runs the step
  WITHOUT its validations; only a FULL run runs both. A release job runs its
  whole stage unless the stage is split over jobs that together run all of
  it exactly once (rule R9, amended and pending a ruling): here only `beta`
  is, into `beta` and `beta_validate`. `--plan` is the dry run of a whole stage.
- **The workflow is checked at start-up.** Under GitHub Actions
  (`GITHUB_ACTIONS=true`), before it runs anything, `kci run` reads the
  workflow file it runs under as it was committed (`GITHUB_WORKFLOW_REF`'s
  path at `GITHUB_WORKFLOW_SHA`, through `git show`) and holds it to the
  machine file and every channels file it names (rules R1-R12 and R14-R22 of
  `src/kci_workflow_check/rules.mojo` and `auto_promotion.mojo`: a job per stage named for it, each job's
  environment its stage's, `needs` the jobs that run the stage's `after`,
  `id-token: write` only where a stage publishes by trusted publishing or is
  farm-connected, one `kci run` per job with `--summary-file`, `--only` only
  in a split stage whose jobs run all of it once (a validations-only job has
  no environment, no identity token, and needs the stage's own job), a
  `pull_request` trigger and no job for the PULL_REQUEST stage (rule R6),
  the inputs `revision`, `reason` and `dry_run`, every `uses:` pinned,
  `farm-connect` exactly on farm-connected stages, and the auto-promotion
  rules above: the main-only conjunct, the one concurrency group, the push
  filter, the set hash handed on, the prod line, and a release job's
  permissions `contents: read` and `id-token` only). A mismatch is refused (exit 3, `KCI-E-WORKFLOW-MISMATCH`, every
  finding listed, nothing run); an unreadable workflow or channels file, or a
  missing variable, is exit 5 and never a pass. The same check was the welded
  test `src/kci_workflow_check/tests/test_repo_kci_yml.mojo` (deleted with
  `kci.yml`), so a drift also failed `./buck2 build //...`. Consequence: a revision whose machine file
  disagrees with the running `kci.yml` cannot be released by it (a manual run
  of an old revision is refused, exit 3).
- **Triggers:** a push to `main` (not a documentation-only one) and a manual
  run (`workflow_dispatch`), and nothing else: kci.yml has **no `pull_request`
  trigger** (one added is refused by rule R6, as is `pull_request_target` and
  every other event), so a pull request never starts it and never shows a
  skipped beta, beta_validate, prod or build job. No environment, publishing token
  or release job is reached from a pull request's code. The push trigger is
  exactly `branches: [main]` with the documentation `paths-ignore` (rule R17).
  Rule R6 of `src/kci_workflow_check` holds all of it, and holds pr.yml to the pull
  request's check alone (next section).
- **The revision.** A run releases the commit `REVISION`: the pushed commit,
  or a manual run's input `revision` (a full commit id; empty means the commit
  the run started on). Every job checks it out, kci refuses a checkout whose
  HEAD is not that commit, and the artifact and result names carry it. kci
  requires `REVISION` to be on `main`'s history for a run of `main`, and on
  the branch's own history for a break-glass run, so no run publishes an
  unmerged commit to `prod`.
- **Dry run on request.** A push is a real run. A manual run reaches `build`
  only, which always builds; its input `dry_run` lets it name a `revision`
  on the history of the commit it started on. No publish job runs on a
  manual run, so no workflow run is a dry run of a publish; `kci run --plan`
  on a developer's machine (not under GitHub Actions) is.
- **What a dry run of a publish job would prove** (a `--plan` run under
  GitHub Actions; no job of `kci.yml` makes one today): the release set verifies
  (members, closure, set hash, platform); the channel's repodata and files
  read anonymously at the URLs kci builds; the job gets a GitHub ID token
  (`id-token: write` is there and the environment gate was passed); its
  claims are the ones kci expects (the `environment` claim is the stage's);
  and prefix.dev's mint endpoint accepts it, so a trusted publisher matching
  organisation `komira-ai`, repository `komira`, workflow `kci.yml` and that
  environment exists. The minted token is discarded unused
  (`credential_probe: MINTED` on the step's row). It does **not** prove: that
  the publisher that matched belongs to that channel (the mint request names
  no channel), that it may write (a publisher saved as read-only still
  mints), the upload request itself, or the read-back after an upload. The
  first real beta publish proves those for beta.
- **NEW NAMES, before prod.** Which names a release publishes is
  `release/artifacts.textproto`'s, reviewed through CODEOWNERS; there is no
  per-run claim. Every publish step reads its channel first and reports the
  declared names the channel holds no file of yet (NEW NAMES) in its result
  file (`new_names[]`) and in the job summary. Each `kci run` also reports
  the NEW NAMES of the stages after it: **the `beta` job's summary shows the
  names new to `komira-ai/prod`** before `prod` publishes them (a first
  publish of a name is the one effect a later release cannot undo; pause
  promotion, above, to read it first). A run given no release version (the
  `beta_validate` job) cannot name the files and says `lookahead skipped`. A
  channel that could not be read is reported "not read", never "none". A dry
  run reports the same.
- **One record.** Every kci invocation writes kci's result document
  (`--result-file`, format `kci.result`): RUNNING before the first effect and
  FINISHED on every exit, with the workflow check (`workflow`), the steps, the
  set hash and the NEW NAMES. Each job uploads it whatever the outcome, as
  `kci-result-<job>-<REVISION>`, and every `kci run` appends a markdown
  summary to the job summary (`--summary-file "$GITHUB_STEP_SUMMARY"`). The
  run is identified by `--run-id gh-<run id>`, `--attempt <run attempt>` and
  `--context` lines. The exit numbers are kci's one table: publishing a set
  the channel already holds, byte for byte, is exit 0.
- **Validations.** A publish step can declare validations (`validation {
  kind: CONDA_INSTALL_ENV ... }`); beta has two: `install-komira-encoding`
  installs `komira_encoding` ALONE (its own requirements must suffice) and
  `install-set` installs `komira_all` ALONE. kci runs them after the step in
  a FULL run, or alone with `--only validation:<name>` against what is
  already published. In order, each failure exit 7 (`VALIDATION_FAILED`, a
  row per finding in the result and the job summary): (1) the pins:
  `release.json`'s version, build and sha256 of each installed name and, for
  the metapackage, of every member its own built requirements name (they
  must be exactly the release's libraries, at the release's version and
  build; none at all is refused), `metadata.json`'s payload sha256, README
  sha256 and `mojo_pin`; (2) whether there is a network at all: every
  declared host is asked once, anonymously; when NONE answers the run is
  INDETERMINATE, exit 5, with a `skip_reason`, never a pass (any HTTP answer,
  a 401 included, is a network, so the checks below run); (3) the channel,
  read from the runner ANONYMOUSLY: the index lists each file with the
  build's sha256 and the channel serves those bytes (only a file's absence,
  or a 404 index, is waited for, up to `wait_for_index_seconds`, 1800 s here,
  then it fails; a 401 or another sha256 fails at once); (4) on the runner,
  with no container: the pinned pixi (`--pixi`, its bytes checked against
  `--pixi-sha256`) in a fresh scratch directory outside the checkout, a
  cleared environment, no system-wide pixi config, `pixi install` of the
  NAMED packages only (so the solver must bring every member through the
  metapackage) from the channel and `mojo-compiler ==<mojo_pin>` from
  Modular's channel; (5) read back: every installed record has the release's
  version, build and sha256 and comes from a declared channel, each
  library's installed `.mojoc` is the build's, and each library's installed
  `share/doc/<name>/README.md` has the sha256 its `metadata.json` records and
  holds at least one ```mojo example; (6) each README's examples, made into
  one program and run with `pixi run --as-is mojo run` from the scratch
  directory, print `readme_<import> validation: N of N checks passed`,
  N > 0, a failure naming the README line. Under `--plan` nothing runs
  (`WOULD_VALIDATE`). The same examples are a welded test of each library's
  own build (`[tests][readme]`), so an API change fails `./buck2 build //...`
  before it can fail a release.
- **Before publishing: a local channel.** The same validations run against a
  release that is not published yet: `komira_pack conda-index --out-dir <dir>
  --package-manifest <release dir>/<platform>/<name>/manifest.json ...`
  writes a local conda channel (the files, each subdir's `repodata.json`
  from the packages' own `info/index.json`), and `kci run --stage beta
  --only validation:<name> ... --channel file:///<dir>` reads and installs
  from it instead of the step's channel (only the compiler and extra
  channels are asked over the network). `--channel` is refused unless the
  run selects only CONDA_INSTALL_ENV validations (no BUILD or PUBLISH step),
  and under GitHub Actions: a workflow validates only what was published
  (rule R14 refuses a `kci run --channel` in the workflow itself). The
  result row records the location (`channel_url`).
- **Each validation is a target.** `./buck2 run
  //release/validations:<name> -- --release-dir <R> --revision-id <C>
  [--channel file:///<dir>]` runs `kci run --stage <stage> --only
  validation:<name>` with kci and the pinned pixi of your platform's row,
  from the repository's root whatever directory it starts in
  ([release/validations/defs.bzl](../release/validations/defs.bzl)): no
  `--scratch-dir` means a fresh directory under the system temp directory.
  The targets are the machine file's validations, both ways
  (`kci_release_machine`'s welded test), and the `beta_validate` job's `kci run`
  passed what they pass (`test_repo_kci_yml`, deleted with `kci.yml`), so a
  developer and the workflow ran the same thing.
- **The channels.** prefix.dev channels `komira-ai/beta` and
  `komira-ai/prod` ([release/channels.textproto](../release/channels.textproto)),
  both public. Uploads go to `https://prefix.dev/api/v1/upload/komira-ai/<channel>`
  and reads to `https://prefix.dev/komira-ai/<channel>/<subdir>/repodata.json`
  ([prefix.dev: channels](https://prefix.dev/docs/prefix/channels/concepts),
  [API](https://prefix.dev/docs/prefix/api)).
- **No secret.** Each channel's credential is trusted publishing: the channel
  trusts this repository, the workflow file `kci.yml` and one GitHub
  environment (`beta` or `prod`), and kci exchanges the job's ID token itself
  (audience `prefix.dev`). kci refuses a token whose environment is not the
  stage's. The publish jobs are top-level jobs of `kci.yml` on purpose: a
  reusable-workflow call changes the token's workflow claim. The `prod`
  environment's deployment branch rule (`main` only) and, when promotion is
  paused, its required reviewer are GitHub environment settings, outside
  this file.
- **Farm and tokens apart.** Only the `build` job joins the tailnet
  (`farm_connected: true` on the stage; rule R11), and it publishes nothing;
  the publish jobs hold a publishing token and no tailnet node.
- **No release machine, no release.** While `release/machine.textproto` is
  absent, a push to `main` is a reported skip (a warning and a summary line;
  every later job is skipped). A manual run without it is refused (exit 1).
- **Known residual:** the publish jobs run the kci binary the `build` job made
  (it travels in the workflow artifact). How kci itself reaches the runner is
  an open design question.

### The workflow subset kci reads

kci holds a workflow to the machine file by reading it with its own reader
(`src/kci_workflow_check/workflow_reader.mojo`), which accepts a strict subset of
YAML and nothing else. Inside the subset every value it reads is exactly the
value YAML, and so GitHub, reads. A line outside it is "cannot tell" (exit 5
at start-up, a red welded test), naming the line: never read, never guessed
at, never a pass. A workflow kci checks is written inside it:

- **Lines:** printable ASCII. A full-line comment may also hold other UTF-8,
  but not a YAML 1.1 line break (U+0085, U+2028, U+2029) or a byte order
  mark. No TAB anywhere, no carriage return.
- **Comments:** a line starting with `#`, or ` #` after a value.
- **Mappings:** by indentation, `key: value` or `key:`. A key is plain
  (`[A-Za-z0-9_.-]`), never quoted. Keys of one mapping differ ignoring case,
  and a key the check reads (`on`, `jobs`, `permissions`, `id-token`, `if`,
  `needs`, `runs-on`, `environment`, `steps`, `run`, `uses`, `with`, `fetch-depth`,
  `inputs` and the trigger names) is written in lower case.
- **Lists:** by indentation, `- value` or `- key: value`, one space after the
  dash.
- **Scalars:** on one line. Plain (no `: ` inside, no final `:`), or
  single-quoted with no `'` inside (so no `''`), or double-quoted with no `"`
  and no backslash inside. Only a comment may follow a quoted scalar.
- **Flow:** `[]`, a list of plain words (`[main]`, `[build, beta]`), and `{}`.
- **Block scalar:** only a literal `|` (no chomping or indentation
  indicator), and only as a `run:` value. It is read as YAML reads it.

Refused, among others: folded `>`, `|-`, `|+`, and any block scalar not under
`run:`; a value continued on the next line; any escape; anchors, aliases and
tags; merge keys `<<`; `?` keys; flow mappings other than `{}`; a quoted or
nested flow item; `---`, `...` and `%` directives. actionlint
(`//:workflow_lint`) stays the YAML-validity gate. The subset is a reader
rule, not a style: a spelling found to read one way to kci and another to
GitHub is answered by keeping it outside the subset, and each such spelling
is a row of `src/kci_workflow_check/tests/test_workflow_subset.mojo`.


## pr.yml: the pull request's check

[`.github/workflows/pr.yml`](../.github/workflows/pr.yml) is workflow `pr` with
one job `check`, so the status check is **`pr / check`** (GitHub lists the
context as `check`; the repository's ruleset requires that context, and only
pr.yml has a job of that id). It runs named Buck2 targets on the farm and does
not run kci. Neither it nor
[`release.yml`](#releaseyml-the-release) is held to the machine file now.

| | |
|---|---|
| trigger | `pull_request` alone: no push, manual run, `pull_request_target`, `workflow_run` or any other event |
| job | the one job `check`, only for a pull request from a branch of this repository (`github.event.pull_request.head.repo.full_name == github.repository`; a fork's run gets no tailnet credential, and a maintainer reads the change and pushes it to a branch here), written bare or as exactly `${{ <condition> }}` (a block scalar or whitespace inside quotes makes GitHub read the `if:` as a format string, which is always true) |
| runner | `runs-on: ubuntu-24.04`, written as that plain scalar: a GitHub-hosted machine, fresh per job. A self-hosted label, label list, runner group, expression (`${{ vars.X }}`) or quoted value is refused, so a pull request's code never reaches a runner that keeps state between jobs |
| permissions | its own `permissions:` mapping, `contents: read` and `id-token: write` (for the farm connection, [farm-connect](#how-it-reaches-the-farm), only); no environment, no secret (no value of the job, nor of the workflow-level `env:`, names `secrets` other than `secrets.GITHUB_TOKEN`), no publish step |
| steps | the pinned full-history checkout of the merge commit, `farm-connect`, and the farm assertion (`//tools/build/ci:assert_remote`). Then the change: `git diff --name-only HEAD^1...HEAD` and the coverage holds of both sides, where HEAD^1 is the merge commit's first parent (the `main` the pull request is merged into; the step stops when HEAD has no second parent). Never the event's `github.event.pull_request.base.sha`: that is `main` when the event fired, and once `main` moves every change merged to it since then would count as the pull request's own and widen the check. Then, each as the `buck2-farm` action (so each fails unless no action ran on the runner): the BXL selector `tools/build/ci/affected.bxl:affected` (the owners of the changed files and everything that depends on them, or `//ci:pr`, the whole check set, when a file cannot be mapped or touches the build system; the heavy checks of `HEAVY` in `tools/build/ci/rules.bzl`, today the kci binary and what depends on it, only when the change touches paths that row owns, so a change that owns none builds `//ci:pr_default` in place of `//ci:pr`), `build --keep-going` of its list, the checks only BXL can make over the whole graph (`test_weld.bxl:check` for each test_weld lint, `graph/checks.bxl:check` for each graph_check, `guard.bxl:check` that `//ci:pr` holds every check target, `python_guard.bxl:check` that it reaches no Python outside the SDK, `default_guard.bxl:check` that `//ci:pr_default` is `//ci:pr` without the roots of `HEAVY` and nothing else, `lock_graphs.bxl:check` that each package's `buildrules.mojo.lock.bzl` holds a unit graph for every platform subdir its `mopm.lock` records, `cases.bxl:run`, and `readme_e2e/cases.bxl:run`, the cases of the README e2e's completeness guard), and `test` of the list's targets that are not of the tests cell. A pull request that adds or deletes a package needs no edit to any release file; adding a target to the check set means regenerating `ci/targets.bzl` (the guard fails, naming the command, when it is not). Nothing ships. |
| every `uses:` | pinned to a full commit id (the local farm-connect action excepted) |

The repository's branch settings require the check **`pr / check`**.

## coverage.yml: the pull request's coverage (not a gate)

[`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml) posts
the check run `coverage`: the line coverage of the `mojo_library` targets and of
the `mojo_package` packages the change touches (the latter from their
`:coverage[reports]`, one kcov report per test), and the branch coverage of
the libraries whose coverage gate reads branch records
(`COVERAGE_BRANCH_GATE`) and of the packages with `:coverage[branches]` (one
lcov file per test, from the compiler's IR; a `branch` line of such a
package's `coverage_held` is checked against it, and only a package whose
tests link a native library, which has no branch records, has that line left
out of what covcheck reads), as covcheck's summary and
annotations on the lines of the "Files changed" view. It is **informational**: not a required check, its
conclusion is `neutral` in the policy's census mode, except that a touched
package under the 99.00% target on a metric it holds (its `coverage_held`: a
`Regression`, which fails in every mode) makes it `failure`; it cannot make
`pr / check` red, so that failure shows on the pull request without
blocking it. Job `measure` (the same farm connection and permissions as
`pr / check`) builds the touched libraries' `[coverage][tests]`, and
`[coverage][branch_info]` of those whose gate reads branch records, with
`-c komira.coverage=true` on the farm, in one call, and runs `covcheck
report` over the reports and those records (`--branch-lcov`); a library
whose coverage build fails is listed as not measured, one whose branch
records (or gate) fail as branch not measured, and the job stays green. Job `post` holds the only write permission
(`checks: write`), checks nothing out and sends the bodies `measure`
uploaded. A pull request from a fork runs neither, and nor does one whose
base is not `main`: a stacked pull request gets no coverage run until it is
retargeted to `main` and then pushed to (a retarget alone is an `edited`
event, which neither workflow listens for; the pull request adding the
workflow sees its first real run then). A pull request whose head predates the workflow (no
`.github/ci/coverage_measure.sh`) is not measured: job `measure` is green
with a notice to merge `main`, job `post` is skipped, and no `coverage` check
run is posted. Making it a required check, or switching coverage on in
`pr / check`, waits for the sweep of tests that fail at `-O0` or under kcov
(in a coverage build one such test leaves its library's conda package
unbuilt: a coverage run or gate blocks only the package it measures from
shipping, never the library or its dependents) and is the CEO's decision. Details:
[The coverage workflow](../tools/build/coverage/README.md#the-coverage-workflow).

## main_red.yml: the main red alert

There is no merge queue: pull requests are checked one at a time and merged
into `main`, and the release run of `release.yml` builds each push to `main`. Two
changes that are each green can still break `main` together. The rule is
**fix forward or revert within the hour**: when the release run of `main`
fails, the author of a culprit pull request lands a fix, or reverts the
pull request, within an hour of the alert, before anything else merges on
top of it.

[`.github/workflows/main_red.yml`](../.github/workflows/main_red.yml) is the
alert. It runs when a run of `release.yml` on `main` completes (`workflow_run`),
builds the Zig program [`//release/ci:main_red`](../release/ci/main_red.zig)
on the farm (`./buck2 build`, then runs the binary that build produced) with
`issues: write`, `actions: read`, `contents: read` and the `id-token: write`
the farm connection exchanges, checking out `main` and running no code of any
pull request. The workflows it reads are `--workflow <name>` flags of that
step (and the trigger's `workflows:` list): the program names none itself, so
a replacement push workflow is added to both in its own pull request. It names
one: `release`. It acts
only on a run of a named workflow started by a push to `main`:

- **Red** (`failure`, `timed_out`, `startup_failure`): the last green
  commit is the newest commit of a successful push run of a named workflow
  on `main` that is an ancestor of the red one; the culprits are the pull
  requests merged into `main` after it (the first-parent commits of the
  range, newest first); the failing targets are the `Action failed:`,
  `GATED TEST FAILED:` and ``Validation for `<target>` failed`` lines of
  the failed jobs' logs, which are buck2's own output (with none, the
  failed job and step). If no issue
  labelled `main-red` is open, it opens one titled `main red: <first
  failing target>`; otherwise it comments on the open one. A red commit
  that a later green run already contains (a re-run of an old run) is
  left alone.
- **Green** (`success`): every open `main-red` issue is closed with the
  comment `Fixed: main is green at <commit> (run <url>)`, unless it records
  a red head the green commit does not contain (a re-run of an older
  commit went green). The recorded heads are the `Head:` lines of the
  issue's body and of the workflow's own comments (`github-actions[bot]`);
  no other comment counts, and a head the API cannot place on `main`'s
  line is skipped.
- **Cancelled or skipped**: nothing.

The issue body, and each comment on a later red run, is one `Key: value`
line per field, in this order, for tools that read it:

```
Run: <run url>
Head: <full commit id>
Last green: <full commit id, or none>
Culprits: #N, #M            (or: Culprits: unknown)
Failing: <target>           (one line per failing target)
Log: <key log line>         (none, one or two lines)
```

**Nothing hides a red `main`.** `release.yml`'s push runs share one
concurrency group with `cancel-in-progress: false` ([Queued
runs](#continuous-auto-promotion)): a running release is never cancelled,
and a newer push replaces only a pending run, which never started. The run
that replaces it builds a later commit of `main`, which carries the
replaced one's changes, and the culprits come from the whole range since
the last green commit, so the replaced commit's pull request is still
named. `main_red.yml` has no concurrency group, so none of its runs is
replaced or cancelled; if two red runs race to open the issue, the newer
issue is closed as a duplicate of the older. One delay remains: a push
that changes only `docs/**` or `*.md` files starts no `release.yml` run, so a
README example it breaks is found by the next push's run, whose
range names it. Cases: `//release/ci/tests:test_main_red`, a `zig_test` the
program is built behind.

## Running it yourself

```sh
./buck2 build //... && ./buck2 test //...
./buck2 build --keep-going tests//functional/...
```

The build-system self-tests (Linux x86_64 client): `tools/build/tests/run_tests.sh`.

The lints alone, without building the rest:

```sh
./buck2 build //:shell_lint //:workflow_lint //:action_pins //:no_endpoint
```

A failing lint prints `Validation for <target> failed:` and its findings.
