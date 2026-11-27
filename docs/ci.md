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
| push to `main` | [`release.yml`](#releaseyml-the-release): builds the release set and publishes the mopm packages to the prod registry, on every push (no schedule, no switch); when that run ends, [`main_red.yml`](#main_redyml-the-main-red-alert). And, when the push changes more than documentation, the TestPyPI half of [`pypi.yml`](#pypiyml-publishing-the-python-package): builds the `komira` wheel on the farm, installs the wheel file on a fresh runner per supported Python, uploads it to TestPyPI, installs it from there per supported Python and runs the quickstart, and records the version when all of that passed. And, on the same pushes, [the macOS arm64 wheel in `pypi.yml`](#the-macos-arm64-wheel-in-pypiyml): the same for the macOS arm64 wheel of the same version, in jobs of the same run. And, on the same pushes, [`npm.yml`](#npmyml-publishing-the-npm-packages): builds the npm packages on the farm and runs their install test on each pinned Node.js, the macOS arm64 package's on the farm's macOS workers ([the macOS package in `npm.yml`](#the-macos-package-in-npmyml)); it publishes them only once `release/npm_publish.txt` says `publish: on`, which it does not yet |
| pull request from a branch of this repository | `pr / check`, whose [macOS part](#the-macos-part-of-the-check) builds the libraries of the macOS set the change reaches on the farm's Macs; and `coverage`, informational, not required ([below](#coverageyml-the-pull-requests-coverage-not-a-gate)) |
| merge group of the [merge queue](#the-merge-queue) (`merge_group`) | `pr / check` on the group's head commit, which is what `main` becomes; `coverage` does not run |
| pull request from a fork | nothing: no farm job runs ([below](#pull-requests-from-forks)) |
| manual (`workflow_dispatch`) | [`release.yml`](#releaseyml-the-release), on the chosen ref, with a reason |
| daily at 05:17 UTC (schedule) and manual (`workflow_dispatch`), on `main` | [the promotion of `pypi.yml`](#the-promotion): the newest version whose TestPyPI smoke passed, downloaded from TestPyPI and held to the sha256 its build recorded, is uploaded to PyPI and installed from there per supported Python; no build. At the same time, [the macOS wheel's promotion jobs in `pypi.yml`](#the-macos-arm64-wheel-in-pypiyml): the same for the macOS arm64 wheel, smoked on a hosted macOS runner |
| weekly (schedule) and manual | [`kpin-update.yml`](../tools/build/kpin/README.md#the-weekly-update): updates the pins and opens one pull request; no farm, and its pull request does not start `pr / check` by itself. A manual run with `real_hosts` instead checks kpin against the real registries |

There is no separate static or lint job, and no other pull request check
that can block a merge: the `coverage` workflow only reports. The scheduled
runs are the [build-system self-tests](#build-system-self-tests), which are not
the gate, the weekly [`kpin-update.yml`](../tools/build/kpin/README.md#the-weekly-update),
which opens a pull request and gates nothing, and the daily
[promotion of `pypi.yml`](#the-promotion), which publishes the newest Python
package that passed its TestPyPI smoke, each wheel (Linux, macOS) its own newest, and gates nothing.
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
2. **Waits for the farm to answer, and refuses to go on unless it does.** It
   opens a TCP connection to the farm's port, giving each try 5 s with 5 s
   between two, until one is accepted or `farm-wait-minutes` (20 by default,
   a whole number from 1 to 120) have passed since the first; the probe that
   starts at the bound is the last. A new node can take a few seconds to get
   its routes, and the connection between the runner and the farm can be lost
   for minutes at a time. Each minute without an answer prints
   `farm-connect: the farm has not answered for <N> min <M> s; waiting up to <W> min 0 s`
   in the job log. When the farm answers after the first try failed, the job
   summary gets `farm-connect: farm unreachable for <N> min <M> s; went on when it answered (probe <n>)`;
   when the bound passes, the job summary gets
   `farm-connect: farm unreachable for <N> min <M> s, the longest wait; not building`
   and the step fails. buck2 with no farm configured builds on the machine it
   runs on, so a job that cannot reach the farm must fail, not quietly build on
   the runner: the wait never falls back to a local build.
3. **Writes the farm's machine buckconfig**, `~/.buckconfig.d/farm.buckconfig`
   (buck2 reads `~/.buckconfig.d/` and `/etc/buckconfig.d/`): first
   `farm_wait_seconds` under `[komira_ci]`, the `farm-wait-minutes` input in
   seconds, which buck2 does not read and the
   [buck2-farm action](#running-a-buck2-command-on-the-farm) reads for its own
   wait; then the `[buck2_re_client]` addresses, instance name, `tls` and
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
   separated by `:` or spaces) writes `macos_library_dirs`; `darwin-config-file`
   (only with `darwin-properties`; an absolute path on the runner) writes those
   macOS keys to that file instead of the machine buckconfig, so only a command
   that names it with `--config-file` configures the macOS platform (`pr.yml`,
   [The macOS part of the check](#the-macos-part-of-the-check)); `tls`
   (`false` by default) and `tls-ca-certs`, the absolute path of a PEM CA file
   on the runner, only with `tls: true`, write `tls` and `tls_ca_certs`.
   A user buckconfig is read before the repository's own, so a key the
   repository's `.buckconfig` (or a file it includes) sets wins over the one
   written here.

Every input is checked before the tailnet is joined: an empty required
input, a value holding a line break, half of the macOS pair, a macOS set equal
to the linux one, a macOS config file without a macOS set, relative or holding
`$`, `tls` other than `true` or `false`, a CA file that is not
an absolute path to a readable file, and a `farm-wait-minutes` that is not a
whole number from 1 to 120 are refused. `//:farm_connect_cases` runs
those checks and the writer from `action.yml`'s own scripts and compares the
buckconfig written whole. It also reads every workflow and holds each step
that uses the action to `tls: ${{ vars.FARM_TLS || 'false' }}` under its
`with:`: a caller that dropped `tls` would connect in plain text whatever
`FARM_TLS` says.
It holds `farm-qos` to `batch` on every step of `release.yml`, `release-macos.yml`, `pypi.yml` and `npm.yml`
and to absent on every step of any other workflow.

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
| `FARM_DARWIN_ARM64_PROPERTIES`, `FARM_DARWIN_MACOS_HOSTS`, `FARM_MACOS_LIBRARY_DIRS` | the macOS arm64 worker property set, the host identities of those workers, and the directories a macOS test run searches for a library (the last is optional): the `darwin-properties`, `darwin-macos-hosts` and `macos-library-dirs` inputs, passed by the job `release-macos` of `release-macos.yml`, by the job `build-macos-arm64` of `pypi.yml`, by the job `build-macos-arm64` of `npm.yml` and by the job `check` of `pr.yml` (which also passes `darwin-config-file`, so that only its step `build for macOS` sees them: [The macOS part of the check](#the-macos-part-of-the-check)), and by the job `mopm-stage` of `release.yml` (which also passes `darwin-config-file`, so that only its step `build the packages`, the build of `//release:mopm_release_artifacts`, sees them: [the mopm jobs](#the-mopm-jobs)), and by no other job |
| `FARM_TLS` | `true` when the service serves REAPI over TLS; unset or empty means `false`. Each workflow passes it as farm-connect's `tls`, so the address and its transport change together |

Variables are not masked, and a job's logs are public. The action masks the
address, and the address is one reachable only from inside the tailnet, so
printing it would still disclose nothing usable. `//:no_endpoint` keeps an
endpoint out of every committed buckconfig, workflow and local action.

The connection is checked on every farm-connected run: the action's
`refuse unless the farm answers` step fails the job before any build when the
farm's port does not answer within `farm-wait-minutes`. The cases of that wait
(`.github/actions/farm-connect/probe_test.zig`, part of `//:farm_connect_cases`)
run the step's own script on a clock of their own, so none sleeps or touches
the network.

**Priority.** A farm that queues by priority class runs a `ci` action before a
`batch` one. The action takes an optional `farm-qos` (`ci` or `batch`) and, when
it is set, writes the request header `x-kbf-qos` as buck2's `http_headers`.
Every job of `release.yml` passes `batch`, and so do the job `build` of `pypi.yml`, the job `build-macos-arm64` of `pypi.yml`, the jobs `build`, `test` and `build-macos-arm64` of `npm.yml` and the job `release-macos` of `release-macos.yml`, so the release work that a push to
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
The program is `./buck2` unless the action's `buck2` input names another, so
a repository that installs its own pinned buck2 can run its farm builds
through the same action, with the machine buckconfig farm-connect writes.

When the connection between the runner and the farm is cut, buck2 fails every
action in flight at once, each with its own `Error:` line holding
`RE channel error: code:`. `assert_remote run`
([`farm_retry.zig`](../tools/build/ci/assert_remote/farm_retry.zig)) then runs
the same command again, when every failure in the output is such a cut:
each failed action (`Action failed:`) or test (`✗ Fail:`) has that line among
buck2's own lines before its output, no test timed out or was fatal, and no
other error stands outside them. A test whose run was cut before it started
gets buck2's lines as its output instead: an empty stdout, and a stderr of only
`Remote Execution Error on Execute with digest ...` with that line right after
it. That output, with nothing else in it but empty lines around the two, is a
cut too. A log that mixes a real failure with cuts, a test whose output quotes
the phrase among output of its own, a buck2 ended by a signal, and a subcommand
other than build, test or bxl are never run again.

The farm's refusal to start a job because an input the job named could not be
read on the host it was placed on is run again the same way. The farm settles
it as an infrastructure failure for the client to run again, and buck2 prints
it in the place of the channel error, word for word
`Error: (Error was returned on the stream by RE: the job failed to start: input-unavailable)`.
A block with that line, or a test whose stderr has it right after the
`Remote Execution Error on Execute` line, counts as the farm's failure just as
a cut does, and a log may mix the two. Any other reason the farm gives for not
starting a job (such as `input-not-allowed`) is final. The job summary line
then names the cause: ``had jobs the farm failed to start (the farm's `input-unavailable` in each of 2 failed block(s))``,
or both causes with a count for each.

Before it runs again, the tool waits for the farm
([`farm_wait.zig`](../tools/build/ci/assert_remote/farm_wait.zig)): the same
probe as farm-connect's (a TCP connection to the farm's port, 5 s for each try,
5 s between two, a line in the job log each minute without an answer), bounded
by the same input. Both come from the machine buckconfig farm-connect wrote,
which the action names as `--farm-config "$HOME/.buckconfig.d/farm.buckconfig"`:
the farm is buck2's own `engine_address`, and the bound is
`farm_wait_seconds` under `[komira_ci]`. When a run is to be run again, a
missing file, or one with no address or no bound, fails the step with exit 2
and the reason, and nothing runs again.

- **The farm answers.** The failed run's output is kept beside the log as
  `buck2-farm.first.log` (`buck2-farm.second.log` after the second run), and
  the job summary gets one line naming the wait, such as
  ``buck2-farm: the first run of `build` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 4 failed block(s)); farm unreachable for 3 min 10 s; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log``
  (`the farm answered at once` when the first probe answered). Then the same
  command runs again.
- **The bound passes first.** The job summary gets
  `...; farm unreachable for <N> min <M> s, the longest wait; not run again`,
  the failed run's log stays in place (later steps that read the log, such as
  `release-macos.yml`'s report, read it), and the step fails with buck2's code.

A step runs at most three times: a third run that fails on the farm too (cut,
or with a job the farm failed to start) fails the step, saying so. The wait reports itself and never hides an outage: each wait is a
line in the job summary, unlike a longer client timeout, which would hide it
(komira-ai/komira#2269). Three runs, not two, because a lost connection can
come back for a few minutes and drop again, and a second run cut that way
otherwise ends a long check that needed a hand re-run. What it costs in runner
minutes: each wait is at most `farm-wait-minutes` (20 by default) of an idle
runner, and each run again redoes only what the action cache does not hold
(the actions cut in flight and those not yet started), so the most a step
adds is two waits, 40 minutes by default, and two partial reruns; every step's
own `timeout-minutes` still bounds the whole. The other choice, a second run
that stays final, costs nothing more in a step, and a whole job's hand re-run
each time an outage cut it twice. The release workflows' publish and upload
steps are not buck2-farm steps, so this never runs one of them twice; a
publish cut half way stays a failed step.

#### A run that hangs on a dead connection

A cut connection does not always fail buck2. When the path between the runner
and the farm drops for a while, the farm closes the connection, and its closing
never reaches the runner: buck2 keeps waiting on an action in `[re_execute]`
over a TCP connection the farm no longer has. Nothing arrives on it, buck2
sends nothing on it, and its own HTTP/2 keepalive does not end it; two runs of
`pr / check` sat so for two hours and for 3 h 40 min, printing the same
`Waiting on ... [re_execute]` line every few seconds, while the farm had
nothing queued or running for them (komira-ai/komira#2438).

So while a run runs, `assert_remote run` keeps a watchdog on the connection
([`farm_watchdog.zig`](../tools/build/ci/assert_remote/farm_watchdog.zig)).
Once a second it asks the kernel (netlink sock_diag, what `ss -ti` reads) for
the runner's established TCP connections to the farm's address and port (the
`engine_address` of the same machine buckconfig) and, for each, how long ago it
last received anything from the farm: the shorter of `tcp_info`'s
`last_data_recv` and `last_ack_recv`, the measure the kernel's own TCP
keepalive uses, counted from the run's start at the earliest, so a connection
buck2's daemon kept idle from an earlier step is judged only by what it hears
in this run. It never reads the log: a remote action that runs for an hour
and prints nothing is normal.

The bound comes from what a live farm does on every connection. The farm server
(komira-ai/kbf) sends each open Execute stream its operation again every 30 s
(`--progress-interval-secs`), PINGs a connection that has been quiet for 30 s
(`--http2-keepalive-interval-secs`), and its kernel acknowledges any byte buck2
sends; it closes a connection that has moved nothing for 30 s plus 120 s
(`--http2-keepalive-timeout-secs`). Those are the server's defaults, read from
its source, not measured on the farm. So on a live connection the longest
silence is about 30 s however slow the build, and a connection silent for more
than 150 s is one the farm has already closed. The watchdog's bound is twice
that, **300 s**. The machine buckconfig can set another as
`dead_connection_seconds` under `[komira_ci]` (whole seconds, at least 1; the
action's cases set 2 s); farm-connect does not write it, so CI runs with 300 s.

When a connection has been silent past the bound, the job log gets, at that
moment,

    buck2-farm: watchdog: the connection to the farm from local port 41022 has heard nothing from the farm for 5 min 1 s, past the bound of 5 min 0 s: the farm has closed it and buck2 would wait on it for ever; ending buck2 (SIGINT)
    buck2-farm: stopping buck2's daemon, which holds the dead connection (`./buck2 kill`)

buck2 is sent SIGINT, as a Ctrl-C, and SIGKILL if it has not ended once the
bound has passed again, at most 10 s later (a line says so); then `./buck2 kill` stops its daemon, which holds the dead
connection and the lost action, so the next run starts with a new one. From
there the run is treated as a cut: the same wait for the farm, its log kept as
`buck2-farm.first.log`, one line in the job summary,

    buck2-farm: the first run of `build` hung on a dead connection to the farm (nothing heard for 5 min 1 s, past the watchdog's bound of 5 min 0 s), so buck2 and its daemon were ended; the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log

and the same bound of three runs: a third run that hangs too fails the step
with `the third run hung on a dead connection to the farm too`. A subcommand
other than build, test or bxl is ended the same way and not run again. A step
that hangs now costs about five minutes and a run again instead of its whole
`timeout-minutes`. Without a readable machine buckconfig, or when the kernel
cannot be asked, the step says so in one line (`no watchdog on the connection to
the farm: ...`, `watchdog stopped: ...`) and runs as it would without one.

Behind the watchdog, every step of `pr / check` has a `timeout-minutes` of its
own, so anything else that hangs ends at its step's bound, never at the job's
330 minutes: 5 or 10 for a step that builds nothing, 30 for farm-connect and
for a buck2 step whose longest run in 35 green checks took under a minute, 45
for the three whose longest took 5 to 6 minutes, and build, test and the macOS
build keep 150, 90 and 60 (`//:buck2_farm_cases` holds every step to a bound
under the job's).

#### What the step checks after buck2

The tool step fails when a `Commands:` summary line says `local:` anything
but `0`, when the log ends a failed run (`BUILD FAILED`, `BXL FAILED`), or when
there is no summary line although the run used the network. A run that executed
no action (everything cached, or a query-only bxl script) prints no summary line
at all, only `Network: up 0B  down 0B`, and passes on that line. `build` and
`bxl` print the same summary. The caller builds the tool first, on the farm, and passes
its path as `assert-remote`. That build, and the few other `./buck2` steps
that do not go through the action (pr.yml's build of its change tool, for
one), are not run again: a cut during one of them still fails its step. The cases are recorded buck2 output
(`//tools/build/ci:assert_remote_unit`, `//tools/build/ci:farm_retry_unit`, which also
runs the wait on a fake clock and a fake farm; `//tools/build/ci:farm_watchdog_unit`,
the watchdog's judgement over given times and the kernel's answer built byte by byte)
and the action's own two lines run over it (`//:buck2_farm_cases`), each case with a
farm on a loopback port of its own that answers at once or never answers (with a bound
of 0 s, so no case sleeps), and for the watchdog's cases a fake farm on that port that
takes the request and then goes silent, or sends a byte every 25 ms, with a bound of 2 s.

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

## The macOS part of the check

`pr / check` builds the libraries of the macOS set (`//release:mopm_darwin_libs`) that the change
reaches, for darwin-arm64, on the farm's macOS workers, after its Linux part and under the same check
name, for a pull request and for a merge group alike. Building a library runs its package's welded tests
on a Mac. This is the one macOS build before the merge; the release workflows below build the whole set
and the macOS wheel after it.

- **What it builds.** The step `select the macOS targets` runs
  [`tools/build/ci/darwin.bxl:select`](../tools/build/ci/darwin.bxl) over the list the selector printed
  (`targets.txt`); [`darwin.bzl`](../tools/build/ci/darwin.bzl) says what it picks. When the change is
  built as the aggregate (`//ci:pr` or `//ci:pr_default`: it touches the build system, or a file the
  selector cannot map), the whole set. Otherwise the `:lib` of each package of the set the change
  reaches (`DARWIN_PACKAGES` of [`release/darwin_libs.bzl`](../release/darwin_libs.bzl), the list
  `release-macos.yml` builds, so the two never disagree); the `:lib` of each package it depends on is
  built first. A change that reaches none skips the build. A line of `targets.txt` that is not a target
  label fails the step, so a selector whose output changed shape never reads as "nothing to build". No
  standalone test (`mojo_test`) is run for macOS, and the macOS wheel and the Python harness tests stay in
  their release workflows. The step `the macOS targets to build` runs
  [`//tools/build/ci:darwin_targets`](../tools/build/ci/darwin_targets/darwin_targets.zig) over the
  selection's log: it writes the labels to `darwin_targets.txt` and sets the step output `any` when there
  is one, and it fails when the log holds no verdict of the selection, or a verdict that disagrees with
  the labels. The cases are in `cases.bxl` (`darwin_cases.bzl`, including what the command prints and
  whether it fails) and in `//tools/build/ci:darwin_targets_unit` and `:darwin_targets_cli_cases`, over
  recorded runs of `darwin.bxl:select`; the self-test scenario `//tools/build/selftest:darwin_select` runs
  the command itself, as pr.yml does, over five lists, and checks its exit status, stdout and verdict.
- **Only that step sees the Macs.** `farm-connect` gets the macOS worker set and
  `darwin-config-file: ${{ runner.temp }}/darwin.buckconfig`: the macOS keys go to that file and not to
  the machine buckconfig, and the step `build for macOS` names it with `--config-file`. Every other step
  configures no macOS platform, exactly as before the macOS part existed. Registering the platform for the
  whole job would change what the Linux part's checks see: `cases.bxl` configures every adopted library
  for darwin-arm64 when that platform is registered, and `//src/crypto:crypto` reaches
  `//third_party/aws-lc:crypto_prefixed`, which is x86_64 only. The build runs through the `buck2-farm`
  action, which fails the step when an action ran on the runner.
- **The Linux part never waits on a Mac.** The macOS part runs after the step `test` and before the
  analysis of the set; it is skipped when an earlier step failed, so a red check takes no Mac time. Its
  actions queue at priority `ci` (`pr.yml` passes no `farm-qos`), ahead of the `batch` actions of
  `release-macos.yml`.
- **Pending while the Macs are busy, for at most 60 minutes.** When every Mac slot is taken the farm
  queues the actions and the step waits: `pr / check` is in progress (pending), not failed. The step's
  `timeout-minutes: 60` bounds that: past it the step fails and the check is red, which takes a queued
  pull request out of the merge queue (it is queued again after a re-run). So the macOS part holds a merge
  at most 60 minutes past the Linux part, and never past the job's own bound of 330 minutes, which ends
  the check red before the queue's 360. The bounds of the three long steps add up to 300 minutes (build
  150, test 90, macOS 60); the other steps are seconds each.
- **How much it costs.** Measured on the farm (four Mac Studios, 32 cores each, 27 of them booked per Mac
  by the farm's pool: 108 Mac action slots), with `./buck2 build --target-platforms
  komira//tools/build/platforms:darwin-arm64` from a checkout of `main`:

  | what was built | libraries | Commands | time |
  |---|---|---|---|
  | the whole set, nothing changed since `main` was built | 66 (the set) | `573 (cached: 573, remote: 0, local: 0)` | 2 s |
  | a comment added to `src/atomic_alias` (its library's output does not change) | 16 | `1350 (cached: 1349, remote: 1, local: 0)` | 16 s |
  | a function added to `src/encoding` (its library and the 16 that depend on it rebuild and rerun their tests) | 17 | `179 (cached: 0, remote: 179, local: 0)` | 8 min 32 s |
  | the whole set, half of it new (`release-macos.yml`, run 45247838989, step `build the macOS set`) | 66 | `1957 (cached: 936, remote: 1021, local: 0)` | 13 min 43 s |

  The load: `pr.yml` ran 587 times from 2026-11-15 to 2026-11-23, at most 13 at once and 2 to 3 at once
  in a typical minute when any ran (the runs' start and end times, from the Actions API). The limit is a
  whole-set build whose actions are new, such as a change to the Mojo rules or toolchains: one takes the
  Macs about 14 minutes, and checks of different commits do not share its actions, so about four of them
  at once reach the 60-minute bound (inferred from the measures above, not measured). A change under
  `tools/build/` that leaves every Mac action's inputs as they were builds the whole set from the cache, in
  seconds.

## The macOS build of the release

The release workflows build macOS after the merge. There are two. The macOS
(darwin-arm64) set of the mopm packages is its own workflow,
[`release-macos.yml`](../.github/workflows/release-macos.yml) (one job, `release-macos`), once per release.
The other is the macOS arm64 wheel of the Python package: the job `build-macos-arm64` of
[`pypi.yml`](../.github/workflows/pypi.yml), at most once per version and only when that
version's macOS file is missing from TestPyPI
([below](#the-macos-arm64-wheel-in-pypiyml)). `release.yml` holds no macOS job, and its job
`mopm-stage` builds the macOS set again as the osx-arm64 half of the packages it publishes, in the same
configuration, so it finds this workflow's actions in the cache ([the mopm jobs](#the-mopm-jobs)). Before the
merge, only [the macOS part of the check](#the-macos-part-of-the-check) builds for macOS: the libraries of
the set the change reaches. A merge group's check builds them for the commit `main` becomes, so the build
of the set in `release-macos.yml` finds those actions in the cache; it still builds the whole set, since a
commit can reach `main` without a merge group (a manual run builds the chosen ref), and the Python harness
tests, which no pull request builds. The rest of this section is about `release-macos.yml`.

- **No other macOS build in a pull request.** `coverage.yml`, the other workflow that runs on a pull
  request, passes no macOS worker set and names no darwin platform or runner, and `pr.yml` names them
  only in its macOS part and in the analysis below. `//ci:pr` is built for the client's own platform
  only: none of the targets it reaches has a macOS execution platform. A
  `cquery` of `attrregexfilter(exec_compatible_with, "macos", deps(//ci:pr))` is
  empty, and the same query for `--target-platforms
  komira//tools/build/platforms:darwin-arm64` over a library is not.
  `//:release_macos_cases` holds the workflows and the root files of `ci/` (`ci/roots/`, `ci/test_roots/`) to it (the lines of
  `pr.yml`'s macOS part, `PR_MACOS_PART`, exactly as written, and where each stands), and holds
  `pypi.yml` (the macOS wheel's jobs are in it) to not running on a pull request or a merge group. The five targets of the macOS wheel
  (`//python:komira_wheel_macos_arm64`, `//python:wheel_install_test_macos_arm64`,
  `//python:wheel_libs_macos_arm64`, `//python:wheel_same_macos_arm64`,
  `//python/smoke:pypi_smoke_macos_arm64`) and the pinned macOS pyarrow and protobuf wheels its install test reads
  (`//python/tests:pyarrow-25.0.1-cp313-cp313-macosx_12_0_arm64.whl`,
  `//python/tests:protobuf-7.36.2-cp310-abi3-macosx_10_9_universal2.whl`) stay out of the check twice: each has an `EXCLUDED` row in
  `tools/build/ci/rules.bzl`, so the pull-request selector never picks it, and each has
  `target_compatible_with = DARWIN_ARM64` (limit `pypi-wheel-macos-arm64` in
  `tools/build/platforms/limits.tsv`), so it builds only with `--target-platforms
  komira//tools/build/platforms:darwin-arm64`, which only the macOS jobs of `pypi.yml` pass.
- **Analysed in every pull request.** What fails before anything is built
  (a target of the set's closure incompatible with darwin-arm64, a toolchain with no
  execution platform, a rule that fails at analysis) is found in the pull request that
  causes it, even when the change reaches no library of the set: the last buck2 step of `pr.yml` runs
  `bxl --config-file release/darwin_analysis.buckconfig komira//release/darwin_analysis.bxl:check`,
  which configures `//release:mopm_darwin_libs` and the macOS Python harness tests
  (`DARWIN_PYTHON_HARNESS` of `release/darwin_libs.bzl`, the targets of the workflow's second build
  step) for darwin-arm64 and analyses them, with their whole closure, as the release's build would,
  and so the macOS npm targets of `npm.yml`'s macOS job (`DARWIN_NPM`, the macOS package and its install
  test, and `//release:npm_packages_macos_arm64`, for Linux, whose transition configures the macOS package).
  It also refuses a Zig tool that an action of the closure runs and that is built for another
  platform than the one the action runs on (`release/exec_tools.bzl`): a Linux tool configured for
  the macOS execution platform analyses fine and fails only on the worker, with "cannot execute
  binary file". Configuring and analysing run no action, so
  nothing is built for macOS and no macOS worker is asked for anything; the config file
  registers the macOS execution platform with a property set that names no worker, which
  configuration needs and nothing uses. The step fails with buck2's own message (or, for a
  Zig tool built for the wrong platform, with the tool, its triple and its platform), naming the
  target and the dependency. A failure that only a build shows (a compile, a welded test)
  is seen by the macOS part, for the libraries the change reaches. `//:release_macos_cases` holds that this
  step is in `pr.yml` once, through the `buck2-farm` action with its assertion, that it and the
  lines of `pr.yml`'s macOS part are the only lines of a pull request workflow that name the macOS
  set, and that the workflow's harness step builds exactly `DARWIN_PYTHON_HARNESS`.
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
  never cancelled. Here a newer push cancels the running macOS build and starts its own,
  and this workflow never queues a release; the macOS build inside `release.yml`, the
  osx-arm64 half of the packages it publishes, does (below, "The publish waits on macOS"). The trigger is
  `push` plus `workflow_dispatch` rather than `workflow_run` after `release.yml`: it
  needs no ordering with the release (nothing waits on it), and `workflow_run` would
  start it only after the whole release finished, build the default branch's head
  instead of the pushed commit, and run for a pull request's `release.yml` run too if
  that ever changed. `timeout-minutes: 90` still bounds a stalled build, and the steps that
  wait on the farm have bounds of their own inside it (farm-connect 5 minutes, the macOS set
  65, the Python harness tests 10):
  a step past its bound fails, so the run ends failed, where a job past its `timeout-minutes`
  is cancelled and GitHub ends its run cancelled.
- **Reported, not blocking (for now).** A red macOS build is a failed run of
  `release-macos.yml`, with a line in its summary, and the release run, the prod publish and
  `main_red.yml` do not see it: none of them `needs` it or reads its result. The job is not
  `continue-on-error`, which would end a failed build green. The last job,
  `release-macos-result` (`needs: release-macos`, `if: ${{ !cancelled() }}`), fails with "the macOS build
  did not run" when the build job was skipped, and with "did not pass" when it failed, so the
  run list, the commit status and the badge never read green for a Mac build that did not
  pass. A build job that ran out its `timeout-minutes` is cancelled by GitHub while the run
  goes on, so `release-macos-result` runs and fails with "the macOS build was cancelled while
  the run went on" (the run itself still reads cancelled, which is why the farm steps carry
  their own bounds). Only when the run itself was cancelled (a newer push, or by hand) does
  `release-macos-result` not run: the run ends cancelled and the newer run builds.
  Its message says what happened rather than guessing: when a buck2 step failed (the build
  of the set, or of the Python harness tests), `//release/ci:buck2_failure` (built before them)
  reads that step's buck2 output and the message is buck2's own lines after `BUILD FAILED`
  (also written to the run's summary);
  when an earlier step failed, the message names it. The farm connection refuses when a
  repository variable is empty (for the macOS set, `FARM_DARWIN_ARM64_PROPERTIES` and
  `FARM_DARWIN_MACOS_HOSTS` go together), and that is a failed run too.
- **The publish waits on macOS.** The set was green on the runs of this workflow before the
  release shipped osx-arm64, and the release now ships it: `release.yml`'s `mopm-stage` builds
  `//release:mopm_release_artifacts`, whose osx-arm64 half is this set (with each package's native
  archives) configured for darwin-arm64, so a macOS build that does not pass fails `mopm-stage`,
  nothing is staged in prod for either platform, and `main_red.yml` sees a failed release. This
  workflow is unchanged and still reported, not blocking: it builds the Python harness tests too,
  and its own red run says which step failed. The cost is the one the separate workflow avoided: a
  stalled Mac build now holds the release, bounded by `mopm-stage`'s `timeout-minutes: 120`.

### Proposed: the macOS build of every `//src` library

Not built yet. `//release:mopm_darwin_libs` covers the mopm packages only. Most of `//src` is
not a mopm package, so a change that breaks one of those libraries on macOS is seen by nobody.
Measured: a `uquery` of `kind(...)` for the library rules (`mojo_library`, gated, shared,
system, native and `cxx_library`) over the `src` directory lists 425 targets. One `build --target-platforms komira//tools/build/platforms:darwin-arm64
--keep-going --skip-incompatible-targets` of that list on the farm, on main after the `http_core`
macOS test fixes and the Mach-O native shared library (`Commands: 18849 (cached: 16445, remote:
2404, local: 0)`), built 405, skipped 4 as incompatible (the connect, git pack, git protocol and
HTTP conformance suites) and stopped on 16. With the fixes below the same build builds 415, skips
7 and stops on 3. A target is counted under the first failing action its build report names:

| Cause | Targets on main | After the fixes | Issue |
| --- | --- | --- | --- |
| the mail servers' serve-loop tests moved the clock before the peer's bytes had reached the server, and stepped a fixed number of times; macOS loopback can deliver after the send returns. Fixed: they wait, with `poll`, for the bytes to arrive | 3 (`smtp_server`, `imap_server`, `smtp_client`) | 0 | |
| `db_postgres`'s TLS handshake test alternated 256 busy rounds over TCP loopback. Fixed: a side blocked on read waits in `poll` | 2 (`db_postgres`, `komira_db_conformance`) | 0 | |
| `job_supervisor`'s tests started `/bin/true`, which macOS keeps in `/usr/bin`. Fixed: they start `/bin/sh -c "exit 0"` | 2 (`job_supervisor`, `komira_job_supervisor_loopback`) | 0 | |
| on macOS `//third_party/aws-lc:crypto` re-exports `//src/awslc`'s archive and had no `[static-pic]` for `native_shared_library`, and `komira_crypto_native` listed ELF-only weak names. Fixed: `checked_cxx_library` takes that archive (`archive`) and the weak list is per OS | 2 (`komira_crypto_native`, `komira_http_core_native`) | 0 | |
| the per-CPU-level links of `libkomira` failed analysis instead of being skipped. Fixed: they are linux-x86_64 only (`komira-limit:isa-variants-linux-x86-64`) | 2 | 0 (skipped) | |
| `phase_timers` counted a usage sample that macOS cannot take (no per-thread `getrusage`) as a dropped record | 1 (`bench_q6_phases`) | 0 | |
| `komira_test_s3_adapter`'s runner starts MinIO through setpriv and `PR_SET_PDEATHSIG` and refuses every start elsewhere. It is Linux only, with its two end-to-end binaries (`komira-limit:s3-adapter-runner-linux`) | 1 | 0 (skipped) | |
| `cbrt` answers one ulp from the expected ones, which come from the Linux DuckDB (`decimal_compare` conformance) | 1 | 1 | komira-ai/komira#2233 |
| the UDF spike helpers' welded tests: the native runtime has no macOS rule for loading a verified library, and the node worker's tests need a darwin-arm64 `node` | 2 (`komira_udf_spike_native`, `komira_udf_spike_node_worker`) | 2 | komira-ai/komira#2199 |

Fixed by the sweeps before this one: tests that assumed Linux's `PATH_MAX`, a `SIGPIPE` that macOS
raises for the whole process, BSD `yes`, the epoll backend, the `libc.so.6` name, a temporary-file
name that two threads could draw alike on macOS's coarser clock, an NFD file name that APFS treats
as the same file as its NFC form, `bench_data`'s Snappy digests (komira-ai/komira#2208),
`phase_timers`' fork stamp (komira-ai/komira#2200), `http_core`'s s2n shim reset and partial-send
tests (komira-ai/komira#2206, komira-ai/komira#2207), the ELF-only native shared library
(komira-ai/komira#2197) and the UDF spike helpers' C (`probe.c`, `channel.c`, `engine_loop.c`).

The proposal keeps this set built, in the same way as the mopm set:

- **One named target, generated.** `//release:darwin_src_libs` is a generated list, like the
  root files of `ci/`, with a guard that fails when the list is stale. It holds every
  library target of `//src` except a `DARWIN_SRC_EXCLUDED` table. Each row of that table names
  a target and the issue above that keeps it out. A row is deleted in the pull request that
  closes its issue. When a new library is added under `//src`, it joins the set when the list
  is regenerated, with no second edit. No step names a pattern target. `//ci:pr`
  leaves the target out (`EXCLUDED` of `tools/build/ci/rules.bzl`), as it does
  `mopm_darwin_libs`.
- **After merge, on main, through the farm.** A second build step in `release-macos.yml`,
  after the mopm set:
  `build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going //release:darwin_src_libs`.
  It runs through the `buck2-farm` action and its assertion, so the summary reads `local: 0`.
  It has the same triggers, concurrency group and `farm-qos: batch` as the job above. It is
  never in a pull request.
- **Reported, not blocking.** `release-macos-result` reports it the way it reports the mopm
  set, and nothing in `release.yml` waits on it. It becomes blocking with the mopm set, once
  it has been green over several runs.

How it fits with the pull request side. No macOS build runs in a pull request. In a pull
request, macOS is only analysed, by the `darwin_analysis.bxl` step above, which builds nothing.
That step can analyse `//release:darwin_src_libs` as well as the mopm set, so a dependency that
is incompatible with darwin-arm64 is caught in the pull request that adds it, under the same
exclusion table. What only a build shows (a compile, a welded test) is caught by this job after
merge. So are the changes no selection reaches: a toolchain change, a change to the Mac hosts,
or a change outside `src` that breaks a library no pull request touched.

## release.yml: the release

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds the
conda packages that `release/artifacts.textproto` declares, as one release set,
with Buck2 targets on the farm. It is written by hand. It holds no job of the Python wheel: `pypi.yml`
builds and installs that on every push that changes code
([below](#pypiyml-publishing-the-python-package)). Nor of the npm packages: `npm.yml` builds and tests
them, the macOS one on the farm's macOS workers ([below](#npmyml-publishing-the-npm-packages)).
**The release set itself publishes to no channel**: the job `release` builds the
set, so a push to `main` still proves the release builds, keeps what it built as
a workflow artifact, and holds no publishing credential and no channel. The
libraries moved to mopm are published by mopm's own jobs: to beta and then to prod, continuously,
on every push to `main` ([below](#the-mopm-jobs); see [releases](releases.md)). Its job
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
publish to beta or prod at once (both would stage against the registry's current state). GitHub keeps at
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
source is deleted. Their names stay reserved on the prod registry (`release/prod_claimed_names.txt`) as global
(flat) names: the prune of the flat names kept them, and prod has no `komira-ai/kci_*` package.

### The mopm jobs

The libraries moved to mopm (every `src/<name>` that has a `mopm.toml`, built
with buildrules' `mojo_package`, which gives each a `:lib` and a `:conda`) go
to the mopm registries `beta` and then `prod`, each as one group, apart from the release set,
**continuously: every push to `main` publishes**. The steps are **build, stage, try, publish to beta,
publish to prod**, and each publish is itself three steps (stage, test, commit). Prod starts only when
beta committed. There is no schedule and no variable that switches either publish on or off. The list is
[`packages.bzl`](../release/readme_e2e/packages.bzl), which
`//:readme_e2e_complete` holds to the `src/` directories that have a
`mopm.toml`, in both directions. Each package is published for two platforms, linux-64 and
osx-arm64, in the same group and at the same version: a member of the plan has one `.conda` per
platform. [`//release:mopm_artifacts`](../release/mopm_artifacts.bzl)
builds each package's `:lib` (the `.mojoc`, which exists only once the tests
passed) into `linux-64/komira-ai/<name>.mojoc`, and each declared native's
archive into `linux-64/komira-ai/<name>.native/lib<id>.a`;
[`//release:mopm_darwin_libs`](../release/darwin_libs.bzl) does the same under `osx-arm64/`, built
for darwin-arm64; and `//release:mopm_release_artifacts` merges the two into one directory (its rule
configures the macOS half for darwin-arm64 through a transition, so one build of it, for Linux,
builds both). That is the layout mopm reads, which requires the namespace directory: `mopm stage`
packs one `.conda` per subdir that holds a member's library, and refuses a member that declares a
native with no archive for one of them. Thirteen jobs of `release.yml` carry the
steps (a documentation-only push does not start the workflow, so it publishes nothing):

| job | when | what it does |
|---|---|---|
| `mopm-stage` | every push to `main`, and a manual run (which sends nothing either) | on the farm (environment `build`, the farm's tailnet token only; it reads no registry token). **Build:** the one mopm the README e2e installs with (`toolchains//:mopm_0_0_138`, `MOPM` of `packages.bzl`) and `//release:mopm_release_artifacts`, the packages of both platforms: its osx-arm64 half compiles and runs its welded tests on the farm's macOS workers. The job's farm connection writes the macOS keys to a buckconfig of their own (`darwin-config-file`), which this build alone names with `--config-file`, so no other step of the job configures a macOS platform; it also passes `-c komira_release.mac_tree=true`, without which the target is incompatible (release/BUCK, limit `release-mac-tree`), so that a Linux graph query of `//...` skips it; a red macOS build fails the step, and nothing is staged. **Version:** `release_beta_version --workspace-root src --version 0.1.<run number>` gives every member the version of this run (below, "The version of every release"). **Stage:** `mopm stage --workspace-root src --artifacts <built> --compiler 1.1.0 --out release/staged_set --registry prod` packs every member from its built `.mojoc`, asks the registry (a read, no token) which versions it holds and writes the staged set S (`plan.json`, each `.conda`, each README: mopm's `spec/staged-set.md`). A version the registry holds with other bytes, or has yanked, fails the step. **Whole:** `release_staged_verify expect` holds the plan of S to every package on every platform the release builds (below). **Try:** `./buck2 build -c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on the farm: every package's README examples are compiled and run as a user of the `.conda` files of S (see the e2e's [README](../tools/build/readme_e2e/README.md)); every locked file of both platforms is checked against the plan, and the linux-64 ones, the farm's, are installed and run. Then `mopm publish --staged S --registry prod --dry-run`: the plan is validated and every file hashed against it, nothing is sent and no token is read. It uploads S and that mopm as the workflow artifact `mopm-staged-<sha>`, kept 7 days, for the beta and prod jobs: a rerun of a failed beta or prod job on a later day still downloads it. |
| `beta-stage` | after `release` and `mopm-stage`, **only on a push to `main`** (a manual run skips all five beta jobs and all seven prod jobs before they start; there is no other switch) | in the environment `beta`, with `contents: read` and `id-token: write`, no farm and no secret. It downloads the set `mopm-stage` kept and runs `mopm publish --staged S --registry beta --oidc --no-commit`: the beta registry opens a group, holds every file in quarantine, and nothing is visible. It keeps the directory, now with `state.json` (the beta group), as the artifact `mopm-beta-staged-<sha>`, kept 7 days, even when the step failed. |
| `beta-test` | after `beta-stage`, on a push to `main` | as `prod-test` below, on the directory `beta-stage` kept: environment `build`, **no registry identity and no secret**, `release_staged_verify verify` of every file against `plan.json`, then the README e2e on the farm on the files that matched. |
| `beta-commit` | after `beta-test`, on a push to `main` | in the environment `beta`: `mopm publish --staged S --registry beta --oidc` on the directory with its `state.json`, after a fresh OIDC exchange: the beta group is committed and the job waits until it is visible. It keeps `plan.json`, `state.json` and `report.json` as `mopm-beta-committed-<sha>`. |
| `beta-abort` | after `beta-stage`, `beta-test` and `beta-commit`, when one of them failed or the run was cancelled, on a push to `main` and with a `beta-stage` that was not skipped | in the environment `beta`: `mopm publish --staged S --registry beta --oidc --abort` ends the open beta group. |
| `beta-served-readmes` | after `beta-commit`, on a push to `main` | as `prod-served-readmes` below, on what the beta registry serves (`--stage beta`). `prod-stage` does not wait for it. |
| `prod-stage` | after `release`, `mopm-stage` and `beta-commit`, **only on a push to `main`** (a manual run skips all seven prod jobs before they start; there is no other switch) | in the environment `prod`, with `contents: read` and `id-token: write`, no farm and no secret. It downloads the set `mopm-stage` kept and runs `mopm publish --staged S --registry prod --oidc --no-commit`: the registry opens a group, holds every file in quarantine, and nothing is visible. It keeps the directory, now with `state.json` (the group), as the artifact `mopm-prod-staged-<sha>`, kept 7 days, even when the step failed. |
| `prod-test` | after `prod-stage`, on a push to `main` | in the environment `build` (the farm's; `id-token: write` for the tailnet join only), with **no registry identity and no secret**. It downloads the directory `prod-stage` kept, checks every file against `plan.json` (`release_staged_verify verify`: sha256 and size), writes `release/staged_set` from the files that matched and from nothing else, and runs `-c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on the farm. |
| `prod-commit` | after `prod-test`, on a push to `main` | in the environment `prod`, with `contents: read` and `id-token: write`. The same command without `--no-commit`, on the same directory with its `state.json`, after a fresh OIDC exchange: the same group is committed and the job waits until it is visible. It keeps `plan.json`, `state.json` and `report.json` as `mopm-prod-committed-<sha>`. |
| `prod-abort` | after `prod-stage`, `prod-test` and `prod-commit`, when one of them failed or the run was cancelled, on a push to `main` and with a `prod-stage` that was not skipped | in the environment `prod`, same permissions: `mopm publish --staged S --registry prod --oidc --abort` ends the open group and gives its place back. |
| `prod-smoke` | after `prod-commit`, on a push to `main` | no environment, no identity, no secret, no farm: `release_staged_verify smoke` downloads the published files from the prod channel and compares each with the plan. On a difference it prints the `mopm yank --group <id> ...` command for a human and fails; it yanks nothing. |
| `prod-add` | after `prod-commit` and `prod-smoke`, on a push to `main` | no environment, no identity, no secret, no farm (a farm action has no network): `release_staged_verify add` makes a fresh project with the mopm `mopm-stage` built, sets its Mojo to the one this release was built for, runs `mopm add komira-ai/<name> --registry prod` for `json`, `uuid` and every package that ships a native archive (`async_api`, `awslc`, `compression`, `crypto`, `libc`, `log`, `metrics`) and then `mopm sync`, and checks the lock and the installed files against the plan. It yanks nothing. |
| `prod-served-readmes` | after `prod-commit`, on a push to `main` | in the environment `build` (the farm's; `id-token: write` for the tailnet join only), with **no registry identity and no secret**. `release_staged_verify served --stage prod` downloads, on the runner, every file of the plan from the prod channel and every member's README from the prod API at this run's version, checks them against the plan of the set `mopm-stage` kept (sha256 and size; each README byte for byte), writes `release/staged_set` from what matched, and runs `-c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all` on that set on the farm ([below](#the-readme-e2e-on-what-the-registry-serves)). |

**The staged set is the whole set.** `mopm stage` packs one `.conda` per subdir a member has a library in,
and the checks after it (`verify`, `smoke`, `add`) read the plan, so a plan that lost a platform or a package
would pass them all. Right after `mopm stage`, the step `the staged set is every package on every platform` of
`mopm-stage` runs `release_staged_verify expect --staged release/staged_set --expect <file>`
([`plan_expect.zig`](../tools/build/ci/release_beta_fetch/plan_expect.zig)) and fails, listing every
difference at once, when a package is not a member of `plan.json`, a member is not a package, or a member
lacks a file for a subdir it must have or has one for a subdir it may not have (or two for one). The file is
`//release:mopm_plan_expectation`, written by [`plan_expectation.bzl`](../release/plan_expectation.bzl) from
the two lists the release builds and from no other: every package of `PACKAGES`
([`packages.bzl`](../release/readme_e2e/packages.bzl)) on linux-64, and every package of `DARWIN_PACKAGES`
([`darwin_libs.bzl`](../release/darwin_libs.bzl): the packages not in `DARWIN_EXCLUDED`) on osx-arm64 as
well. It runs before the README e2e and before `beta-stage` or `prod-stage` asks a registry for a group, so a
short set never reaches either registry. It reads `plan.json` only. **It cannot see the natives:** a package's
`[native.<id>]` archive is inside its `.conda`, not a file of the plan, so a `.conda` that lacks one passes
this step (`mopm stage` refuses a member that declares a native with no archive, and the README e2e links
the linux-64 ones).

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

Five of the seven `prod-*` jobs publish the set `mopm-stage` tried to the prod registry as one group (`prod-add`
installs from it after the commit, and `prod-served-readmes` runs the README e2e on what it serves), on every push to
`main` and with no switch, in three steps that the registry keeps apart: **stage** (upload, nothing visible), **test** (on the bytes the registry holds),
**commit** (visible all at once). `prod-stage` needs `release` and `mopm-stage`: the set it stages is the one
the README e2e of `mopm-stage` passed on, at the version of this run (below), and it needs `beta-commit`: a
release build or an e2e that failed stops the run before anything is staged in prod, and so does any failure of
the beta publish ([below](#the-beta-publish)). `//:release_workflow_cases` holds the job graph of both
publishes, the gates, the environments, the permissions, the commands and the order of each test job's steps,
that a beta job names only the registry `beta` and every other job only `prod`, that every upload of
`mopm-staged-<sha>`, `mopm-beta-staged-<sha>` and `mopm-prod-staged-<sha>` is kept 7 to 14 days, and that no
schedule exists; `//:release_plan_expect_cases` holds that `mopm-stage` checks the staged plan against the
expectation as the step right after `mopm stage`, with no condition and no ignored failure, and that `beta-stage`
and `prod-stage` need `mopm-stage`.

**A member must be claimed on prod first.** The registry creates a package name only for its claimed owner, so a
release member whose name is not claimed on the prod registry makes `prod-stage` refuse and turns `main` red. The
pull request check cannot write to the live registry (and does not read it), so the names claimed there are
committed in `release/prod_claimed_names.txt` (one per line, sorted), and `//release:prod_claimed_names_cases`
refuses a pull request in which a member (every `src/<name>` with a `mopm.toml`, `PACKAGES` of
`release/readme_e2e/packages.bzl`) is missing from it: "<name> is a member of the release and is not in
release/prod_claimed_names.txt: claim it on the prod registry first, then add it to release/prod_claimed_names.txt".
A maintainer adds a name to the file only after claiming it on the prod registry, in the pull request that adds the
member or ahead of it: names claimed for libraries not published yet (each with its row in `release/UNPUBLISHED.md`)
are listed too, and the check accepts a name no member has. The file keeps the names of deleted packages (the
`kci_*` libraries), whose names stay reserved as flat names, and refuses the dropping of one of them, an unsorted or repeated line, and an empty file. It is a
committed claim, not a live read: it does not notice a claim the registry lost, and `prod-stage` stays the
last word.

**Every library not published says why.** Every Mojo library under `src/` (a directory with a `BUCK` file and a
`.mojo` file outside its `tests/`) is either a member or has a row in
[`release/UNPUBLISHED.md`](../release/UNPUBLISHED.md) with the reason it is not published, and
`//release:unpublished_cases` refuses a pull request that leaves a library out of both, keeps the row of a member,
keeps a row for a deleted directory, keeps a row that names a published library as the one it waits for, or holds a
row that does not parse, rows out of order, or counts that are not the table's. So the
pull request that publishes a library deletes its row, and the one that adds a library adds a row.

**Every README says who runs its examples.** [`release/README_COVERAGE.md`](../release/README_COVERAGE.md) lists
every `src/<name>/README.md`: whether the package has a `mopm.toml`, whether `//release/readme_e2e/verify:<name>`
exists, which README gate (`mojo_adopted_library` or `mojo_library`) runs its examples in the build, whether it holds
an example, and so who runs them (the release e2e, a build gate, both, or nobody). The graph check
`//release:readme_coverage`, run by the pull request check as `checks.bxl:check` like every graph check, writes that
text from the build graph (a `uquery` of `//src/...` and `//release/readme_e2e/verify:`) and the READMEs (read by
the README examples tool's own reader) and fails when the committed file is not it byte for byte, printing each line
that differs with the line it must be. So a pull request that adds a README, moves a package to mopm, or gives a
README its first example (or takes its last away) changes the row in the same change.

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
   without `state.json` means the stage failed before it asked for a group, and a step says there is
   nothing to end. Which of the two steps runs is each step's `if: hashFiles('mopm-prod/staged/state.json')`
   (`!= ''` or `== ''`), so the job downloads the directory into the workspace, the only place `hashFiles`
   reads, and no step holds shell logic; `beta-abort` is the same with `mopm-beta`. A group that was already committed is not ended: mopm refuses and says to yank it.
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
   staged and committed the set (`toolchains//:mopm_0_0_138`), in a directory it makes on the runner (both
   paths absolute):
   `mopm init --name release-check/prod_add`; then it sets `[toolchain] mojo` of the `mopm.toml` that init
   wrote to the Mojo this release was built for, the `<mojo>` of the build string `mojo<mojo>_<n>` of the
   plan's files (init writes mopm's own default, and `mopm add` resolves the newest version built for the
   project's Mojo, so a project left at that default would get the last release built for it); a plan that
   names two Mojo versions, or a `mopm.toml` without exactly one such line, is refused before `mopm add` runs.
   Then `mopm add komira-ai/<name> --registry prod` for packages of
   [`packages.bzl`](../release/readme_e2e/packages.bzl): a library with no dependency (`json`), one with
   dependencies (`uuid`: `atomic_alias`, `awslc`, `clock`), and every package that ships a native archive
   (the keys of `RELEASE_NATIVES` in [`release/BUCK`](../release/BUCK): `async_api`, `awslc`, `compression`,
   `crypto`, `libc`, `log`, `metrics`), each by its own name; then
   `mopm sync --registry prod --cache <its own directory>`. `//tools/build/ci:prod_add_set_cases` fails the
   build when a package of `RELEASE_NATIVES` is not in that list or a name of the list is no package of
   `packages.bzl`, so a native package that joins the release is added from prod from its first release
   on. A command that exits other than 0
   fails the job with that command and the first line of its stderr. Then it reads `mopm.lock` and refuses,
   listing every difference: a `lock_version` other than 3, a `channels` other than exactly
   `https://conda.mopm.dev/`, a `mojo` other than exactly the release's Mojo, an entry with a flat name, with a channel other than its namespace's
   (`https://conda.mopm.dev/komira-ai/`), that is not a member of the plan or is at another version than
   this run's, an artifact whose URL, sha256 or size is not the plan's file, and an added package the lock
   does not hold; the osx-arm64 entries are checked like the others. For each locked file of the runner's
   subdir (linux-64) it checks what `sync` installed: the file
   kept in `.mopm/pkgs` has the plan's sha256 and size, the environment's `conda-meta` record names that
   sha256, and the package's `lib/mojo/<name>.mopm.json` is there. It yanks nothing; a failure says what a
   user would get, and a person decides what to do. Its cases (`//tools/build/ci:release_staged_verify_unit`)
   run a registry and a mopm in memory.

7. **`prod-served-readmes`** runs once the group is visible, beside the smoke and the add. See
   [the README e2e on what the registry serves](#the-readme-e2e-on-what-the-registry-serves).

**The identity.** No job holds a registry token and neither the environment `prod` nor `beta` holds a
secret. The three prod jobs that talk to the registry run in the environment `prod` and exchange the job's
GitHub OIDC token; the registry trusts this repository's `release.yml`, run on `main` from a push, in the
environment `prod`, and lets that identity act for the owner of the packages (the names are owned by the
maintainers' account, not by the repository). The three beta jobs that talk to the registry do the same in
the environment `beta`, which the beta registry must trust in the same way ([not set up
yet](#before-the-first-release)). `beta-test` and `prod-test` are in the environment
`build`, whose identity no registry trusts, and run nothing that reads a token.

**What this proves.** The files the registry holds in quarantine, which it copies when the group is
committed, are the files of S: the registry pinned each sha256 when it opened the group, and `prod-test`
hashed the same directory against the same plan. The README examples of every package ran on exactly those
bytes before anything was committed, and after the commit the channel serves bytes whose sha256 and size
are the plan's, the API serves each package's README as the plan staged it, and the README examples ran
again on those served files and READMEs. A user's `mopm add komira-ai/<name> --registry prod` and `mopm sync` on a clean runner lock
the full names under the namespace's channel at this run's version and install exactly those bytes.

**What it does not prove.**
- The registry's own verdict: a group can still end `rejected` after the tests passed (the commit job
  fails and the group frees its versions); the tests do not read what the registry stored.
- The registry's derived outputs (repodata, the sparse index) are read only for the packages
  `prod-add` adds and their dependencies; the other members are checked as files by `prod-smoke`, not
  resolved from the index.
- A package's own unit tests are not in the `.conda`: they ran when its `.mojoc` was built.
- Native libraries are loaded as the packages say: `prod-add` installs every package that ships a native
  archive, and its static library, from the registry, but no job builds or runs a program against what it
  installed.
- A plan member that is not an `upload` (a version the registry already holds) makes the README e2e and
  `release_staged_verify` refuse the set; a release publishes only a set of new versions, which is why every
  run gives the members the version `0.1.<run number>` (below).

**Needs a mopm with `--no-commit` and `--abort`.** The jobs run the mopm that `mopm-stage` built: the pin
`MOPM` in [`packages.bzl`](../release/readme_e2e/packages.bzl) (`toolchains//:mopm_0_0_138` in the
`mopm-stage` job). The first mopm release with both flags is 0.0.66, so the pin has them; a later move of
the pin must keep them, in the same change as the toolchain entry the job builds.

#### The README e2e on what the registry serves

`prod-test` and `beta-test` run the README e2e on the files the registry holds in quarantine, before the
commit; after the commit, a user gets what the registry serves: the files from its channel and each README
from its API. `beta-served-readmes` (after `beta-commit`) and `prod-served-readmes` (after `prod-commit`)
run the README e2e of every package on exactly that. Each is a job of the environment `build` with no
registry identity and no secret, and runs, in order:

1. `release_staged_verify served --stage <beta|prod> --staged <the set mopm-stage kept> --out release/staged_set --attempts 5 --delay 30`
   ([source](../tools/build/ci/release_beta_fetch/served.zig)), on the runner, which has the network the
   farm lacks. It reads `plan.json` and each member's README from the set `mopm-stage` kept (its `.conda`
   files are not read). It reads the registry's index (`https://api.beta.mopm.dev/index/config.json` or
   `https://api.mopm.dev/index/config.json`) and refuses one whose `stage` is not the registry's, whose
   `channel_url` is not its pinned channel (`https://conda.beta.mopm.dev/`, `https://conda.mopm.dev/`) or
   whose `api_v2_url` is not its pinned API root (`https://api.beta.mopm.dev/api/v2`,
   `https://api.mopm.dev/api/v2`). Then, with https GETs that follow no redirect, it downloads every file
   of the plan from `<channel><namespace>/<subdir>/<filename>` and compares its sha256 and size with the
   plan, and reads `<api_v2_url>/packages/<namespace>/<name>/<version>` (mopm's `getVersion`) for every
   member at this run's version: the answer must name the member and the version, in the state
   `published`, with a `readme` equal byte for byte to the plan's README. Every difference (a file or a
   version not served, another size or hash, no readme, a readme of another length or with another byte,
   with the first differing byte) is reported at once; a pass that found one is repeated up to five times
   30 seconds apart, as the smoke's is, because a cache can lag the commit. Only when everything matched
   does it write `release/staged_set` (beside its checked-in `BUCK`): `plan.json`, each README as served
   and each file as downloaded. Its cases (`//tools/build/ci:served_unit`) run a registry in memory, and
   `//tools/build/ci:served_cli_cases` run the built tool with `served` on cases that fail before any request.
2. `./buck2 build -c komira_release.staged=stage -c komira_release.beta_version=0.1.<run number> //release/readme_e2e/verify:all`
   on the farm: the README e2e of every package installs from that set and compiles and runs the
   examples of the README the registry served. A package the set lacks fails at the e2e's phase
   `staged`, and `expect` of `mopm-stage` already holds the plan to every package of the release.

The job fails when a file or a README the registry serves is not the plan's, when a package's version is
not served, or when any README example fails. It yanks nothing: a failure after the commit says what a
user gets, and a person decides what to do ([Yanking a bad release](#yanking-a-bad-release)). `prod-stage` does not need
`beta-served-readmes`, so a beta failure here does not stop the prod publish of the same run; it makes the
run red. `//:release_workflow_cases` holds both jobs
([`release_served_readmes.zig`](../.github/workflows/release_served_readmes.zig)): the needs, the gate, the
environment and permissions, the one artifact (`mopm-staged-<sha>`), the `served` command of its own
registry, the order of the steps, the e2e asserted remote, and no write to a registry.

#### The beta publish

Before prod, every push to `main` publishes the same set S to the registry `beta`, in four jobs with the shape
of the first four prod jobs above and the registry `beta` and the environment `beta` in place of `prod`:
**`beta-stage`** (`mopm publish --staged S --registry beta --oidc --no-commit`, the directory kept as
`mopm-beta-staged-<sha>` even when the step failed), **`beta-test`** (`release_staged_verify verify` of that
directory against `plan.json`, then the README e2e on the files that matched, with no registry identity),
**`beta-commit`** (the same command without `--no-commit`, after a fresh exchange; `plan.json`, `state.json`
and `report.json` kept as `mopm-beta-committed-<sha>`, for whoever has to yank the beta group) and
**`beta-abort`** (`--abort`, when one of the three failed or the run was cancelled and `beta-stage` was not
skipped). `beta-stage` needs `release` and `mopm-stage`, as `prod-stage` did; `prod-stage` needs
`beta-commit`.

**One set, one version, two registries.** `mopm stage` plans S against prod, and `plan.json` names no
registry (mopm's `spec/staged-set.md`). Every member of S is a version that neither registry holds yet,
`0.1.<run number>` (below), so every member is an `upload` on either registry and the plan prod's stage wrote
is the plan for beta as well: beta and prod get the same versions of the same bytes. `state.json`, which
`--no-commit` writes, does name its registry, and mopm refuses a state of another registry; so the beta
jobs work on their own directory (`mopm-beta-staged-<sha>`), and `prod-stage` downloads S again from
`mopm-staged-<sha>`, which holds no state. `//:release_workflow_cases` refuses a beta job that names a
registry other than `beta`, any other job that names a registry other than `prod`, the environment `beta`
on any job but `beta-stage`, `beta-commit` and `beta-abort`, and a job that downloads the other registry's
directory.

**When beta fails.** A failure of `beta-stage`, `beta-test` or `beta-commit` (or a cancel) runs `beta-abort`,
which ends the open beta group; `prod-stage` needs `beta-commit`, so every prod job is skipped, and
`prod-abort` does not run either (its `prod-stage` was skipped: there is no prod group). Nothing reaches prod
and the run is red. When beta committed and a prod job fails, the version stays published on beta and
`prod-abort` ends the prod group; the next push publishes a new version to both. A rerun is not the way to
recover: "Re-run failed jobs" of a failed `prod-test` or `prod-commit` finds the group that `prod-abort`
already ended named in `state.json`, and mopm refuses it (the same holds for the beta jobs), and "Re-run all
jobs" fails at `mopm-stage`'s upload of `mopm-staged-<sha>`, which already exists. A failed `beta-stage` or
`prod-stage` does rerun cleanly with "Re-run failed jobs": it starts again from S, which holds no `state.json`,
and the registry opens an ended group again as its next attempt. Otherwise, push again.

**After the commit.** `beta-served-readmes` downloads what the beta registry serves (every file from its
channel, every README from its API) and runs the README e2e on it, as `prod-served-readmes` does for prod
([above](#the-readme-e2e-on-what-the-registry-serves)). No job adds from beta (there is no beta add).

#### Before the first release

This is the one-time setup of the registries, outside this repository. It is done for komira's packages on
`prod`. **It is not done on `beta` yet:** until the beta registry trusts this workflow in the environment
`beta` as a publisher for the packages' owner, every push to `main` fails at `beta-stage` (the exchange is
refused and nothing is created), and because `prod-stage` needs `beta-commit`, nothing is published to prod
either. The first real beta publish is the first push to `main` after that setup. It is listed also because a
repository that copies this workflow must do the same before its first push. There is no variable that turns
the publish on or off, so a push before a registry is ready fails at the first request that is refused and
changes nothing, but that must not be the way it is found out. For each of `beta` and `prod`, in this order:

1. On the registry, the package names exist under the maintainers' publishing account (a personal account the
   maintainers designate, not an organization owner): that account claims the name of every package in
   [`packages.bzl`](../release/readme_e2e/packages.bzl) (every `src/` directory with a `mopm.toml`) on the
   registry.
   Ownership is a registry record, not something `mopm.toml` can express.
2. The registry's group publish is live for that account, and the registry trusts this
   repository's `release.yml`, run on `main` from a push, in the environment of the same name (`beta` or
   `prod`), as a CI publisher of the owner. Without it the exchange is refused (`oidc_not_trusted`) and nothing is created. The registry's
   trust should match the ref, the `job_workflow_ref` and the event (`push`), not the environment alone.
3. The GitHub environment (`beta`, `prod`) deploys only from `main` (selected branches, `main` only). The
   OIDC subject the registry sees names the environment, and a workflow on any branch can declare the same
   environment, so the environment's branch rule is what keeps a branch out; each job's `if` is a second lock,
   and `==` on `github.ref` compares ignoring case.
4. The pinned mopm has `--no-commit` and `--abort` (above).
5. The versions: nothing to set. Each release carries the version `0.1.<run number>` (next section), so no
   version has to be reserved.

The beta and prod jobs start only on a push to `main`: a manual run builds and stages and publishes nothing.

**Beta and prod only on a push: a release without a push is not supported.** A manual run never reaches the
environment `beta` or `prod` (it is break-glass and publishes nothing). To release, merge to `main`: the push is the
release, and its version is its run number.

#### The version of every release

A registry creates a (name, version) pair once, and a mopm version is exactly `MAJOR.MINOR.PATCH`:
`+b123`, `-b123`, `.post123` and `.dev123` are not versions. A registry that holds a version with other
bytes refuses the set (`mopm stage` fails, and the README e2e refuses a plan member that is not an
`upload`), so a fixed version in `mopm.toml` would let only the first release through. So every push to
`main` gives each member of the checkout of `mopm-stage` the version
`0.1.<github.run_number>` before `mopm stage`, and the set that is staged, tested and committed in beta and in prod
has exactly those versions. The number stays inside the
`>=0.1,<0.2` the packages ask of each other, sorts above `0.1.0`, and the newest push is the newest
version. A run that was replaced while pending (above) used a number that is never published, so the
published versions can skip numbers. The README e2e of `mopm-stage`, `beta-test` and `prod-test` is told the number with
`-c komira_release.beta_version=0.1.<run number>` (the name is from an earlier beta publish that took it; it is
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
before the stage, with the run number, and the e2e of `mopm-stage`, `beta-test` and `prod-test` is given the same number.

#### The plan reader and the registry client

[`release_beta_fetch.zig`](../tools/build/ci/release_beta_fetch/release_beta_fetch.zig) holds what
`release_staged_verify` shares with the old beta check: the plan reader (it refuses a plan it cannot
check: no member, a member that is not an `upload`, a path that leaves its directory, a malformed
sha256, a file above 64 MiB, a name listed twice, two paths of the set that collide, in any letter case)
and the https client that reads a registry's index and files with no redirect followed. It is no longer
built as a program of its own (the earlier beta job that ran it is gone; `beta-test` runs `release_staged_verify`); its cases
(`//tools/build/ci:release_beta_fetch_unit`) run against a registry in memory and a socket on
loopback, and cover a changed byte, another size, a missing package, an index of another stage, and
a redirect.

## pypi.yml: publishing the Python package

[`.github/workflows/pypi.yml`](../.github/workflows/pypi.yml) publishes the Linux x86_64 `komira` wheel
([python/README.md](../python/README.md)) in two halves of one file. It is written by hand. The macOS arm64
wheel of the same version is published by nine more jobs of the same file, with the same two halves
([the macOS arm64 wheel in `pypi.yml`](#the-macos-arm64-wheel-in-pypiyml)): an independent chain, so a red
`pypi` run on `main` is a failure of either chain, and the job names say which
([which run to look at](#which-run-to-look-at)).

| event | half | what the run does |
|---|---|---|
| a push to `main` that changes more than documentation | the TestPyPI half | builds the wheel on the farm, installs the wheel file on a fresh runner per supported Python and runs the quickstart ([the user test](#the-user-test-of-the-wheel-file)), uploads it to TestPyPI, installs it from TestPyPI on a fresh runner per supported Python and runs the quickstart, and, when all of that passed, saves [the record](#the-record-of-a-version-that-passed) of the version. It never touches PyPI. |
| daily at 05:17 UTC (`schedule`, one cron entry, `17 5 * * *`) and manual (`workflow_dispatch`, no input) | [the promotion](#the-promotion) | takes the newest record, downloads that version's file from TestPyPI, holds it to the record's sha256 and size, uploads those same bytes to PyPI and installs it from PyPI per supported Python. It builds nothing. |

**How a run knows its half.** By `github.event_name`, and nothing else: every job of the TestPyPI half has
`if: github.ref == 'refs/heads/main' && github.event_name == 'push'` (the smoke jobs add the state of the
upload), every job of the promotion `... && github.event_name != 'push'`, and the verdict jobs the same with
`always() &&` in front. A run is one half; the other half's jobs are skipped, and a skipped job is not a
failure. `//:pypi_workflow_cases` holds each job's exact gate, and its play (`pypi_workflow_run.zig`) runs
the file for a push, a schedule and a manual run: a push uploads to TestPyPI and to no other index, and the
promotion uploads to PyPI and to no other index. Without the gates a push would promote too; the play holds
that as well.

The push filter is `release.yml`'s (`paths-ignore`: `docs/**`, `**.md`, held equal to `release.yml`'s by the
cases): a push of documentation alone starts no run. The version is `0.1.<N>`, `<N>` the build number of
`release_json stamp`, which counts only commits that change more than `docs`, `*.md` and `.github`
([below](#the-version-and-documentation-only-commits)), so each code commit is a new version. The wheel
carries the Mojo runtime libraries and requires no distribution of Modular's; its requirements are
pyarrow and protobuf. A pull request never starts the
workflow.

**The wheel's description.** The body of `METADATA`, which is the page of the version on PyPI, is
[`python/README.md`](../python/README.md) followed by the assembled changelog, `//python:changelog[description]`.
The tool is [`python/changelog`](../python/changelog/BUCK) (Zig, with its own cases): it puts the section
`## 0.1.<N>` (`<N>` the stamp the wheel takes its version from; `## Unreleased` with none) before the first
release heading of [`python/CHANGELOG.md`](../python/CHANGELOG.md), holding the bullets of every file of
`python/changelog.d/` in file-name order, and writes every heading of the result one level down so that it
nests under the README. A change to the package adds a file there and never a line of `CHANGELOG.md`
([the working guide](../python/README.md#changelog-entries)), so queued pull requests edit no common line,
and the section a release ships lists every change merged since the newest section `CHANGELOG.md` keeps.
The build is stamped with its commit too (`-c komira.package_commit`), and every link of the description to
the repository's `main` (`.../blob/main/...`, `.../tree/main/...`) opens that commit instead, so the pages a
version's PyPI page links to describe that version; the `Documentation` URL is the install page of that
commit, and the `Changelog` URL stays `main`'s `CHANGELOG.md`, which keeps a section for every version on
PyPI. The Linux and the macOS wheel read the one target, so their `METADATA` is the same
(`//python:wheel_same_macos_arm64`). The wheel depends on the target, so a malformed file of `changelog.d/`
(a name that is not a slug and `.md`, an empty file, a line that is neither a bullet nor an indented
continuation, a heading), a `## Unreleased` heading in `CHANGELOG.md` and a `CHANGELOG.md` with no release
heading fail the build of the wheel, naming the file and the line; `//python/tests:changelog_names_test`
fails, listing the names, when a public name of `komira` or `komira.pl` appears in no code span of the
changelog or of a fragment; that a change of behaviour has a fragment of its own is left to review. The workflow runs
the same targets as before.

| job | half | environment | permissions | what it does |
|---|---|---|---|---|
| `build` | push | `build` | `contents: read`, `id-token: write` (the tailnet only) | on the farm ([farm-connect](#how-it-reaches-the-farm), `farm-qos: batch`): builds `//release/ci:release_json` and takes the stamp (`release_json stamp`); builds the wheel and its install test (`//python:komira_wheel[release]` and `//python:wheel_install_test`) with the three stamp flags (`-c komira.package_stamp`, `komira.package_commit`, `komira.package_timestamp_ms`), `//python/smoke:pypi_smoke` and `//python:supported_pythons[linux-x86_64]` (the exact versions of [python/pythons.bzl](../python/pythons.bzl) as a JSON list, `pythons.json`); runs `pypi_smoke dist`, which makes the dist directory and writes `built.txt`, the record of the wheel's file name, sha256 and size; copies the quickstart, its expected output and the ABI table beside the driver; runs `pypi_smoke matrix` (its output `matrix`, one entry per Python). Keeps `pypi-<version>-dist` (the wheel) and `pypi-<version>-smoke` (the driver, those three files, `pythons.json` and `built.txt`) for 14 days. No upload step. |
| `wheel-user-test` | push | none | none | [the user test of the wheel file](#the-user-test-of-the-wheel-file): one job per Python of the list, on a fresh runner with no checkout, `pypi_smoke install --index dist`. |
| `testpypi` | push | `testpypi` | `id-token: write` | after `wheel-user-test`; no farm, no checkout, no buck2. Downloads the two artifacts, prints the size of the project on TestPyPI and on PyPI ([storage](#storage-on-the-indexes)), runs `pypi_smoke state --index testpypi`, and uploads the wheel to TestPyPI only when the state is `absent`. |
| `testpypi-smoke` | push | none | none | one job per entry of `build`'s `matrix` (`fail-fast: false`, so every Python reports): `pypi_smoke verify --index testpypi`, then `pypi_smoke install --index testpypi` with the quickstart files of the smoke artifact, on a runner with that exact version from `actions/setup-python`. Skipped when the state is `differs`. |
| `testpypi-passed` | push | none | none | after every `testpypi-smoke` job passed: saves the smoke artifact in the Actions cache under `pypi-passed-linux-x86_64-<version>` ([the record](#the-record-of-a-version-that-passed)). |
| `result-testpypi` | push | none | none | the push run's verdict (below). |
| `promote` | promotion | none | none | restores the newest record from the cache (`actions/cache/restore` with the prefix `pypi-passed-linux-x86_64-`, `fail-on-cache-miss: true`), prints the size of the project on both indexes, runs `pypi_smoke promote` ([below](#the-promotion)), and `pypi_smoke matrix` on the record's `pythons.json`. Keeps `pypi-<version>-dist` (the file downloaded from TestPyPI) and `pypi-<version>-smoke` (the record) for 14 days. No farm, no build, no identity. |
| `pypi` | promotion | `pypi` | `id-token: write` | after `promote`: downloads the two artifacts, runs `pypi_smoke state --index pypi`, and uploads the file to PyPI only when the state is `absent`. |
| `pypi-smoke` | promotion | none | none | the same as `testpypi-smoke` against PyPI, one job per entry of `promote`'s `matrix`. Skipped when the state is `differs`. |
| `result-pypi` | promotion | none | none | the promotion's verdict (below). |

**The verdict jobs.** A job that was skipped because one before it failed would otherwise leave a run looking
finished, so each half ends in a verdict job that holds no permission, runs `always()`, and prints one
workflow command per step (the job results reach the steps through `env:`, never inside a `run:`). A
failing step names the job that did not succeed and ends the run red; a notice step prints and goes on. The
notice that nothing new was uploaded is the last step, so it prints only when nothing failed.
`result-testpypi` fails when `build`, `wheel-user-test` or `testpypi` did not succeed, when `testpypi-smoke`
or `testpypi-passed` did not (unless the state was `differs`): `... this version is never promoted to PyPI`,
and when an index is over 80 percent of its size limit ([below](#storage-on-the-indexes)); it prints
`bytes differ at the same version: ...` for `differs` and, last, `already on TestPyPI: komira <version> is on
TestPyPI with the bytes built; nothing was uploaded, and the smoke passed` for `same`. `result-pypi` prints
`not promoted: komira <versions> on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed,
or its run had not ended); komira <version> is the newest version that passed` when `promote` skipped
newer versions; it fails when `promote`, `pypi` or `pypi-smoke` did not succeed, when PyPI holds the version
with other bytes than TestPyPI serves, and when an index is over 80 percent; last, it prints `already
published: komira <version> is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI
smoke passed` for `same`.

**Why one file.** PyPI's trusted publishing binds a publisher to a workflow file name and an
environment, not to an event: the publishers of TestPyPI and PyPI trust `pypi.yml` with the environments
`testpypi` and `pypi`, so the push trigger needed no change on either index, and an upload from another
workflow file would need a publisher of its own (the macOS uploads are in `pypi.yml` too, so the one publisher
per index covers both wheels: [below](#trusted-publishing-of-the-macos-file)). `release.yml` holds no publishing
credential. A job's index identity is the OIDC token of its environment: only `testpypi` and `pypi` hold a
token an index trusts, and only for their own index. `build` names the environment `build`, which no index
trusts, and has no upload step. Every other job holds no permission at all (`permissions: {}`): the
smoke jobs read the quickstart from the smoke artifact, not from a checkout. `//:pypi_workflow_cases`
(`pypi_workflow_contract.zig` says what it holds) pins the triggers, the concurrency, the nineteen jobs in
order and each one's `if:`, runner, `needs`, environment and permissions. Of each chain it pins that
`id-token` is on its build job and its two upload jobs alone, that `farm-connect`, buck2 and a checkout are
in its build job alone, that `actions/cache/save` is in its record job alone and `actions/cache/restore` in
its promote job alone, that the publish action appears only in its two upload jobs and `setup-python` only
in its smoke jobs (and the Linux `wheel-user-test`). Of the file it pins that every action is pinned to a
commit and that no secret, `curl`, `jq`, `twine` or `continue-on-error` is anywhere in it.
`//:release_macos_cases` holds that no Linux job of `pypi.yml` names macOS, that neither chain needs or
reads the other's jobs, and that both build jobs stamp the same way. `//:farm_connect_cases` holds both
build jobs (`build` and `build-macos-arm64`) to `farm-qos: batch`.

### One run at a time, and which commits get a TestPyPI version

A push run is in the concurrency group `pypi-testpypi`, a promotion (scheduled or manual) in `pypi-promote`,
each with `cancel-in-progress: false`. A running run is never cancelled, so an upload is never cut short.
GitHub keeps at most one pending run per group: a newer run of the group cancels the pending one and takes
its place. So when merges land faster than a push run takes, the builds do not pile up: one run builds, one
waits, and the waiting one is always the newest merge. **A commit whose run waited and was replaced gets no
TestPyPI version of its own**: its changes are in the newer commit's wheel (`main` moves forward only), and
its version number is skipped, so the versions on TestPyPI are not consecutive. A commit whose run started is
uploaded at its own version. The two halves are in different groups so that a push never replaces a waiting
promotion, and a promotion never waits behind a day of merges; a promotion that runs beside a push run only
promotes a version whose record was saved before it started. The play of `//:pypi_workflow_cases` (`queue`)
holds this from the file's text: three merges while the first runs leave the first and the third started and
the second cancelled; a promotion starts beside a running push, and a push that lands while a manual run
waits replaces nothing; one group for both halves, or `cancel-in-progress: true`, is refused by what it
would do. The groups are the run's, and a run holds both wheels' chains, so a push run waits until
both chains of the previous run have ended: a macOS build that takes its full time limit holds back the next
Linux TestPyPI version by that long, and a slow Linux job holds back the next macOS one.

### The user test of the wheel file

Before any upload, the push run installs the wheel it built as a user does, on a machine that has never seen
the repository: `wheel-user-test`, one job per supported Python for `linux-x86_64` (today CPython 3.11.17,
3.12.15, 3.13.16 and 3.14.8), each on a fresh GitHub-hosted runner (`ubuntu-24.04`) with no checkout:
downloads the two artifacts, sets up that Python with `actions/setup-python`, and runs `pypi_smoke install
--index dist`. `fail-fast: false`, so every Python finishes and each failure is its own job. `testpypi` needs
it, so a wheel that does not install and run from its own file is uploaded nowhere and takes no file name and
no space on TestPyPI.

**What it runs.** `pypi_smoke install --index dist` is the install of the index smoke with the dist directory
in place of the index: an empty virtual environment of the runner's Python; the wheel's requirements, if it
has any, from PyPI; then `komira==<version>` with `--no-deps --no-index --find-links <dist>`, so pip reads no
index for `komira` and installs the one wheel of the directory; `pip check`, `pip show` and `pip freeze` hold
the environment to `komira` at the built version and the distributions its `Requires-Dist` names (pyarrow and protobuf),
and nothing else; no `modular` package is importable; and
the quickstart, the program the README and the install page show (held byte for byte by
`//python/smoke:readme_shows_quickstart` and `//python/smoke:install_page_shows_quickstart`), runs and must
print exactly what `python/examples/quickstart.expected` says. Today that is import, the version, the
engine's ABI version, a Parquet file the program writes itself, an aggregate and a GROUP BY with an ORDER BY
over it read as rows, a pyarrow Table, a reader and the PyCapsule interface, and the two `KomiraError` messages
of a missing file and a SQL syntax error. When the quickstart grows (a pandas result, say),
this job and the index smokes run the new program with no change here. A local directory does not lag, so
the install is tried once (`--attempts` and `--delay` are refused with `--index dist`).

**One user-like test, in this file.** `release.yml` ran the same job on every merge until the push run of
this file existed. It is gone from there: the push run now builds every code merge's wheel at the same
moment, from the same commit and stamp, and installs it from the file and then from TestPyPI, so the
`release.yml` job told nothing sooner and nothing more. `release.yml`'s cases (`//:release_workflow_cases`)
hold that it has no wheel job, no `setup-python`, no wheel target and no smoke driver. What changed with it:
A merge that breaks either wheel turns this file's push run red, and `main_red.yml` watches this file's push
runs as it watches `release.yml`'s, so it opens the `main red` issue as before.

**The list.** The supported Pythons are one list, [`python/pythons.bzl`](../python/pythons.bzl): each minor's
pinned farm interpreter and the exact version `actions/setup-python` installs on each hosted platform. The
wheel's metadata, the package's tests and every job that installs the wheel once per Python read it. The
build builds `//python:supported_pythons[<platform>]` (a JSON list of exact versions, oldest first) into the
smoke artifact, and `pypi_smoke matrix --pythons <that file> --platform <name>` writes the job matrix, each
entry with the platform's hosted runner (`platforms` in `python/smoke/src/matrix.zig`: `linux-x86_64` on
`ubuntu-24.04`, `macos-arm64` on `macos-15`). The promotion writes its matrix from the record's copy, so the
PyPI smoke of a version installs it on the Pythons its TestPyPI smoke did. Adding a Python is a line in
`pythons.bzl` and its pin: every job matrix gets one more entry with no change to the workflow. A list that is
not JSON strings, a version that is not `3.<minor>.<micro>`, a minor twice or out of order, or an empty list
fails the `matrix` step naming the entry, and `//python/smoke:supported_pythons_lists` holds both real lists to
their versions in the pull request's check. The macOS arm64 wheel has no user test of its file before its
upload: its install test runs on the farm's Macs, and its first install as a user's is its TestPyPI smoke on
`macos-15`.

### The record of a version that passed

What the promotion needs from a push run is what that run's build made and that its TestPyPI smoke passed on
every Python. The build writes it beside the driver (`pypi_smoke dist --record`): `built.txt`, one line,
`<file name> <sha256> <size>`. The smoke artifact, which holds `built.txt`, the driver, the quickstart files
and `pythons.json`, is the record. `testpypi-passed` needs `testpypi-smoke`, a matrix job, which succeeds only
when every one of its entries did, and then saves the record in the repository's Actions cache with
`actions/cache/save` under the key `pypi-passed-linux-x86_64-<version>` (`pypi-passed-macos-arm64-<version>`
for the macOS wheel, saved by its own job of `pypi.yml`; the cache is the branch's, not the workflow's, and the
two prefixes never meet). So "passed" is the push run's own verdict, written down only when it passed: a version
whose smoke failed on any Python, or whose run was cancelled or has not ended, has no record and is never
promoted. The play holds that a smoke failure saves no record, and that a record job that did not wait for the
smoke would save one.

Why the cache: it is the one store a later run of another event can read without a token. A cache key is
written once (a second save of the same key is a no-op), the entries of `main` are written only by runs on
`main` (a run on a pull request writes its own scope and cannot write `main`'s), and a restore with a key
prefix returns the most recently created entry of that prefix (GitHub's documented rule for a partial key
match). That is the newest version that passed as long as the push runs save their records in version
order, which they do one at a time; a re-run of an older run's failed jobs that passes after a newer version
passed breaks the order, and then the promotion restores the older record: `promote` refuses it when PyPI
already holds a newer version (red, nothing published), and otherwise promotes the older version, until the
next push run saves a newer record. GitHub evicts an entry that nothing reads for 7 days (its documented
policy, not measured here); the promotion reads the newest one every day, so only older, superseded records
go. If the promotion is off for more than 7 days with no push in between, it finds no record and is red
until the next push run passes (below).

The record carries the version's own driver, quickstart, expected output and list of Pythons, so the PyPI
smoke of a version runs what that version's TestPyPI smoke ran, not what `main` holds on the day of the
promotion.

### The promotion

**Cadence.** Once a day, at 05:17 UTC (the cron entry `17 5 * * *`; off the hour, when GitHub's scheduled
runs queue least), and on a manual run on `main` (Actions > pypi > Run workflow). An index takes a file name
once, ever, and a PyPI project holds 10 GiB unless its limit is raised (PyPI's documented default), so the
schedule gives PyPI at most one version a day, the newest that passed, while TestPyPI gets one per code
merge. A manual run is a promotion like the daily one (it starts no build and takes no input), so a day with
a manual run can promote twice, when a new version passed in between.

**What it does.** `promote` restores the newest record and runs `pypi_smoke promote --record built.txt --out
<dist>`, which:

1. reads the record: one line, `<file name> <sha256> <size>`, the file name parsed as a wheel's
   (`<name>-<version>-<tag>.whl`);
2. reads TestPyPI's project JSON (`https://test.pypi.org/pypi/komira/json`): the record's version must list
   the record's file with the record's sha256 and size; every newer version that lists a file of the same tag
   (the same platform) has no record, and is named and skipped (`skipped=` output, the `not promoted` notice).
   Versions compare as dot-separated numbers (`0.1.10` is newer than `0.1.9`); a version that is not is left
   out, with a log line;
3. reads PyPI's project JSON: if PyPI's newest version of the same tag is newer than the record's, it refuses
   (a run of an older commit passed after a newer one) and nothing is promoted; equal is fine (the state
   `same` below), and so is no project yet;
4. downloads the file from the URL TestPyPI lists, which must be on `test-files.pythonhosted.org`, and refuses
   it unless its sha256 and size are the record's and it is the wheel the record names;
5. writes it alone into the dist directory and appends `version`, `filename` and `skipped` to the job's
   outputs.

Then `pypi` asks PyPI's state for that file and uploads it for `absent`, and `pypi-smoke` verifies that PyPI
serves those bytes and installs it on every Python of the record. So the bytes on PyPI are the bytes TestPyPI
served and the build recorded: the promotion never rebuilds, and a file TestPyPI changed, or a download cut
short, is refused before any upload.

Each promotion ends in one of these ways, and `pypi_workflow_run.zig` (in `//:pypi_workflow_cases`) plays
each from the workflow's text and holds what the run prints, what it uploads and that it is green or red:

| what TestPyPI and PyPI hold | the run |
|---|---|
| a newest record not on PyPI | PyPI `absent`: uploaded, the PyPI smoke passes; green |
| a newest record not on PyPI, and a newer TestPyPI version with no record | the same, with the notice `not promoted: komira <newer> ...` naming the skipped version; green |
| a newest record already on PyPI (a day with no new version that passed) | PyPI `same`: nothing uploaded, the PyPI smoke runs; green with `already published` (and `not promoted` when a newer version did not pass: the day publishes nothing and says why) |
| no record at all, or `promote` refused (a file TestPyPI changed, a record older than PyPI's newest) | nothing uploaded; red, `the promote job did not succeed`, its log saying why |
| PyPI holds the version's file with other bytes | nothing uploaded, no PyPI smoke; red |
| the upload or the PyPI smoke fails | red, naming the job |

**What a day costs.** The promotion builds nothing: it is the cache restore, two JSON requests and a
download per platform, the upload and the PyPI smoke jobs on hosted runners, minutes in all (inferred from
the jobs it runs; not yet measured). The farm work moved to the push run: one wheel build per code merge,
less when merges land faster than a run (above), at `farm-qos: batch`, which queues behind pull-request
checks. The first release (komira 0.1.1512, a manual run) took 60 minutes from start to the verdict, 56 of
them in `build` (measured from the run's job times); a push run builds the same targets, so expect the same
order until its build hits the cache (inferred).

**Stopping it.** Either disable the workflow (Actions > pypi > the `...` menu > Disable workflow; enable it
again the same way), which stops the push runs, the daily and the manual runs without a commit, or delete the
`schedule:` entry in a pull request, which leaves the push runs and the manual run (`//:pypi_workflow_cases`
then needs the same edit: it holds exactly one schedule). Both wheels' promotions are in this one workflow, so
disabling it stops both. GitHub also disables a scheduled workflow of a
public repository after 60 days with no activity in the repository; enabling it again is the same click.
Required reviewers on the environment `pypi` (owner step 1 below) hold each promotion before its PyPI upload
until someone approves it, which turns the daily release into a watched one; required reviewers on
`testpypi` would hold every push run.

### Storage on the indexes

An index holds a project to a size limit, 10 GiB (`10 * 1024^3` bytes, the indexes' documented default) unless the index raised it, and takes
a file name once, ever: a file can be deleted only by a project owner, in the index's web page, and its name
can never be uploaded again. TestPyPI gets one wheel per platform for every code merge, so it fills first.

Each run prints the size on both indexes in its job summary: `testpypi` (a push run) and `promote` (a
promotion) run `pypi_smoke storage --index <testpypi|pypi> --project komira --limit-gib 10 --over-percent 80`,
once per index and before the state and the upload (so the numbers are there when an upload is refused for
its size). Each sums the `size` of every file of every release in the index's project JSON, and appends a
line such as `- komira on TestPyPI: 3.21 GiB (3446145024 bytes) in 41 files of 37 versions, 32.1% of the 10
GiB limit` to the summary; above 80 percent the line ends `: **over 80%**`, the step prints an `::error` line
and its output `over` is `true`. The step itself succeeds (the upload still runs: the index is not full yet),
and the verdict job ends the run red with `an index holds over 80 percent of the size limit of komira (the
summary of the job ... says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md,
Storage on the indexes`. A project the index does not know yet is 0 bytes.

**What to do when it is red.** Whoever watches the release (the maintainer on duty) does one of:

1. **Prune TestPyPI.** A TestPyPI owner of the project deletes old versions in the web page (test.pypi.org >
   Your projects > komira > Manage > Releases > the version > Options > Delete). Delete only versions older
   than the newest version on PyPI: they can never be promoted (the promotion takes the newest record, and
   refuses one older than PyPI's newest), and deleting them changes nothing PyPI serves. Start from the oldest.
   The next run's summary shows the new total.
2. **Ask for a higher limit.** When pruning is not enough (PyPI over 80 percent, where releases are never
   deleted, or TestPyPI full of versions still newer than PyPI's), a higher limit is requested on the indexes'
   public support tracker, [github.com/pypi/support](https://github.com/pypi/support) (the project limit
   request form; it names the project and the index). The request speaks for the project, so it is made by
   the project's owner, or with the owner's go, never by an automation. When the index raises the limit, the
   `--limit-gib` of the storage steps in `pypi.yml` (and in `//:pypi_workflow_cases`) is changed in a pull
   request to the new limit.

### The driver

Every step that does more than start a program is `//python/smoke:pypi_smoke`, a Zig program built by the
push run's `build` and carried to the later jobs as an artifact (and to the promotion in the record), so no
workflow step holds shell logic. It takes flags only. `--index` is `testpypi` (TestPyPI) or `pypi` (PyPI), and
for `install` also `dist` (the dist directory itself, with no index); any other value is a usage error. The
exit status is 0 for success, 1 for a refusal or a failure (the last line printed is `pypi_smoke: FAILED:
<why>`, and an `::error` line for the log) and 2 for a usage error.

| subcommand | flags | what it does |
|---|---|---|
| `dist` | `--wheel <file.whl> --out <dir> --record <file> --github-output <file>` | reads the wheel: exactly one `*.dist-info` directory holding `METADATA` and `WHEEL`, one `Name` and one `Version` in `METADATA`, one `Tag` in `WHEEL`. The file name is `<name>-<version>-<tag>.whl` with the name normalized (each run of `-`, `_` or `.` becomes `_`, lowercase), and the dist-info directory must agree. Writes the same bytes under that name into `--out` (which must not exist or be empty), writes `--record` (one line, `<file name> <sha256> <size>`), and appends `version`, `filename` and `sha256` to the GitHub output file. |
| `state` | `--index <testpypi\|pypi> --dist <dir> --github-output <file>` | `--dist` holds exactly one wheel and nothing else. One request for the version's JSON on the index, no retry. Appends `state=absent`, `same` or `differs` (below). Any other answer than a 404 or a 200 with the expected shape fails. |
| `present` | `--index <testpypi\|pypi> --name-file <file> --github-output <file>` | reads the one-line file name (`komira-<version>-<tag>.whl`) from `--name-file`, asks the index's JSON for that release (as `state` does) and appends `present=true` (the release lists a file of exactly that name) or `present=false`. It needs no wheel, so it runs before anything is built. An index error is a refusal and appends nothing. |
| `verify` | `--index <testpypi\|pypi> --dist <dir> [--attempts <1..20>] [--delay <0..300>]` | asks the index for the file it serves and compares it with the built one (below). A refused attempt is tried again up to `--attempts` times (default 5), `--delay` seconds apart (default 30), because an index can lag an upload. |
| `install` | `--index <testpypi\|pypi\|dist> --dist <dir> --python <exe> --example <quickstart.py> --expect <quickstart.expected> --abi-table <komira.tsv> --work <dir> [--attempts <n>] [--delay <s>]` | installs the published wheel into an empty environment and runs the example (below); with `--index dist`, the wheel of `--dist` itself ([the user test](#the-user-test-of-the-wheel-file)). `--attempts` and `--delay` as for `verify`, for the install of `komira` only; refused with `--index dist`, which installs once. |
| `matrix` | `--pythons <list> --platform <name> --github-output <file>` | reads the list of supported Pythons ([above](#the-user-test-of-the-wheel-file)) and appends `matrix=<JSON>`, the `include` list of a job matrix with the platform, the Python and the hosted runner of every entry. A malformed list is a refusal and appends nothing. |
| `storage` | `--index <testpypi\|pypi> --project <name> --limit-gib <1..1000> --over-percent <1..100> --summary <file> --github-output <file>` | one request for the project's JSON; sums the size of every file of every release; appends the summary line and `over=true\|false` and `bytes=<total>` ([above](#storage-on-the-indexes)). Over the threshold is an `::error` line, not a failure. A 404 is 0 bytes; any other answer that is not a project's JSON with sizes is a refusal and appends nothing. |
| `promote` | `--record <file> --out <dir> --github-output <file>` | [the promotion](#the-promotion)'s choice and download: the record's file from TestPyPI, held to the record; newer TestPyPI versions of the same tag named as skipped; refused when PyPI's newest is newer. Any refusal appends nothing and writes nothing into `--out`. |

The driver's cases (`//python/smoke:*_unit`, one test target per scenario) use a fake index and a fake runner
and make no network request; the live indexes are reached only by a run of this workflow.

**The three index states.** `state` asks the index about the one file of the dist directory,
`komira-0.1.<N>-py3-none-manylinux_2_35_x86_64.whl` (or `...-py3-none-macosx_11_0_arm64.whl` in the macOS chain):

- `absent`: the index has no such file (the version may exist with another file, another platform's wheel).
  The job uploads it, by trusted publishing, with the publish action's defaults (`skip-existing` off,
  attestations on). `testpypi` sets the action's `repository-url` to TestPyPI's upload endpoint; `pypi` sets
  none, the action's default being PyPI.
- `same`: the index has the file with the same sha256. Nothing is uploaded and the smoke runs: a re-run, a push
  that changed only what the stamp ignores, or (on PyPI) a day whose newest record is published already.
- `differs`: the index has the file with another sha256. Nothing is uploaded and the smoke does not run. On
  TestPyPI it is a push that changed only what the stamp ignores and changed the wheel's bytes
  ([below](#the-version-and-documentation-only-commits)): green with a notice. On PyPI it cannot come from the
  promotion, which sends TestPyPI's own bytes, so it is an error: red, and the PyPI owner looks at the release.

**What the smoke proves.** Two checks per index, on a runner that is not the farm, after the upload:

1. `verify`: the file the index serves is the file that was built. The index's JSON for the version names the
   file with its sha256, its size and its URL. The sha256 and size must be the built wheel's, the URL must
   be on the index's file host (`test-files.pythonhosted.org` or `files.pythonhosted.org`), and the bytes
   that URL serves are downloaded and hashed again, so a wheel changed after the index recorded it fails.
   Then the `METADATA` of the served bytes and of the built wheel are compared on `Name`, `Version`,
   `Requires-Python` and the full ordered list of `Requires-Dist`, and `Name` and `Version` must agree with
   the file name. Every difference of an attempt is listed, not only the first.
2. `install`: a user's install works, on each supported Python, one job each. `actions/setup-python` gives that
   CPython at the exact version [python/pythons.bzl](../python/pythons.bzl) names and `pypi_smoke` makes an empty
   virtual environment with it. For TestPyPI, the wheel's `Requires-Dist` requirements are installed first from
   the real PyPI (`--only-binary=:all:`), then `komira==<version>` with `--no-deps` from TestPyPI alone, so
   nothing but `komira` comes from TestPyPI. For PyPI, `komira==<version>` is one install from PyPI. Every pip
   runs `--isolated`, without a cache. Then `pip check` must pass, `pip show komira` must report the version,
   `pip freeze` must list `komira==<version>` once and otherwise only the distributions the wheel's
   `Requires-Dist` names, at any version (pyarrow and protobuf; the wheel carries the Mojo runtime, so no `mojo-compiler`
   and no other distribution is installed), no package named `modular` may be importable, and
   the quickstart runs with `python -I` in a directory holding only the example (it writes its own Parquet
   file there, so no data file is passed): it must exit 0 and print what `python/examples/quickstart.expected`
   says, compared exactly, with `<version>` replaced by the version, `<abi_version>` by the ABI version of the
   `--abi-table` file (`src/so/abi/komira.tsv`: `major * 1000 + minor`, so `1.10` is 1010) and `<cwd>` by the real
   path (symlinks resolved) of that directory, which the missing-file message names. A failed step names the command, its exit
   status and the last lines of its stderr.

The user test of the wheel file is the first gate: `testpypi` `needs` `wheel-user-test`, so a wheel that does
not install and run from its own file is uploaded nowhere. The TestPyPI smoke is the release gate: only a
version whose TestPyPI smoke passed on every Python gets a record, and only a record is promoted to PyPI.

The quickstart is [`python/examples/quickstart.py`](../python/examples/README.md). Today it asserts the
version and the engine's C ABI version; that it writes a small Parquet file with pyarrow, registers it and runs an
aggregate and a GROUP BY with an aggregate and an ORDER BY; that the answers read as rows, as a pyarrow Table with
its schema, with `to_reader()` and through the Arrow PyCapsule interface; that a missing file and a SQL syntax
error raise `KomiraError` with messages naming the file's absolute path and the line and column; and that the
session closes. The README's block under "What works"
is the same text, and the README's output block is `quickstart.expected`, both held byte for byte by
`//python/smoke:readme_shows_quickstart`. The pull request check runs the same quickstart against the installed
wheel on the farm, `//python:wheel_install_test` (`python/tests/test_installed.py`), which compares its stdout with
`quickstart.expected` and uploads nothing. The install page,
[docs/install.md](install.md), shows the same program and what it prints, `quickstart.expected` with the
newest release `python/CHANGELOG.md` keeps ([python/CHANGELOG.md](../python/CHANGELOG.md)) and the ABI version put in, held by
`//python/smoke:install_page_shows_quickstart`.

**What the macOS smokes prove.** The same two checks, `verify` and `install`, on the macOS wheel: on the
GitHub-hosted runner `macos-15` (Apple silicon, free for public repositories), once per supported CPython from
`actions/setup-python` (3.11.9 and 3.12.10 for 3.11 and 3.12: their newer patch releases have no macOS build there), the macOS driver (`//python/smoke:pypi_smoke_macos_arm64`, cross-compiled on the farm for
`aarch64-macos`) checks that the index serves the bytes that were built and that `pip install komira==<version>` into an
empty environment gives a package that imports, reports the version and the ABI version, and runs the quickstart (the same program and expected output, with `<cwd>`
substituted, and no data file).
The wheel is self-contained: `komira/_lib/libkomira.dylib` and, in `komira/_lib/lib/`, the three Mojo runtime
libraries (`libAsyncRTRuntimeGlobals.dylib`, `libKGENCompilerRTShared.dylib`, `libMSupportGlobals.dylib`); it depends on
no package of Modular's.

**What ran where.** The build, the stamp and the wheel's own install test
(`//python:wheel_install_test`, which installs the wheel into an empty environment and loads `libkomira`) run on the
farm, in the push run's `build`, before any upload, on the same bytes that are uploaded. The macOS wheel's build and its install test
(`//python:wheel_install_test_macos_arm64`) run on the farm's Macs, in `build-macos-arm64` of `pypi.yml`. The user test of the wheel
file, `storage`, `state`, the uploads, `promote`, `verify` and `install` run on GitHub-hosted runners, in the later jobs. The index checks and the install from an index
run on a runner only, because a farm action has no network.

**What it does not prove.** It does not run a query (none exists yet). It tests two wheels, linux x86_64 and macOS
arm64, the four supported CPython minors at one patch release each, and one install route (`pip`), and the macOS wheel only on the macOS version of the hosted
runner, not on the oldest macOS it claims (11.0). Wheels for arm64 Linux and for other platforms come later,
each with its own smoke.

### Owner steps before the first run

Steps 1 and 2 were done once, in GitHub and on the indexes, outside this repository, and need no change for
the push trigger (a publisher names the workflow file and the environment, not the event) or for the macOS
wheel, whose uploads are in the same file:

1. In the repository's Settings > Environments, create `testpypi` and `pypi`, each restricted to the
   branch `main` (deployment branches: selected branches, `main` only). Required reviewers on `pypi` are
   optional: they hold each promotion before the PyPI upload. The environment `build` already exists.
2. On test.pypi.org and on pypi.org, add a pending trusted publisher (Your account > Publishing): project
   `komira`, owner `komira-ai`, repository `komira`, workflow `pypi.yml`, environment `testpypi` on
   TestPyPI and `pypi` on PyPI.
   The one publisher per index covers the uploads of both wheels
   ([why](#trusted-publishing-of-the-macos-file)). A publisher naming another workflow file matches no upload;
   the index owner may remove it.

### Yanking a bad release

A release is never deleted from PyPI, by the workflow or by hand: an index does not let a file name be uploaded
again, even after its file is deleted, so a deleted release leaves a version that can never be fixed in place. A
bad release is yanked by the PyPI project's owner: in the project's release settings on pypi.org, on the version,
Yank, with a reason. A yanked version stays installable by `==` and is skipped by a plain `pip install komira`.
The next version is the next code commit whose TestPyPI smoke passes, promoted the next day. Yanking does not
remove the file, so a promotion whose newest record is the yanked version still finds it (`same`) and uploads
nothing; to stop releases while a fix is made, disable the workflow ([above](#the-promotion)).

### The version and documentation-only commits

The version is `0.1.<N>`, with `<N>` from `release_json stamp`, which does not count commits that touch only
documentation (`docs`, `*.md`, `.github`). A push of `docs/**` and `*.md` alone starts no run (the push
filter). A push that changes `.github` alone starts a run that builds the version of the last code commit:
when its bytes are the ones on TestPyPI (`same`), nothing is uploaded, the smoke runs and the run is green with
`already on TestPyPI`; when they differ (`differs`: the wheel's `METADATA` holds the package's description,
`python/README.md` and the assembled changelog, and a README edit, or a file of `python/changelog.d/`, that landed with no code since the version was uploaded changes it),
nothing is uploaded, the smoke does not run, and the run is green with a notice that says the version's bytes
differ. The fix reaches the index with the next commit that changes code, which has the next version.

## The macOS arm64 wheel in pypi.yml

Nine jobs of [`.github/workflows/pypi.yml`](../.github/workflows/pypi.yml), after the Linux jobs of each half,
publish the macOS arm64 `komira` wheel, `komira-0.1.<N>-py3-none-macosx_11_0_arm64.whl`, the same name and
version as the Linux file of the same commit. They run on the file's triggers (a push to `main` that changes
more than documentation, the daily cron, a manual run) and in its two halves, told apart by `github.event_name`:
the push half builds the wheel on the farm's Macs when TestPyPI lacks it, uploads it to TestPyPI, smokes it on a
hosted macOS runner and saves its record; the promotion takes the newest macOS record and publishes that file to
PyPI. The jobs' names say which chain a failure is in, and the two chains are independent
(next paragraphs). Nothing of the macOS chain is skipped or
softened: its build, its uploads, its smokes and its verdict jobs are the ones this section lists.

| job | half | environment | permissions | what it does |
|---|---|---|---|---|
| `build-macos-arm64` | push | `build` | `contents: read`, `id-token: write` (the tailnet only) | on an ubuntu runner that only asks the farm, whose Macs are the workers (`farm-connect` with the macOS worker set and hosts, `farm-qos: batch`): takes the stamp, builds the Linux driver and `//python:supported_pythons[macos-arm64]` and runs `pypi_smoke matrix --platform macos-arm64` (its output `matrix`), builds `//python:komira_wheel_macos_arm64[file_name]` (the wheel's file name, written at analysis) and asks TestPyPI whether it lists that file (`pypi_smoke present`). Only if it does not, it builds `//python:komira_wheel_macos_arm64[release]`, `//python:wheel_install_test_macos_arm64`, the wheel read back (`//python:wheel_libs_macos_arm64` and `//python:wheel_same_macos_arm64`, one step) and `//python/smoke:pypi_smoke_macos_arm64` for `--target-platforms komira//tools/build/platforms:darwin-arm64`, runs `pypi_smoke dist` with its record, copies the quickstart files, and keeps `pypi-<version>-macos-arm64-dist` and `pypi-<version>-macos-arm64-smoke` (both drivers, the quickstart files, `pythons.json`, `built.txt`). Its output `version` is empty when nothing was built. No upload step. |
| `testpypi-macos-arm64`, `testpypi-smoke-macos-arm64`, `testpypi-passed-macos-arm64`, `result-testpypi-macos-arm64` | push | as their twins in `pypi.yml` | as their twins in `pypi.yml` | the same as `pypi.yml`'s `testpypi`, `testpypi-smoke`, `testpypi-passed` and `result-testpypi` on the macOS dist, when the build made a wheel: the upload with the Linux driver (no storage steps), the smoke on the hosted runner `macos-15` (Apple silicon) with the macOS driver, the record under `pypi-passed-macos-arm64-<version>`, the verdict. |
| `promote-macos-arm64`, `pypi-macos-arm64`, `pypi-smoke-macos-arm64`, `result-pypi-macos-arm64` | promotion | as their twins in `pypi.yml` | as their twins in `pypi.yml` | the same as `pypi.yml`'s promotion from the newest macOS record (the prefix `pypi-passed-macos-arm64-`), with the Linux driver on ubuntu and the macOS driver on `macos-15`; no storage steps. |

Both chains are in the concurrency groups of `pypi.yml`, `pypi-testpypi` for a push run and `pypi-promote`
for a promotion, each with `cancel-in-progress: false`. `//:pypi_workflow_cases` holds the file: the contract
files (`pypi_workflow_contract.zig` for the Linux jobs and the triggers, `pypi_macos_jobs_contract.zig` for the
macOS jobs) pin the triggers, the groups, the nineteen jobs in order with each one's `if:`, runner, `needs`,
environment and permissions, and each job's outputs and steps after the build; the plays
(`pypi_workflow_run.zig`, `pypi_macos_jobs_run.zig`) run the file for each event and answer and look at it one
chain at a time: for every pair of a Linux and a macOS outcome of a push or a promotion, a chain's verdict is
green exactly when that chain passed, and the run is green only when both chains are.

**The macOS wheel's chain is independent of the Linux one.** The two chains share a file, not a dependency: a
job needs only jobs of its own chain, no job of either reads the other's results, artifacts or record, and
each chain's verdict job names its own failures (the annotation title is `pypi` for the Linux chain and
`pypi-macos-arm64` for the macOS chain). A red macOS chain never holds the Linux wheel, and a red Linux chain
never holds the macOS wheel; the run is red when either is, so a red macOS chain makes the `pypi` run red.
Both chains of a push build
the same commit (each build job runs the same stamp step), so they carry the same stamp and the same version; the Linux file is
`komira-0.1.<N>-py3-none-manylinux_2_35_x86_64.whl` and the macOS file
`komira-0.1.<N>-py3-none-macosx_11_0_arm64.whl` (the platform `darwin-arm64`, whose floor is macOS 11.0), two
files of one release. Each chain has its own artifacts and its own record, so each promotes the newest
version of its own that passed ([what a Mac user gets](#what-a-mac-user-gets)). A Mac build is the scarce
resource, so it is asked for only when needed: `build-macos-arm64` builds the file name first (no compile)
and runs `pypi_smoke present` against TestPyPI, and every Mac build after that step, and every step after it
but the one that stops buck2, carries `if: steps.testpypi_file.outputs.present != 'true'`: a re-run, or a
push that changed only what the stamp ignores, builds nothing on the Macs. `//:release_macos_cases` holds
the order, the exact gate on each Mac build, that the file-name build alone is ungated, that
`build-macos-arm64` runs on the ubuntu runner with the macOS worker set, hosts and the `tls` literal, that the
macOS smoke jobs run the macOS driver, that each macOS job is in its half.

**What the macOS wheel holds, read back.** Before anything is uploaded, the build holds the wheel to what a
Mac loads (python/BUCK, "The macOS wheel, read back"). The wheel rule refuses, on every member
(`tools/build/package/native_policy/policy.zig`, `codesign.zig`): an ELF file (a Linux library), a Mach-O file for a
CPU other than arm64 or a universal one, a minimum macOS (LC_BUILD_VERSION) above the tag's `macosx_11_0`,
an install name that is not `@rpath/<file>`, a run path that is not `@loader_path`-relative, a load that is
neither a member nor under `/usr/lib` or `/System/Library`, and a code signature that is missing or whose
CodeDirectory hashes do not match the file (macOS on arm64 maps no unsigned code). The step `the macOS
wheel read back` builds two checks of the finished file: `//python:wheel_libs_macos_arm64` walks the
loads from `komira/_lib/libkomira.dylib` as dyld does, through each library's own LC_RPATH, so every
`@rpath` and `@loader_path` load is a member of the wheel and every Mach-O member is loaded (nothing
points at a build path, a home directory, Homebrew or conda), and the three Mojo runtime dylibs carry the
darwin toolchain's bytes; `//python:wheel_same_macos_arm64` holds it to the Linux wheel of the same stamp:
the same Python files, METADATA (so the same Requires-Python and classifiers) and licence files byte for
byte, WHEEL differing only in its Tag's platform part (both `py3-none`), and the files only one wheel has
are its native libraries: `libkomira.dylib` and the three runtime dylibs on macOS; `libkomira.so`, the
eleven native owner libraries and the three runtime `.so` files on Linux.


### Which run to look at

There is one run of `pypi` per push and one per promotion; the job names say which chain a failure is in, and
the verdict jobs annotate it under the title `pypi` (Linux) or `pypi-macos-arm64` (macOS).

| to know | look at |
|---|---|
| whether a merge's Linux wheel was built, passed its user test, reached TestPyPI and installs from there | the `pypi` run of that push; its verdict is the job `result-testpypi` |
| whether the same merge's macOS wheel did | the same run; its verdict is `result-testpypi-macos-arm64` |
| what reached PyPI today, and why a newer version did not | the scheduled `pypi` run: `result-pypi` for Linux, `result-pypi-macos-arm64` for macOS; each names the versions it skipped |
| how full the indexes are | the job summary of `testpypi` in a `pypi` push run, or of `promote` in a `pypi` promotion |
| whether `main` is red | the `main red` issue: [`main_red.yml`](#main_redyml-the-main-red-alert) reads the push runs of `release` and `pypi` (not of `release-macos`), so a red macOS chain, which makes the `pypi` run red, opens or keeps it |

Until the farm's macOS workers run build actions, every push run of `pypi` is red at `build-macos-arm64`
(`the macOS build job did not succeed`) and every promotion is red at `promote-macos-arm64` (no macOS record
exists, `fail-on-cache-miss`): that is the macOS chain reporting, and it says nothing about the Linux wheel,
whose jobs and verdict are green or red on their own.

### Trusted publishing of the macOS file

An index's trusted publisher names the repository, the workflow file and the environment; an upload from any
other file is refused by the index. The macOS uploads (`testpypi-macos-arm64` and `pypi-macos-arm64`) are in
`pypi.yml`, as the Linux uploads are, so the one publisher each index has for `pypi.yml` (environment
`testpypi` on TestPyPI, `pypi` on PyPI) covers both wheels, and nothing needs adding on either index.

A publisher that names any other workflow file of this repository matches no upload; the index owner may
remove one, and nothing breaks if it stays.

### What a Mac user gets

PyPI holds, for each version, the files promoted for it, and each platform is promoted on its own (the
newest version whose TestPyPI smoke passed for that platform; `pypi_smoke promote` compares PyPI's newest
version of the same wheel tag only, so a newer Linux file never blocks an older macOS one). pip on a Mac with
Apple silicon and macOS 11 or newer takes, of each version, only a file whose tag fits it
(`macosx_11_0_arm64`), and no source distribution is published, so:

- a version that has only the Linux file does not exist for pip on a Mac: `pip install komira` installs the
  newest version that has a macOS file, `pip install --upgrade komira` stays there, and
  `pip install komira==<that version>` fails with `No matching distribution found`;
- while no version had a macOS file (before 0.1.1623, the first with one), `pip install komira` on a Mac
  failed with `No matching distribution found for komira`; on an Intel Mac it always does;
- a lock file written on Linux (a pin, `uv lock`, Poetry) can name a version with no macOS file, and installing
  from it on a Mac then fails.

**Holding a version until both files passed is not done, and is not recommended now.** A hold (promote only
the newest version that passed on both platforms) would keep every version on PyPI installable on both, but
while the macOS build cannot run no version passes on macOS, so it would stop every PyPI release, Linux
included, for a gap outside the package; and a Mac user gains nothing from it, since pip already gives them
the newest version that has their file. Once macOS builds pass routinely, a hold costs at most a day's delay
and removes the lock-file failure, and is worth deciding then. The promotion rule is unchanged by the move
of the macOS wheel's jobs into `pypi.yml`.

## npm.yml: publishing the npm packages

[`.github/workflows/npm.yml`](../.github/workflows/npm.yml) builds, tests and publishes the npm packages of
[`node/`](../node/README.md) ([the design, section 4](design/typescript_package.md#4-release)): the main
package `@komira-ai/komira` and its platform packages `@komira-ai/komira-linux-x64-gnu` and, built on the
farm's macOS workers, `@komira-ai/komira-darwin-arm64` ([below](#the-macos-package-in-npmyml)). It is written by
hand. **It publishes nothing yet**: the publish waits for the owner's go (the design's D4), and the go is a
change of one committed file ([the gate](#the-publish-gate)). Until then every run builds the packages and
runs their install test, and the publish and the smoke are skipped.

It runs on a push to `main` that changes more than documentation (`paths-ignore`: `docs/**`, `**.md`, the
list of `release.yml` and `pypi.yml`), and on nothing else: no pull request, no schedule, no manual run. The
version is `0.1.<N>`, the wheel's (`<N>` the build number of `release_json stamp`), so the npm packages and
the wheel of one commit carry one version. Every run is in the concurrency group `npm-main` with
`cancel-in-progress: false`: a running run is never cancelled, and of the waiting runs only the newest is
kept, so two runs never publish at once.

| job | environment | permissions | what it does |
|---|---|---|---|
| `build` | `build` | `contents: read`, `id-token: write` (the tailnet only) | on the farm ([farm-connect](#how-it-reaches-the-farm), `farm-qos: batch`): builds `//release/ci:release_json` and takes the stamp, builds `//release/ci:npm_smoke` and the pinned `//third_party/node:node` and `//third_party/node:npm` (npm 11.20.0), reads the gate (`npm_smoke gate`, its output `publish`), builds `//release:npm_packages` with the three stamp flags and release.yml's three release values ([why](#stamped-builds-of-releasebuck)) and holds the directory to its record (`npm_smoke verify`, its output `version`). Keeps `npm-set-<sha>` (the tarballs and `npm_set.json`) and `npm-tools-<sha>` (`npm_smoke`, Node.js, npm) for 14 days. No publish step. |
| `test` | `build` | `contents: read`, `id-token: write` (the tailnet only) | on the farm: downloads the two artifacts, builds `//release:npm_packages[npm_set.json]` again with the build job's stamp and the release values, and runs `npm_smoke verify --built`: the kept directory is its record, and the record is the one this stamp builds, so the tarballs the install test installs (built from the same stamp, reproducible) are the kept ones. Then builds `//node:install_test` with the same stamp: npm installs the tarballs into an empty project and the package's tests import it by its name, on Node.js 22, 24 and 26. No npm identity. |
| `build-macos-arm64` | `build` | `contents: read`, `id-token: write` (the tailnet only) | on the farm with its macOS workers, beside `test`, with the build job's stamp ([below](#the-macos-package-in-npmyml)): builds `//node:install_test_macos_arm64` for darwin-arm64, then `//release:npm_packages_macos_arm64` (with the release values as well), holds the directory to its record (`npm_smoke verify`), and keeps it as `npm-set-macos-arm64-<sha>` for 14 days. No npm identity. |
| `publish` | `npm` | `contents: read`, `id-token: write` (trusted publishing) | only when `build`'s output `publish` is `true`, after `build` and `test` passed and `build-macos-arm64` ended, whatever its result (a cancelled run publishes nothing); no checkout, no farm, no build, no token. Downloads the set with the macOS package (`npm-set-macos-arm64-<sha>`) when `build-macos-arm64` succeeded and the set without it (`npm-set-<sha>`) otherwise, and the tools, and runs `npm_smoke publish`: holds the directory to `npm_set.json` again, then, for each platform package and last the main package (which names them in its `optionalDependencies`), asks the registry for that version and runs `npm publish <file> --access public` when it is absent. |
| `smoke` | none | none | only when `publish` ran and succeeded, with the set `publish` took (its output `set`); no checkout, no identity. Runs `npm_smoke smoke`: installs `@komira-ai/komira` at exactly the set's version from the registry into an empty project (`npm install --ignore-scripts --engine-strict`, tried up to five times, 30 seconds apart, while the registry catches up), holds the `integrity` npm recorded in `package-lock.json` for each package to `npm_set.json`, and, with no step between, runs `SELECT 1 AS n` through the installed package, which must print the set's version, `n` and `1`. The one job whose test reaches the network, and it reaches only the npm registry. |

**The set and its record.** `//release:npm_packages` ([release/npm_packages.bzl](../release/npm_packages.bzl))
is one directory: each package's tarball, under the name `npm pack` gives it, and `npm_set.json`, which
`npm_smoke set` writes from the tarballs as a build action: the main package's name, the version, and each
package's name, version, file, SHA-256 and the sha512 `integrity` npm reports, the platform packages first
and the main package last, the order they are published in. Stamped, it takes each package's `[release]`
tarball and refuses an unstamped one; a pull request builds it unstamped (`0.0.0`), which checks all but
the stamp. The main package names exactly the set's platform packages in its `optionalDependencies`:
`npm_smoke set` refuses the set otherwise (`--main-optional`, the names the main package's rule gives it),
so a main package never names a platform package that is not published with it. It is not a member of the
conda `//release:release_set` and not an entry of `release/artifacts.textproto`.
`//release:npm_packages_macos_arm64` is the same set with the macOS package and the main package that names
it ([below](#the-macos-package-in-npmyml)). [`release/npm_names.txt`](../release/npm_names.txt) lists the
two sets' names, and `//release:npm_names_cases` holds the list equal to them (the macOS set's names read
from the list `release/BUCK` declares it with, `//release:npm_macos_arm64_names`, since a pull request does
not build it).

**The tool.** [`//release/ci:npm_smoke`](../release/ci/npm_smoke/cli.zig) is one Zig program for every
step (`set`, `gate`, `verify`, `publish`, `smoke`), built behind its cases
(`//release/ci/tests:test_npm_smoke`, with npm and node in memory), so each step of the workflow is one
command. It runs the pinned npm as `<node> <npm>/bin/npm-cli.js` with the public registry, the config files
of its own work directory, written empty, and a cache of its own, so no npmrc of a runner is read. Trusted
publishing needs npm 11.5.1 or later under Node.js 22.14 or later; the pins are npm 11.20.0 and Node.js
24.21.0.

### Stamped builds of release/BUCK

`release/BUCK` holds `//release:npm_packages` and also calls the macro `release_set`
([release_set.bzl](../release/release_set.bzl)), which fails the evaluation of the whole file, and so the
build of every target in it, when the build is stamped (`komira.package_stamp` set to anything but `0`) and
does not also pass `komira.release_revision`, `komira.release_run_id` and `komira.release_attempt`. So the
three stamped builds of `release/BUCK` in `npm.yml` (the set twice, and the macOS job's
`//release:npm_packages_macos_arm64`) pass the three values exactly as `release.yml`'s build of
`//release:release_set` does (`${{ github.sha }}`, `gh-${{ github.run_id }}`, `${{ github.run_attempt }}`);
the set reads none of them. A pull request builds everything unstamped, so its check never evaluates
`release/BUCK` this way. `//:release_stamp_cases`
([release_stamp_test.zig](../.github/workflows/release_stamp_test.zig) says what it holds), part of the pull
request's check, reads every workflow and local action instead: each command that sets
`komira.package_stamp` and names a target of `release` or of a package that holds a target depending on one
of `release` (the root package, `ci` and `tools/build/ci`; any target of them counts, which is stricter than
the failure), or a recursive pattern over one, must pass the three values, and a
new workflow is read the same way. It also holds `release_set.bzl` to read exactly those keys, so a fourth
value it starts to need turns the case red.

### The publish gate

[`release/npm_publish.txt`](../release/npm_publish.txt) holds one line, `publish: off` or `publish: on`.
`build` reads it (`npm_smoke gate`, the step `gate`) and hands it on as its output `publish`; `publish` and
`smoke` run only when it is `true`. The file says `publish: off`. The owner's go is a pull request that
changes it to `publish: on`, after the owner steps below; it is under `release/`, so it needs the release
approver's review. `//release:npm_publish_gate_cases` refuses any other text, so a typo or a merge cannot
leave a gate the build job would fail on, or read as on. To stop publishing again, the same change back.

### Trusted publishing

npm's trusted publishing binds a package's publisher to the workflow file name and an environment, so
publishing has a file of its own, as PyPI's has, and only the job `publish` runs in the environment `npm`.
npm exchanges that job's OIDC token for the publish and generates the provenance itself: no `NPM_TOKEN`
exists, and no secret is read. `build`, `test` and `build-macos-arm64` hold `id-token: write` for the farm
connection alone, in the environment `build`, which npm does not trust. `smoke` holds no permission.
`//:npm_workflow_cases` ([npm_workflow_test.zig](../.github/workflows/npm_workflow_test.zig) says what it
holds) pins the trigger, the top-level `permissions: {}`, the five jobs and each one's condition, runner,
`needs`, environment and permissions, the gate, the set `publish` and `smoke` take, the macOS job's install
test, set and artifact in that order with no step it may skip or pass over, that only `publish` runs the
publish command and that neither `publish` nor `smoke` has a checkout, the farm or buck2, and that no line
names a token or a secret; each defect written into the real file is refused.

### The macOS package in npm.yml

`@komira-ai/komira-darwin-arm64` (`//node:package_macos_arm64`: the Mach-O addon and libkomira's macOS
directory, `libkomira.dylib` and the three Mojo runtime libraries, as the macOS arm64 wheel carries them) is
built for darwin-arm64 by the job `build-macos-arm64`, on the farm's macOS workers, never by a pull request
(rule B9). The job runs beside `test`, after `build`, whose stamp it takes, so both sets carry one version.
farm-connect passes it the macOS worker set and hosts (`FARM_DARWIN_ARM64_PROPERTIES`,
`FARM_DARWIN_MACOS_HOSTS`, `FARM_MACOS_LIBRARY_DIRS`), as it does `pypi.yml`'s macOS job.

1. `//node:install_test_macos_arm64`, with `--target-platforms komira//tools/build/platforms:darwin-arm64`:
   on a macOS worker, the pinned npm installs `//node:package_with_macos_arm64` (the main package naming both
   platform packages) into an empty project, offline and with no install script, npm resolves its platform
   package to the macOS one by `os` and `cpu`, and `node/install/`'s tests import it by its name on the
   macOS Node.js 22, 24 and 26 (`//third_party/node:node_22_macos_arm64` and the others, unpacked by the
   macOS build of `node_act`). The tests load the addon and `libkomira.dylib`, ad-hoc signed by the linker
   and nothing else, from the files npm wrote; the loader refuses a library it will not run (an invalid
   signature, or a quarantine Gatekeeper rejects), so the load is the test of those files.
2. `//release:npm_packages_macos_arm64` from the same stamp: the macOS package configured for darwin-arm64 by
   the set's transition, as step 1 configured it, so its tarball is the one step 1 installed; the linux-x64
   package and the main package are built on the Linux workers. `npm_smoke verify` holds the directory to
   its record, and the job keeps it as `npm-set-macos-arm64-<sha>`.

`publish` takes that set when the job succeeded, and `npm-set-<sha>` (`//release:npm_packages`, whose main
package names the linux-x64 package alone) otherwise: when the install test failed, the build failed, or the
job ran out of its 120 minutes, nothing was kept, and the main package of the release does not name the
macOS package. The Linux packages are published whatever the Macs did; `publish` waits for the job to end. A
failed macOS job turns the run red. `publish` hands its choice on as its output `set`, which `smoke` reads,
so a re-run of failed jobs that re-runs the macOS job but not `publish` cannot point the smoke at another set
than the one published; a re-run of `publish` itself after the macOS job's result changed stops at the main
package (the registry holds that version with other bytes), and the next code commit publishes again. Both steps build with `-c komira_release.mac_tree=true`, the gate of the
targets that need the macOS execution platform; pr.yml's last step configures and analyses the macOS package,
its install test and the set with it (`release/darwin_analysis.bxl`), running no action, so a change that
leaves them unanalysable fails its pull request.

### A failed run

npm creates a (name, version) once. `npm_smoke publish` asks the registry for each version first: one it
holds with the set's integrity is not published again (a re-run of a run whose publish stopped part way),
and one it holds with other bytes stops the job before anything else is published. A run that fails before
the main package is published leaves only platform packages that nothing names, and the next code commit
publishes `0.1.<N+1>`. A failed smoke turns the run red ([main_red.yml](#main_redyml-the-main-red-alert)
watches `npm`); whether to `npm deprecate` that version is the owner's call. No one publishes by hand.

### Owner steps before the first publish

- Confirm that the `komira-ai` scope on npm is the company's.
- Create each package of `release/npm_names.txt` (`@komira-ai/komira-darwin-arm64` among them) on npm with
  its trusted publisher: the repository
  `komira-ai/komira`, the workflow `npm.yml`, the environment `npm`. Whether npm lets a trusted publisher be
  configured before the package exists, and so how the first version of each is created, is the owner's to
  settle.
- Create the environment `npm` on GitHub, deployable from `main` only.
- Then change `release/npm_publish.txt` to `publish: on`.

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
| steps | the pinned full-history checkout of the merge commit (a merge group: its head commit), `farm-connect`, and the farm assertion (`//tools/build/ci:assert_remote`). Then the change, written by `//tools/build/ci:change` (built on the farm like the assertion, run on the runner in the checkout, with the event, the merge group's `base_sha` and the output directory as flags; `tools/build/ci/change/change.zig` says what it runs and refuses, and its cases run its choice of base against a fake git): `git diff --name-only <base>...HEAD` and the coverage holds of both sides. A pull request's base is HEAD^1, the merge commit's first parent (the `main` the pull request is merged into; the step stops when HEAD has no second parent). Never the event's `github.event.pull_request.base.sha`: that is `main` when the event fired, and once `main` moves every change merged to it since then would count as the pull request's own and widen the check. A merge group's base is its `merge_group.base_sha`, the commit the group's head was built on (the step stops when it is not an ancestor of HEAD); the head is a squash commit on top of it, not a merge commit. Any other event stops the step. Then, each as the `buck2-farm` action (so each fails unless no action ran on the runner): the BXL selector `tools/build/ci/affected.bxl:affected` (the owners of the changed files and everything that depends on them, or `//ci:pr`, the whole check set, when a file cannot be mapped or touches the build system; the heavy checks of `HEAVY` in `tools/build/ci/rules.bzl`, today none since only `komira_base` reaches them, only when the change touches paths that row owns, so a change that owns none builds `//ci:pr_default` in place of `//ci:pr`), `build --keep-going` of its list, the checks only BXL can make over the whole graph (`test_weld.bxl:check` for each test_weld lint, `graph/checks.bxl:check` for each graph_check, `guard.bxl:check` that `//ci:pr` holds every check target, `python_guard.bxl:check` that it reaches no Python outside the SDK, `default_guard.bxl:check` that `//ci:pr_default` is `//ci:pr` without the roots of `HEAVY` and nothing else, `lock_graphs.bxl:check` that each package's `buildrules.mojo.lock.bzl` holds a unit graph for every platform subdir its `mopm.lock` records and that a package which loads a native shared library pins it in `system_libs` of that lock, `cases.bxl:run`, and `readme_e2e/cases.bxl:run`, the cases of the README e2e's completeness guard), and `test` of the list's targets that are not of the tests cell. Then [the macOS part](#the-macos-part-of-the-check): `tools/build/ci/darwin.bxl:select` over that list, its labels written by `//tools/build/ci:darwin_targets` (built on the farm like the change tool), and, when there is one, `build --config-file $RUNNER_TEMP/darwin.buckconfig --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going` of its labels (bounded at 60 minutes), skipped when an earlier step failed. Last, the analysis of the whole macOS set (`release/darwin_analysis.bxl:check`). A pull request that adds or deletes a package needs no edit to any release file; adding a root to the check set means adding its one empty file, `ci/roots/<cell>/<package>:<name>` (`ci/test_roots/...` for a test), and a new target that depends on an old root deletes the old root's file, so two pull requests that add targets never edit the same file (the guard fails, naming each file to add or delete and the command that writes them all, when they are out of date: [tools/build/ci/README.md](../tools/build/ci/README.md#the-aggregate-cipr)). Nothing ships. |
| every `uses:` | pinned to a full commit id (the local farm-connect action excepted) |

The repository's branch settings require the check **`pr / check`**.
`//:pr_workflow_cases` (`.github/workflows/pr_workflow_test.zig`) holds the
trigger, the job's condition, the concurrency group, that the change step runs
the change tool with the event and the group base, and the job's bound below the
queue's check timeout, and that no other workflow has a job `check`.

### Adding a target: one file per root

`//ci:pr` lists its roots as literal labels, so they are committed, one empty
file per root named by its label (`ci/roots/komira/src/avro:avro_conda`;
`ci/test_roots/...` for a test; [tools/build/ci/README.md](../tools/build/ci/README.md#the-aggregate-cipr)).
Before, they were rows of eight sorted shard files, so two pull requests that
added targets near each other in one shard (any two task-example batches did,
in one package) conflicted, and each had to merge `main` and regenerate after
every other merge. With one file per root, two such pull requests add
different files and merge in either order. The ways weighed, with what each costs:

| | Merges of two pull requests that add targets | The check's time | What the guard proves |
|---|---|---|---|
| one file per root (this) | no conflict, in one package or two | as before: `ci/BUCK` globs about 1300 empty files | as before: every root has its file and every file is a root's, both ways, each named by its path |
| one committed file per top-level package | a conflict still, for two in one package (`src/` holds most rows) | as before | as before |
| the lists made in the check from the graph, none committed | no file to conflict | a query of the whole graph before the build (the guard asks it already) | nothing about a list: the list is the graph's by construction, and `./buck2 build //ci:pr` with no committed list is no longer one target a person or a step can name |

A pull request opened before this layout conflicts once: each shard file it
edited (`ci/targets/shard_<n>.bzl`) is a modify/delete conflict with `main`,
which deleted them all (the files it did not edit are deleted with no conflict).
Merge `main`, take the deletion of whatever is left
(`git rm -qf --ignore-unmatch ci/targets.bzl 'ci/targets/shard_*.bzl'`), and write the roots
from the graph (the command in the README), or add the one file the guard names
for each root the pull request adds. From then on the pull request merges with
the others with no second round.

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
- **A merge group builds for macOS too.** Its `pr / check` has the same
  [macOS part](#the-macos-part-of-the-check): the libraries of the set the group's change reaches are
  built for darwin-arm64 on the farm's Macs before `main` moves. The whole set builds again in
  `release-macos.yml` on the push to `main`
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
alert. It runs when a run of `release.yml`, `pypi.yml` or `npm.yml` on `main` completes (`workflow_run`),
builds the Zig program [`//release/ci:main_red`](../release/ci/main_red.zig)
on the farm (`./buck2 build`, then runs the binary that build produced) with
`issues: write`, `actions: read`, `contents: read` and the `id-token: write`
the farm connection exchanges, checking out `main` and running no code of any
pull request. The workflows it reads are `--workflow <name>` flags of that
step (and the trigger's `workflows:` list): the program names none itself, so
a replacement push workflow is added to both in its own pull request. It names
three: `release`; `pypi`, whose push run builds the Python wheels (Linux and macOS) and installs them from their files
and from TestPyPI (its scheduled and manual runs are not push runs and are never read); and `npm`, whose
push run builds the npm packages and runs their install test (and, once its gate is on, publishes and smokes
them). The macOS
workflow `release-macos` is not named: a Mac build is reported, not blocking
([The macOS build of the release](#the-macos-build-of-the-release)), so its red run opens no issue. The macOS
wheel's jobs are in `pypi.yml`, so a red macOS chain makes the `pypi` run red and is reported; the
macOS packages the release publishes are built by `release`'s own `mopm-stage`, so a macOS build of them
that fails there is a red `release` run. A green run of
either closes the open issues whose heads it contains, so an issue opened for a red `pypi` run can be
closed by a green `release` run of a later commit; the next red `pypi` run opens or comments again. It acts
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

**Nothing hides a red `main`.** The push runs of each watched workflow share one
concurrency group with `cancel-in-progress: false` (`release-main`, and `pypi-testpypi`): a running run is never cancelled,
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

## A cold build of the Linux check set

How long the farm takes when nothing is cached: the Linux set that `pr / check` builds when a change
is built as the aggregate (`//ci:pr`; `//ci:pr_default` is the same set while `HEAVY` is empty), and
the smaller set of `//src/arrow:arrow` and `//src/bench:bench`. A cold measurement is a sanctioned
use of `--no-remote-cache` (B2), never a step of CI. Run it from a fresh worktree at the commit to
measure, when the farm's queue is quiet:

```sh
./buck2 kill && ./buck2 clean
./buck2 cquery 'deps(//ci:pr)' > /dev/null
./buck2 build --no-remote-cache --keep-going --console simple //ci:pr
```

`kill` gives the build a fresh daemon and `clean` drops the outputs of earlier builds in the
worktree. The `cquery` does the analysis first, so the build's time is its execution. The summary
must read `Commands: N (cached: 0, remote: N, local: 0)`. Without `--keep-going`, buck2 starts no
new action after the first failure, so a failed build reports fewer commands than the set has.

The measured builds. `main at` is the merge commit of that pull request on main. The wall times are
`date -u` taken around the build command, except the first row's, which is the build's time from the
record of that run; the `Commands:` lines and the exit codes are buck2's final summary:

| main at | targets | flags | wall | buck2 summary | exit |
|---|---|---|---|---|---|
| komira-ai/komira#2106 | `//src/arrow:arrow //src/bench:bench` | `--no-remote-cache` | 4,818 s (20 Nov 2026) | `Commands: 341 (cached: 0, remote: 341, local: 0)` | 3 |
| komira-ai/komira#2106 | `//src/arrow:arrow //src/bench:bench` | `--no-remote-cache` | 639 s (24 Nov 2026, 02:49:15Z to 02:59:54Z) | `Commands: 482 (cached: 0, remote: 482, local: 0)` | 0 |
| komira-ai/komira#2194 | `//ci:pr` | `--no-remote-cache --keep-going` | 21,101 s (24 Nov 2026, 04:23:53Z to 10:15:34Z) | `Commands: 24028 (cached: 0, remote: 24028, local: 0)` | 2 |

The first two rows build the same commit and targets. The 20 Nov build failed when its test action
`test_codec_libraries` was killed (exit code 137) and it ran without `--keep-going`; either is a
likely reason it reports 341 commands to the later build's 482 (inferred, not measured).

The `//ci:pr` build at komira-ai/komira#2194 failed three actions; this list is of that commit only:

- `buildrules//rules/coverage/branch:llvm23` (`llvm_branch_unpack`): a farm fault, not a build
  defect. The farm answered `the task tool exited nonzero (exit code Some(-1))`, with no output from
  the action.
- `//src/trace:test_span_microbench__cov` (`mojo_cov_run`): the test failed its assertion
  `one name, registered once` (2, expected 1) at `src/trace/tests/test_span_microbench.mojo:103`.
- `//src/bench_q6_phases:bench_q6_phases` (`mojo_build_test test_probe_phases`): the link step
  failed with `unable to find suitable c compiler for linking`.

Each action's wait in the farm's queue, from `queue_time_us` in the build's event log
(`./buck2 log show`): the second row's build waited 2.1 s at the median and 11.9 s at p90; the
`//ci:pr` build waited 36.1 s at the median, 111.7 s at p90 and 589 s at most. In both builds the
first 20 actions waited under 10 s, so the queue was quiet when each started; in the `//ci:pr` build
the farm's capacity set the pace (inferred from the queue times).
