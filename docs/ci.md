# Continuous integration

A pull request from a branch of this repository runs ONE check: `pr / check`,
the one job `check` of [`.github/workflows/pr.yml`](#pryml-the-pull-requests-check),
a workflow of its own, on a GitHub-hosted runner that reaches the build farm
over a tailnet. The runner is
a thin buck2 client: it checks the repository out and asks the farm to build
the units the change reaches ([the units](#the-per-change-checks-units)).
Nothing is compiled on the runner.

| event | runs |
|---|---|
| push to `main` | the release path of `kci.yml`; when that run ends, [`main_red.yml`](#main_redyml-the-main-red-alert) |
| pull request from a branch of this repository | `pr / check`; and `coverage`, informational, not required ([below](#coverageyml-the-pull-requests-coverage-not-a-gate)) |
| pull request from a fork | nothing: no farm job runs ([below](#pull-requests-from-forks)) |
| manual (`workflow_dispatch`) | the release path of `kci.yml`, on the chosen ref |

There is no separate static or lint job, and no other pull request check
that can block a merge: the `coverage` workflow only reports. The only
scheduled run is the
[build-system self-tests](#build-system-self-tests), which is not the gate.
`ci.yml` and its check `ci / build` no longer exist. The whole-repository
`//...` build they ran on every push to `main` is not run by any workflow now;
a pull request's check covers the units the change reaches, and every target of
the graph is in some unit, so a change to any target is built by its unit.

## What the check builds

The build is the gate: building a target runs the tests welded to it and to its
dependencies, so the check points at build targets and nothing else. What a
build of the whole repository covers, and so what the units add up to:

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
   target there that does not build fails its unit; the targets that must fail
   are `tests//negative`, built as `expect_red`s by the
   [self-tests](#build-system-self-tests) and not by this one. Every target of `tests//functional` is meant to build, so nothing
   there is excluded: a probe or fixture that is expected to fail belongs in
   `tests//negative`.
A contributor runs the same three commands on any client. A green local
`./buck2 build //... && ./buck2 test //...` is the whole-repository form of
what the units of `pr / check` prove, dead Markdown links included (`//:docs`).

Publishing is not part of the check. The release workflow
[kci.yml](#kciyml-the-release) has no `pull_request` trigger: a pull request
never starts it and never shows a skipped release job.

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
   `[buck2_re_client]` addresses, instance name, `tls = false` and
   `execution_concurrency_limit`, and `linux_x86_64_properties` under
   `[komira_re]`. Developers put the same keys in their own gitignored
   `.buckconfig.local` ([DEVELOPMENT.md](../DEVELOPMENT.md)).

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
its unit (`//src/tests/helpers/komira_test_minio/...`) is affected, that is, when a PR
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
([`gate_runner.sh`](../tools/build/mojo/gate_runner.sh)) makes `TEST_TMPDIR`
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
on a nightly schedule and on demand, never on a push or a pull request, with
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

**Direction.** The script is to be replaced, case by case, by targets of the
`tests` cell, so that each case is cached, runs in parallel, has a name, and
runs under `./buck2 test` or `./buck2 build` like everything else. Cases that
look convertible from their description: 2 (gate red, ungated builds), 3
(a binary without the dep fails to compile), 4 (incomplete closure refused),
10 (execution platform resolution, an aquery), 13 and 14 (bundle and launcher
parity, already remote actions), 17 (Markdown link validation), 28 and 29
(already `tests//functional` targets), 30 (optimization levels from aquery),
31 (lint weld), 34 to 36 (generator goldens and refusals). Cases that observe
the client or the daemon (1, 5, 6, 7, 9, 12, 25, 32, 33) need a harness that
can start a scratch daemon or clone and are still to be analysed.

## kci.yml: the release

[`.github/workflows/kci.yml`](../.github/workflows/kci.yml) releases the conda
packages that `release/artifacts.textproto` declares, through `kci` (`bin/kci`).
It is written by hand. The stages are owned by the release machine,
[`release/machine.textproto`](../release/machine.textproto): `build`, then
`gamma`, then `prod`, and `pr`, the per-change check of a pull request, which is
the one job of [`pr.yml`](#pryml-the-pull-requests-check), not of this file. The
workflow runs one job per stage (but `pr`), named for its
stage, running in the stage's GitHub environment and running exactly one
`kci run --stage <its name>`, except that `gamma` is split over two jobs:
`gamma` runs its step (`--only step:publish`) and `validate` its two
validations (`--only validation:install-komira-encoding --only
validation:install-set`). kci reads `release/machine.textproto` by
convention (its one default path), so no line of the workflow names it.

| job (stage) | runner | what it does |
|---|---|---|
| `build` | GitHub-hosted (`ubuntu-24.04`) joined to the farm by [`farm-connect`](#how-it-reaches-the-farm), environment `build`, `contents: read` + `id-token: write` (for the tailnet only) | builds `//bin/kci:kci[runnable]`, then `kci run --stage build --revision-id <REVISION>`: every declared artifact, built on the farm, stamped from git, verified, and `release.json` with the set hash. The release directory, the kci binary and the build's result file leave the job as one workflow artifact named `kci-release-<REVISION>`. |
| `gamma` | GitHub-hosted (`ubuntu-24.04`), environment `gamma` on a push to `main` and `gamma-breakglass` on any other run (see [Break-glass](#break-glass-a-manual-run-to-gamma)), `id-token: write` | runs `release_version.sh` at `REVISION`, then `kci run --stage gamma --only step:publish`: the release directory `build` made, published to the channel `komira-ai/gamma`. Nothing is built here. |
| `validate` (stage `gamma`) | GitHub-hosted (`ubuntu-24.04`), no environment, `contents: read` only | downloads the platform table's linux-x86_64 pixi pin (its URL and sha256 are the job's `PIXI_URL` and `PIXI_SHA256`, held to the table by `test_repo_kci_yml`) and keeps it only at that sha256, then `kci run --stage gamma --only validation:install-komira-encoding --only validation:install-set --pixi <that file> --pixi-sha256 "$PIXI_SHA256"`: what `gamma` published, installed from the channel the way a consumer gets it, on the runner with no container (see Validations). Holds no identity token; re-running it re-validates without re-publishing. |
| `prod` | GitHub-hosted (`ubuntu-24.04`), environment `prod`, `id-token: write` | after `gamma` and `validate`, on a PUSH to `main` only (a manual run, of `main` too, stops at `gamma`): the same bytes (the set `validate` validated, by hash), published to `komira-ai/prod` with no manual step. Nothing is built here. |

The same release directory, from the one artifact `kci-release-<REVISION>`,
is published to each channel: it is never rebuilt. `build.set_hash`,
`gamma.set_hash` and `prod.set_hash` in the three result files are the same
value, and the release's `release_produced_by` names the one build run. It
is checked, not assumed: the `build` job's output `set_hash` (read from its
kci result) goes to `gamma` and `validate` as `--release-set-hash`; the
`validate` job's output `validated_set_hash` (read from ITS result, never
from the value it was given) goes to `prod`. kci recomputes the unpacked
release's set and refuses another (exit 3, `KCI-E-SET-HASH`) before anything
is read from a channel, so `prod` publishes exactly the set `gamma` published
and `validate` installed (rule R19 holds the wiring).

### Continuous auto-promotion

A push to `main` IS the release: `build` -> `gamma` -> `validate` -> `prod`,
with no manual step. `prod` starts only when `gamma` and `validate` both
succeeded in the same run (no job-level `if:` names `always()`, so GitHub's
implicit `success()` holds). A push that touches only documentation
(`docs/**`, `**.md`) starts no run: `release_version.sh` does not count those
files either, so the build number would not move (rule R17 holds the two
lists equal). A push that changes nothing a package carries (a `.github`-only
push) rebuilds the same bytes under the same name and build number, and each
channel answers NOOP (exit 0).

- **Only a push to `main` reaches `prod`.** A manual run of `main` is
  break-glass like any other manual run and stops at `gamma`. The `prod`
  job's `if:` carries `github.event_name == 'push' && github.ref ==
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
  (rule R22). So `validate` validates FOR REAL on every push: a `validate`
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
  its result carries a `set_hash` only for a run that is not `--plan` and,
  when it selects validations, whose every validation VALIDATED and
  SUCCEEDED. `validate`'s `validated_set_hash` comes from that field, so a
  dry run hands `prod` nothing, and `prod` refuses an empty hash.
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

  The rule is the run's, not the stage's: a push to `main` holds `gamma` to
  it too, where it counts only `gamma`'s MAIN-LINE builds (those whose
  `h<8 hex>` is a commit on `main`'s freshly fetched history; a branch's
  break-glass build is reported and not counted). Before refusing, kci asks
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
  (break-glass: a workflow_dispatch of <ref> reaches gamma only)`, or, from
  `validate`, `prod: NEXT (runs automatically; it waits only while the prod
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
`gamma` job also runs in the environment `gamma` from a manual run, with no
break-glass reason and no reviewer. Neither `kci.yml` nor `kci` can refuse
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
build, gamma and validate still run for the revision being released. Because
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

### Break-glass: a manual run to gamma

Every manual run (`workflow_dispatch`, of a branch or of `main`) is
BREAK-GLASS: it builds its revision and publishes it to `komira-ai/gamma`
(and validates it there), and never reaches `prod`. Its `gamma` job runs in
the GitHub environment **`gamma-breakglass`** (the machine file's
`break_glass_environment` for the stage `gamma`; rule R2 holds the job's
`environment:` to exactly `${{ github.event_name == 'push' && 'gamma' ||
'gamma-breakglass' }}`), which has a REQUIRED REVIEWER and administrator
bypass turned off, so every break-glass publish waits for an approval that
GitHub records with the run. The gamma
channel trusts `gamma-breakglass` as a second trusted publisher
(`break_glass_push_identity` in `release/channels.textproto`), and kci
publishes a break-glass run only from it (`KCI-E-STAGE-ENVIRONMENT`
otherwise). The input `reason` is required; it reaches kci only through each
job's `env:` (`--context reason=...`), never inside a `run:` script (rule
R18; nor in a `with: script:`, and no step's or job's `name:` holds any
expression at all), and kci refuses a break-glass run without one, with
one that is only whitespace, or with one over 200 bytes once trimmed
(exit 3, `KCI-E-BREAK-GLASS-REASON`). A break-glass run that can publish
releases the commit it started on: a `revision` input is for a dry run only, on the history of that commit (kci refuses any other, exit 3, `KCI-E-BREAK-GLASS-REVISION`). Every job's summary of such a run
starts `BREAK-GLASS: <ref> <revision> by <actor>: <reason>`.

**What is the lock, and what is not.** A pull request's run uses the
pull request's own `kci.yml`, and a run of a branch (a manual run, or a push
to a branch whose own `kci.yml` adds it as a push trigger) uses that
branch's own `kci.yml` and builds that branch's own `kci`. Anyone with
write access can make either one. So NOTHING in `kci.yml` or in kci can stop
such a run from naming an environment and asking for an identity token:
the reason is recorded by kci only when the branch's `kci.yml` and kci are
unmodified. The locks are GitHub's settings: `gamma` and `prod` deploy only
from `main` (a job naming either from a pull request's merge ref or another
branch is rejected before it starts, and GitHub's identity token for a job
in an environment names only the environment, so the environment's branch
rule is what stands between a branch and the channel's trusted publisher),
and `gamma-breakglass` needs a reviewer's approval for every job. ⚠ **Until
the settings in [GitHub settings](#github-settings-the-release-relies-on)
are in place, anyone with write access can publish any branch, or any
same-repository pull request, to gamma, with no recorded reason.**

Known residual: a break-glass build of a branch commit can carry the same
build number as a later `main` release (a different `h<8 hex>` string, so
the registry accepts both); a gamma consumer solving "latest" may pick
either until `main`'s next number.

### GitHub settings the release relies on

None of these is in the repository; each is a setting an administrator
makes, and the release is only as safe as they are. ⚠ The `gamma`,
`gamma-breakglass`, second-publisher and ruleset rows are NOT set yet: until
they are, a branch's own `kci.yml` can still publish to gamma, and every
break-glass publish is refused by prefix.dev (no trusted publisher for
`gamma-breakglass`).

⚠ **GitHub creates an environment the first time a job names it, with NO
protection rules** (GitHub's documentation, "Managing environments for
deployment": the newly created environment "will not have any protection
rules"). So `gamma-breakglass` may already exist when you get to it: any
manual run after this file is on `main`, or any push to a branch whose own
`kci.yml` names it, creates it with no reviewer. Its existing is NOT the
setting. Open it and confirm the Required reviewers rule is on it. **Do not
add the prefix.dev publisher for `gamma-breakglass` until that environment
shows a required reviewer**: with the publisher and no reviewer, every
break-glass run publishes to gamma unapproved.

⚠ **A recorded reason is guaranteed only for a run of an unmodified
`kci.yml`.** `gamma-breakglass` deploys from any branch, and GitHub matches
the branch rule against the run's ref. So a same-repository pull request, or
a push to a branch whose own `kci.yml` names `environment:
gamma-breakglass`, reaches the gamma publisher with no `reason` input and no
kci reason check (that check is in the branch's own kci). The reviewer's
approval is the only gate there. **The reviewer must refuse any
`gamma-breakglass` job whose run is not a `workflow_dispatch` of `kci.yml`,
or whose summary lacks the line `BREAK-GLASS: <ref> <revision> by <actor>:
<reason>`.** Turn on **Prevent self-review** for `gamma-breakglass` so that
the approval comes from a second person.

⚠ **Administrators bypass a reviewer by default.** GitHub's documentation
("Managing environments for deployment"): "By default, administrators can
bypass the protection rules and force deployments to specific
environments"; its 2023-03-01 changelog adds that an administrator can
"bypass all protection rules on a given environment ... and force the
pending jobs referencing the environment to proceed". So with the box
**Allow administrators to bypass configured protection rules** checked (the
default), a repository administrator can force a `gamma-breakglass` job, a
pull request's or a branch push's own included (no reason input, no kci
reason check), and a paused `prod` job, with no second person's approval.
Uncheck it on `gamma-breakglass` and on `prod`. The bypass forces a PENDING
job; a job a deployment branch rule refuses is not pending, and GitHub
matches that rule against the run's `GITHUB_REF` (`refs/pull/<n>/merge` for
a pull request), so the `main`-only rule on `gamma` and `prod` holds either
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
| environment `gamma`, deployment branches | Selected: `main` | only `main` publishes to gamma without break-glass |
| environment `gamma-breakglass` (FIRST: before the next row) | any branch, **required reviewer**, **Prevent self-review**, **Allow administrators to bypass configured protection rules UNCHECKED**. It may already exist, auto-created by GitHub with no protection: confirm the reviewer rule is on it | every break-glass publish waits for a recorded approval by a second person (for a run of an unmodified `kci.yml` the reason is recorded too; for any other run, the reviewer refuses it) |
| prefix.dev `komira-ai/gamma`, trusted publishers (ONLY AFTER `gamma-breakglass` shows a required reviewer) | `komira-ai/komira`, `kci.yml`, environment `gamma`, AND a second one for environment `gamma-breakglass` | a break-glass run can publish to gamma at all (without it, every break-glass publish is refused by prefix.dev) |
| prefix.dev `komira-ai/prod`, trusted publisher | `komira-ai/komira`, `kci.yml`, environment `prod` only | (already set) |
| repository ruleset, then VERIFIED | block creating and updating branches and tags matching `[Mm][Aa][Ii][Nn]` except the branch `main`, and the tag `main`. Then try to create the branch `MAIN`: it must be refused | no ref that is `main` in another case exists, so GitHub's case-insensitive `if:` and concurrency comparisons cannot be fooled by one (whether the environment branch rule `main` matches `MAIN` is undocumented). Until the check passes, prod's case-variant exposure is OPEN |

- **One command.** kci has exactly one command, `kci run --stage S`. There is
  no `kci build`, `kci publish` or `kci ci check`. `kci run` also takes
  `--only step:<name>` / `--only validation:<name>` (repeatable) to run a
  selection; such a run is recorded with `scope: SELECTIVE` and its last
  stderr line says `-- not a full run`. `--only step:<name>` runs the step
  WITHOUT its validations; only a FULL run runs both. A release job runs its
  whole stage unless the stage is split over jobs that together run all of
  it exactly once (rule R9, amended and pending a ruling): here only `gamma`
  is, into `gamma` and `validate`. `--plan` is the dry run of a whole stage.
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
  missing variable, is exit 5 and never a pass. The same check is the welded
  test `src/kci_workflow_check/tests/test_repo_kci_yml.mojo`, so a drift also
  fails `./buck2 build //...`. Consequence: a revision whose machine file
  disagrees with the running `kci.yml` cannot be released by it (a manual run
  of an old revision is refused, exit 3).
- **Triggers:** a push to `main` (not a documentation-only one) and a manual
  run (`workflow_dispatch`), and nothing else: kci.yml has **no `pull_request`
  trigger** (one added is refused by rule R6, as is `pull_request_target` and
  every other event), so a pull request never starts it and never shows a
  skipped gamma, validate, prod or build job. No environment, publishing token
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
- **Dry run on request.** A push is a real run. A manual run is a real run
  unless its input `dry_run` is true (`--plan` for gamma, validate and prod;
  `build` always builds).
- **What a dry run proves.** For each publish job: the release set verifies
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
  first real gamma publish proves those for gamma.
- **NEW NAMES, before prod.** Which names a release publishes is
  `release/artifacts.textproto`'s, reviewed through CODEOWNERS; there is no
  per-run claim. Every publish step reads its channel first and reports the
  declared names the channel holds no file of yet (NEW NAMES) in its result
  file (`new_names[]`) and in the job summary. Each `kci run` also reports
  the NEW NAMES of the stages after it: **the `gamma` job's summary shows the
  names new to `komira-ai/prod`** before `prod` publishes them (a first
  publish of a name is the one effect a later release cannot undo; pause
  promotion, above, to read it first). A run given no release version (the
  `validate` job) cannot name the files and says `lookahead skipped`. A
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
  kind: CONDA_INSTALL_ENV ... }`); gamma has two: `install-komira-encoding`
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
  from the packages' own `info/index.json`), and `kci run --stage gamma
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
  (`kci_release_machine`'s welded test), and the `validate` job's `kci run`
  passes what they pass (`test_repo_kci_yml`), so a developer and the
  workflow run the same thing.
- **A runner that runs a `DEPLOY_PROBE`: the link-local precondition.** A
  probe (design: [deploy_step.md](design/deploy_step.md)) runs the
  operator's image on `--network=bridge` against a freshly deployed
  service. On a runner hosted in a cloud, that network reaches the IPv4
  link-local range (RFC 3927), where the VM's metadata server hands out the
  runner VM's own credentials. kci changes nothing on the host, so the
  operator sets standing host rules once, before any probe runs there, so
  that no container on the host reaches:
  - the IPv4 link-local range: for example `iptables -I DOCKER-USER -d
    <the link-local range> -j REJECT` (REJECT rather than DROP, so a probe of
    it fails at once);
  - the documented IPv6 metadata address `fd00:ec2::254`: an `ip6tables`
    rule, or IPv6 off on the docker bridge;
  - on Azure, the WireServer `168.63.129.16`, on tcp ports 80 and 32526
    only: docker forwards container DNS to its port 53, so that stays open.

  Before every probe kci runs a **pre-flight**: a throwaway container
  (`--rm`, the probe's hardening flags, the same `--network=bridge`) of the
  digest-pinned helper image, busybox, given as `--preflight-image` from the
  platform table's `preflight_image` (`tools/build/platforms/table.bzl`),
  whose command is `nc -z -w 3` to the instance-metadata address of the
  link-local range, port 80. Only exit 1 (nothing answered) lets the probe
  run; exit 0, any other exit, a failed pull or kci's timeout around it is
  `INDETERMINATE`, exit 5, and the probe never runs. Only that one address
  and port are checked: the pre-flight catches the rule being absent, not a
  rule with holes, and the other rules above are documented, not verified.
  kci never inserts or removes a rule and needs no privilege at run time.
  `nc`'s exit contract is a farm test
  (`//src/kci_validate:preflight_exit_contract`). The helper image is
  Docker Hub's `library/busybox` 1.37.0, pinned by its linux/amd64 image
  manifest digest (not the multi-arch index's). A row whose
  `preflight_image` is a `placeholder(...)` passes an all-zero digest
  instead, and kci refuses every run that selects a `DEPLOY_PROBE` at
  start. `CONDA_INSTALL_SMOKE` has the same exposure today and takes the
  same pre-flight in a follow-up.
- **The channels.** prefix.dev channels `komira-ai/gamma` and
  `komira-ai/prod` ([release/channels.textproto](../release/channels.textproto)),
  both public. Uploads go to `https://prefix.dev/api/v1/upload/komira-ai/<channel>`
  and reads to `https://prefix.dev/komira-ai/<channel>/<subdir>/repodata.json`
  ([prefix.dev: channels](https://prefix.dev/docs/prefix/channels/concepts),
  [API](https://prefix.dev/docs/prefix/api)).
- **No secret.** Each channel's credential is trusted publishing: the channel
  trusts this repository, the workflow file `kci.yml` and one GitHub
  environment (`gamma` or `prod`), and kci exchanges the job's ID token itself
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

### The per-change check's units

`kci run --stage pr --affected-by <base>` builds UNITS, and a unit passes only
when it builds and its tests pass. The units are derived when the check runs,
so the release files list no package:

- **Declared:** the artifacts of `release/artifacts.textproto` (and any
  explicit `checks` it declares, to group targets its own way).
- **Derived:** the buck2 build system's `derive_checks` command,
  `release/ci/derive_checks.py`, reads `//...` and `tests//functional/...`
  from the live graph (`buck2 cquery`) and answers one check per path group
  for every target no declared unit names or matches: `<p>` for each
  library `//src/<p>/...` and each test-only package
  `//src/tests/<kind>/<p>/...`, `repo_root` for `//:`, `tools_<t>` for each
  `//tools/<t>/...`, `<d>` for any other top directory, `functional_tests`
  for `tests//functional/...`; a name an artifact holds gets `_package`.
  Every name is one kci accepts (`[a-z][a-z0-9_]*`) whatever the directory
  is called: upper case becomes lower, any other character `_`, and a name
  not starting with a letter gets `pkg_` (`//src/3d` is `pkg_3d`); groups
  whose names meet are one check. kci adds them after the declared units,
  under the file's own rules.
- **Coverage by construction:** every target of the graph is in some unit. A
  pull request that adds a package gets a check for it, and one that deletes
  a package no longer derives one; neither edits a release file.
- **A declared target that matches nothing:** for a check, a NOTICE line in
  the result (the package it named is gone; the rest of the check builds);
  for an artifact, a refusal (`KCI-E-ARTIFACT`): a release must build what an
  artifact names. A derive tool that fails or answers outside its grammar is
  "cannot tell" (`KCI-E-AFFECTED`), never a pass.
- **A universe the derive tool cannot query:** when its `buck2 cquery` fails,
  for any reason (a target with an unknown or invisible dependency, a
  transport error, a buck2 that does not start), `derive_checks.py` answers
  one `BROKEN <reason>` line holding buck2's error, and kci FAILS the check
  (`KCI-E-BUILD-FAILED`): nothing is built, and no affected command runs.

**Which units a change reaches:** each build system's `affected` command,
`buck2 run //tools/build/ci:affected` ([`tools/build/ci`](../tools/build/ci)),
maps the change's files to the targets that own them (a `BUCK` file to its
package, a `.bzl` file to every package that loads it, a deleted file to the
package that held it at the base commit), takes their reverse dependencies, and
answers the units whose targets (labels, or the package patterns of the derived
checks) are among them. A file it cannot map, and a change to `.buckconfig`,
the toolchains, `tools/build`, `prelude` or `third_party`
([`rules.txt`](../tools/build/ci/rules.txt)), answer `WIDENED`: every unit.
A widened answer is given only after `buck2 cquery` configures the whole
universe. A failed query is never a widening: when the query mapping the
files, the reverse-dependency query or the query configuring the universe
fails, for any reason (a target with an unknown or invisible dependency, a
transport error), the answer is `BROKEN`, carrying buck2's error (its
stderr whole up to 8 KiB, else the first and last 4 KiB), and kci FAILS the
check (`KCI-E-BUILD-FAILED`). The decision is the failure, not buck2's text:
the target buck2 names, when it names one, only leads the message. So a
change that plants a target buck2 cannot configure fails its own check,
widened or not. A
non-empty change that reaches no unit answers `AFFECTED 0`, which kci refuses
(`KCI-E-AFFECTED-VACUOUS`): never a pass. The job's checkout has the full
history, so the base commit is there. In `pr.yml` the base is the first parent
of the merge commit the job builds, so the change is the pull request's alone
however far `main` has moved since the pull request's event.

**How the reached units are built:** units whose `build_targets` commands are
identical (both build systems of `release/artifacts.textproto` share
`sh release/ci/build_targets.sh`) are built in ONE run over the union of their
targets, so a `build_targets` command must be correct on such a union.
`release/ci/build_targets.sh` builds with `--keep-going`, then checks the lints
and runs the tests among all the targets (a failed build stops before the lints
and tests). The run's timeout bounds the whole batch, not each unit in it:
with the build budget (below), all of the budget left; without it, the
per-run timeout (`--build-timeout-s`, default 3600 s).
The run's output is in
`<log dir>/_batch_<k>.stdout` and `.stderr`, and its full argv, one argument per
line, in `_batch_<k>.argv` (k counts the batches from 1; a unit alone logs to
`<unit>.stdout` and `.stderr`).

- **The batch passes:** every unit in it is `BUILT`. Nothing is retried.
- **The batch fails:** kci builds its units one at a time, in order, to name
  the failing ones. Each retry re-runs `sh release/ci/build_targets.sh` over
  that one unit's targets, with its own timeout (as the batch's), and logs to
  `<unit>.stdout` and `.stderr`; the batch already built every target that
  does not depend on a failure, so the retries run on a warm cache. A failing
  wide change therefore costs the batch's time plus the retries, up to the
  cap. A retry that fails, times out or is killed is a failed unit. After 3
  failed units it stops retrying: the rest are listed as not tried, and a
  later batch that fails is noted as not attributed (a later batch that
  passes still builds its units). The step is FAILED (`KCI-E-BUILD-FAILED`);
  the summary's line is `BUILD step: F of N unit(s) failed: ...`.
- **The batch times out (or is killed by a signal):** the batch had all that
  was left of the build budget (the note then says `timed out after N min[ S
  s], all that was left of the build budget (--build-budget-s B)`, N min S s
  the time it was allowed), or without a budget the whole `--build-timeout-s`
  (default 3600 s), not a share per unit. It is not retried and no unit of
  it is attributed: FAILED.
- **The batch fails but every unit builds alone:** the units interfere or the
  build is flaky. That is INDETERMINATE (`KCI-E-CANNOT-TELL`), never a pass.
  FAILED outranks it: if a unit failed or a batch was not attributed anywhere
  in the step, the step is FAILED and the interference is a note.
- **A run cannot be started** (a batch, a unit alone or a retry): the step
  stops at once, nothing after it is started, and the step is INDETERMINATE
  (`KCI-E-CANNOT-TELL`) even when a unit has already failed.

**The build budget** (`--build-budget-s <n>`, accepted only with
`--affected-by`, at most 604800, a week): the seconds the per-change check
may take, counted from kci's own start on the monotonic clock
(`CLOCK_MONOTONIC`), so everything kci does first (the workflow check, the
git reads, the derive and affected commands) is charged to it. Every run
(each derive and affected command, a batch, a unit alone, a retry) gets all
the whole seconds left until the deadline, read just before it starts
(`--build-timeout-s` is refused beside `--build-budget-s`: no fixed cap
cuts a wide batch short of the budget); a run that passed, failed or timed out is
charged alike. A build run (a batch, a unit alone, a retry) that times out
is FAILED, with the `timed out after N min[ S s], ...` note above. A derive
or affected command that times out is INDETERMINATE (`KCI-E-AFFECTED`), its
note a plain `timed out`: it gets all the budget left too, so a hung
affected command can use the whole budget before the step ends
INDETERMINATE. A run with less than one second left is not started. A
derive or affected command not started makes the step INDETERMINATE
(`KCI-E-AFFECTED`: kci cannot tell what the change reaches). A build run not
started lists its units, and those of every later run, as `BUILD step: U of
N unit(s) not built: the build budget (--build-budget-s B) was spent before
their run could start: ...`, which is FAILED (`KCI-E-BUILD-FAILED`), never
a pass; the units earlier runs built keep their `BUILT` lines. A batch whose
retries ran out of budget is not called interference. Without the flag,
each run has its `--build-timeout-s` and there is no total.

`pr.yml` passes the time its job has left: its first step writes the job's
deadline, 115 of the job's 120 minutes (`timeout-minutes`), and the
`kci run` step stops with an error if that file is missing, then passes the
seconds left until it. The time `build kci` took is therefore not taken from
a wide change's build, and kci reports which units it did not build about 5
minutes before GitHub would cancel the job (kci's own last seconds of
writing its result, and the steps after kci, which take seconds, fall in
those 5 minutes). `build kci` itself takes from seconds (a cached kci) to most
of an hour (a change to kci or to what it depends on), so a fixed per-batch
number either wasted the job's time or overran it. The welded test
`src/kci_workflow_check/tests/test_repo_kci_yml.mojo` holds `pr.yml` to these
steps and numbers.

Whatever the outcome, a `BUILT <unit>` line names exactly the units a
successful run covered. The result document's `affected_by.units` is the set
the change reached, not the set that built.

To see the units a change would build, with nothing built:

```sh
kci run --stage pr --affected-by <base commit> --revision-id <HEAD> \
  --work-dir "$PWD" --log-dir <dir> --result-file <file> --plan
python3 release/ci/derive_checks.py --from release/artifacts.textproto  # the derived checks alone
```

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
- **Flow:** `[]`, a list of plain words (`[main]`, `[build, gamma]`), and `{}`.
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

[`.github/workflows/pr.yml`](../.github/workflows/pr.yml) is the machine file's
`pr` stage and nothing else: workflow `pr`, one job `check`, so the status check
is **`pr / check`**. It is written by hand and held to the machine file the way
kci.yml is (rule R6 of `src/kci_workflow_check/rules.mojo`, `check_pull_request_workflow`):
`kci run --stage pr` reads the file it runs under (`GITHUB_WORKFLOW_REF`) and
holds it to the pull request's rules (a run of any other stage holds its file
to the release workflow's), and the welded test
`src/kci_workflow_check/tests/test_repo_kci_yml.mojo` reads both files on every build.

| | |
|---|---|
| trigger | `pull_request` alone: no push, manual run, `pull_request_target`, `workflow_run` or any other event |
| job | the one job `check`, only for a pull request from a branch of this repository (`github.event.pull_request.head.repo.full_name == github.repository`; a fork's run gets no tailnet credential, and a maintainer reads the change and pushes it to a branch here), written bare or as exactly `${{ <condition> }}` (a block scalar or whitespace inside quotes makes GitHub read the `if:` as a format string, which is always true) |
| runner | `runs-on: ubuntu-24.04`, written as that plain scalar: a GitHub-hosted machine, fresh per job. A self-hosted label, label list, runner group, expression (`${{ vars.X }}`) or quoted value is refused, so a pull request's code never reaches a runner that keeps state between jobs |
| permissions | its own `permissions:` mapping, `contents: read` and `id-token: write` (for the farm connection, [farm-connect](#how-it-reaches-the-farm), only); no environment, no secret (no value of the job, nor of the workflow-level `env:`, names `secrets` other than `secrets.GITHUB_TOKEN`), no publish step |
| steps | the pinned full-history checkout of the merge commit, `farm-connect`, `//bin/kci:kci[runnable]`, then `kci run --stage pr --affected-by "$change_base"`, where `change_base` is the merge commit's first parent (`git rev-parse --verify HEAD^1`, the `main` the pull request is merged into; the step stops when HEAD has no second parent). Never the event's `github.event.pull_request.base.sha`: that is `main` when the event fired, and once `main` moves every change merged to it since then would count as the pull request's own and widen the check. `src/kci_workflow_check` (R6) holds the exact line, and lets no `${{ }}` into a script (R18). It builds and tests the units the change reaches on the farm, in one batch per shared build command, a failed batch retried unit by unit to name its failing units. The units are the artifacts of `release/artifacts.textproto` and the checks derived from the build graph when the job runs (see [The per-change check's units](#the-per-change-checks-units)), so a pull request that adds or deletes a package needs no edit to any release file. Nothing ships. |
| every `uses:` | pinned to a full commit id (the local farm-connect action excepted) |

The repository's branch settings require the check **`pr / check`**.

## coverage.yml: the pull request's coverage (not a gate)

[`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml) posts
the check run `coverage`: the line coverage of the `mojo_library` targets the
change touches, and the branch coverage of those whose coverage gate reads
branch records (`COVERAGE_BRANCH_GATE`), as covcheck's summary and
annotations on the lines of the "Files changed" view. It is **informational**: not a required check, its
conclusion is `neutral` in the policy's census mode, and it cannot make
`pr / check` red. Job `measure` (the same farm connection and permissions as
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
into `main`, and the release run of `kci.yml` builds each push to `main`. Two
changes that are each green can still break `main` together. The rule is
**fix forward or revert within the hour**: when the release run of `main`
fails, the author of a culprit pull request lands a fix, or reverts the
pull request, within an hour of the alert, before anything else merges on
top of it.

[`.github/workflows/main_red.yml`](../.github/workflows/main_red.yml) is the
alert. It runs when a run of `kci.yml` on `main` completes (`workflow_run`)
and runs [`release/ci/main_red.py`](../release/ci/main_red.py) with
`issues: write`, `actions: read` and `contents: read`, checking out `main`
and running no code of any pull request. It acts only on a run started by a
push to `main`:

- **Red** (`failure`, `timed_out`, `startup_failure`): the last green
  commit is the newest commit of a successful push run of `kci.yml` on
  `main` that is an ancestor of the red one; the culprits are the pull
  requests merged into `main` after it (the first-parent commits of the
  range, newest first); the failing targets are the `Action failed:`,
  `GATED TEST FAILED:` and ``Validation for `<target>` failed`` lines of
  the failed jobs' logs (with none, the failed job and step). If no issue
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

**Nothing hides a red `main`.** `kci.yml`'s push runs share one
concurrency group with `cancel-in-progress: false` ([Queued
runs](#continuous-auto-promotion)): a running release is never cancelled,
and a newer push replaces only a pending run, which never started. The run
that replaces it builds a later commit of `main`, which carries the
replaced one's changes, and the culprits come from the whole range since
the last green commit, so the replaced commit's pull request is still
named. `main_red.yml` has no concurrency group, so none of its runs is
replaced or cancelled; if two red runs race to open the issue, the newer
issue is closed as a duplicate of the older. One delay remains: a push
that changes only `docs/**` or `*.md` files starts no `kci.yml` run (rule
R17), so a README example it breaks is found by the next push's run, whose
range names it. Cases: `//release/ci/tests:test_main_red`.

## merge-from-live (not yet running)

[`.github/workflows/merge_from_live.yml`](../.github/workflows/merge_from_live.yml)
is the planned weekly pull request bumping every pin (buck2, the toolchain
downloads, third-party archives) to its live release, merged only if its own
`pr / check` run is green. It is a stub: its script,
[`.github/ci/merge_from_live.sh`](../.github/ci/merge_from_live.sh), states the
design and exits 1, and the workflow has no schedule until the script opens
pull requests.

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
