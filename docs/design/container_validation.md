# Container validation: running an image as a validation, in the cell

Status: design, no code. It extends [the DEPLOY step](deploy_step.md)'s `DEPLOY_PROBE` validation kind
(grammar V1, runner V2, wiring V3, workflow check D6) and builds on its GCP adapter (G4). Every name
below that is not in `main` is new here.

## What is it for, and what is out of scope?

A `DEPLOY_PROBE` runs the operator's image, pinned by digest, with `docker run` on the machine that runs
`kci run`, against the cell a DEPLOY step just deployed into. kci reads what the image wrote and decides
the verdict. This document adds the general form: **run an image as a validation, inside the cell**, as a
one-shot cloud job that kci creates, waits on and deletes.

Running in the cell matters for three reasons the runner cannot meet:

- **No docker daemon.** A `kci run` that itself runs as a cloud job or in a pod has no docker daemon, and
  mounting a node's docker socket would give root on the node.
- **Private endpoints.** Only a job in the cell's network reaches a service with no public address.
- **The published image itself.** A validation can run the image a PUBLISH step just pushed into the
  cell's private registry, by digest, on fixed input (a static-data test). The runner cannot pull it
  anonymously, and the cell can.

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

What is shared, then: the kind, every V1 field and refusal, the file contract (`/work/out/results.jsonl`,
one `{id, outcome, detail}` per line), the verdict, the one-row rule, the run id derivation
(`probe_run_id`), the gate. What is new: `placement`, `image_output`, a runner per placement, the cell's
probe identity and results bucket, and the start checks for a `CELL` probe.

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
| `image` | As in V1: `<repo>@sha256:<hex>`, a tag refused. Under `CELL` it must also be pullable anonymously (checked at start, below). |
| `image_output` | New, `{step, name}`, only under `CELL`. Resolved exactly as a DEPLOY step resolves an `Image{output: StepOutput}` (I4): `step` names a BUILD step of this machine file, `name` an `OCI` artifact that step declares, and the release set holds that member; it runs as `image_registry(ctx)/<name>@<digest>` in this step's cell. |
| `args`, `target`, `timeout_seconds`, `expect` | As in V1, under both placements. kci appends `--validation-run-id=<id>` and, with `target`, `--target-url=<value>`. |

Refused in the machine file (pure parser, `kci_release_machine/probe.mojo`), each with a red case:

- a `placement` other than `RUNNER` or `CELL`;
- both `image` and `image_output`, or neither;
- `image_output` under `RUNNER` (the runner cannot pull from the cell's private registry; deploy step Q5);
- an `image_output` whose `step` is not a BUILD step of this file, or whose `name` that step does not
  declare as `OCI`;
- any field that grants the probe something: `uses`, `grant`, `secret_env`, a service account, a size
  (`secret_env` is already refused by V1). See "Security".

Where it attaches is unchanged from V1: **a DEPLOY step only**. A `CELL` probe needs a cell and the
credential of the job that deploys into it; a DEPLOY step is the one step that names both. A BUILD step
has no cell, a PR stage holds no credential, and a PUBLISH into a cell is question Q9.

## Where it runs

| | `RUNNER` (V2) | `CELL` (this design) |
|---|---|---|
| executes | `docker run` on the machine running `kci run` | a one-shot cloud job in the step's cell (on GCP a Cloud Run job, one task, no retries) |
| started by | kci, through `ProcessRunner` | kci, with the cell's deploy identity, through the adapter's `CellJobs` |
| runs as | the runner's user, no credential in the container | the cell's **probe identity**: deny-all, never the deploy identity |
| reaches | what the runner reaches (a hosted runner: public endpoints) | the cell's network: private endpoints too |
| image | any digest, pulled anonymously | an anonymous digest, or the release set's image in the cell's registry (`image_output`) |
| results | `/work/out/results.jsonl` on a bind mount | the same file, uploaded once by komira's job supervisor (below) |
| link-local pre-flight | yes (V2) | no: a cloud job always reaches its metadata server; the identity pre-flight replaces it |
| row | `environment: CONTAINER` | `environment: CONTAINER`, plus the new key `cell` |

**Which job.** A `CELL` probe runs in the job named after its stage, after its DEPLOY step, like every
probe with a `target`. D6's rule widens: a part job's `--only validation:<name>` must not name a
`DEPLOY_PROBE` that has a `target` **or `placement: CELL`**. A part job holds no identity token, so it
cannot create a job in the cell.

## Execution

Code: a `CellJobs` trait in `kci_cloud` (new file `cell_jobs.mojo`), which an adapter implements beside
`CloudAdapter`; `CellProbeRunner[J: CellJobs]` in `kci_validate`. In order, for one probe:

1. **Start checks**, at `kci run`'s start with the other start checks, before any step. Each fails before
   the DEPLOY step lands, so a probe that can never run never lets a deploy through first:
   - the cell's cloud has a `CellJobs` implementation in this kci, and the cell's `bootstrap_level` is at
     least 2 (Q3); otherwise REFUSED, exit 3;
   - the image's manifest and config are fetched **anonymously** by digest (an `image_output` image is
     read from the cell's registry with the deploy identity, since the cell's own runtime pulls it). Not
     found, or a config whose entrypoint is not komira's job supervisor, is REFUSED; a fetch that fails
     is INDETERMINATE, exit 5.
