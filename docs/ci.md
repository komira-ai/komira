# Continuous integration

A pull request from a branch of this repository runs ONE check: `pr / check`,
and the same check runs again on each pull request in [the merge queue](#the-merge-queue),
on top of the ones ahead of it, before it reaches `main`. The check is
the one job `check` of [`.github/workflows/pr.yml`](#pryml-the-pull-requests-check),
a workflow of its own, on a GitHub-hosted runner that reaches the build farm
over a tailnet. The runner is
a thin buck2 client: it checks the repository out and asks the farm to build
and test the targets the change reaches ([pr.yml](#pryml-the-pull-requests-check)).
Nothing is compiled on the runner.

| event | runs |
|---|---|
| push to `main` | [`release.yml`](#releaseyml-the-release): builds the release set, installs the Python wheel as a user does ([the user test](#the-user-test-of-the-wheel)), and publishes the mopm packages to the prod registry, on every push (no schedule, no switch); when that run ends, [`main_red.yml`](#main_redyml-the-main-red-alert) |
| pull request from a branch of this repository | `pr / check`; and `coverage`, informational, not required ([below](#coverageyml-the-pull-requests-coverage-not-a-gate)) |
| merge group of the [merge queue](#the-merge-queue) (`merge_group`) | `pr / check` on the group's head commit, which is what `main` becomes; `coverage` does not run |
| pull request from a fork | nothing: no farm job runs ([below](#pull-requests-from-forks)) |
| manual (`workflow_dispatch`) | [`release.yml`](#releaseyml-the-release), on the chosen ref, with a reason |
| daily at 05:17 UTC (schedule) and manual (`workflow_dispatch`), on `main` | [`pypi.yml`](#pypiyml-publishing-the-python-package): builds the `komira` wheel on the farm, installs the wheel file on a fresh runner per supported Python and runs the quickstart ([the user test](#the-user-test-of-the-wheel)), uploads it to TestPyPI, installs it from there and runs the quickstart, then does the same on PyPI; the macOS arm64 wheel of the same version is a second chain of jobs in the same file, built on the farm's Macs only when an index lacks it and smoked on a hosted macOS runner |
| weekly (schedule) and manual | [`kpin-update.yml`](../tools/build/kpin/README.md#the-weekly-update): updates the pins and opens one pull request; no farm, and its pull request does not start `pr / check` by itself. A manual run with `real_hosts` instead checks kpin against the real registries |

There is no separate static or lint job, and no other pull request check
that can block a merge: the `coverage` workflow only reports. The scheduled
runs are the [build-system self-tests](#build-system-self-tests), which are not
the gate, the weekly [`kpin-update.yml`](../tools/build/kpin/README.md#the-weekly-update),
which opens a pull request and gates nothing, and the daily
[`pypi.yml`](#the-daily-run), which publishes the Python package when `main` has new code and
gates nothing.
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
     committed file; every relative link and anchor in the repository's
     Markdown resolving (`//:docs`, a `markdown_docs` target); and the
     shared core of [AGENTS.md](../AGENTS.md) equal byte for byte to its
     canonical copy and that copy's recorded SHA-256, with `CLAUDE.md`
     importing `AGENTS.md` (`//:agents_md_cases`). The lint of
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
   `[komira_re]`. It also writes two keys for a slow connection to the farm
   (through a tailnet relay it carries a few MB/s for all of a job's
   uploads): `grpc_keepalive_timeout_secs = 60`, since buck2's default of
   10 s to answer a PING drops a connection whose PING waits behind upload
   data, with every stream on it; and `max_concurrent_uploads_per_action = 4`,
   so fewer streams share the connection and each blob finishes sooner.
   Developers put the addresses, instance name, `tls` and properties in their own gitignored
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
It holds `farm-qos` to `batch` on every step of `release.yml` and `pypi.yml` and to
absent on every step of any other workflow.

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
| `FARM_DARWIN_ARM64_PROPERTIES`, `FARM_DARWIN_MACOS_HOSTS`, `FARM_MACOS_LIBRARY_DIRS` | the macOS arm64 worker property set, the host identities of those workers, and the directories a macOS test run searches for a library (the last is optional): the `darwin-properties`, `darwin-macos-hosts` and `macos-library-dirs` inputs, passed by the job `release-macos` of `release-macos.yml` and by the job `build-macos-arm64` of `pypi.yml`, and by no other job |
| `FARM_TLS` | `true` when the service serves REAPI over TLS; unset or empty means `false`. Each workflow passes it as farm-connect's `tls`, so the address and its transport change together |

Variables are not masked, and a job's logs are public. The action masks the
address, and the address is one reachable only from inside the tailnet, so
printing it would still disclose nothing usable. `//:no_endpoint` keeps an
endpoint out of every committed buckconfig, workflow and local action.

The connection is checked on every farm-connected run: the action's
`refuse unless the farm answers` step fails the job before any build when the
farm's port does not answer.

**Priority.** A farm that queues by priority class runs a `ci` action before a
`batch` one. The action takes an optional `farm-qos` (`ci` or `batch`) and, when
it is set, writes the request header `x-kbf-qos` as buck2's `http_headers`.
Every job of `release.yml` passes `batch`, and so do the jobs `build` and `build-macos-arm64` of `pypi.yml` and the job `release-macos` of `release-macos.yml`, so the release work that a push to
`main` starts waits behind the pull-request checks when the farm is full; no
other workflow passes it, so they stay at `ci`. The class is not a platform
property: it is not part of an action's digest, so a release build and a pull
request still share the same action-cache entries. It changes the order of the
queue only: a running action keeps its slot, and a farm that does not read the
header (or a buck2 that does not send it) queues the action as `ci`.

Give CI its own remote-execution instance name, a sub-instance such as
`<prefix>/ci`, so its action-cache entries are kept apart from developers' on a
service that keys the cache by instance (Buildbarn does; a cache tier that
ignores instance names, such as bazel-remote without
`--enable_ac_key_instance_mangling`, does not).

### Running a buck2 command on the farm

The local action
[`.github/actions/buck2-farm`](../.github/actions/buck2-farm/action.yml) runs
one `./buck2` command (build, test or bxl) and fails its step unless buck2
succeeded and no action ran locally. It is two lines, both the built tool
`//tools/build/ci:assert_remote`
([`assert_remote.zig`](../tools/build/ci/assert_remote/assert_remote.zig)): the
first, `assert_remote run`, runs buck2 with its output copied to the job log
and to a file, and the second reads the file.

When the connection between the runner and the farm is cut, buck2 fails every
action in flight at once, each with its own `Error:` line holding
`RE channel error: code:`. `assert_remote run`
([`farm_retry.zig`](../tools/build/ci/assert_remote/farm_retry.zig)) then runs
the same command once more, when every failure in the output is such a cut:
each failed action (`Action failed:`) or test (`✗ Fail:`) has that line among
buck2's own lines before its output, no test timed out or was fatal, and no
other error stands outside them. A log that mixes a real failure with cuts, a
test whose output only quotes the phrase, and a subcommand other than build,
test or bxl are never run again. The first output is kept beside the log as
`buck2-farm.first.log`, the job summary gets one line saying the step ran
again after a cut connection, and the second run is final: when it is cut too,
the step fails saying so. There is never a third run. The release workflows'
publish and upload steps are not buck2-farm steps, so this never runs one of
them twice; a publish cut half way stays a failed step.

The tool step fails when a `Commands:` summary line says `local:` anything
but `0`, when the log ends a failed run (`BUILD FAILED`, `BXL FAILED`), or when
there is no summary line although the run used the network. A run that executed
no action (everything cached, or a query-only bxl script) prints no summary line
at all, only `Network: up 0B  down 0B`, and passes on that line. `build` and
`bxl` print the same summary. The caller builds the tool first, on the farm, and passes
its path as `assert-remote`. That build, and the few other `./buck2` steps
that do not go through the action (pr.yml's build of its change tool, for
one), are not run again: a cut during one of them still fails its step. The cases are recorded buck2 output
(`//tools/build/ci:assert_remote_unit`, `//tools/build/ci:farm_retry_unit`) and
the action's own two lines run over it (`//:buck2_farm_cases`).

## Pull requests from forks

A fork's pull request gets no OIDC token and no repository variables
(GitHub withholds them from `pull_request` runs of forks), so it cannot join the
tailnet and has no farm address. Remote execution also runs the commands a
build describes, so running a stranger's build would be running its code on the
farm's workers. Therefore:

- The job `check` of `pr.yml` is **skipped** for a fork's pull request:
  `if: github.event_name == 'merge_group' || github.event.pull_request.head.repo.full_name == github.repository`
  (the first term is for the [merge queue](#the-merge-queue), whose groups always run).
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
- The workflows use `pull_request` (and `pr.yml` also `merge_group`, which runs
  only what a maintainer queued). There is no `pull_request_target`
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
| `child_reap` (required): start `sleep 30` through `supervisor`, stop it, reap it | alive after 300 ms, died of SIGTERM (15), a second reap finds no child | any test that runs its own server process (the embedded MinIO of `komira_test_minio`) |
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

## The macOS build of the release

macOS builds run only in release workflows, never in a pull request. There are two. The macOS
(darwin-arm64) set of the mopm packages is its own workflow,
[`release-macos.yml`](../.github/workflows/release-macos.yml) (one job, `release-macos`), once per release.
The other is the macOS arm64 wheel of the Python package: the job `build-macos-arm64` of
[`pypi.yml`](../.github/workflows/pypi.yml), at most once per version and only when that version's macOS file is
missing from an index
([below](#pypiyml-publishing-the-python-package)). `release.yml` holds no macOS job. The farm has far more Linux cores than
Mac ones, so a macOS leg in the pull request check would queue every change
behind the scarcest machines; the macOS platform is built in the release workflows
instead. The rest of this section is about `release-macos.yml`.

- **Not in a pull request.** `pr.yml` (and `coverage.yml`, the other workflow that
  runs on a pull request) pass no macOS worker set to the farm connection and name
  no darwin platform or runner (beyond the analysis below, which builds nothing), and
  `//ci:pr` is built for the client's own platform
  only: none of the targets it reaches has a macOS execution platform. A
  `cquery` of `attrregexfilter(exec_compatible_with, "macos", deps(//ci:pr))` is
  empty, and the same query for `--target-platforms
  komira//tools/build/platforms:darwin-arm64` over a library is not.
  `//:release_macos_cases` holds the workflows and the shards of `ci/targets/` to it, and holds
  `pypi.yml` to not running on a pull request or a merge group. The three targets of the macOS wheel
  (`//python:komira_wheel_macos_arm64`, `//python:wheel_install_test_macos_arm64`,
  `//python/smoke:pypi_smoke_macos_arm64`) stay out of the check twice: each has an `EXCLUDED` row in
  `tools/build/ci/rules.bzl`, so the pull-request selector never picks it, and each has
  `target_compatible_with = DARWIN_ARM64` (limit `pypi-wheel-macos-arm64` in
  `tools/build/platforms/limits.tsv`), so it builds only with `--target-platforms
  komira//tools/build/platforms:darwin-arm64`, which only `pypi.yml` passes.
- **Analysed in every pull request, built in none.** What fails before anything is built
  (a target of the set's closure incompatible with darwin-arm64, a toolchain with no
  execution platform, a rule that fails at analysis) is found in the pull request that
  causes it: the last buck2 step of `pr.yml` runs
  `bxl --config-file release/darwin_analysis.buckconfig komira//release/darwin_analysis.bxl:check`,
  which configures `//release:mopm_darwin_libs` for darwin-arm64 and analyses it, with its
  whole closure, as the release's build would. Configuring and analysing run no action, so
  nothing is built for macOS and no macOS worker is asked for anything; the config file
  registers the macOS execution platform with a property set that names no worker, which
  configuration needs and nothing uses. The step fails with buck2's own message, naming the
  target and the dependency. A failure that only a build shows (a compile, a welded test)
  is still seen first by `release-macos.yml`. `//:release_macos_cases` holds that this
  step is in `pr.yml` once, through the `buck2-farm` action with its assertion, and that it
  is the only line of a pull request workflow that names the macOS set.
- **On the farm's Macs, not a hosted runner.** The job runs on the same ubuntu
  runner as the others and asks the farm: `farm-connect` with the macOS worker set
  and hosts (the repository variables above), then
  `build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going //release:mopm_darwin_libs`
  through the `buck2-farm` action, which fails the step if any action ran on the
  runner. The compiles and the welded tests run on the macOS workers; the toolchain
  unpack runs on a Linux worker of the same farm. A job without the macOS
  variables fails its second step, naming the key, instead of building on the runner.
- **One list.** `//release:mopm_darwin_libs` (`release/darwin_libs.bzl`) builds the
  `:lib` of every package of `release/readme_e2e/packages.bzl` (every `src/<name>`
  with a `mopm.toml`) except `DARWIN_EXCLUDED` (empty today: a package's own C builds for macOS; a vendored
  third_party C or C++ library is the case that would be listed). A package moved to mopm joins the
  macOS build with no second edit. The target is left out of `//ci:pr` on purpose
  (`EXCLUDED` of `tools/build/ci/rules.bzl`).
- **Priority, timing, bound.** `farm-qos: batch` like every job of the file; once per
  release (a push to `main` that is not documentation-only, or a manual run: the same
  triggers as `release.yml`, so it builds the same commit), never per pull request, in
  parallel with the Linux jobs; nothing in `release.yml` `needs` it or reads its result.
  It is a separate workflow with its own concurrency group, `release-macos-<ref>`, and
  `cancel-in-progress: true`: `release.yml` is one group in which a running release is
  never cancelled, so a macOS job inside it that stalled would hold the next push's
  release, the Linux prod publish included. Here a newer push cancels the running macOS
  build and starts its own, and a macOS build never queues a release. The trigger is
  `push` plus `workflow_dispatch` rather than `workflow_run` after `release.yml`: it
  needs no ordering with the release (nothing waits on it), and `workflow_run` would
  start it only after the whole release finished, build the default branch's head
  instead of the pushed commit, and run for a pull request's `release.yml` run too if
  that ever changed. `timeout-minutes: 90` still bounds a stalled build.
- **Reported, not blocking (for now).** A red macOS build is a failed run of
  `release-macos.yml`, with a line in its summary, and the release run, the prod publish and
  `main_red.yml` do not see it: none of them `needs` it or reads its result. The job is not
  `continue-on-error`, which would end a failed build green. The last job,
  `release-macos-result` (`needs: release-macos`, `if: always()`), fails with "the macOS build
  did not run" when the build job was skipped, and with "did not pass" when it failed, so the
  run list, the commit status and the badge never read green for a Mac build that did not
  pass. Its message says what happened rather than guessing: when a buck2 step failed (the build
  of the set, or of the Python harness tests), `//release/ci:buck2_failure` (built before them)
  reads that step's buck2 output and the message is buck2's own lines after `BUILD FAILED`
  (also written to the run's summary);
  when an earlier step failed, the message names it. The farm connection refuses when a
  repository variable is empty (for the macOS set, `FARM_DARWIN_ARM64_PROPERTIES` and
  `FARM_DARWIN_MACOS_HOSTS` go together), and that is a failed run too. The set has not yet been measured on the macOS workers, and the publish must
  not wait on a platform the release does not ship. When the set is green over several runs,
  move the job back into `release.yml` as a `needs` of `prod-commit` (or keep the workflow
  and have the publish wait on it).

## release.yml: the release

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds the
conda packages that `release/artifacts.textproto` declares, as one release set,
with Buck2 targets on the farm, and installs the Python wheel as a user does on every run
([below](#the-user-test-of-the-wheel)). It is written by hand.
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
pull request never starts it, and a documentation-only push builds and tests no wheel either.

Two checks of the retired build stage are not made here: that every package's
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
| the release set, [`//release:release_set`](../release/release_set.bzl) built with the stamp (`-c komira.package_stamp`, `komira.package_commit`, `komira.package_timestamp_ms`) and the revision and run (`komira.release_revision`, `komira.release_run_id`, `komira.release_attempt`) | every package the artifacts file declares (`<lib>_conda[release]`), the metapackage `komira_all` over them (the packer's `conda-meta`, as an action of the farm), and `release.json` and `set_hash.txt`. One build action holds the set to the artifacts file (the library names, their order, the metapackage's arguments), and `release_json write` checks every package (a directory of exactly the manifest, the package and its metadata, no symlink; the manifest's name, platform, subdir and sha256; the metadata's agreement, size and `stamped`) before it writes `release.json` (format `kci.release_set` major 2, a name kept from the retired kci: the revision, the platform, `produced_by`, the members and the set hash, whose text is [`set_json.zig`](../release/ci/release_lib/set_json.zig)'s header). Built without a stamp (the pull request's check builds `//release:release_set` as part of `//ci:pr`), the same checks run over the unstamped packages, minus `stamped`, and no release directory is produced. |
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

kci, the build and deploy CLI the repository once had, was retired and removed: no workflow runs it.
The `kci_*` libraries are not release members: `release/artifacts.textproto` and the release set list none and their
source is deleted. Their names stay claimed on the prod registry (`release/prod_claimed_names.txt`).

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
passed) into `linux-64/komira-ai/<name>.mojoc`, and each declared native's
archive into `linux-64/komira-ai/<name>.native/lib<id>.a`: the layout mopm
reads, which requires the namespace directory. Seven jobs of `release.yml` carry the
steps (a documentation-only push does not start the workflow, so it publishes nothing):

| job | when | what it does |
|---|---|---|
| `mopm-stage` | every push to `main`, and a manual run (which sends nothing either) | on the farm (environment `build`, the farm's tailnet token only; it reads no registry token). **Build:** the one mopm the README e2e installs with (`toolchains//:mopm_0_0_113`, `MOPM` of `packages.bzl`) and `//release:mopm_artifacts`. **Version:** `release_beta_version --workspace-root src --version 0.1.<run number>` gives every member the version of this run (below, "The version of every release"). **Stage:** `mopm stage --workspace-root src --artifacts <built> --compiler 1.0.0 --out release/staged_set --registry prod` packs every member from its built `.mojoc`, asks the registry (a read, no token) which versions it holds and writes the staged set S (`plan.json`, each `.conda`, each README: mopm's `spec/staged-set.md`). A version the registry holds with other bytes, or has yanked, fails the step. **Try:** `./buck2 build -c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on the farm: every package's README examples are compiled and run as a user of the `.conda` files of S (see the e2e's [README](../tools/build/readme_e2e/README.md)). Then `mopm publish --staged S --registry prod --dry-run`: the plan is validated and every file hashed against it, nothing is sent and no token is read. It uploads S and that mopm as a workflow artifact (a day) for the next job. |
| `prod-stage` | after `release` and `mopm-stage`, **only on a push to `main`** (a manual run skips all six prod jobs before they start; there is no other switch) | in the environment `prod`, with `contents: read` and `id-token: write`, no farm and no secret. It downloads the set `mopm-stage` kept and runs `mopm publish --staged S --registry prod --oidc --no-commit`: the registry opens a group, holds every file in quarantine, and nothing is visible. It keeps the directory, now with `state.json` (the group), as the artifact `mopm-prod-staged-<sha>`, even when the step failed. |
| `prod-test` | after `prod-stage`, on a push to `main` | in the environment `build` (the farm's; `id-token: write` for the tailnet join only), with **no registry identity and no secret**. It downloads the directory `prod-stage` kept, checks every file against `plan.json` (`release_staged_verify verify`: sha256 and size), writes `release/staged_set` from the files that matched and from nothing else, and runs `-c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on the farm. |
| `prod-commit` | after `prod-test`, on a push to `main` | in the environment `prod`, with `contents: read` and `id-token: write`. The same command without `--no-commit`, on the same directory with its `state.json`, after a fresh OIDC exchange: the same group is committed and the job waits until it is visible. It keeps `plan.json`, `state.json` and `report.json` as `mopm-prod-committed-<sha>`. |
| `prod-abort` | after `prod-stage`, `prod-test` and `prod-commit`, when one of them failed or the run was cancelled, on a push to `main` and with a `prod-stage` that was not skipped | in the environment `prod`, same permissions: `mopm publish --staged S --registry prod --oidc --abort` ends the open group and gives its place back. |
| `prod-smoke` | after `prod-commit`, on a push to `main` | no environment, no identity, no secret, no farm: `release_staged_verify smoke` downloads the published files from the prod channel and compares each with the plan. On a difference it prints the `mopm yank --group <id> ...` command for a human and fails; it yanks nothing. |
| `prod-add` | after `prod-commit` and `prod-smoke`, on a push to `main` | no environment, no identity, no secret, no farm (a farm action has no network): `release_staged_verify add` makes a fresh project with the mopm `mopm-stage` built, runs `mopm add komira-ai/<name> --registry prod` for `json`, `uuid` and `libc` and then `mopm sync`, and checks the lock and the installed files against the plan. It yanks nothing. |

**Why `mopm stage` is a step of the job and not a build action.** It asks the
registry which versions exist, and an action is offline. So the farm takes the
set it wrote as an input: `//release/staged_set:set` is the files
of the directory `release/staged_set/` (`mopm stage --out` writes them there; they
are not in the repository, `.gitignore`), `//release/staged_set:taken` is that set
copied by one action, so the farm gets the files once and not once per target, and
[`//release/readme_e2e/verify`](../release/readme_e2e/verify/BUCK) installs from
the copy only under `-c komira_release.staged=stage`. Without that flag the targets
install from `//release/readme_e2e:staged`, the set the build assembles from the
packages it made (same layout, `skip` and `refuse` members aside): hermetic, so
the pull request check builds it, on every change, with no network. The release
job tries the real set; the pull request check tries the assembled one.

The cases of `mopm stage` and `mopm publish --staged` are mopm's. What this
repository holds to is the e2e's own cases
([`tools/build/readme_e2e`](../tools/build/readme_e2e/README.md)) and the
completeness of the list.

#### The prod publish

Five of the six `prod-*` jobs publish the set `mopm-stage` tried to the prod registry as one group (the sixth,
`prod-add`, installs from it after the commit), on every push to
`main` and with no switch, in three steps that the registry keeps apart: **stage** (upload, nothing visible), **test** (on the bytes the registry holds),
**commit** (visible all at once). `prod-stage` needs `release` and `mopm-stage`: the set it stages is the one
the README e2e of `mopm-stage` passed on, at the version of this run (below), so a release build or an e2e
that failed stops the run before anything is staged in prod. There is no beta stage in front of prod. `//:release_workflow_cases` holds the job graph, the gates, the
environments, the permissions, the commands and the order of the test's steps, and that no beta job and no schedule exists.

**A member must be claimed on prod first.** The registry creates a package name only for its claimed owner, so a
release member whose name is not claimed on the prod registry makes `prod-stage` refuse and turns `main` red. The
pull request check cannot write to the live registry (and does not read it), so the names claimed there are
committed in `release/prod_claimed_names.txt` (one per line, sorted), and `//release:prod_claimed_names_cases`
refuses a pull request in which a member (every `src/<name>` with a `mopm.toml`, `PACKAGES` of
`release/readme_e2e/packages.bzl`) is missing from it: "<name> is a member of the release and is not in
release/prod_claimed_names.txt: claim it on the prod registry first, then add it to release/prod_claimed_names.txt".
A maintainer adds a name to the file only after claiming it on the prod registry, in the pull request that adds the
member. The file keeps the names of deleted packages (the `kci_*` libraries), whose names stay claimed, and refuses the
dropping of one of them, an unsorted or repeated line, and an empty file. It is a
committed claim, not a live read: it does not notice a claim the registry lost, and `prod-stage` stays the
last word.

**The release declaration and the release set agree, and one so package.** `//release:release_checks_cases`
holds `release/artifacts.textproto` to `tools/build/package/release_set.txt`: the same metapackage, the same
members in the same order, and the same `--license`, `--summary` and `--home`, so a member listed in one file and
missing from the other is refused, naming it. It also refuses a release that names both `so_conda` and
`komira_so_libkomira_conda`: they are one package name, version and build with different contents, so a channel
would be handed two files for one name.

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
   exactly `https://conda.mopm.dev/`), downloads `<channel_url><namespace>/<subdir>/<filename>` (each
   namespace, `komira-ai` here, is its own channel) for every file of the plan (https, no redirect
   followed) and compares each file's sha256 and size with the plan, trying up to five times 30 seconds
   apart because the channel's cache can lag a commit by a minute. On failure it prints the exact
   `mopm yank --group <id> --registry prod --reason ...` for the group in `state.json`; a person decides
   whether to run it.
6. **`prod-add`** runs after the smoke, so the channel already serves every file. `release_staged_verify add`
   ([source](../tools/build/ci/release_beta_fetch/prod_add.zig)) does what a user does, with the mopm that
   staged and committed the set (`toolchains//:mopm_0_0_113`), in a directory it makes on the runner (both
   paths absolute):
   `mopm init --name release-check/prod_add`, then `mopm add komira-ai/<name> --registry prod` for three
   packages of [`packages.bzl`](../release/readme_e2e/packages.bzl), a library with no dependency (`json`),
   one with dependencies (`uuid`: `atomic_alias`, `awslc`, `clock`) and one that ships a native library
   (`libc`), then `mopm sync --registry prod --cache <its own directory>`. A command that exits other than 0
   fails the job with that command and the first line of its stderr. Then it reads `mopm.lock` and refuses,
   listing every difference: a `lock_version` other than 3, a `channels` other than exactly
   `https://conda.mopm.dev/`, an entry with a flat name, with a channel other than its namespace's
   (`https://conda.mopm.dev/komira-ai/`), that is not a member of the plan or is at another version than
   this run's, an artifact whose URL, sha256 or size is not the plan's file, and an added package the lock
   does not hold. For each locked file of the runner's subdir it checks what `sync` installed: the file
   kept in `.mopm/pkgs` has the plan's sha256 and size, the environment's `conda-meta` record names that
   sha256, and the package's `lib/mojo/<name>.mopm.json` is there. It yanks nothing; a failure says what a
   user would get, and a person decides what to do. Its cases (`//tools/build/ci:release_staged_verify_unit`)
   run a registry and a mopm in memory.

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
are the plan's. A user's `mopm add komira-ai/<name> --registry prod` and `mopm sync` on a clean runner lock
the full names under the namespace's channel at this run's version and install exactly those bytes.

**What it does not prove.**
- The registry's own verdict: a group can still end `rejected` after the tests passed (the commit job
  fails and the group frees its versions); the tests do not read what the registry stored.
- The registry's derived outputs (repodata, the sparse index) are read only for the three packages
  `prod-add` adds and their dependencies; the other members are checked as files by `prod-smoke`, not
  resolved from the index.
- A package's own unit tests are not in the `.conda`: they ran when its `.mojoc` was built.
- Native libraries are loaded as the packages say: `prod-add` installs `libc` and its static library from
  the registry, but no job builds or runs a program against what it installed.
- A plan member that is not an `upload` (a version the registry already holds) makes the README e2e and
  `release_staged_verify` refuse the set; a release publishes only a set of new versions, which is why every
  run gives the members the version `0.1.<run number>` (below).

**Needs a mopm with `--no-commit` and `--abort`.** The jobs run the mopm that `mopm-stage` built: the pin
`MOPM` in [`packages.bzl`](../release/readme_e2e/packages.bzl) (`toolchains//:mopm_0_0_113` in the
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
- in `[dependencies]` and `[dev-dependencies]`, keyed by the member's full name as mopm writes it
  (`"komira-ai/json"`) or by a bare or quoted bare name, a requirement on another member with an exact
  comparator `=X.Y.Z` (a string, an inline table's `version`, or `[dependencies."<name>"]`'s `version`)
  gets the new number, because `mopm stage` checks each requirement against the member's version.
  Every other comparator (`^0.1`, `>=0.1, <0.2`, `~0.1.0`, `0.1`, `*`, `=0.1`) accepts every `0.1.x`
  and is kept; `mopm stage` itself refuses a range that does not accept the new version.

It writes nothing and fails when the version is not `0.1.<PATCH>` (digits, no leading zeros, no
suffix), a member's version is not in `0.1.x`, two members share a name, a requirement on a member is
not comparators it can read or pins a number the member does not have, a dependency key is neither a
bare name nor a quoted bare or `"<namespace>/<name>"` name (mopm's grammar), or a manifest holds a
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

### The user test of the wheel

Every run of `release.yml`, so every push to `main` that changes more than documentation, builds the Python
wheel that `pypi.yml` publishes and installs it as a user does, on a machine that has never seen the
repository. A merge that breaks `pip install komira` or the quickstart turns that run red, and so `main`
([main_red.yml](#main_redyml-the-main-red-alert) opens its issue when the run ends), instead of the next
daily publish finding it. Nothing is uploaded to any index: the upload stays in `pypi.yml`, once a day
([below](#the-daily-run)). Two jobs:

| job | environment | permissions | what it does |
|---|---|---|---|
| `wheel` | `build` | `contents: read`, `id-token: write` (the tailnet only) | on the farm (`farm-qos: batch`): takes the stamp (`release_json stamp`) and builds `//python:komira_wheel[release]`, `//python:wheel_install_test` and `//python/smoke:pypi_smoke` with the three stamp flags, as `pypi.yml`'s `build` does (`//:release_workflow_cases` holds the wheel's build line, target and stamp flags, to be the same text as `pypi.yml`'s, and the stamp to be the run's commit in both), so the same commit gives the same bytes; runs `pypi_smoke dist`; copies the quickstart, its expected output, its data and the ABI table beside the driver; runs `pypi_smoke matrix` on [`python/supported_pythons.tsv`](../python/supported_pythons.tsv), whose result is the job's output `matrix`. Keeps `wheel-<sha>-dist` (the wheel alone) and `wheel-<sha>-smoke` (the driver and those four files) for 7 days. |
| `wheel-user-test` | none | none | one job per row of the list for `linux-x86_64` (today CPython 3.13), each on a fresh GitHub-hosted runner (`ubuntu-24.04`) with no checkout: downloads the two artifacts, sets up the row's Python with `actions/setup-python`, and runs `pypi_smoke install --index dist` (below). `fail-fast: false`, so every Python finishes and each failure is its own job. |

**What it runs.** `pypi_smoke install --index dist` is the install of the index smoke with the dist directory
in place of the index: an empty virtual environment of the runner's Python; the wheel's requirements, if it
has any, from PyPI; then `komira==<version>` with `--no-deps --no-index --find-links <dist>`, so pip reads no
index for `komira` and installs the one wheel of the directory; `pip check`, `pip show` and `pip freeze` hold
the environment to `komira` at the built version and nothing else; no `modular` package is importable; and
the quickstart, the program the README and the install page show (held byte for byte by
`//python/smoke:readme_shows_quickstart` and `//python/smoke:install_page_shows_quickstart`), runs and must
print exactly what `python/examples/quickstart.expected` says. Today that is import, the version, the
engine's ABI version and a Parquet file registered in a session. When the quickstart grows (a query, say),
this job runs the new program with no change here. A local directory does not lag, so the install is tried
once (`--attempts` and `--delay` are refused with `--index dist`).

**The list.** `python/supported_pythons.tsv` holds one row per Python and platform, `<platform><TAB><python>`.
Adding a Python is adding its row: both `release.yml` and `pypi.yml` read the list through `pypi_smoke matrix`
and get one more job. A platform a row may name is one whose wheel a workflow builds on every merge
(`platforms` in `python/smoke/src/matrix.zig`: `linux-x86_64` today, on `ubuntu-24.04`); a row naming another,
a Python that is not `3.<minor>`, or a row given twice fails the `matrix` step naming the line, and
`//python/smoke:supported_pythons_list` makes the same check on the real list in the pull request's check.
The macOS arm64 wheel is not in it: its builds are kept out of `release.yml` (`//:release_macos_cases`), its
install test runs on the farm's Macs, and its first install as a user's is the macOS TestPyPI smoke of
`pypi.yml`. A per-merge user test of it belongs with the macOS release build in `release-macos.yml`.

**Order.** Neither job needs a job of the release, and no job needs either or reads their result: the release
set and the mopm packages hold no wheel, so a red user test makes the run red without holding back
`release`, `mopm-stage` or the prod publish, and those never hold it back. A failed step is shown in the run
as the job `wheel-user-test (<platform>, <python>, <runner>)` with the step's name and the driver's
`::error` line, which names the command that failed, its exit status and its stderr. `//:release_workflow_cases`
holds the contract and plays the job graph from the file: a failed user test, or a failed wheel build, ends
the run red and every other job still runs.

**How `pypi.yml` knows.** It does not read this run: a daily run builds `main` as it is then, which may be a
commit this workflow never ran on (a documentation-only push, or a run replaced while it waited). Instead
`pypi.yml` runs the same job, `wheel-user-test`, on the bytes it built and will upload, and `testpypi` needs
it: a wheel that failed it is never uploaded ([below](#pypiyml-publishing-the-python-package)).

## pypi.yml: publishing the Python package

[`.github/workflows/pypi.yml`](../.github/workflows/pypi.yml) builds the `komira` wheel
([python/README.md](../python/README.md)), installs the wheel file on a fresh runner for every Python of the
list ([the user test](#the-user-test-of-the-wheel), as `release.yml` does on every merge), uploads it to
TestPyPI, installs it from there on a fresh runner and runs the quickstart, and only then does the same on
PyPI. The macOS arm64 wheel of the same name
and version is published by six more jobs of the same file, a chain of their own (below), on every run; both wheels carry the Mojo runtime libraries and require no other distribution. It is written by hand. It runs once a day on `main`
(`schedule`, one cron entry, `17 5 * * *`: 05:17 UTC) and when started by hand (`workflow_dispatch`, which takes no
input), and on nothing else; every job has `if: github.ref == 'refs/heads/main'`. A pull request never starts it.

| job | environment | permissions | what it does |
|---|---|---|---|
| `build` | `build` | `contents: read`, `id-token: write` (the tailnet only) | on the farm ([farm-connect](#how-it-reaches-the-farm), `farm-qos: batch`): builds `//release/ci:release_json` and takes the stamp (`release_json stamp`); builds the wheel and its install test (`//python:komira_wheel[release]` and `//python:wheel_install_test`) with the three stamp flags (`-c komira.package_stamp`, `komira.package_commit`, `komira.package_timestamp_ms`) and `//python/smoke:pypi_smoke`; runs `pypi_smoke dist`, which makes the dist directory; copies the quickstart, its expected output, its data and the ABI table beside the driver; runs `pypi_smoke matrix` on `python/supported_pythons.tsv` (the output `matrix`). It keeps two workflow artifacts, `pypi-<version>-dist` (the wheel) and `pypi-<version>-smoke` (the driver and those four files), for 14 days. It has no upload step and holds no index identity. |
| `wheel-user-test` | none | none | [the user test of the wheel](#the-user-test-of-the-wheel), the same job as `release.yml`'s, on this run's dist: one job per Python of the list, on a fresh runner with no checkout, `pypi_smoke install --index dist`. |
| `testpypi` | `testpypi` | `id-token: write` | after `wheel-user-test`; no farm, no checkout, no buck2. Downloads the two artifacts, runs `pypi_smoke state --index testpypi`, and uploads the wheel to TestPyPI only when the state is `absent`. |
| `testpypi-smoke` | none | `contents: read` | `pypi_smoke verify --index testpypi`, then `pypi_smoke install --index testpypi`, on a runner with the Python `actions/setup-python` gives (3.13). Skipped when the state is `differs`. |
| `pypi` | `pypi` | `id-token: write` | after `testpypi-smoke`: the same as `testpypi` for PyPI. |
| `pypi-smoke` | none | `contents: read` | the same as `testpypi-smoke` for PyPI. Skipped when the state is `differs`. |
| `result` | none | none | fails the run, naming the job, when `build`, `wheel-user-test`, `testpypi`, `testpypi-smoke`, `pypi` or `pypi-smoke` did not succeed, and prints a notice when the bytes differ at the same version (below). Its last step prints the notice `already published: komira <version> is on TestPyPI and PyPI with the bytes built; nothing was uploaded, and the smoke passed on both` when both indexes said `same`; being last, it prints only when no step above it failed. |
| `build-macos-arm64` | `build` | `contents: read`, `id-token: write` (the tailnet only) | on every run (`if: github.ref == 'refs/heads/main'`), on an ubuntu runner that only asks the farm, whose Macs are the workers (`farm-connect` with the macOS worker set and hosts, `farm-qos: batch`): takes the stamp, builds the Linux driver, builds `//python:komira_wheel_macos_arm64[file_name]` (the wheel's file name, written at analysis) and asks both indexes whether each lists that file (`pypi_smoke present`). Only if one does not, it builds `//python:komira_wheel_macos_arm64[release]`, `//python:wheel_install_test_macos_arm64` and `//python/smoke:pypi_smoke_macos_arm64` for `--target-platforms komira//tools/build/platforms:darwin-arm64`, runs `pypi_smoke dist`, and keeps `pypi-<version>-macos-arm64-dist` (the macOS wheel alone) and `pypi-<version>-macos-arm64-smoke` (the Linux driver and the macOS driver). Its output `version` is empty when nothing was built. No upload step. |
| `testpypi-macos-arm64` | `testpypi` | `id-token: write` | `needs` the macOS build and runs only when it built a wheel. The same as `testpypi`, on the macOS dist, with the Linux driver. |
| `testpypi-smoke-macos-arm64` | none | `contents: read` | on the hosted runner `macos-15` (Apple silicon): `verify`, then `install` with the macOS driver on CPython 3.13. Skipped when the state is `differs`. |
| `pypi-macos-arm64` | `pypi` | `id-token: write` | after `testpypi-smoke-macos-arm64`: the same as `pypi`, for the macOS dist. |
| `pypi-smoke-macos-arm64` | none | `contents: read` | the same as `testpypi-smoke-macos-arm64` for PyPI. Skipped when the state is `differs`. |
| `result-macos-arm64` | none | none | the macOS chain's verdict: fails the run when `build-macos-arm64` did not succeed, and, when it built a wheel, when an upload or a smoke of the macOS chain did not succeed; a notice when the bytes differ at the same version, and a notice that this version's macOS wheel is on both indexes already when the build found it and built nothing. |

**Why its own file.** PyPI's trusted publishing binds a publisher to a workflow file name and an
environment. `release.yml` holds no publishing credential, and this file is the one that does, so the
credential is reachable from this file only. A job's index identity is the OIDC token of its environment:
only `testpypi`, `pypi`, `testpypi-macos-arm64` and `pypi-macos-arm64` hold a token an index trusts, and only for
their own index. `build` and `build-macos-arm64` name the environment `build`, which no index trusts, and have no
upload step. `//:pypi_workflow_cases` pins the triggers (exactly one `schedule:` of one cron entry at a fixed
minute and hour of every day, then `workflow_dispatch` with no input), that no line reads a run input, the
thirteen jobs, each job's `if:`, runner, `needs`, environment and
permissions (the two macOS smoke jobs run on `macos-15`, `wheel-user-test` on its matrix entry's runner, every other
job on `ubuntu-24.04`), that `id-token` is on no
other job, that `farm-connect` and buck2 are in the two build jobs alone, that the publish action appears only in
the four upload jobs (`testpypi`, `pypi` and their macOS twins), that `setup-python` appears only in the four smoke jobs
and `wheel-user-test`,
that every action is pinned to a commit, and that no secret, `curl`, `jq`, `twine` or `continue-on-error`
is anywhere in the file. Its file `pypi_workflow_run.zig` plays a run from the workflow's text for each answer of
the indexes and each failed job ([below](#the-daily-run)). `//:release_macos_cases` pins the macOS chain beyond that (below). `//:farm_connect_cases`
holds `build` and `build-macos-arm64` to `farm-qos: batch`.

**The macOS wheel's chain is independent of the Linux one.** No Linux job `needs` a macOS job or reads its
result, no macOS job `needs` a Linux job or reads its result, and no Linux job names macOS: a red macOS chain
never holds the Linux release, and a red Linux chain never holds the macOS wheel. Both chains build the same
commit, so they carry the same stamp and the same version (`0.1.<N>`); the Linux file is
`komira-0.1.<N>-py3-none-manylinux_2_35_x86_64.whl` and the macOS file
`komira-0.1.<N>-py3-none-macosx_11_0_arm64.whl` (the platform `darwin-arm64`, whose floor is macOS 11.0), two files
of one release. The macOS chain has its own artifacts (`pypi-<version>-macos-arm64-dist` and
`...-macos-arm64-smoke`), so the two dist directories never mix and each upload sends one wheel. A Mac
build is the scarce resource, so it is asked for only when needed: `build-macos-arm64` builds the file name first
(no compile) and runs `pypi_smoke present` against TestPyPI and PyPI, and every Mac build after those two
steps, and every step after them but the one that stops buck2, carries
`if: steps.testpypi_file.outputs.present != 'true' || steps.pypi_file.outputs.present != 'true'`. A daily run with no
new code finds the file on both indexes and builds nothing on the Macs. `//:release_macos_cases` holds
the order (the file name, the two `present` steps, then the Mac builds), the exact gate on each Mac build, that the
file-name build alone is ungated, that `build-macos-arm64` runs on the ubuntu runner (a hosted macOS runner is
refused there) with the macOS worker set, hosts and the `tls` literal, and that the macOS smoke jobs run the macOS driver.

**One run at a time.** The workflow is in the concurrency group `pypi` with `cancel-in-progress: false`: a
running publish is never cancelled, and a second run waits. GitHub keeps one waiting run per group: a third
run (a manual one, or the next day's) replaces the one that waits, which is safe because each run publishes
the commit `main` is at when it starts.

### The daily run

**Cadence.** Once a day, at 05:17 UTC (the cron entry `17 5 * * *`; off the hour, when GitHub's scheduled
runs queue least). An index takes a file name once, ever, and a PyPI project holds at most 10 GB, so the
workflow publishes at most one version a day, and a day that changed no code publishes nothing: the version
is `0.1.<N>` with `<N>` the stamp's build number, which moves only with a commit that changes code. So each
run ends in one of three ways, and `pypi_workflow_run.zig` (in `//:pypi_workflow_cases`) plays each from the
workflow's text and holds what the run prints and that it is green:

| what landed on `main` since the last run | the indexes say | the run |
|---|---|---|
| nothing (or a commit the stamp ignores and that leaves the wheel's bytes alone) | `same` on both | nothing uploaded, both smokes run; green with the notice `already published: komira <version> is on TestPyPI and PyPI with the bytes built; nothing was uploaded, and the smoke passed on both` |
| a documentation-only commit that changes the wheel's description (`python/README.md`) | `differs` | the user test of the wheel file runs and passes; nothing uploaded, no index smoke; green with the notice `bytes differ at the same version: ...` ([below](#the-version-and-documentation-only-commits)) |
| a commit that changes code | `absent` on both | the user test passes, then uploaded to TestPyPI, smoked, then to PyPI, smoked; green |
| any of these, with a wheel that fails its user test | not asked | nothing uploaded, no index is asked; red, naming `wheel-user-test` |

The macOS chain asks for its own file by name (`pypi_smoke present`) and, on a day with no code commit, finds
it on both indexes and builds nothing on the Macs. A failed job ends the run red and names the job, as for a
manual run; the play holds that too (a failed build, upload or smoke on either chain, and a run after one that
stopped between the TestPyPI and the PyPI upload, which uploads to PyPI alone and prints no `already published`).

**What a day costs.** The first release (komira 0.1.1512, a manual run) took 60 minutes from start to the
verdict, 56 of them in `build` (a farm build at `farm-qos: batch`, which queues behind pull-request checks),
and the jobs after it took under 4 minutes together (measured from the run's job times). A day with no code
commit builds the same targets from the same stamp, so its farm work is cache hits; this is inferred, not yet
measured on a scheduled run. Every job is far inside its `timeout-minutes` (120 for the builds) and GitHub's
6-hour job limit. While the macOS wheel's build fails (komira-ai/komira#2002), its file is never on an index,
so each daily run tries the Mac build again and ends red on the macOS chain; the Linux chain publishes and is
green on its own.

**Stopping it.** Either disable the workflow (Actions > pypi > the `...` menu > Disable workflow; enable it
again the same way), which stops the daily and the manual runs without a commit, or delete the `schedule:`
entry in a pull request, which leaves the manual run (`//:pypi_workflow_cases` then needs the same edit:
it holds exactly one schedule). GitHub also disables a scheduled workflow of a public repository after 60 days
with no activity in the repository; enabling it again is the same click. Required reviewers on the
environment `pypi` (owner step 1 below) hold a scheduled run before its PyPI upload until someone approves it,
which turns the daily release back into a watched one.

**The driver.** Every step that does more than start a program is
`//python/smoke:pypi_smoke`, a Zig program built by `build` and carried to the later
jobs as an artifact, so no workflow step holds shell logic. It takes flags only. `--index` is `testpypi`
(TestPyPI) or `pypi` (PyPI), and for `install` also `dist` (the dist directory itself, with no index); any other
value is a usage error. The exit status is 0 for success, 1 for a
refusal or a failure (the last line printed is `pypi_smoke: FAILED: <why>`, and an `::error` line for the
log) and 2 for a usage error.

| subcommand | flags | what it does |
|---|---|---|
| `dist` | `--wheel <file.whl> --out <dir> --github-output <file>` | reads the wheel: exactly one `*.dist-info` directory holding `METADATA` and `WHEEL`, one `Name` and one `Version` in `METADATA`, one `Tag` in `WHEEL`. The file name is `<name>-<version>-<tag>.whl` with the name normalized (each run of `-`, `_` or `.` becomes `_`, lowercase), and the dist-info directory must agree. Writes the same bytes under that name into `--out` (which must not exist or be empty) and appends `version`, `filename` and `sha256` to the GitHub output file. |
| `state` | `--index <testpypi\|pypi> --dist <dir> --github-output <file>` | `--dist` holds exactly one wheel and nothing else. One request for the version's JSON on the index, no retry. Appends `state=absent`, `same` or `differs` (below). Any other answer than a 404 or a 200 with the expected shape fails. |
| `present` | `--index <testpypi\|pypi> --name-file <file> --github-output <file>` | reads the one-line file name (`komira-<version>-<tag>.whl`) from `--name-file`, asks the index's JSON for that release (as `state` does) and appends `present=true` (the release lists a file of exactly that name) or `present=false` (no such release, or the release without that file) to the GitHub output file. It needs no wheel, so it runs before anything is built. An index error (HTTP 5xx, transport, a body that is not JSON) is a refusal and appends nothing. |
| `verify` | `--index <testpypi\|pypi> --dist <dir> [--attempts <1..20>] [--delay <0..300>]` | asks the index for the file it serves and compares it with the built one (below). A refused attempt is tried again up to `--attempts` times (default 5), `--delay` seconds apart (default 30), because an index can lag an upload. |
| `install` | `--index <testpypi\|pypi\|dist> --dist <dir> --python <exe> --example <quickstart.py> --expect <quickstart.expected> --data <file>... --abi-table <komira.tsv> --work <dir> [--attempts <n>] [--delay <s>]` | installs the published wheel into an empty environment and runs the example (below); with `--index dist`, the wheel of `--dist` itself (`--no-index --find-links <dist>`, [the user test](#the-user-test-of-the-wheel)). `--attempts` and `--delay` as for `verify`, for the install of `komira` only; refused with `--index dist`, which installs once. |
| `matrix` | `--supported <list> --platform <name> --github-output <file>` | reads the list of supported Pythons ([the user test](#the-user-test-of-the-wheel)) and appends `matrix=<JSON>`, the `include` list of a job matrix with the platform, the Python and the hosted runner of every row of `--platform`. A malformed list, or one with no row for the platform, is a refusal and appends nothing. |

**The three index states.** `state` asks the index about the one file of the build, `komira-0.1.<N>-py3-none-manylinux_2_35_x86_64.whl`
(`<N>` is the stamp's build number), or `komira-0.1.<N>-py3-none-macosx_11_0_arm64.whl` in the macOS chain:

- `absent`: the index has no such file (the version may exist with another file, another platform's wheel).
  The job uploads it, by trusted publishing, with the publish action's defaults
  (`skip-existing` off, attestations on). `testpypi` sets the action's `repository-url` to TestPyPI's upload
  endpoint; `pypi` sets none, the action's default being PyPI.
- `same`: the index has the file with the same sha256. Nothing is uploaded and the smoke runs: a run that was
  cut short after the upload finishes the checks. When both indexes say `same` and both smokes pass, `result`
  ends the run green with the notice `already published` (the run of a day with no code commit).
- `differs`: the index has the file with another sha256. Nothing is uploaded and the smoke does not run; the
  run ends green with a notice ([below](#the-version-and-documentation-only-commits)).

**What the smoke proves.** Two checks per index, on a runner that is not the farm, after the upload:

1. `verify`: the file the index serves is the file that was built. The index's JSON for the version names the
   file with its sha256, its size and its URL. The sha256 and size must be the built wheel's, the URL must
   be on the index's file host (`test-files.pythonhosted.org` or `files.pythonhosted.org`), and the bytes
   that URL serves are downloaded and hashed again, so a wheel changed after the index recorded it fails.
   Then the `METADATA` of the served bytes and of the built wheel are compared on `Name`, `Version`,
   `Requires-Python` and the full ordered list of `Requires-Dist`, and `Name` and `Version` must agree with
   the file name. Every difference of an attempt is listed, not only the first.
2. `install`: a user's install works. `actions/setup-python` gives CPython 3.13 and `pypi_smoke` makes an empty
   virtual environment with it. For TestPyPI, the wheel's `Requires-Dist` requirements are installed first from
   the real PyPI (`--only-binary=:all:`), then `komira==<version>` with `--no-deps` from TestPyPI alone, so
   nothing but `komira` comes from TestPyPI. For PyPI, `komira==<version>` is one install from PyPI. Every pip
   runs `--isolated`, without a cache. Then `pip check` must pass, `pip show komira` must report the version,
   `pip freeze` must list `komira==<version>` and nothing else (the wheel carries the Mojo runtime, so no
   `mojo-compiler` and no other distribution is installed), no package named `modular` may be importable, and
   the quickstart runs with `python -I` in a directory holding only the example and its data file: it
   must exit 0 and print what `python/examples/quickstart.expected` says, compared exactly, with `<version>`
   replaced by the version and `<abi_version>` by the ABI version of the `--abi-table` file
   (`src/so/abi/komira.tsv`: `major * 1000 + minor`, so `1.1` is 1001). A failed step names the command, its exit
   status and the last lines of its stderr.

The user test of the wheel file is the first gate: `testpypi` `needs` `wheel-user-test`, so a wheel that does
not install and run from its own file is uploaded nowhere. The smoke of TestPyPI is the release gate: the
`pypi` job `needs` `testpypi-smoke`, so a wheel that does not install and run from TestPyPI is never uploaded
to PyPI.

The quickstart is [`python/examples/quickstart.py`](../python/examples/README.md). Today it asserts the
version, the engine's C ABI version, and that a `Session` registers `readings.parquet` and closes. It
asserts no query result: the call that runs a query has not landed. The README's block under "What works"
is the same text, held byte for byte by `//python/smoke:readme_shows_quickstart`. The install page,
[docs/install.md](install.md), shows the same program and what it prints, `quickstart.expected` with the
newest release of [python/CHANGELOG.md](../python/CHANGELOG.md) and the ABI version put in, held by
`//python/smoke:install_page_shows_quickstart`.

**What the macOS smokes prove.** The same two checks, `verify` and `install`, on the macOS wheel: on the
GitHub-hosted runner `macos-15` (Apple silicon, free for public repositories) with CPython 3.13 from
`actions/setup-python`, the macOS driver (`//python/smoke:pypi_smoke_macos_arm64`, cross-compiled on the farm for
`aarch64-macos`) checks that the index serves the bytes that were built and that `pip install komira==<version>` into an
empty environment gives a package that imports, reports the version and the ABI version, and runs the quickstart.
The wheel is self-contained: `komira/_lib/libkomira.dylib` and, in `komira/_lib/lib/`, the three Mojo runtime
libraries (`libAsyncRTRuntimeGlobals.dylib`, `libKGENCompilerRTShared.dylib`, `libMSupportGlobals.dylib`); it depends on
no package of Modular's.

**What ran where.** The build, the stamp and the wheel's own install test
(`//python:wheel_install_test`, which installs the wheel into an empty environment and loads `libkomira`) run on the
farm, in `build`, before any upload, on the same bytes that are uploaded. The macOS wheel's build and its install test
(`//python:wheel_install_test_macos_arm64`) run on the farm's Macs, in `build-macos-arm64`. The user test of the wheel
file, `state`, the upload, `verify` and `install` run on GitHub-hosted runners, in the later jobs. The index checks and the install from an index
run on a runner only, because a farm action has no network.

**What it does not prove.** It does not run a query (none exists yet). It tests two wheels, linux x86_64 and macOS
arm64, one CPython (3.13) and one install route (`pip`), and the macOS wheel only on the macOS version of the hosted
runner, not on the oldest macOS it claims (11.0). Wheels for arm64 Linux and for other platforms come later,
each with its own smoke. A change to the driver is tested by `//python/smoke:pypi_smoke`'s cases, which
use a fake index and a fake runner and make no network request; the live indexes are reached only by a run
of this workflow.

### Owner steps before the first run

These are done once, in GitHub and on the indexes, outside this repository:

1. In the repository's Settings > Environments, create `testpypi` and `pypi`, each restricted to the
   branch `main` (deployment branches: selected branches, `main` only). Required reviewers on `pypi` are
   optional: they hold the run before the PyPI upload. The environment `build` already exists.
2. On test.pypi.org and on pypi.org, add a pending trusted publisher (Your account > Publishing): project
   `komira`, owner `komira-ai`, repository `komira`, workflow `pypi.yml`, environment `testpypi` on
   TestPyPI and `pypi` on PyPI.
3. Run the workflow on `main` (Actions > pypi > Run workflow). The first run creates the project on each
   index.

### Yanking a bad release

A release is never deleted, by the workflow or by hand: an index does not let a file name be uploaded again,
even after its file is deleted, so a deleted release leaves a version that can never be fixed in place. A bad
release is yanked by the PyPI project's owner: in the project's release settings on pypi.org, on the version,
Yank, with a reason. A yanked version stays installable by `==` and is skipped by a plain
`pip install komira`. The next version is the next run on a commit that changes code. Yanking does not
remove the file, so the daily run on an unchanged `main` still finds it (`same`) and uploads nothing; to stop
releases while a fix is made, disable the workflow ([above](#the-daily-run)).

### The version and documentation-only commits

The version is `0.1.<N>`, with `<N>` from `release_json stamp`, which does not count commits that touch only
documentation (`docs`, `*.md`, `.github`). A change to `python/README.md`, which is the package's description and
so is in the wheel's `METADATA`, therefore builds a wheel with the same version and different bytes. When the
index already holds the version's file, `state` says `differs` on it: nothing is uploaded, the index smoke does
not run (the user test of the wheel file ran before the state was asked, on the new bytes), and the run is green
with a notice that says the version's bytes differ. The fix reaches the index with
the next commit that changes code, which has the next version.

## pr.yml: the pull request's check

[`.github/workflows/pr.yml`](../.github/workflows/pr.yml) is workflow `pr` with
one job `check`, so the status check is **`pr / check`** (GitHub lists the
context as `check`; the repository's ruleset requires that context, and only
pr.yml has a job of that id). It runs named Buck2 targets on the farm and does
not run kci (retired).

| | |
|---|---|
| trigger | `pull_request` into `main` and `merge_group` (`checks_requested`, into `main`) alone: no push, manual run, `pull_request_target`, `workflow_run` or any other event |
| concurrency | one group per pull request, `pr-<number>`, where a newer push cancels the older check; a merge group has no number and takes its ref (`refs/heads/gh-readonly-queue/main/…`), which is its own, so merge groups never cancel each other |
| job | the one job `check`, for every merge group and for a pull request only from a branch of this repository (`github.event_name == 'merge_group' \|\| github.event.pull_request.head.repo.full_name == github.repository`; a fork's run gets no tailnet credential, and a maintainer reads the change and pushes it to a branch here; a merge group's event has no `pull_request`, and without its own term the job would be skipped there, which counts as passed), written bare or as exactly `${{ <condition> }}` (a block scalar or whitespace inside quotes makes GitHub read the `if:` as a format string, which is always true) |
| runner | `runs-on: ubuntu-24.04`, written as that plain scalar: a GitHub-hosted machine, fresh per job. A self-hosted label, label list, runner group, expression (`${{ vars.X }}`) or quoted value is refused, so a pull request's code never reaches a runner that keeps state between jobs |
| permissions | its own `permissions:` mapping, `contents: read` and `id-token: write` (for the farm connection, [farm-connect](#how-it-reaches-the-farm), only); no environment, no secret (no value of the job, nor of the workflow-level `env:`, names `secrets` other than `secrets.GITHUB_TOKEN`), no publish step |
| steps | the pinned full-history checkout of the merge commit (a merge group: its head commit), `farm-connect`, and the farm assertion (`//tools/build/ci:assert_remote`). Then the change, written by `//tools/build/ci:change` (built on the farm like the assertion, run on the runner in the checkout, with the event, the merge group's `base_sha` and the output directory as flags; `tools/build/ci/change/change.zig` says what it runs and refuses, and its cases run its choice of base against a fake git): `git diff --name-only <base>...HEAD` and the coverage holds of both sides. A pull request's base is HEAD^1, the merge commit's first parent (the `main` the pull request is merged into; the step stops when HEAD has no second parent). Never the event's `github.event.pull_request.base.sha`: that is `main` when the event fired, and once `main` moves every change merged to it since then would count as the pull request's own and widen the check. A merge group's base is its `merge_group.base_sha`, the commit the group's head was built on (the step stops when it is not an ancestor of HEAD); the head is a squash commit on top of it, not a merge commit. Any other event stops the step. Then, each as the `buck2-farm` action (so each fails unless no action ran on the runner): the BXL selector `tools/build/ci/affected.bxl:affected` (the owners of the changed files and everything that depends on them, or `//ci:pr`, the whole check set, when a file cannot be mapped or touches the build system; the heavy checks of `HEAVY` in `tools/build/ci/rules.bzl`, today none since only `komira_base` reaches them, only when the change touches paths that row owns, so a change that owns none builds `//ci:pr_default` in place of `//ci:pr`), `build --keep-going` of its list, the checks only BXL can make over the whole graph (`test_weld.bxl:check` for each test_weld lint, `graph/checks.bxl:check` for each graph_check, `guard.bxl:check` that `//ci:pr` holds every check target, `python_guard.bxl:check` that it reaches no Python outside the SDK, `default_guard.bxl:check` that `//ci:pr_default` is `//ci:pr` without the roots of `HEAVY` and nothing else, `lock_graphs.bxl:check` that each package's `buildrules.mojo.lock.bzl` holds a unit graph for every platform subdir its `mopm.lock` records and that a package which loads a native shared library pins it in `system_libs` of that lock, `cases.bxl:run`, and `readme_e2e/cases.bxl:run`, the cases of the README e2e's completeness guard), and `test` of the list's targets that are not of the tests cell. A pull request that adds or deletes a package needs no edit to any release file; adding a target to the check set means regenerating `ci/targets.bzl` and its shards `ci/targets/shard_<n>.bzl` in one step (the guard fails, naming the command, when they are out of date or a shard nears the 1000-line limit). Nothing ships. |
| every `uses:` | pinned to a full commit id (the local farm-connect action excepted) |

The repository's branch settings require the check **`pr / check`**.
`//:pr_workflow_cases` (`.github/workflows/pr_workflow_test.zig`) holds the
trigger, the job's condition, the concurrency group, that the change step runs
the change tool with the event and the group base, and the job's bound below the
queue's check timeout, and that no other workflow has a job `check`.

## The merge queue

`main` takes a pull request only through GitHub's merge queue. A pull request
whose review passed and whose `pr / check` is green is added to the queue; the
queue makes a branch `gh-readonly-queue/main/pr-<n>-<sha>` holding `main`, the
pull requests ahead of it and its own squash commit, runs `pr / check` there
(event `merge_group`), and moves `main` to that commit when the check is green.
A pull request is no longer brought up to date with `main` and checked again
every time `main` moves: it is checked once more, on top of exactly what will be
ahead of it, and `main` moves only to commits a check built.

The queue is a rule of the repository's ruleset for `main`:

```json
{
  "type": "merge_queue",
  "parameters": {
    "merge_method": "SQUASH",
    "grouping_strategy": "ALLGREEN",
    "max_entries_to_build": 5,
    "min_entries_to_merge": 1,
    "max_entries_to_merge": 5,
    "min_entries_to_merge_wait_minutes": 5,
    "check_response_timeout_minutes": 360
  }
}
```

and the repository's squash message settings are `squash_merge_commit_title:
PR_TITLE` and `squash_merge_commit_message: BLANK`. Why each:

- **Squash, as before.** `main` gets one commit per pull request.
- **The message is the title alone.** The queue writes the squash message from
  the repository's default settings; nobody passes one when queueing. The title
  gives `<title> (#<n>)`, the subject merges had before. The body is left blank:
  the repository is public, and neither the pull request's description nor its
  branch commits (the `COMMIT_MESSAGES` default) are held to the rules of a
  public commit message, so neither is copied into `main`'s history.
- **Each pull request is checked on its own (`ALLGREEN`).** Every queued pull
  request's own commit must pass `pr / check` before it merges, so a red commit
  never reaches `main`, not even inside a group whose last commit is green. The
  check of a merge group builds what is affected between its `base_sha` and its
  head: at least that pull request's own change, built on top of the ones ahead.
- **Five build at once, up to five merge together.** A check takes tens of
  minutes. Five queued pull requests building at once give up to five merges per
  check duration instead of one, while leaving most of the farm to the checks of
  pull requests that are still being written. When the first ones of the queue are green
  together they reach `main` in one push, so `release.yml` runs once for them.
  `min_entries_to_merge: 1` means a pull request never waits for others to make a
  group (so the wait minutes never apply).
- **A pull request whose check fails leaves the queue.** The queue removes it
  and rebuilds the ones behind it without it; it comes back only when it is queued
  again, after a fix. A check that has not reported after
  `check_response_timeout_minutes` (360, the most GitHub allows) counts as
  failed; `pr / check` ends at its `timeout-minutes` of 330 first, so the queue
  sees a red check, not a silence.
- **The macOS build stays in the release workflows.** A merge group runs
  `pr.yml` alone, which builds no macOS target; the macOS set builds in
  `release-macos.yml` on the push to `main`, as before
  ([The macOS build of the release](#the-macos-build-of-the-release)).
- **`coverage` does not run on a merge group.** It reports on a pull request's
  "Files changed" view and is not required, so the queue does not wait for it.

A merge group runs the queued change's code on the farm with the farm
credential, as a push to `main` does. Queue only pull requests from branches of
this repository: a fork's change is read and pushed to a branch here first, as in
[Pull requests from forks](#pull-requests-from-forks). The farm's trust
credential accepts the tokens of this repository's runs; a merge group's token
names the queue's branch, not `main`.

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

Pull requests reach `main` through the [merge queue](#the-merge-queue), which
checks each one on top of the ones ahead of it, and the release run of
`release.yml` builds each push to `main`. The queue's check builds what the
change affects, not the release set, so `main` can still go red. The rule is
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
concurrency group with `cancel-in-progress: false` (see above): a running release is never cancelled,
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
