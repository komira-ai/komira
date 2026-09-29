# Continuous integration

`.github/workflows/ci.yml` has two jobs.

| job | runs for | reaches the build farm | what it runs |
|---|---|---|---|
| `static` | every push to `main`, every pull request (forks included), nightly, manual | no | `.github/ci/static_checks.sh`, and a download of the pinned buck2 checked against its sha256 |
| `farm` | pushes to `main`, nightly, manual runs of `main`, and pull requests from a branch of this repository once a maintainer approves the run | yes, as an ephemeral tailnet node | `tools/build/checks/run_checks.sh` on remote execution |

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
5. Secrets and uploads are fenced (`.github/ci/workflow_fences.py`): a job
   that reads a secret names an `environment:`, nothing outside a job reads
   one, and an artifact upload runs only if the job's `redact` step
   succeeded.

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
   `BUCKCONFIG_LOCAL` environment secret. No committed file names the farm.
   Each address in it is registered with the runner's log masking. It refuses
   a config whose `instance_name` is not a CI sub-instance, one whose last
   `/`-separated component is `ci` (see "What farm access means" below).
3. `.github/ci/fetch_buck2.sh` installs the buck2 that `tools/buck2` pins,
   reading the URL, size and sha256 from that file, so CI and a developer run
   the same binary.
4. `tools/build/checks/run_checks.sh` runs with `TMPDIR` in the runner's temp directory.

The runner keeps no cache of its own: the farm's action cache and CAS are the
cache. Builds use deferred materialization, so the runner downloads only what
a check reads.

The execution platforms set `allow_cache_uploads = False`, so buck2 itself
does not upload action results from the runner. That is a setting in
`tools/build/platforms/defs.bzl`, which a change can edit; it is not a control. The
controls are on the service side, below.

On failure, `buckconfig_local.sh redact` replaces every address from
`.buckconfig.local`, and as a backstop every private or shared-range IPv4
address, with `<redacted>` in the check logs, deletes any copy of the file,
then re-reads every file and fails if any of those strings remains. The logs
are uploaded as a workflow artifact only if that step succeeded; if
redaction fails, nothing is uploaded. Artifacts of a public repository can be
downloaded by anyone, and log masking does not apply to them.

## What farm access means

Remote execution runs the commands a build describes. A run of the `farm`
job can therefore run any command on the remote-execution workers, and on a
typical Buildbarn deployment that is more than "a build": unless the service
is hardened, an action runs with the worker's privileges, on the worker's
network, next to the shared storage servers. A malicious action there can
write action-cache entries for any instance name directly to storage, and can
tamper with files a worker shares between actions. Denying action-cache
writes at the client-facing endpoint does not stop that, because the action
does not come through that endpoint.

So CI gives farm access only to code that someone trusted has pushed or
approved, and it narrows what an accident or a leaked credential can reach:

- CI uses its own instance name, a sub-instance ending in `/ci` (for example
  `<prefix>/ci`). Buildbarn keys the action cache by instance name, so CI's
  entries live apart from those of developers' builds, while its actions
  still reach the same workers (a scheduler routes a sub-instance to workers
  registered for its prefix). This keeps CI from writing developers' entries
  through the service's front door. It does not stop an action that talks to
  storage directly.
- The farm credentials live in GitHub Environments with branch and reviewer
  rules (below), not in repository secrets.
- The tailnet policy lets `tag:ci` reach the remote-execution endpoint on one
  host and nothing else.

What closes the rest is on the service side, and is the farm operator's to
apply: authenticate the storage and scheduler servers so only worker
identities can write the action cache or register as workers; run actions as
a non-root user with no write access to the worker's shared cache; restrict
the workers' network so an action cannot reach storage or the scheduler; deny
action-cache writes at the client-facing endpoint. Until then, treat a `farm`
run as able to affect every build that uses the same service.

## Pull requests from forks

A pull request from a fork never reaches the farm. Remote execution runs the
commands a build describes, so farm access is code execution on the workers;
it is given only to code that someone with write access to this repository
has pushed.

Two independent things enforce this:

- The `farm` job's `if:` skips it unless the pull request's head branch is in
  this repository. Only people with write access can push one.
- GitHub gives a `pull_request` run from a fork no secrets (repository or environment) and a
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

A skipped job satisfies a required status check, so a fork's pull request
shows `farm` as passed without having run it. Merge a fork's change only
after its commit has a `farm` run from a branch of this repository.

Pull requests from a branch of this repository run `farm` through the
`farm-pr` environment, which requires a maintainer to approve each run. The
branch's own workflow file is what runs, so before approving, read the whole
change, `.github/` included: an approved run gets the farm secrets.

The `farm` job skips pull requests opened by Dependabot (they get Dependabot
secrets, not these). Push the change to a branch of this repository to test
it on the farm.

## Repository settings CI expects

- No repository secrets. Two environments (Settings > Environments), each
  holding `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` (a Tailscale OAuth client
  that may create auth keys for `tag:ci`) and `BUCKCONFIG_LOCAL` (the whole
  `.buckconfig.local`, in the format of `.buckconfig.local.example`, with
  `instance_name = <prefix>/ci`):
  - `farm`: deployment branches "Selected branches", `main` only. A branch
    that edits the workflow to name `farm` is refused before any step runs.
    Manual runs work from `main` only.
  - `farm-pr`: required reviewers (maintainers), "Prevent self-review" on
    when there is more than one maintainer. Every pull-request run waits for
    approval.
- Stronger, if you can: Tailscale workload identity federation instead of an
  OAuth secret. The pinned `tailscale/github-action` accepts `oauth-client-id`
  plus `audience` with `permissions: id-token: write`; trust the subjects
  `repo:komira-ai/komira:environment:farm` and
  `repo:komira-ai/komira:environment:farm-pr`. No long-lived Tailscale
  secret is then stored in GitHub, and a token is valid for one run.
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
