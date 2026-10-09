# Container validation: running an image as a validation, in the cell

Status: design, no code. It extends [the DEPLOY step](deploy_step.md)'s `DEPLOY_PROBE` validation kind
(grammar V1, runner V2, wiring V3, workflow check D6) and builds on its GCP adapter (G4). The job it runs
follows komira's job model: one binary under `komira_job_supervisor`, which is the container's PID 1
(#1050). Every name below that is not in `main` is new here.

## What is it for, and what is out of scope?

A `DEPLOY_PROBE` runs the operator's image, pinned by digest, with `docker run` on the machine that runs
`kci run`, against the cell a DEPLOY step just deployed into. kci reads what the image wrote and decides
the verdict. This document adds the general form: **run an image as a validation, inside the cell**, as a
one-shot cloud job that kci creates, waits on and deletes.

Running in the cell matters for two reasons the runner cannot meet in v1:

- **No docker daemon.** A `kci run` that itself runs as a cloud job or in a pod has no docker daemon, and
  mounting a node's docker socket would give root on the node.
- **The published image itself.** A validation can run the image a PUBLISH step just pushed into the
  cell's private registry, by digest, on fixed input (a static-data test). The runner cannot pull it
  anonymously, and the cell can.

**Private endpoints are a later phase.** A Cloud Run job reaches only public addresses unless its spec
sets Direct VPC egress (`template.template.vpcAccess`) or a connector, and G4's job model writes no
`vpcAccess`. So a v1 `CELL` probe reaches what a hosted runner reaches. The later phase adds a cell
setting naming the network and subnetwork (read by the adapter's `configure`, like `project`), written by
the probe job as `vpcAccess.networkInterfaces[{network, subnetwork}]` with egress `PRIVATE_RANGES_ONLY`,
and G4's job model gains the same field for `container_job` (question Q-O3).

Out of scope, each with its own design: a validation that creates cloud resources (it would need a
grant, see "Security"); secrets for a probe; egress rules; clouds other than GCP (each adapter brings its
own); a validation on a PUBLISH step or in a stage of its own.

## Supersede or extend: extend

**`DEPLOY_PROBE` stays the one kind, and a `placement` field chooses where it runs.** There is no second
kind word. The reasons, each from the code:

- **The verdict is the same function.** V2's `probe_case_checks` (`kci_validate/probe_results.mojo`)
  judges `results.jsonl` against `expect`, and `keep_set_hash_only_if_validated` gates promotion on the
  one row a probe writes. A second kind would either call the same two functions under another name or
  grow a second verdict that drifts from the first.
- **The grammar is the same.** V1's `probe.mojo` already has every field an in-cell run needs: `image`
  by digest, `args`, an optional `target`, `timeout_seconds`, `expect`. `target` is already optional, so a
  probe with no endpoint (a static-data test) is already expressible.
- **What differs is only where the container runs.** That is a runner behind a port (below), not a
  grammar. The docker runner stays the default, so every machine file V1 accepts means what it meant.
- **A rename is not free.** `DEPLOY_PROBE` is a word of `kci_api/verbs.mojo` and of every result
  document's `validations[].kind`; renaming it inside major 1 would refuse documents that exist.

What is shared, then: the kind, every V1 field and refusal, the file contract (`results.jsonl`, one
`{id, outcome, detail}` per line), the verdict, the one-row rule, the run id derivation (`probe_run_id`),
the gate. What is new: `placement`, `image_output`, a runner per placement, the cell's probe identity and
results bucket, and the start checks for a `CELL` probe.

## The grammar

```textproto
step {
  name: "deploy"
  kind: DEPLOY
  cells: "release/cells.textproto"
  cell: "staging"
  resources: "deploy/app.json"
  validation {
    name: "static-data"
    kind: DEPLOY_PROBE
    placement: CELL                                   # new: RUNNER (the default) or CELL
    image_output { step: "build" name: "shop-api" }   # new: CELL only; instead of `image`
    args: "--fixture=golden"
    timeout_seconds: 600
    expect: "golden"
  }
}
```

| field | rule |
|---|---|
| `placement` | Optional, `RUNNER` or `CELL`, at most once. Absent is `RUNNER`: V2's docker runner, unchanged. |
| `image` | As in V1: `<repo>@sha256:<hex>`, a tag refused. Under `CELL` the registry must be one Cloud Run pulls from: Artifact Registry (`<region>-docker.pkg.dev`), Docker Hub or GHCR (`ghcr.io`); any other is refused. Docker Hub is the hosts `docker.io` and `index.docker.io`, and a reference with no host (`alpine@sha256:...`), which means `docker.io` (a one-segment name under `library/`), as docker reads it. It must also be pullable anonymously (checked at start, below). |
| `image_output` | New, `{step, name}`, only under `CELL`. Resolved exactly as a DEPLOY step resolves an `Image{output: StepOutput}` (I4): `step` names a BUILD step of this machine file, `name` an `OCI` artifact that step declares, and the release set holds that member; it runs as `image_registry(ctx)/<name>@<digest>` in this step's cell. |
| `args`, `target`, `timeout_seconds`, `expect` | As in V1, under both placements. kci appends `--validation-run-id=<id>` and, with `target`, `--target-url=<value>`. |

Refused by the parser (`kci_release_machine`), each with a red case:

- a `placement` other than `RUNNER` or `CELL`;
- both `image` and `image_output`, or neither;
- `image_output` under `RUNNER` (the runner cannot pull from the cell's private registry; deploy step Q5);
- an `image_output` whose `step` is not a BUILD step of this file;
- under `CELL`, an `image` whose registry is not in the list above.

Already refused today, and kept: `secret_env`, by name; and every field the parser does not know, as
`unknown field` (`parse.mojo`'s `_parse_validation`). That covers any field that would grant the probe
something (`uses`, `grant`, a service account, a size). See "Security".

Checked by `kci run` (K6f), not the parser, because the parser opens no file: that `name` is an artifact
the BUILD step's `artifacts` file declares, of type `OCI`.

Where it attaches is unchanged from V1: **a DEPLOY step only**. A `CELL` probe needs a cell and the
credential of the job that deploys into it; a DEPLOY step is the one step that names both. A BUILD step
has no cell, a PR stage holds no credential, and a PUBLISH into a cell is decided below (KD9).

## Where it runs

| | `RUNNER` (V2) | `CELL` (this design) |
|---|---|---|
| executes | `docker run` on the machine running `kci run` | a one-shot cloud job in the step's cell (on GCP a Cloud Run job, one task, no retries) |
| started by | kci, through `ProcessRunner` | kci, with the cell's deploy identity, through the adapter's `CellJobs` |
| runs as | the runner's user, no credential in the container | the cell's **probe identity**: deny-all, never the deploy identity |
| reaches | what the runner reaches (a hosted runner: public endpoints) | public endpoints in v1; the cell's network in a later phase (above) |
| image | any digest, pulled anonymously | an anonymous digest from Artifact Registry, Docker Hub or GHCR, or the release set's image in the cell's registry (`image_output`) |
| results | `/work/out/results.jsonl` on a bind mount | the same file, uploaded once by `komira_job_supervisor` (below) |
| link-local pre-flight | yes (V2) | no: a cloud job always reaches its metadata server; the identity pre-flight replaces it |
| row | `environment: CONTAINER` | `environment: CONTAINER`, plus the new key `placement: CELL` |

**Which job.** A `CELL` probe runs in the job named after its stage, after its DEPLOY step, like every
probe with a `target`. D6's rule widens: a part job's `--only validation:<name>` must not name a
`DEPLOY_PROBE` that has a `target` **or `placement: CELL`**. A part job holds no identity token, so it
cannot create a job in the cell.

## Execution

Code: a `CellJobs` trait in `kci_cloud` (new file `cell_jobs.mojo`), which an adapter implements beside
`CloudAdapter`; `CellProbeRunner[J: CellJobs]` in `kci_validate`.

### Names

- **The job** is `kci-probe-<h>`, where `<h>` is the first 32 hex digits of the sha256 of the validation
  run id. That is 42 bytes of lowercase letters, digits and `-`, inside Cloud Run's job-name rule
  (starts with a letter, at most 63). The run id itself (`[a-z0-9_-]`, which holds `_`) goes only into a
  label.
- **The results object** is `kci-probe/<h>/results.jsonl`.
- **Labels**, on the job and on `template.labels` (the execution template, so every execution carries
  them too): `kci-run-id=<id>` (`labels.mojo`'s `validation_run_label_key`), `kci_probe_machine`,
  `kci_probe_cell` and `kci_probe_max_seconds`. The three probe keys are `[a-z_]`, so they fit the
  standard label rule (`label_problems`), and they are none of the six identity keys. The machine and
  cell values go through `labels.mojo`'s value encoding, as every kci label value does. G4's
  `container_job` writes no `template.labels` today, so its executions carry no run id: the same gap,
  for G4 to fix.

### Order, for one probe

1. **Start checks**, at `kci run`'s start with the other start checks, before any step. Each fails before
   the DEPLOY step lands, so a probe that can never run never lets a deploy through first:
   - the cell's cloud has a `CellJobs` implementation in this kci, and the cell's `bootstrap_level` is at
     least 2 (KD3); otherwise REFUSED, exit 3;
   - **the identity pre-flight** (below), the first of its two runs;
   - **the image's config.** For `image_output`, kci reads it from the release set's **local** OCI layout,
     which `verify_member` has already tied to `set_hash`. It never reads the cell's registry here:
     PUBLISH runs before DEPLOY, so a fresh digest is not in the cell yet, and PUBLISH's own read-back
     proves it is there once pushed. For `image`, kci fetches the manifest and config **anonymously** by
     digest; an index is resolved to its linux/amd64 manifest, and that manifest's digest is what the job
     runs. Not found, no linux/amd64 manifest, or a config that breaks the supervisor contract (below) is
     REFUSED; a fetch that fails is INDETERMINATE, exit 5.
2. **Identity pre-flight again** (check `kci:identity`), after the DEPLOY step and before the job is
   created, since the policy can change between the two. A failure creates nothing.
3. **Results slot.** kci mints one signed URL for the results object in the cell's results bucket:
   method `PUT`, valid until kci's deadline plus 300 s, with four signed headers the upload must send:
   - `x-goog-if-generation-match: 0` (create only);
   - `x-goog-meta-kci-run-id: <id>` (the object is born stamped);
   - `x-goog-content-length-range: 0,1048576` (V2's `RESULTS_MAX_BYTES`);
   - the content type.
4. **Create and run.** One job, created with:
   - the image by digest (never a tag), task count 1, parallelism 1, **no retries**;
   - task timeout `timeout_seconds` plus the upload allowance (a constant for the supervisor's PUT);
   - the service account **set explicitly** to the probe identity. On GCP an omitted account falls back
     to the project's default compute account, so the adapter refuses a job spec without it, and the
     fake and the emulator both fall back as GCP does, so the test catches the omission;
   - the labels above;
   - `args` only (never `command`, so the image's entrypoint, the supervisor, runs): the supervisor's
     flags, then `--`, then V1's args (below).

   The job carries **none of the DEPLOY scope's identity labels**, so the step's `list_owned` never sees
   it as `leftover`. On GCP the job is written by G4's `job_json`: one writer of a Run job, not two.
5. **Wait.** kci polls the execution until it is terminal or kci's deadline passes. The deadline is the
   task timeout plus the start allowance, a constant for image pull and scheduling. At the deadline kci
   cancels the execution.
6. **Read.** kci reads the results object's metadata first (below), then the bytes, and judges them with
   V2's `probe_case_checks`, unchanged.
7. **Clean up, closed world.** kci deletes exactly what it created, by the names it created: the job (its
   executions go with it) and every generation of the results object. It then reads each one back and
   expects not found. That is check `kci:cleanup`.

### The supervisor contract

A `CELL` image runs komira's job binary model: its entrypoint is `komira_job_supervisor`, and the
supervisor starts the probe program as its child. Cloud Run's `args` replace the image's `CMD`, so the
child cannot come from `CMD` at run time. kci reads it from the image config at start instead:

- the config's `Entrypoint` must be exactly the supervisor, and its `Cmd` exactly one element, the probe
  program's path;
- kci writes `--job-binary=<that path>`, `--max-runtime-secs=<timeout_seconds>`, `--results-file`,
  `--results-url` and one `--results-header` per signed header, then `--` and V1's args;
- the supervisor runs in probe mode (K6d): no heartbeat. It makes the results file's directory, starts
  the child, and after the child exits PUTs the file (zero bytes when the child wrote none). It exits with
  the child's status when the PUT succeeds, and non-zero when it fails. The task's filesystem is writable,
  so no volume is mounted.

The probe image keeps V1's file contract and needs no cloud code. This check is a contract check, not a
security boundary: an image that breaks it only fails its own probe.

### Leftovers

A kci killed between steps 4 and 7 deletes nothing. The task timeout still ends the execution, so
nothing keeps running or billing. At its start, each `kci run` with a `CELL` probe lists the jobs
labelled for **its own** `(machine, cell)`. It deletes one only if every execution of it is terminal
**and** its age exceeds its `kci_probe_max_seconds` (kci's deadline plus 60), measured against the cloud's
own clock (the list response's `Date`), never the runner's (V2's sweep rule). Another machine's or
another cell's job is never touched. Bootstrap gives the results bucket a lifecycle rule that deletes
objects, every generation, after one day.

### The run id

`probe_run_id` (V2) is stamped on the job, its executions (`template.labels`) and the results object
(signed metadata). The image creates nothing: its identity is denied everything. So every billable
object a `CELL` probe causes carries the id, and kci creates and deletes all of them. The DEPLOY step's
scope still carries no validation run id (deploy step "Run id").

## Verdict and exit

The image reports exactly as under `RUNNER`: a row `pass` per `expect` id, exit 0. It cannot report
INDETERMINATE: any other outcome word is a failure (KD7). kci decides, and adds its own checks
(`kci:identity`, `kci:image`, `kci:job`, `kci:results`, `kci:cleanup`; a case id cannot hold `:`).

| condition | effect, outcome, exit |
|---|---|
| The execution succeeded, the results object passes the writer checks below and holds exactly the `expect` ids, each `pass`, and cleanup verified | VALIDATED, SUCCEEDED |
| The execution failed (a non-zero exit, or the task timeout), or a row is missing, extra, repeated, not `pass` or malformed | VALIDATED, VALIDATION_FAILED, 7 |
| The results object fails a writer check: more than one generation, a `kci-run-id` that is not this probe's, a `timeCreated` after the execution's completion, or a size over 1 MiB | VALIDATED, VALIDATION_FAILED, 7; its bytes are never judged |
| The execution succeeded and there is no results object | VALIDATED, INDETERMINATE, 5: the supervisor always uploads, and exits non-zero when its upload fails, so only a broken supervisor gets here |
| The identity pre-flight fails; the job cannot be created (quota, a refused create); the execution never started before kci's deadline; the results object cannot be read | INDETERMINATE, 5, with a `skip_reason`; never a pass |
| Every case passed but a delete failed, or a deleted object still reads back | INDETERMINATE, 5: a pass that leaves something behind is not a pass |
| The DEPLOY step did not succeed | NOT_REACHED |
| `--plan` | WOULD_VALIDATE; nothing is created |

A failed upload makes the execution fail, so it reads as VALIDATION_FAILED, not INDETERMINATE: kci sees
the execution's outcome, not the supervisor's own exit code (KD8).

**`set_hash`** needs nothing new. The probe is one `validations[]` row, and
`keep_set_hash_only_if_validated` keeps the hash only when every selected validation is VALIDATED and
SUCCEEDED, so a `CELL` probe that fails empties it, as a `RUNNER` probe does (V3). The row gains one key,
`placement` (`CELL`; absent under `RUNNER`); the cell is already on the step row. A reader of an older
kci records it in `ignored_keys`. `environment` stays `CONTAINER`: the result parser refuses any other
value, so a new word would break older readers.

## Security

### The probe identity holds nothing

Bootstrap creates it, one per cell, and attaches a deny policy that names it alone. A deny overrides
allow grants from any level (project, folder, organization, a single bucket, a group). The pre-flight
checks that deny and does not try to prove an empty set of grants, which reading allow policies cannot
prove.

**What the pre-flight compares.** Only the policy's `rules` array. The server's fields (`name`, `uid`,
`etag`, `createTime`, `updateTime`, and every other top-level field) are never compared. kci requires
exactly one rule, and in it:

- `deniedPrincipals` is exactly the probe identity's principal;
- `exceptionPrincipals` and `exceptionPermissions` are empty;
- there is no `denialCondition`;
- `deniedPermissions` holds every entry of kci's **canonical deniable list**.

Each list is sorted bytewise before comparing, so order on the server never matters.

**The canonical deniable list** is data in `kci_cloud_gcp`, with a version number. It uses permission
groups (`<service>/*.*`) wherever deny policies accept them, so a new permission inside a service needs
no change, and names single permissions only for a service that has no group form. Bootstrap writes the
list of the kci that runs it. **The list is append-only:** an entry is never removed or rewritten, only
added under a new version, so version N+1 always contains version N (K6c pins it).

**When kci's list moves ahead of a cell.** A cell whose list is a superset of kci's passes; a cell missing
any entry is INDETERMINATE, and the message names the missing entries and says to rerun bootstrap level 2.
So a newer kci never weakens a cell, and an older kci never refuses a cell bootstrapped by a newer one.

**The allow side.** The pre-flight also lists the project's allow policy and refuses any binding that
names the probe identity: the common mistake, cheaply caught.

**The residual.** A cloud does not let a deny policy name every permission. A grant on a single resource,
of a permission no deny can name, is not caught (open question Q-O1).

### The rest

- **No grants in v1.** The machine file has no field that grants the probe anything (refused above), and
  a grant could not take effect past the deny anyway. A `RUNNER` probe has no credential at all, so this
  matches it.
- **Never the deploy identity.** The deploy identity creates, runs, reads and deletes the job. The job's
  account is the probe identity, checked in the job spec kci writes and checked to differ from `whoami`.
- **No secrets.** No environment is passed except what the platform sets. The signed URL is the one
  bearer value in the job. It lets one object of at most 1 MiB be created once, by name, for minutes.
- **Who can write the results object.**
  - *The precondition:* the resource model cannot grant a cell workload this bucket. It is a bootstrap
    item, not a resource of the list, so no `uses` line can name it and no resource list may adopt it
    (the rule deploy step Q4 makes for the bootstrap registry). Only the deploy identity and the cell's
    administrators can write it.
  - *Reading the job can deny, never forge.* Anyone who can read the job in the cell can read the URL.
    If they create the object first, the probe's own upload fails, the execution fails, and the verdict
    is VALIDATION_FAILED.
  - *An overwrite is caught.* A writer with delete and create on the bucket (an administrator, or the
    deploy identity misused) could replace the object after the probe wrote it. The bucket keeps object
    versioning on, so a replacement is a second generation, and kci refuses to judge an object with more
    than one generation, a `kci-run-id` other than this probe's, or a `timeCreated` later than the
    execution's completion. A tag-conditioned deny on writes would close this too; versioning needs no
    second policy, so it is the choice.
  - *The audit log.* The create through the URL is recorded in the bucket's data-access audit log (when
    enabled), attributed to the deploy identity, which signed the URL. A reader of that log can see the
    URL, so log readers are among those who can deny a probe (above), never forge one.
- **The results bucket**, written by bootstrap level 2: uniform bucket-level access, public access
  prevention enforced, soft delete retention 0 (a deleted object is gone, not kept and billed), object
  versioning on, and the one-day lifecycle rule. kci checks the object's size (at most 1 MiB) from its
  metadata before it reads a byte.
- **Results are not read from logs.** Logs would need no URL, but every workload in the cell may write
  logs (the implicit `cell LOGS WRITE` edge, `kci_cloud/grants.mojo`), including the service under
  test, so a log line could forge a pass.
- **Pinned by digest.** As in V1, and the job spec holds the platform manifest's digest, never a tag. An
  `image` must be pullable without credentials (start check), so a private image fails as it does on the
  runner, not through the platform's own pull identity.
- **Egress.** The job's egress is Cloud Run's default: public addresses. kci restricts nothing in v1
  (KD6). What bounds it is the identity: the probe can reach the network, but it holds no credential and
  no data.

### What the deploy identity needs (GCP, beyond deploy)

- create, run, get, list and delete jobs; get and cancel executions, in the cell's project;
- act as the probe identity, granted on that account only, never project-wide;
- read the deny policies attached to the project;
- get, list, create and delete objects in the results bucket only;
- sign as itself (`signBlob` on its own account), for the URL;
- **only if Q-O3 chooses the `testIamPermissions` fallback:** Service Account Token Creator on the probe
  account only, to call `testIamPermissions` as the probe identity.

Bootstrap level 2 writes these grants, the probe identity, its deny policy and the results bucket. On
GCP, deny policies exist only for a project inside an organization, and the role that writes them is
granted at the organization. So level 2 is an administrator's step, like every bootstrap, and a project
with no organization cannot host a `CELL` probe. The read side may also need an organization-level grant
(open question Q-O3; checked in K6e).

## PR split

V2, V3 and D6 merge first. "The fake" is `kci_cloud_fake`'s new `FakeCellJobs`, the executable spec:
- a job runs a scripted function that gets its args and returns an exit and the bytes it uploads;
- it falls back to a default identity when none is named, as GCP does;
- it holds deny and allow policies, and a versioned bucket with create-only writes, a size cap and object
  metadata.

Each row names the planted defect that must turn its test red.

| PR | packages | depends on | tests prove | planted mutant goes red |
|---|---|---|---|---|
| **K6a** the runner port | `kci_validate`: a `ProbeRunner` trait, V2's docker code as `DockerProbeRunner`, one shared `judge_probe` | V2 | V2's argv golden and verdict tests unchanged, byte for byte; the verdict table above driven through a scripted `ProbeRunner` | absent results with exit 0 judged a pass; the timeout check dropped from `judge_probe` |
| **K6b** grammar | `kci_release_machine`: `parse.mojo` (`_parse_validation`: `placement`, `image_output`), `graph.mojo` (`StageValidation` gains both fields), `probe.mojo` (the refusals); `kci_api/verbs.mojo` (`PROBE_PLACEMENT_RUNNER`, `PROBE_PLACEMENT_CELL`) | V1 | Every V1 file parses unchanged with placement `RUNNER`; a red case for each refusal under "The grammar"; `uses` and `grant` in a validation are refused as unknown fields | `image_output` accepted under `RUNNER`; both `image` and `image_output` accepted; an unknown `placement` read as `RUNNER`; a `quay.io` image accepted under `CELL` |
| **K6c** port, fake and bootstrap | `kci_cloud` (`cell_jobs.mojo`, bootstrap items at level 2, the canonical-rules comparison), `kci_cell` (accepts level 2), `kci_cloud_fake` (`FakeCellJobs`), `kci_validate` (`CellProbeRunner`) | K6a | On the fake: a pass, with zero jobs and zero objects left, and the job, its execution and the object each carrying `kci-run-id`. The deny: removed, a second principal, an exception, a condition, or a list missing one canonical entry are each INDETERMINATE with zero creates; the same policy with rules reordered, the server fields changed, or one extra entry passes. An allow binding on the probe identity is INDETERMINATE. With the deny present, a scripted probe that reads a bucket granted to its identity is refused by the fake. A probe writing a failing row and exiting 0 is VALIDATION_FAILED. A forger creating the object first gives VALIDATION_FAILED. An overwrite after the probe (a second generation) is VALIDATION_FAILED. An upload over 1 MiB is refused by the fake bucket. No start before the deadline is INDETERMINATE, with a cancel and a delete recorded. A failed delete is INDETERMINATE. The sweep removes an old terminal job, and keeps a young one, a running one and another cell's. Every version of the canonical deniable list contains the version before it | the pre-flight skipped; an entry removed from the newest list version (the append-only test goes red); the job created with no account (it runs as the fake's default identity, and the identity case goes red); the delete after the verdict dropped; the create-only header dropped (the forger case passes); the generation count not checked (the overwrite case passes); the rules compared in server order (the reordered case is refused); the subset rule inverted (the extra-entry case is refused); `template.labels` not written (the execution carries no run id); the sweep matching by name prefix (another cell's job removed) |
| **K6d** supervisor probe mode | `komira_job_supervisor` (a mode with no heartbeat; `--results-file`, `--results-url`, `--results-header`) | #1050 (the supervisor as PID 1) | Over a scripted connector: one PUT after the child exits, with every given header; zero bytes when the file is absent; the results directory made before the child starts; the child's exit kept when the PUT succeeds; a non-zero exit when the PUT fails, even after a child exit 0; `--max-runtime-secs` stops the child | the PUT before the child exits; the child's exit returned after a failed PUT |
| **K6e** GCP | `kci_cloud_gcp` (`cell_jobs.mojo`, the job written by G4's `job_json` with `template.labels`; the canonical deniable list); `komira_gcp_run` (Executions `Get` and `Cancel`, Jobs `Run`, all generated today); a new generated IAM v2 client package, `src/komira_gcp_iam_v2`, for deny policies (`Policies.GetPolicy`, `ListPolicies`): `komira_gcp_iam` is the IAM v1 admin API and holds none; IAM Credentials `signBlob` in `komira_gcp_wif` beside its `signJwt` (`sign_jwt.mojo`), since IAM Credentials has no generated client and its callers own their calls (`komira_gcp_iam/BUCK`); `komira_gcp_core` (V4 signing over a sign function, not only a key); the G4 emulator | G4, K6c | K6c's cases rerun on the GCP emulator, with the same assertions; a golden of the job JSON (account, no retries, one task, timeout, both label sets, `args` and no `command`); the signed URL against a published V4 vector, with `signBlob` scripted | the account dropped from the job JSON (the emulator runs it as the default account, and the identity case goes red); retries left at the platform default (a failing probe runs twice, and the execution count goes red); the content-length range left unsigned (the over-size case is accepted) |
| **K6f** wiring | `kci_cli` (start checks; the image config read from the local layout for `image_output`; the `OCI` declaration check; the run after the DEPLOY step), `kci_api/result_rows.mojo` (`placement` on a validation row), `kci_workflow_check` (the R9 rule widened), `docs/ci.md` | K6b, K6c, K6d, V3, D6, I4 | End to end on `FakeCloud` and `FakeCellJobs`, with the cell's fake registry **empty at start**: an `image_output` probe passes its start checks from the local layout, the stage's PUBLISH fills the registry, and the job runs the cell's digest. A failing `CELL` probe empties `set_hash`, exit 7; a pass keeps it; `--plan` makes zero calls. A cell at level 1, a failing identity pre-flight, an image fetch that fails, a config that breaks the supervisor contract, and an `image_output` naming an undeclared artifact each stop the run before the DEPLOY step makes a call. A part job naming a `CELL` probe without a `target` is refused naming R9. The `placement` key round-trips | the `image_output` start check reading the cell registry (the empty-registry case is refused at start); the start checks run after the DEPLOY step (the fake records deploy calls); the R9 arm only for `target`; the row written SUCCEEDED whatever the verdict |

Merge order: K6a, and K6d after #1050, first; then K6b, K6c, K6e, K6f. Before K6e is called done, these
are shown on a real project and recorded in its PR body, with the operator's go for the spend:

1. A deny on all deniable permissions blocks a bucket-level grant.
2. An execution carries `template.labels`.
3. The task timeout ends a running task.
4. Whether reading a deny policy needs `denyReviewer` granted at the organization. If it does, the
   alternative is `testIamPermissions` called as the probe identity through impersonation, which proves
   the effect rather than reading the policy (Q-O3). It proves the effect only for the resources and
   permissions it names, never for the rest.
5. The deny policy's size limits, against the canonical list's length.
6. That a signed `PUT` honours `x-goog-if-generation-match`, `x-goog-content-length-range` and
   `x-goog-meta-*`.
7. That Cloud Run pulls a public GHCR image directly. If it does not, GHCR leaves the registry list.

## Decided

Decided by the lead.

| # | question | decision |
|---|---|---|
| KD1 | Extend `DEPLOY_PROBE` with `placement`, or add a new kind? | Extend (see "Supersede or extend"). One verdict, one gate, no rename of a wire word. |
| KD2 | Should `CELL` become the default placement, or be required for some cells? | Not in v1. `RUNNER` stays the default, so V1 files keep their meaning. Requiring `CELL` (for a cell marked production) is a rule to add with that cell attribute. |
| KD3 | Gate the probe identity, its deny and the results bucket on `bootstrap_level: 2`? | Yes. It is the first reader of the field (deploy step Q7), and a cell at level 1 refuses a `CELL` probe at start. |
| KD4 | Grants for a probe (an authenticated endpoint, reading test data)? | Not in v1. A grant needs an exception to the deny, which is a design of its own. |
| KD5 | Secrets for a probe? | Later, by reference in the cell's secret store, mounted only into the job; kci never holds the value (deploy step Q5). |
| KD6 | Egress rules (none, or the cell's network only)? | Not in v1. The deny-all identity is the boundary; add an `egress` field when an adapter can enforce it. |
| KD7 | Let the image report INDETERMINATE (an outcome word `indeterminate`)? | No. Only kci decides that a validation could not tell; an image that cannot tell fails. |
| KD8 | Should a failed upload read as INDETERMINATE rather than VALIDATION_FAILED? | VALIDATION_FAILED in v1. Telling them apart needs the task's own exit code (Run's `Tasks` methods, not generated), and both are never a pass. |
| KD9 | Allow a `CELL` probe on a PUBLISH into a cell, or in a stage of its own? | Later. A static-data test of a published image with no deploy fits a PUBLISH into a cell; it needs D6's token rule for that step first. |
| KD10 | A fixed job size, or a `size` field? | Fixed in v1 (one vCPU, 512 MiB): a probe is a client. A field later, refused until then. |

## Open questions (for the project owner; recommendation first)

| # | question | recommendation |
|---|---|---|
| Q-O1 | Permissions no deny policy can name: accept the residual? | Accept and document it, with the allow-policy check of the pre-flight. Revisit per cloud as the deniable set grows. |
| Q-O2 | Require `komira_job_supervisor` as the entrypoint of a `CELL` image? | Yes. The image keeps V1's file contract and needs no cloud code; the supervisor is the one uploader, and a test pins its exit on a failed upload. The check is a contract check, not a security boundary. |
| Q-O3 | A `CELL` probe needs the cell's project to sit in an organization (deny policies exist only there), and reading the deny may need an organization-level grant for each cell's deploy identity. Accept both? And the private-endpoint phase (Direct VPC egress from a cell setting): when? | Accept the organization requirement: without a deny there is no deny-all identity, and a probe without one would hold whatever the project grants by default. Prefer `testIamPermissions` through impersonation if the read needs an organization grant, so a deploy identity holds nothing at the organization; it then holds Token Creator on the probe account only, and the check proves the effect only for the resources and permissions it names. Schedule private endpoints after K6f, with G4's `vpcAccess`. |
