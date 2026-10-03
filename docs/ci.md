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

There is no nightly run, and no separate static or lint job.

## What the job runs

```sh
./buck2 build //...
./buck2 test //...
tools/build/tests/run_tests.sh
```

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
3. **[`tools/build/tests/run_tests.sh`](../tools/build/tests/README.md)**
   tests what a build of `//...` does not: where actions ran, cache
   identity across checkouts, analysis-time refusals, a `buck2 run` from a
   fresh clone, targets that must fail by design (the `tests` cell), and
   the `./buck2` bootstrap. It needs a Linux x86_64 client, and refuses any
   other (exit 2), because it runs binaries the farm built for Linux x86_64,
   and `readelf`/`objdump`, on the client.

A contributor on Linux x86_64 runs the same three commands; on another
client (macOS arm64) the first two. A green local
`./buck2 build //... && ./buck2 test //...` is what the first two steps of CI
prove, dead Markdown links included (`//:docs`).

There is no publish step yet. When release targets exist, publishing is a
step after these, on pushes to `main` only, of artifacts the same job built.

## The runner

A GitHub-hosted `ubuntu-24.04` virtual machine, fresh for every job, so nothing
from one job survives into the next. It holds `git`, and what
[`./buck2`](../buck2) needs: `sh`, `curl`, `zstd` and `sha256sum`.
`run_tests.sh` also needs `readelf` and `objdump`, and `docker` for the image
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
tools/build/tests/run_tests.sh
```

The lints alone, without building the rest:

```sh
./buck2 build //:shell_lint //:workflow_lint //:action_pins //:no_endpoint
```

A failing lint prints `Validation for <target> failed:` and its findings.
