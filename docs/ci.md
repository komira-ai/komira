# Continuous integration

`.github/workflows/ci.yml` has two jobs.

| job | runs for | reaches the build farm | what it runs |
|---|---|---|---|
| `static` | every push to `main`, every pull request (forks included), nightly, manual | no | `.github/ci/static_checks.sh`, and a download of the pinned buck2 checked against its sha256 |
| `farm` | pushes to `main`, pull requests from a branch of this repository, nightly, manual | yes, as an ephemeral tailnet node | `tools/build/checks/run_checks.sh` on remote execution |

`farm` waits for `static`, so a lint failure stops a run before it uses the
farm.

## What each job checks

`static_checks.sh` needs no secret and runs nothing from the change except as
text to lint:

1. shellcheck, severity warning, over every tracked shell script. Scripts the
   rules run as `busybox sh <script>` have no shebang and are checked as
   busybox. A per-file exclusion must name a file that exists.
2. actionlint over the workflows.
3. Every `uses:` names a full commit SHA, never a tag or branch.
4. No committed file configures remote execution: `.buckconfig` names no
   endpoint, and `.buckconfig.local` is gitignored and untracked.

shellcheck and actionlint are downloaded at pinned versions and refused unless
their sha256 matches the pin in the script.

`farm` runs `tools/build/checks/run_checks.sh` in full, the umbrella-mount check included
(a manual run can turn that one off). Most of it is remote cache hits; the one
part that always executes on the farm is the uncached build behind the
per-action platform check. The nightly run re-checks `main` when nothing was
pushed, which catches drift on the farm side (cache eviction, workers,
toolchain downloads).

## How the farm job reaches the farm

1. `tailscale/github-action` joins the tailnet with an OAuth client, as an
   ephemeral node tagged `tag:ci`. The node is removed when the runner goes
   away. The tailnet policy lets `tag:ci` reach the remote-execution port and
   nothing else.
2. `.github/ci/buckconfig_local.sh write` writes `.buckconfig.local` from the
   `BUCKCONFIG_LOCAL` repository secret. No committed file names the farm. Each
   address in it is registered with the runner's log masking.
3. `.github/ci/fetch_buck2.sh` installs the buck2 that `tools/buck2` pins,
   reading the URL, size and sha256 from that file, so CI and a developer run
   the same binary.
4. `tools/build/checks/run_checks.sh` runs with `TMPDIR` in the runner's temp directory.

The runner keeps no cache of its own: the farm's action cache and CAS are the
cache. Builds use deferred materialization, so the runner downloads only what
a check reads.

Clients never write the action cache (`allow_cache_uploads = False` on every
execution platform); results enter it only from executed actions.

On failure, the check logs are uploaded as a workflow artifact, after
`buckconfig_local.sh redact` has replaced every address from
`.buckconfig.local` with `<redacted>` and deleted any copy of the file.
Artifacts of a public repository can be downloaded by anyone, and log masking
does not apply to them.

## Pull requests from forks

A pull request from a fork never reaches the farm. Remote execution runs the
commands a build describes, so farm access is code execution on the workers;
it is given only to code that someone with write access to this repository
has pushed.

Two independent things enforce this:

- The `farm` job's `if:` skips it unless the pull request's head branch is in
  this repository. Only people with write access can push one.
- GitHub gives a `pull_request` run from a fork no repository secrets and a
  read-only token, whatever the workflow file in the fork says. Without the
  OAuth secret the runner cannot join the tailnet, and without
  `BUCKCONFIG_LOCAL` it does not know where the farm is. Editing the `if:` in
  a fork gains nothing.

This workflow deliberately uses no `pull_request_target`. That event runs in
the context of this repository, with its secrets and a token that can write;
it is meant for workflows that never execute the pull request's code.
Checking out the fork's head under it and building it gives that code the
secrets (the "pwn request" pattern). A "safe to test" label on top does not
fix it: the label approves a pull request, not a commit, so a push after the
label runs unreviewed code, and even the reviewed commit can edit the build
rules or the scripts that run with the secrets.

To run a fork's change on the farm, a maintainer reviews it and pushes the
reviewed commit to a branch of this repository, then opens a pull request
from that branch:

```sh
git fetch origin pull/<N>/head
git push origin FETCH_HEAD:refs/heads/ci/pr-<N>
```

The run tests exactly the commit the maintainer pushed.

Pull requests opened by Dependabot also receive no repository secrets, so
their `farm` job fails at the tailnet step. Push the change to a branch of
this repository to test it on the farm.

## Repository settings CI expects

- Secrets: `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` (a Tailscale OAuth client
  that may create auth keys for `tag:ci`), and `BUCKCONFIG_LOCAL` (the whole
  `.buckconfig.local`, in the format of `.buckconfig.local.example`).
- Settings > Actions > General > "Approval for running fork pull request
  workflows from contributors": "Require approval for all external
  contributors". This limits what a fork can run on GitHub's hosted runners;
  it is not what keeps forks off the farm.
- Settings > Actions > General > "Workflow permissions": "Read repository
  contents and packages permissions". The workflow also sets `permissions:`
  per job.

## Running the checks yourself

```sh
.github/ci/static_checks.sh "$(mktemp -d)"   # linux x86_64; no farm needed
checks/run_checks.sh                         # needs .buckconfig.local
```
