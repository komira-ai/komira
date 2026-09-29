# Continuous integration

CI is one job, `build` in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
on a GitHub Actions runner that lives on the build farm. The runner is a thin
buck2 client: it checks the repository out and asks the farm to build it.
Nothing is compiled on the runner.

| event | runs |
|---|---|
| push to `main` | always |
| pull request from a branch of this repository | always |
| pull request from a fork | only after a maintainer approves the run ([below](#pull-requests-from-forks)) |
| manual (`workflow_dispatch`) | on the chosen ref |

There is no nightly run, and no separate static or lint job.

## What the job runs

```sh
./buck2 build //...
./buck2 test //...
tools/build/checks/run_checks.sh
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
     over every shell script, actionlint over the workflows, every `uses:`
     pinned to a commit SHA, and no remote-execution endpoint in a committed
     file. The lint of the scripts the Mojo and Rust rules run is reached
     through their toolchains, so no Mojo or Rust target builds while one of
     those scripts has a finding. The linters are pinned downloads, run on
     the farm like any other action.
2. **`./buck2 test //...`** runs the standalone tests (`mojo_test` and
   friends).
3. **[`tools/build/checks/run_checks.sh`](../tools/build/checks/README.md)**
   checks what no build action can observe: where actions ran, cache
   identity across checkouts, analysis-time refusals, a `buck2 run` from a
   fresh clone, targets that must fail by design, the lint coverage of the
   tree, and the `./buck2` bootstrap.

A contributor runs the same three commands. A green local
`./buck2 build //... && ./buck2 test //...` is what the first two steps of CI
prove.

There is no publish step yet. When release targets exist, publishing is a
step after these, on pushes to `main` only, of artifacts the same job built.

## The runner

- A container on the farm's Kubernetes cluster, registered to this
  repository only, with the labels `self-hosted` and `komira-farm`, running
  one job per container and discarding it afterwards (an ephemeral runner).
  Nothing from one job, including a fork's, survives into the next.
- It holds `git`, and what [`./buck2`](../buck2) needs: `sh`, `curl`, `zstd`
  and `sha256sum`. `run_checks.sh` still needs `python3` (the doc link check
  and a few JSON reads), `readelf` and `objdump`, and `docker` for the image
  run leg of the format check (skipped without it).
- The farm connection is **machine configuration**, not repository
  configuration: the runner image carries a machine-wide buckconfig (buck2
  reads `/etc/buckconfig.d/` and `~/.buckconfig.d/`) with the
  `[buck2_re_client]` endpoints and the `[komira_re]` worker property sets.
  The job reads no secret, writes no `.buckconfig.local` and names no GitHub
  Environment. Its logs are not redacted and are public, so the endpoints in
  that configuration must be addresses reachable only from inside the farm.
- Give CI its own remote-execution instance name, a sub-instance such as
  `<prefix>/ci`, so its action-cache entries are kept apart from developers'
  on a service that keys the cache by instance (Buildbarn does; a cache tier
  that ignores instance names, such as bazel-remote without
  `--enable_ac_key_instance_mangling`, does not).

## Pull requests from forks

Remote execution runs the commands a build describes, so running a pull
request's build is running its code on the farm's workers. A fork's pull
request therefore runs only after a maintainer approves that run:

- **Repository setting** (Settings > Actions > General > "Approval for
  running fork pull request workflows from contributors"): **Require approval
  for all external contributors**. GitHub then holds every run from a fork
  until someone with write access clicks "Approve and run" on the pull
  request's Checks tab.
- **Approving is a code review.** Read the whole change first, `.github/`,
  `tools/` and every `BUCK` and `.bzl` file included: the workflow, the
  rules and the lint scripts all run from the pull request's own tree.
  Approve again after each new push; GitHub asks for a fresh approval.
- The workflow uses `pull_request` only. There is no `pull_request_target`
  workflow here, on purpose: it runs with the base repository's token, and
  checking the fork's code out under it hands that token to the code.
- The job's token is read-only (`permissions: contents: read`) and the
  checkout does not keep it (`persist-credentials: false`).

## What farm access means

An action can run any command on a worker. On a typical Buildbarn
deployment, unless the service is hardened, that command runs with the
worker's privileges, on the worker's network, next to the shared storage: it
can write action-cache entries for any instance directly to storage, and
tamper with files a worker shares between actions. Denying action-cache
writes at the client-facing endpoint does not stop that, because the action
does not come through that endpoint. The runner living on the farm does not
change this; approval does, by deciding whose code runs.

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
tools/build/checks/run_checks.sh
```

The lints alone, without building the rest:

```sh
./buck2 build //:shell_lint //:workflow_lint //:action_pins //:no_endpoint
```

A failing lint prints `Validation for <target> failed:` and its findings.