2. **Identity pre-flight** (check `kci:identity`), after the DEPLOY step. kci reads the cell's deny policy
   for the probe identity and compares it **byte for byte** with the canonical policy bootstrap writes
   (the rule deploy step Q14 uses for trust). It also lists the project's allow policy and refuses any
   binding that names the probe identity. A missing, changed or unreadable policy is INDETERMINATE, and
   nothing is created.
3. **Results slot.** kci mints one signed URL for one object, `kci-probe/<validation run id>/results.jsonl`
   in the cell's results bucket: method `PUT`, valid for `timeout_seconds` plus the start allowance plus
   300 s, with two signed headers the upload must send: create-only (`x-goog-if-generation-match: 0`) and
   the run id as object metadata (`x-goog-meta-kci-run-id: <id>`). So the object is born stamped, and a
   second write of that name fails.
4. **Create and run.** One job named `kci-probe-<validation run id>`, created with:
   - the image by digest (never a tag), `args` as V1 builds them, task count 1, parallelism 1,
     **no retries**, task timeout `timeout_seconds`;
   - the service account **set explicitly** to the probe identity. On GCP an omitted account falls back
     to the project's default compute account, so the adapter refuses a job spec without it, and the
     fake and the emulator both fall back as GCP does, so the test catches the omission;
   - labels: `kci-run-id=<id>` (`labels.mojo`'s `validation_run_label_key`), `kci-probe-machine`,
     `kci-probe-cell` and `kci-probe-max-seconds` (`timeout_seconds` + allowance + 60);
   - the supervisor's flags before the image's own: `--results-file=/work/out/results.jsonl`,
     `--results-url=<signed URL>`, one `--results-header` per signed header, and an in-memory volume at
     `/work/out`.
   The job carries **none of the DEPLOY scope's identity labels**, so the step's `list_owned` never sees
   it as `leftover`. On GCP the job is written by G4's `job_json`: one writer of a Run job, not two.
5. **Wait.** kci polls the execution until it is terminal or kci's own deadline passes:
   `timeout_seconds` plus the start allowance, a constant for image pull and scheduling. At the deadline
   kci cancels the execution.
6. **Read.** kci reads the results object, then judges it with V2's `probe_case_checks`, unchanged.
7. **Clean up, closed world.** kci deletes exactly what it created, by the names it created: the job
   (its executions go with it) and the results object. It then reads each one back and expects not
   found. That is check `kci:cleanup`.

**Leftovers.** A kci killed between steps 4 and 7 deletes nothing. The task timeout still ends the
execution, so nothing keeps running or billing. At its start, each `kci run` with a `CELL` probe lists
the jobs labelled for **its own** `(machine, cell)` and deletes one only if every execution of it is
terminal **and** its age exceeds its `kci-probe-max-seconds`, measured against the cloud's own clock (the
list response's `Date`), never the runner's (V2's sweep rule). Another machine's or another cell's job is
never touched. Bootstrap gives the results bucket a lifecycle rule that deletes objects after one day,
so a leftover object expires on its own.

**The run id.** `probe_run_id` (V2) names the job and stamps the job, its executions and the results
object. The image creates nothing: its identity is denied everything. So every billable object a `CELL`
probe causes carries the id, and kci creates and deletes all of them. The DEPLOY step's scope still
carries no validation run id (deploy step "Run id").

## Verdict and exit

The image reports exactly as under `RUNNER`: a row `pass` per `expect` id, exit 0. It cannot report
INDETERMINATE: any other outcome word is a failure (Q7). kci decides, and adds its own checks
(`kci:identity`, `kci:image`, `kci:job`, `kci:results`, `kci:cleanup`; a case id cannot hold `:`).

| condition | effect, outcome, exit |
|---|---|
| The execution succeeded, the results object holds exactly the `expect` ids, each `pass`, and cleanup verified | VALIDATED, SUCCEEDED |
| The execution failed (a non-zero exit, or the task timeout), or a row is missing, extra, repeated, not `pass` or malformed | VALIDATED, VALIDATION_FAILED, 7 |
| The execution succeeded and there is no results object | VALIDATED, INDETERMINATE, 5: the supervisor always uploads (zero bytes when the image wrote nothing) and exits non-zero when its upload fails, so only a broken supervisor gets here |
| The identity pre-flight fails; the job cannot be created (quota, a refused create); the execution never started before kci's deadline; the results object cannot be read | INDETERMINATE, 5, with a `skip_reason`; never a pass |
| Every case passed but a delete failed, or a deleted object still reads back | INDETERMINATE, 5: a pass that leaves something behind is not a pass |
| The DEPLOY step did not succeed | NOT_REACHED |
| `--plan` | WOULD_VALIDATE; nothing is created |

A failed upload makes the execution fail, so it reads as VALIDATION_FAILED, not INDETERMINATE: kci sees
the execution's outcome, not the supervisor's own exit code (Q8).

**`set_hash`** needs nothing new. The probe is one `validations[]` row, and
`keep_set_hash_only_if_validated` keeps the hash only when every selected validation is VALIDATED and
SUCCEEDED, so a `CELL` probe that fails empties it, as a `RUNNER` probe does (V3). The row gains one key,
`cell`, the cell it ran in, absent under `RUNNER`. A reader of an older kci records it in `ignored_keys`.
`environment` stays `CONTAINER`: the result parser refuses any other value, so a new word would break
older readers.

## Security

- **The probe identity holds nothing.** Bootstrap creates it, one per cell, and attaches a deny policy
  naming it alone and every permission the cloud lets a deny policy name. A deny overrides allow grants
  from any level (project, folder, organization, a single bucket, a group). The pre-flight checks that
  deny before every probe and does not try to prove an empty set of grants, which reading allow policies
  cannot prove.
  - **The residual.** A cloud does not let a deny policy name every permission. The allow-policy check in
    the pre-flight catches the common mistake, a project binding on the probe identity; a grant on a
    single resource, of a permission no deny can name, is not caught (Q10).
- **No grants in v1.** The machine file has no field that grants the probe anything (refused above), and
  a grant could not take effect past the deny anyway. A `RUNNER` probe has no credential at all, so this
  matches it.
- **Never the deploy identity.** The deploy identity creates, runs, reads and deletes the job. The job's
  account is the probe identity, checked in the job spec kci writes and checked to differ from `whoami`.
- **No secrets.** No environment is passed except what the platform sets. The signed URL is the one
  bearer value in the job. It lets one object be created once, by name, for minutes.
  - Anyone who can read the job in the cell can read that URL. If they write the object first, the
    probe's own upload fails, the execution fails, and the verdict is VALIDATION_FAILED. Reading the job
    can turn a pass into a failure; it cannot turn a failure into a pass.
- **Results are not read from logs.** Logs would need no URL, but every workload in the cell may write
  logs (the implicit `cell LOGS WRITE` edge, `kci_cloud/grants.mojo`), including the service under
  test, so a log line could forge a pass.
- **Pinned by digest.** As in V1, and the job spec holds the digest, never a tag. An anonymous image must
  be pullable without credentials (start check), so a private image fails as it does on the runner, not
  through the platform's own pull identity.
- **Egress.** The job's egress is the cell's default for jobs. kci restricts nothing in v1 (Q6). What
  bounds it is the identity: the probe can reach the network, but it holds no credential and no data.
- **What the deploy identity needs**, on GCP, beyond deploy:
  - create, run, get, list and delete jobs; get and cancel executions, in the cell's project;
  - act as the probe identity, granted on that account only, never project-wide;
  - read the deny policies attached to the project;
  - get, create and delete objects in the results bucket only;
  - sign as itself (`signBlob` on its own account), for the URL.

  Bootstrap level 2 writes these grants, the probe identity, its deny policy and the results bucket.
  On GCP, deny policies exist only for a project inside an organization, and the role that writes them
  is granted at the organization. So level 2 is an administrator's step, like every bootstrap, and a
  project with no organization cannot host a `CELL` probe. Whether the read side also needs an
  organization-level grant is verified in K6e.

## PR split

V2, V3 and D6 merge first. "The fake" is `kci_cloud_fake`'s new `FakeCellJobs`, the executable spec: a
job runs a scripted function that gets its args and returns an exit and the bytes it uploads; it falls
back to a default identity when none is named, as GCP does; and it holds deny and allow policies and a
bucket with create-only writes. Each row names the planted defect that must turn its test red.

| PR | packages | depends on | tests prove | planted mutant goes red |
|---|---|---|---|---|
| **K6a** the runner port | `kci_validate`: a `ProbeRunner` trait, V2's docker code as `DockerProbeRunner`, one shared `judge_probe` | V2 | V2's argv golden and verdict tests unchanged, byte for byte; the verdict table above driven through a scripted `ProbeRunner` | absent results with exit 0 judged a pass; the timeout check dropped from `judge_probe` |
| **K6b** grammar | `kci_release_machine` (`probe.mojo`, `deploy.mojo`), `kci_api/verbs.mojo` (`PROBE_PLACEMENT_RUNNER`, `PROBE_PLACEMENT_CELL`) | V1 | Every V1 file parses unchanged with placement `RUNNER`; a red case for each refusal under "The grammar" | `image_output` accepted under `RUNNER`; both `image` and `image_output` accepted; an unknown `placement` read as `RUNNER` |
| **K6c** port, fake and bootstrap | `kci_cloud` (`cell_jobs.mojo`, bootstrap items at level 2), `kci_cell` (accepts level 2), `kci_cloud_fake` (`FakeCellJobs`), `kci_validate` (`CellProbeRunner`) | K6a | On the fake: a pass, with zero jobs and zero objects left, and every object the run created carrying `kci-run-id`; a deny removed, changed or naming a second principal is INDETERMINATE with zero creates; an allow binding on the probe identity is INDETERMINATE; with the deny present, a scripted probe that reads a bucket granted to its identity is refused by the fake; a probe writing a failing row and exiting 0 is VALIDATION_FAILED; a forger writing the object first gives VALIDATION_FAILED; no start before the deadline is INDETERMINATE, with a cancel and a delete recorded; a failed delete is INDETERMINATE; the sweep removes an old terminal job, and keeps a young one, a running one and another cell's | the pre-flight skipped; the job created with no account (it runs as the fake's default identity, and the identity case goes red); the delete after the verdict dropped; the create-only header dropped (the forger case passes); the sweep matching by name prefix (another cell's job removed); the run-id label dropped |
| **K6d** supervisor probe mode | `komira_job_supervisor` (a mode with no heartbeat; `--results-file`, `--results-url`, `--results-header`) | none | Over a scripted connector: one PUT after the child exits, with every given header; zero bytes when the file is absent; the child's exit kept when the PUT succeeds; a non-zero exit when the PUT fails, even after a child exit 0 | the PUT before the child exits; the child's exit returned after a failed PUT |
| **K6e** GCP | `kci_cloud_gcp` (`cell_jobs.mojo`, the job written by G4's `job_json`), `komira_gcp_run` (Executions `Get`, `Cancel`, Jobs `Run`: generated today), `komira_gcp_iam` (deny-policy `Get`, IAM Credentials `SignBlob`, both new), `komira_gcp_core` (V4 signing over a sign function, not only a key), the G4 emulator | G4, K6c | K6c's cases rerun on the GCP emulator, with the same assertions; a golden of the job JSON (account, no retries, one task, timeout, labels); the signed URL against a published V4 vector, with `SignBlob` scripted | the account dropped from the job JSON (the emulator runs it as the default account, and the identity case goes red); retries left at the platform default (a failing probe runs twice, and the execution count goes red); the deny comparison loosened to a subset |
| **K6f** wiring | `kci_cli` (start checks, the run after the DEPLOY step, `image_output` through I4), `kci_api/result_rows.mojo` (`cell` on a validation row), `kci_workflow_check` (the R9 rule widened), `docs/ci.md` | K6b, K6c, K6d, V3, D6, I4 | End to end on `FakeCloud` and `FakeCellJobs`: a failing `CELL` probe empties `set_hash`, exit 7; a pass keeps it; `--plan` makes zero calls; `image_output` runs the cell's digest; a cell at level 1, an image fetch that fails and a non-supervisor entrypoint each stop the run before the DEPLOY step makes a call; a part job naming a `CELL` probe without a `target` is refused naming R9; the `cell` key round-trips | the start checks run after the DEPLOY step (the fake records deploy calls); the R9 arm only for `target`; the row written SUCCEEDED whatever the verdict |

Merge order: K6a and K6d first, then K6b, K6c, K6e, K6f. Before K6e is called done, three things are
shown on a real project and recorded in its PR body, with the operator's go for the spend:

1. A deny on all deniable permissions blocks a bucket-level grant.
2. An execution carries its job's labels.
3. The task timeout ends a running task.

## Open questions (recommendation first)

| # | question | recommendation |
|---|---|---|
| Q1 | Extend `DEPLOY_PROBE` with `placement`, or add a new kind? | Extend (see "Supersede or extend"). One verdict, one gate, no rename of a wire word. |
| Q2 | Should `CELL` become the default placement, or be required for some cells? | Not in v1. `RUNNER` stays the default, so V1 files keep their meaning. Requiring `CELL` (for a cell marked production) is a rule to add with that cell attribute. |
| Q3 | Gate the probe identity, its deny and the results bucket on `bootstrap_level: 2`? | Yes. It is the first reader of the field (deploy step Q7), and a cell at level 1 refuses a `CELL` probe at start. |
| Q4 | Grants for a probe (an authenticated endpoint, reading test data)? | Not in v1. A grant needs an exception to the deny, which is a design of its own. |
| Q5 | Secrets for a probe? | Later, by reference in the cell's secret store, mounted only into the job; kci never holds the value (deploy step Q5). |
| Q6 | Egress rules (none, or the cell's network only)? | Not in v1. The deny-all identity is the boundary; add an `egress` field when an adapter can enforce it. |
| Q7 | Let the image report INDETERMINATE (an outcome word `indeterminate`)? | No. Only kci decides that a validation could not tell; an image that cannot tell fails. |
| Q8 | Should a failed upload read as INDETERMINATE rather than VALIDATION_FAILED? | Accept VALIDATION_FAILED in v1. Telling them apart needs the task's own exit code (Run's `Tasks` methods, not generated), and both are never a pass. |
| Q9 | Allow a `CELL` probe on a PUBLISH into a cell, or in a stage of its own? | Later. A static-data test of a published image with no deploy fits a PUBLISH into a cell; it needs D6's token rule for that step first. |
| Q10 | Permissions no deny policy can name: accept the residual? | Accept and document it, with the allow-policy check of the pre-flight. Revisit per cloud as the deniable set grows. |
| Q11 | A fixed job size, or a `size` field? | Fixed in v1 (one vCPU, 512 MiB): a probe is a client. A field later, refused until then. |
| Q12 | Require komira's job supervisor as the entrypoint of a `CELL` image? | Yes. The image keeps V1's file contract and needs no cloud code; the supervisor is the one uploader, and a test pins its exit on a failed upload. |
