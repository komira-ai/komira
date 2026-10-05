# Continuous integration

CI is one job, `build` in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
on a GitHub-hosted runner that reaches the build farm over a tailnet. The
runner is a thin buck2 client: it checks the repository out and asks the farm
to build it. Nothing is compiled on the runner.

| event | runs |
|---|---|
| push to `main` | the farm build |
| pull request from a branch of this repository | the farm build |
| pull request from a fork | no farm build; the lints that need no farm ([below](#pull-requests-from-forks)) |
| manual (`workflow_dispatch`) | the farm build, on the chosen ref |

There is no separate static or lint job. The only scheduled run is the
[build-system self-tests](#build-system-self-tests), which is not the gate.

## What the job runs

```sh
./buck2 build //...
./buck2 test //...
./buck2 build --keep-going tests//functional/...
```

The build is the gate: building a release target runs the tests welded to it
and to its dependencies, so the job points at build targets and nothing else.

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
   target there that does not build fails the job; the targets that must fail
   are `tests//negative`, built as `expect_red`s by the
   [self-tests](#build-system-self-tests) and not by this one. Every target of `tests//functional` is meant to build, so nothing
   there is excluded: a probe or fixture that is expected to fail belongs in
   `tests//negative`.
A contributor runs the same three commands on any client. A green local
`./buck2 build //... && ./buck2 test //...` is what the first two steps of CI
prove, dead Markdown links included (`//:docs`).

Publishing is not part of this job. It is a separate workflow,
[kci.yml](#kciyml-the-release), whose only job on a pull request is the
per-change check `pr`; its release jobs never run for one.

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

To check the connection without a build, run the manual workflow
[`tailnet-probe`](../.github/workflows/tailnet-probe.yml) (the same join and the
same port check, which also prints how the path runs, direct or relayed, and
that the ports a CI node must not reach are blocked) from a branch of this
repository.

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

- The `build` job (and `core_split`'s) is **skipped** for a fork's pull
  request: `if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository`.
- The job **`fork-advisory`** runs instead, on a hosted runner with no tailnet,
  no id-token and no variable: it builds the lints that need no farm
  (`//:shell_lint //:workflow_lint //:action_pins //:push_verdicts //:no_endpoint`)
  on the runner itself, and writes to the run's summary that no farm build ran.
  It is not the farm verdict.
- ⚠ A skipped job counts as passed for a required status check. Do not rely on
  the `build` check alone to merge a fork's change: read it, push it to a branch
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

## Build-system self-tests

[`tools/build/tests/run_tests.sh`](../tools/build/tests/README.md) tests what a
build does not: where actions ran, cache identity across checkouts,
analysis-time refusals, a `buck2 run` from a fresh clone, targets that must
fail by design (the `tests` cell), and the `./buck2` bootstrap. It is one shell
script of numbered cases, takes well over an hour, and is **not the gate**: the
gate is the three build commands above. It runs in its own workflow,
[`build_system_selftests.yml`](../.github/workflows/build_system_selftests.yml),
on a nightly schedule and on demand, never on a push or a pull request, with
the same farm connection and the same job permissions as `ci`. Two runs never
overlap. It needs a Linux x86_64 client and refuses any other (exit 2).

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
`gamma`, then `prod`, and `pr`, the per-change check of a pull request. The workflow runs one job per stage, named for its
stage, running in the stage's GitHub environment and running exactly one
`kci run --stage <its name>`, except that `gamma` is split over two jobs:
`gamma` runs its step (`--only step:publish`) and `validate` its validation
(`--only validation:install`). kci reads `release/machine.textproto` by
convention (its one default path), so no line of the workflow names it.

| job (stage) | runner | what it does |
|---|---|---|
| `build` | GitHub-hosted (`ubuntu-24.04`) joined to the farm by [`farm-connect`](#how-it-reaches-the-farm), environment `build`, `contents: read` + `id-token: write` (for the tailnet only) | builds `//bin/kci:kci[runnable]`, then `kci run --stage build --revision-id <REVISION>`: every declared artifact, built on the farm, stamped from git, verified, and `release.json` with the set hash. The release directory, the kci binary and the build's result file leave the job as one workflow artifact named `kci-release-<REVISION>`. |
| `gamma` | GitHub-hosted (`ubuntu-24.04`), environment `gamma` on a push to `main` and `gamma-breakglass` on any other run (see [Break-glass](#break-glass-a-manual-run-to-gamma)), `id-token: write` | runs `release_version.sh` at `REVISION`, then `kci run --stage gamma --only step:publish`: the release directory `build` made, published to the channel `komira-ai/gamma`. Nothing is built here. |
| `validate` (stage `gamma`) | GitHub-hosted (`ubuntu-24.04`, docker installed), no environment, `contents: read` only | `kci run --stage gamma --only validation:install`: what `gamma` published, installed from the channel the way a consumer gets it, in a digest-pinned container (see Validations). Holds no identity token; re-running it re-validates without re-publishing. |
| `prod` | GitHub-hosted (`ubuntu-24.04`), environment `prod`, `id-token: write` | after `gamma` and `validate`, on a PUSH to `main` only (a manual run, of `main` too, stops at `gamma`): the same bytes (the set `validate` validated, by hash), published to `komira-ai/prod` with no manual step. Nothing is built here. |
| `pr` (the check `kci / pr`) | GitHub-hosted (`ubuntu-24.04`) joined to the farm by [`farm-connect`](#how-it-reaches-the-farm), no environment, `contents: read` + `id-token: write` (for the tailnet only) | a pull request from a branch of this repository only (a fork's runs nothing): builds `//bin/kci:kci[runnable]`, then `kci run --stage pr --affected-by <the pull request's base commit>`: the units the change reaches, built and tested on the farm. The units are the artifacts of `release/artifacts.textproto` and the checks derived from the build graph when the job runs (see [The per-change check's units](#the-per-change-checks-units)), so a pull request that adds or deletes a package needs no edit to any release file. Nothing ships. |

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
and `validate` installed (rule R17 holds the wiring).

### Continuous auto-promotion

A push to `main` IS the release: `build` -> `gamma` -> `validate` -> `prod`,
with no manual step. `prod` starts only when `gamma` and `validate` both
succeeded in the same run (no job-level `if:` names `always()`, so GitHub's
implicit `success()` holds). A push that touches only documentation
(`docs/**`, `**.md`) starts no run: `release_version.sh` does not count those
files either, so the build number would not move (rule R15 holds the two
lists equal). A push that changes nothing a package carries (a `.github`-only
push) rebuilds the same bytes under the same name and build number, and each
channel answers NOOP (exit 0).

- **Only a push to `main` reaches `prod`.** A manual run of `main` is
  break-glass like any other manual run and stops at `gamma`. The `prod`
  job's `if:` carries `github.event_name == 'push' && github.ref ==
  'refs/heads/main'` (rule R13). ⚠ GitHub compares strings IGNORING CASE, so
  that `if:` also passes for a branch named `MAIN`: it is defence in depth,
  not the lock. The locks are, in order: the `prod` environment's
  deployment branches (`main` only); a repository ruleset that refuses
  creating or updating any branch or tag that is `main` in another case
  (see [GitHub settings](#github-settings-the-release-relies-on)); and the
  `prod` job's third step, `only a push to main reaches this job`, which
  compares `GITHUB_EVENT_NAME` and `GITHUB_REF` byte for byte in shell (rule
  R19). At start-up under GitHub Actions kci refuses the same (exit 3,
  `KCI-E-NOT-ON-MAIN`): a run that is not a push to `refs/heads/main`, a ref
  that is `main` in another case (for every stage), a revision that is not
  the pushed commit (`GITHUB_SHA`), and one that is not on
  `refs/remotes/origin/main`'s history (asked by its FULL name: git resolves
  `origin/main` to a TAG of that name first, and `actions/checkout` with
  `fetch-depth: 0` fetches every tag). History git cannot read (a shallow
  clone, no `refs/remotes/origin/main`) is exit 5, never a pass.
- **The revision is checked by the workflow, before anything built from
  it.** Every release job starts with `actions/checkout` at `REVISION` and
  then the step `the revision this run releases` (rule R19, byte for byte):
  `REVISION` is a full commit id; on a push it is `GITHUB_SHA`; on a manual
  run it is on the history of `GITHUB_SHA` (the commit the run started on).
  On a run of `main` this file is `main`'s own, so a manual run of `main`
  whose `revision` input names an unmerged commit is refused there, before
  the farm-connect action, `./buck2` or `kci` (all of which are that
  revision's own code, and could leave any in-kci check out) run.
- **Queued runs: one release at a time, newest push wins.** A PUSH to `main`
  is in the concurrency group `kci-release-main` (rule R14 holds the group
  text byte for byte). A running release is never cancelled. GitHub keeps at
  most one PENDING run per group: a newer queued run cancels the pending one
  and takes its place (when it is QUEUED, before it runs anything), so the
  newest push wins and queued pushes coalesce. That is safe because `main`
  only moves forward: the newer push carries the older one's changes, and
  `prod`'s summary lists them (`carried to prod`: every first-parent commit
  of `main` after the channel's previous build of this version, so a run
  that was replaced, or never started, is reported by the run that released
  its commit). A run replaced while pending also shows as **cancelled** in
  the Actions list, with no summary. No manual run is in that group, so none
  can replace a pending release, whatever revision it names: a dry run is in
  `kci-plan-<run id>` (it writes nothing), any other manual run in
  `kci-ref-<ref name>`. A pull request's runs are one group per pull request
  (a newer push cancels the older check).
  - ⚠ **A RE-RUN of an old run of `main` is a push run** and joins
    `kci-release-main`: it can replace a pending release, and then releases
    an older revision (prod refuses it, `KCI-E-SUPERSEDED`, or answers
    NOOP). Never re-run an old run of `main` while a release is pending. If
    one did replace a pending push, re-run the newest cancelled run of
    `main`.
  - `prod`'s last step says when `main` has moved past what it released
    (`prod: main is at <tip>, past <revision>: a newer run is pending, or
    was replaced or cancelled; if none is queued, re-run the newest
    cancelled run of main`), counting only commits a push would release (not
    `docs/**` or `**.md`).
  - ⚠ **A push GitHub does not start a run for is not reported by itself.**
    GitHub's path filter reads at most the first 300 changed files of a
    push; when the files that matter are past them, the workflow may not
    run (GitHub's documentation, "workflow syntax", `paths`). So a large,
    mostly-documentation merge that also touches code can be skipped. The
    next push that does start a release carries it, and its `carried to
    prod` list names the commit; until then nothing says it waits.
- **Never backward.** `prod` refuses to publish a build number lower than one
  `komira-ai/prod` already lists for the same version (exit 3,
  `KCI-E-SUPERSEDED`, read anonymously from the channel's listing): only a
  late re-run of an old run reaches it, since the group serialises live
  runs. An equal build number is NOOP. Rolling back is a revert on `main`,
  released forward as the next build number.
- **The prod line.** Every release job ends with the step `the prod line`
  (`if: always()`, rule R18), which writes one plain line to the job summary
  and to the log: `prod: SKIPPED (<job> <status>: exit <n>)` when that job
  did not succeed, `prod: SKIPPED (nothing to release)`, `prod: SKIPPED
  (break-glass: a workflow_dispatch of <ref> reaches gamma only)`, or, from
  `validate`, `prod: NEXT (runs automatically; it waits only while the prod
  environment has a required reviewer)`. `prod`'s own `kci run` writes
  `promoted to prod: <names> <build>` or `promoted to prod: nothing new
  (<build> already there)` and the commits it carried; its last step writes
  `prod: FAILED (...)` when the job failed, and the `main is at ...` line
  above. Whether `prod` is paused is not read by any job (it would need
  `actions: read`, which no job holds); the environment's page says so.

### Pausing promotion to prod

**Pausing promotion to prod.** Settings -> Environments -> `prod` -> Required
reviewers: add a reviewer. Every prod job from then on waits for approval;
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
'gamma-breakglass' }}`), which has a REQUIRED REVIEWER, so every break-glass
publish waits for an approval that GitHub records with the run. The gamma
channel trusts `gamma-breakglass` as a second trusted publisher
(`break_glass_push_identity` in `release/channels.textproto`), and kci
publishes a break-glass run only from it (`KCI-E-STAGE-ENVIRONMENT`
otherwise). The input `reason` is required; it reaches kci only through each
job's `env:` (`--context reason=...`), never inside a `run:` script (rule
R16), and kci refuses a break-glass run without one, or with one over 200
bytes (exit 3, `KCI-E-BREAK-GLASS-REASON`), or whose revision is not on the
history of the commit the run started on. Every job's summary of such a run
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
makes, and the release is only as safe as they are.

| setting | value | what it locks |
|---|---|---|
| environment `prod`, deployment branches | Selected: `main` | only `main` publishes to prod (already set) |
| environment `gamma`, deployment branches | Selected: `main` | only `main` publishes to gamma without break-glass |
| environment `gamma-breakglass` | any branch, **required reviewer** | every break-glass publish waits for a recorded approval |
| prefix.dev `komira-ai/gamma`, trusted publishers | `komira-ai/komira`, `kci.yml`, environment `gamma`, AND a second one for environment `gamma-breakglass` | a break-glass run can publish to gamma at all (without it, every break-glass publish is refused by prefix.dev) |
| prefix.dev `komira-ai/prod`, trusted publisher | `komira-ai/komira`, `kci.yml`, environment `prod` only | (already set) |
| repository ruleset | block creating and updating branches and tags matching `[Mm][Aa][Ii][Nn]` except the branch `main`, and the tag `main` | no ref that is `main` in another case exists, so GitHub's case-insensitive `if:` and concurrency comparisons cannot be fooled by one (whether the environment branch rule `main` matches `MAIN` is undocumented) |

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
  machine file and every channels file it names (rules R1-R19 of
  `src/kci_ci_check/rules.mojo` and `auto_promotion.mojo`: a job per stage named for it, each job's
  environment its stage's, `needs` the jobs that run the stage's `after`,
  `id-token: write` only where a stage publishes by trusted publishing or is
  farm-connected, one `kci run` per job with `--summary-file`, `--only` only
  in a split stage whose jobs run all of it once (a validations-only job has
  no environment, no identity token, and needs the stage's own job), a
  `pull_request` trigger only the PULL_REQUEST stage's job answers (rule R6),
  the inputs `revision`, `reason` and `dry_run`, every `uses:` pinned,
  `farm-connect` exactly on farm-connected stages, and the auto-promotion
  rules above: the main-only conjunct, the one concurrency group, the push
  filter, the set hash handed on, the prod line, and a release job's
  permissions `contents: read` and `id-token` only). A mismatch is refused (exit 3, `KCI-E-WORKFLOW-MISMATCH`, every
  finding listed, nothing run); an unreadable workflow or channels file, or a
  missing variable, is exit 5 and never a pass. The same check is the welded
  test `src/kci_ci_check/tests/test_repo_kci_yml.mojo`, so a drift also
  fails `./buck2 build //...`. Consequence: a revision whose machine file
  disagrees with the running `kci.yml` cannot be released by it (a manual run
  of an old revision is refused, exit 3).
- **Triggers:** a push to `main` (not a documentation-only one) and a manual
  run (`workflow_dispatch`) release; a pull request to `main` runs the job
  `pr` and nothing else.
  Every release job's `if:` keeps a pull request out
  (a top-level `&&` conjunction with the term
  `github.event_name != 'pull_request'`;
  grouping, negation, a call or a partial `${{ }}` is refused), so
  no environment, publishing token or release job is reached from a pull
  request's code. The `pr` job's condition
  (`github.event.pull_request.head.repo.full_name == github.repository`)
  keeps a fork's code off the farm: a fork's run gets no tailnet credential,
  and a maintainer reads the change and pushes it to a branch here. Both
  conditions are written bare or as exactly `${{ <condition> }}`: a block
  scalar (`if: |`) holding `${{`, or whitespace inside quotes around it,
  makes GitHub read the `if:` as a format string, which is always true.
  The `pr` job runs on `runs-on: ubuntu-24.04`, written as that plain
  scalar: a fresh GitHub-hosted machine. A self-hosted label, a label list, a
  runner group, an expression (`${{ vars.X }}`, a fork-conditional) or a
  quoted value is refused, so a pull request's code never reaches a runner
  that keeps state between jobs.
  The push trigger is exactly `branches: [main]` with the documentation
  `paths-ignore` (rule R15): with no branch filter, another pattern,
  `branches-ignore` or `tags`, a push to a pull request's head branch would
  run the release jobs, and `github.event_name != 'pull_request'` holds for
  a push. The `pr` job has
  its own `permissions:` (`contents: read`, `id-token: write` for the
  tailnet only), so it never gets the workflow-level permissions or the
  repository's default token, and no stored secret reaches it: no value of
  that job, nor of the workflow-level `env:`, names the `secrets` context
  other than `secrets.GITHUB_TOKEN`.
  Rule R6 of `src/kci_ci_check` holds all of it.
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
- **Validations.** A publish step can declare a validation (`validation {
  kind: CONDA_INSTALL_SMOKE ... }`); gamma's is `install`. kci runs it after
  the step in a FULL run, or alone with `--only validation:install` against
  what is already published. In order, each failure exit 7
  (`VALIDATION_FAILED`, a row per finding in the result and the job summary),
  never a skip: (1) the pins: `release.json`'s version, build and sha256 of
  `komira_encoding` and `komira_all`, `metadata.json`'s payload sha256 and
  `mojo_pin`; (2) the channel, read from the runner ANONYMOUSLY: the index
  lists each file with the build's sha256 and the channel serves those bytes
  (only a file's absence, or a 404 index, is waited for, up to 600 s, then it
  fails; a 401 or another sha256 fails at once); (3) `docker run` of
  `ghcr.io/prefix-dev/pixi:0.67.2-bookworm-slim` pinned by digest, read-only,
  no capabilities, as the runner's uid, with only `HOME`, `PIXI_HOME`,
  `PIXI_CACHE_DIR` and `TMPDIR` set and one scratch mount: `pixi install` of
  the pinned packages from the channel and `mojo-compiler ==<mojo_pin>` from
  Modular's channel, then `mojo run` of
  [release/smoke/smoke_komira_encoding.mojo](../release/smoke/smoke_komira_encoding.mojo);
  (4) read back from the mount: every installed record has the release's
  version, build and sha256 and comes from a declared channel, the
  installed `.mojoc` is the build's, and the program printed
  `komira_encoding validation: N of N checks passed`, N > 0. Under `--plan`
  nothing runs (`WOULD_VALIDATE`). The same program is a `mojo_test` against
  the in-repository library, so an API change fails `./buck2 test //...`
  before it can fail a release.
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
  library `//src/<p>/...`, `repo_root` for `//:`, `tools_<t>` for each
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

To see the units a change would build, with nothing built:

```sh
kci run --stage pr --affected-by <base commit> --revision-id <HEAD> \
  --work-dir "$PWD" --log-dir <dir> --result-file <file> --plan
python3 release/ci/derive_checks.py --from release/artifacts.textproto  # the derived checks alone
```

### The workflow subset kci reads

kci holds a workflow to the machine file by reading it with its own reader
(`src/kci_ci_check/workflow_reader.mojo`), which accepts a strict subset of
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
is a row of `src/kci_ci_check/tests/test_workflow_subset.mojo`.

## merge-from-live (not yet running)

[`.github/workflows/merge_from_live.yml`](../.github/workflows/merge_from_live.yml)
is the planned weekly pull request bumping every pin (buck2, the toolchain
downloads, third-party archives) to its live release, merged only if its own
`ci` run is green. It is a stub: its script,
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
