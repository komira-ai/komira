# Stage-job identities: who a stage runs as, inside the cell

Status: design, no code. It builds on [the DEPLOY step](deploy_step.md) (cells, the resource model, the
derived stamp of G3, the GCP adapter of G4 and G5, question Q13) and on the container-validation design
(the `CellJobs` port of its row K6c, the probe identity and bootstrap level 2; komira #1170, not yet
merged). Every name below that is not in `main` is new here, or comes from #1170 and is marked so.

## What is it for, and what is out of scope?

An operator can run a stage of a release machine **inside the stage's cell**, as one-shot cloud jobs,
instead of on a CI runner: a **build** job runs the stage's BUILD steps and their tests, then a
**deploy** job runs its PUBLISH steps into the cell, its DEPLOY steps and their validations. Something
outside the cell (the operator's launcher) starts those jobs. This document is kci's half of that: the
**mechanism** by which kci creates, binds, checks, rotates and deletes the identity each job runs as,
and how a launch names it.

The **policy** is the operator's: which identity a stage job runs as, per cell and stage, and what it may
touch. kci takes the operator's stage-job policy as its requirement and states below where the cloud
enforces it, where only kci does, and where neither can (section "What the policy asks that the cloud
cannot enforce").

Out of scope, each with its own design:

- **The launch contract**: how a caller asks a cell to start, stop and read a stage job (argument vector,
  maximum runtime, result location, how a stop at the maximum concludes). This document fixes only what
  the launch says about identity, and what the cloud lets a launch change (section "The launch").
- **The handoff** from the build job to the deploy job (what it carries, its digest). This document
  fixes only who may write and read it.
- **A run identity for the job** that a party outside the cell can verify (a token exchange). This
  document fixes what the cell offers such an exchange: one workload identity per job, with a stable id.
- Clouds other than GCP. The model is cloud-neutral; the grants and checks below are GCP's, as G4's are.

## The three roles

For each **(cell, stage)** that runs in a cell there are up to three identities, one cloud principal each,
in the cell's project. They are never shared by two stages, two cells or two machines.

| role | exists when | runs |
|---|---|---|
| `build` | the stage is named for the cell (below) | the stage's BUILD steps and their tests |
| `deploy` | the stage has a DEPLOY step, or a PUBLISH step into a cell, and every such step names **this** cell | the stage's PUBLISH steps, DEPLOY steps and their validations |
| `fork` | the stage's kind is `PULL_REQUEST` | the stage's BUILD steps for a pull request from another repository |

Three facts from the machine file shape this table:

- **A stage with cell steps has exactly one cell.** A deploy job holds one cell's identity, so a stage
  whose DEPLOY or PUBLISH-into-cell steps name two cells cannot run as a stage job (refused at render,
  below). A stage with no cell step (build only) may run in several cells, with a `build` identity in
  each and no `deploy`.
- **A cell has at most one `deploy` identity per machine.** The machine file already refuses two DEPLOY
  steps naming one cell (deploy step, "Refusals in the machine file"), and a cell is owned by one
  machine (Q14). So "stage `gamma`'s deploy job touches what stage `prod` owns in the same cell" cannot
  arise inside one machine; the boundary that matters is between cells, and between a stage job and the
  cell's bootstrap items (section "Scope").
- **A `PULL_REQUEST` stage never deploys** (already refused), so it has no `deploy` identity.

**Which cells a stage runs in** is declared in the cells file (below), not inferred: kci checks the
declaration against the machine file.

### What each role may do

| | `build` | `deploy` | `fork` |
|---|---|---|---|
| read the base image by digest (the cell's registry, or a public one) | yes | yes | yes |
| write the stage's handoff (the cell's staging bucket, under `<stage>/`, create-only) | yes | no | under `<stage>/fork/` only, which no other role reads |
| read the stage's handoff | yes, not `<stage>/fork/` | yes, not `<stage>/fork/` | `<stage>/fork/` only |
| the stage's secrets by reference (below) | yes | yes | **none** |
| write the cell's registry (PUBLISH into the cell) | no | yes | no |
| the DEPLOY scope `(machine, cell)` (create, update, delete what the stage's resource list owns; the bindings its edges lower to) | no | yes, cloud-scoped as "Scope" says | no |
| run a `CELL` probe (#1170): create, run, read and delete probe jobs, act as the probe identity | no | yes, exactly #1170's list | no |
| create its own result object (the cell's stage results bucket, its own prefix, create-only) | yes | yes | yes |
| act as any identity | no | the cell's workload accounts (`kci-` names) and the probe identity; never a `kcb-` account other than the probe's | no |
| read its own account (to learn its own role, below) | yes | yes | yes |
| hold a key, or mint a token for another account | never | never | never |

## What a stage identity is never

- **Never the probe identity.** #1170's probe identity is deny-all and its pre-flight relies on it
  holding nothing. A stage identity is a different account; no stage identity holds a role on the probe
  account except the `deploy` identity's act-as, which is exactly what #1170 grants its deploy identity.
- **Never the cell's level-1 deploy identity** (the account a CI runner impersonates through the cell's
  workload-identity provider, deploy step "Credentials" and Q14). That account stays for stages that run
  on a runner. A stage identity is not it, cannot act as it, and it cannot act as a stage identity.
- **Never a human credential.** Bootstrap is a human verb run once with the admin's own credentials; the
  identities it leaves are service accounts with **no user-managed key**. A job's token is minted by the
  platform for that execution (the metadata server), lives at most an hour, and is never written anywhere.
- **Never the launcher's.** The launcher holds no act-as on any account (section "The launch"), so a job
  cannot run as its caller, and the caller cannot pick the account.

## Lifecycle

### Who creates it: bootstrap level 3

The stage identities, their grants and their job templates are **bootstrap items** of a new
`bootstrap_level: 3`, created by an administrator with their own credentials, never by a DEPLOY step.
Why not a resource of the stage's resource list (a `service_account` with `uses` lines on itself):

- **The loop.** The `deploy` identity is what applies the stage's resource list. A list cannot create
  the principal that applies it: the first apply has no identity to run as, and a later apply that drops
  the account deletes the identity it is running as (the DEPLOY step's closed world).
- **The grants are not edges.** Creating Run jobs, writing project policy for the role table's roles,
  acting as workload accounts: none is a `uses` verb on a target of the list, and granting them needs the
  project's IAM administration, which no identity kci runs as holds: bootstrap is the administrator's step,
  as #1170's level 2 is.
- **Adding a stage is adding a principal with deploy rights.** That deserves the same human step a cell
  gets.

Levels are cumulative: level 3 requires level 2 (the probe identity, its deny, the results bucket),
because a `deploy` job runs `CELL` probes and the disjointness check below reads the probe identity
(question Q-SJ4). Level 3 adds, per (cell, stage, role): the account, its bindings, its job template;
and per cell: the staging bucket and the stage results bucket.

### The cells file

A cell names the stages that run in it, and each stage's secrets by reference:

```textproto
cell {
  name: "gamma"
  cloud: "gcp"
  setting { key: "project" value: "example-gamma" }
  setting { key: "region" value: "europe-west1" }
  bootstrap_level: 3
  stage_job { stage: "gamma" secret: "smtp-relay" }
  stage_job { stage: "pr" }
}
```

| field | rule |
|---|---|
| `stage_job` | Repeated, only at `bootstrap_level: 3`. One per stage, a stage at most once per cell. |
| `stage_job.stage` | The step-name grammar. Checked against the machine file at render and at `kci run`'s start, not by the cells parser (it reads no machine file): the stage exists; if it has any DEPLOY or PUBLISH-into-cell step, every one of them names this cell; a stage with cell steps is named by no other cell. |
| `stage_job.secret` | Repeated, the step-name grammar, unique within the entry. Refused on a `PULL_REQUEST` stage (its `fork` role resolves no secret, and its `build` role runs pull-request code). |

Refused by the cells parser, each with a red case: `stage_job` below level 3; a duplicate stage; a
duplicate secret; an unknown field in `stage_job`. Refused against the machine file, before any call: an
unknown stage; a stage whose cell steps name another cell, or two cells; a stage with cell steps named by
two cells; a secret on a `PULL_REQUEST` stage.

### Names and stamps

Every bootstrap item is stamped in its **own namespace**, which the DEPLOY scope never decodes, and named
with its own prefix, which no derived name of the resource model can take:

| item | GCP name | stamp |
|---|---|---|
| a stage account | `kcb-` and 10 base32 characters of sha256(`<machine>/<cell>/stage-job/<stage>/<role>/g<generation>`), 14 bytes | its description, the whole of it: `kci-bootstrap:v1 owner=<machine>/<cell> item=stage-job/<stage>/<role> gen=<n>` then `kci-level=3` |
| its job template | the same derivation over `.../<role>/template` | labels on the job and on `template.labels`: `kci_bootstrap=v1`, `kci_bs_machine`, `kci_bs_cell`, `kci_bs_stage`, `kci_bs_role`, values through `labels.mojo`'s encoding |
| a stage secret | over `<machine>/<cell>/stage-secret/<stage>/<name>` | labels, the same keys with `kci_bs_secret` |
| the staging and stage results buckets | over `<machine>/<cell>/staging` and `.../stage-results` | labels |
| a binding | none written | **derived**, as G3 derives a DEPLOY binding's (below) |

Why this shape:

- **The DEPLOY scope must never see these as its own.** A description whose first line is not
  `kci:v<scheme>` is not stamped for the resource model (deploy step, "Description carriers"), and the
  labels are none of the six identity keys, so `list_owned` never reports a bootstrap item and the DEPLOY
  step never deletes it as `leftover`, as #1170 does for its probe jobs.
- **Nor adopt it.** Adoption takes over an object with no stamp. A bootstrap stamp is a stamp: the
  adapter's `read_existing` reports such an object as **foreign**, so a resource list that names a
  `kcb-` object by `physical_name` is refused as a conflict, never adopted. Validate also refuses a
  `physical_name` that starts `kcb-`.
- **The prefix is the cloud-side boundary.** Derived names start `kci-` (G4's `names.mojo`). The
  `deploy` identity's grants are conditioned on that difference (section "Scope").
- **The description fits.** It is checked against the 256-byte limit at render, so a long machine, cell
  or stage name fails before anything is created.
- **The generation** makes a rotated account a new name (section "Rotation").

**Bindings are attributed by G3's derived rule, in the bootstrap namespace.** A binding is a bootstrap
item of (machine, cell) when its member is a `kcb-` account whose stamp names (machine, cell), its role is
on that role's row of the **bootstrap role table** (data in `kci_cloud_gcp`, injective like G4's), and its
condition, if any, equals byte for byte the condition the render writes. G4's read reports every
conditional binding as an unmanaged difference of the DEPLOY scope; with this rule the adapter can tell a
bootstrap binding from a stranger's (question Q-SJ6).

**The run id.** Executions are the billable objects. Their labels come only from the template (the launch
cannot set labels, below), so an execution carries machine, cell, stage and role, never the run id. The
run id reaches the job in its arguments and is written in its result; the launch reply returns the
execution's name, so a caller maps execution to run. This differs from #1170's probe jobs, which kci
creates per run and so labels per run.

### Scope: what the cloud enforces, and what only kci does

**The cloud's boundary is the project.** GCP scopes most permissions by project, by single resource, or
by a condition on the resource's name; it does not scope by label. Two consequences:

- **One project per cell at level 3.** Derived names hash the machine and the cell, so two cells sharing
  a project share no name prefix, and no condition can keep one cell's `deploy` identity off the other's
  objects. The render and the pre-flight list the project's service accounts and refuse a project that
  holds an account stamped (`kci:v` or `kci-bootstrap:v1`) for another (machine, cell).
- **Inside the project, the name prefix.** The `deploy` identity's administrative grants carry a
  condition that excludes `kcb-` names, so it cannot change, delete or act as a bootstrap item:

| `deploy` grant (project unless said) | condition |
|---|---|
| create, update, delete Run jobs, services and worker pools; get and cancel executions | the resource name does not start `.../kcb-` |
| create, update, delete service accounts | the name does not start `kcb-` |
| act as (Service Account User) | the account does not start `kcb-`; plus, on the probe account only, act-as granted on that account (#1170) |
| set the project's policy | `modifiedGrantsByRole` `hasOnly` the project rows of G4's and G5's role table (today `roles/logging.logWriter`) |
| set the policy of a secret, a job, a service, a service account | the name does not start `kcb-`, and `modifiedGrantsByRole` `hasOnly` that target's rows of the role table |
| write the cell's registry; read the staging bucket under `<stage>/`; create in the stage results bucket under `<stage>/deploy/` | per bucket or repository, prefix conditions on object names |

`hasOnly` limits **which roles** a grant may add, never to whom: a `deploy` identity can give a role of
the table to any member, itself included. Every role in the table is a narrow verb on one target type, so
this is the table's reach, not more; a role added to the table widens it, and the role-table test must say
so.

**Inside the scope, kci.** That a `deploy` job changes only what its resource list owns is kci's own rule
(`refuse_unless_owned`, the stamps), as it is for a runner today. A `deploy` job runs a released kci image
and no step of the repository's own code (it builds nothing and runs no `RUNNER` probe, below), so the
rule is code the cell's owner chose. A `build` job is different: its BUILD steps and tests are the
repository's code, and they can do whatever the `build` identity can. **For a `build` or `fork` job the
cloud's grants are the only boundary**, which is why those roles hold no deploy grant, no registry write
and no act-as at all.

**Whether GCP honours each condition** is checked on a real project before the GCP row is done (section
"PR split"). If any of the name conditions is not honoured for a resource type, kci refuses level 3 on
GCP: a `deploy` identity that can rewrite its own stage's templates, or act as a `build` account, is not
scoped (question Q-SJ10).

### Binding to the stage: the template

A stage job runs from a **job template**, one Run job per (cell, stage, role), created by bootstrap with:

- `template.template.serviceAccount` set to that role's account, explicitly (an unset account falls back
  to the project's default compute account; #1170's rule, and the fake falls back the same way);
- the image by digest, a released kci base image (question Q-SJ2);
- one task, no retries;
- for `build` and `deploy`, each stage secret as an environment variable whose value source is that
  secret, version `latest`; the `fork` template has none;
- its labels on the job and on `template.labels`.

The account **is** the binding: whoever runs the template runs as that account, and nobody else can make
it run as another without updating the job, which needs act-as on the new account.

**Secrets by reference.** A stage secret is a Secret Manager secret that bootstrap creates empty and the
administrator fills; kci never writes or reads its value (`kci_secret_writer` is the resource model's
verb, not used here). The platform resolves it into the job's environment at execution start, with the
job's own account (accessor granted on that secret only). The value is never in a launch request, a
template's literal fields, a row or a log: kci writes a stage secret's name, never its variable's value,
into its result and summary.

### The launch, and what it can change

A launch runs a template through Run's `run` method with overrides. What the cloud lets a caller change,
and what kci does about it:

| override | the cloud | kci |
|---|---|---|
| image | not overridable | the template's digest is the image; the launch contract refuses a request whose digest is not the template's (Q-SJ2) |
| service account | not overridable | the account is the template's |
| labels | not overridable | the run id goes in the arguments (above) |
| arguments | replaced | a request: kci in the job checks them against its own identity (below) |
| environment | merged, a caller's variable wins | kci in the job refuses `GOOGLE_APPLICATION_CREDENTIALS`, and any variable outside the template's and the platform's names |
| task count | replaced | kci in the job refuses a task count other than 1 (`CLOUD_RUN_TASK_COUNT`) |
| timeout | replaced | the launch contract's maximum |

**The launcher's grant** (written by bootstrap level 3, on each template of that cell, never project-wide):
run with overrides, get the job, get, list and cancel its executions; read the stage results bucket. **No
act-as, no create, no update, no delete.** Running a template needs no act-as on its account (act-as is
checked when a job is created or updated), so the launcher can run a stage job as its role's account and
cannot run anything else as it.

**How a launch names the identity: `CellJobs`.** #1170's `CellJobs` port (K6c) creates, runs and deletes
probe jobs. This design adds one read to it:

```text
resolve_stage_job(cell, stage, role) -> StageJobRef { template, account, account_unique_id, image_digest }
```

It takes the triple, never a principal, an email, a key or a token, and resolves it from the cells file,
the machine file and the cell. It **refuses by name**, never defaulting:

- a role outside `build`, `deploy`, `fork` (the word `probe` included), and a missing role;
- a stage the cells file does not name for that cell;
- a role that does not exist for that stage (a `deploy` for a stage with no cell step here; a `fork` for a
  stage that is not `PULL_REQUEST`);
- a template whose account is unset, is the probe identity, is the level-1 deploy identity, is not a
  `kcb-` account, or carries a stamp that is not this triple's;
- a template, account or stamp that is missing (bootstrap level 3 has not run for it).

The launch contract calls `resolve_stage_job` and then runs `StageJobRef.template`; it returns the
account and its unique id in its reply, so the caller can record them.

### Inside the job: the identity is the authority

A stage job runs `kci run` in **stage-job mode**:

- **Credentials.** kci's GCP credentials today come only from `GOOGLE_APPLICATION_CREDENTIALS` and never
  from the metadata server (deploy step, "Credentials"). Stage-job mode is a new flag,
  `--credentials=metadata`, accepted only with `--stage-job`, and it refuses a set
  `GOOGLE_APPLICATION_CREDENTIALS`. The token is the metadata server's, for the template's account.
- **Who am I.** kci reads its account from the metadata server, reads that account's stamp, and takes
  (machine, cell, stage, role) **from the stamp**. Arguments are requests: a `--stage` other than the
  stamp's stage, a cells file or cell other than the stamp's, a machine name other than the stamp's, are
  refused before any step.
- **What may run.** A `build` identity runs BUILD steps only; a `deploy` identity runs PUBLISH, DEPLOY and
  validations only, never BUILD; a `fork` identity runs BUILD steps and resolves no secret. A step outside
  the role is refused by name, before any step runs, with zero cloud calls. A `RUNNER` probe (#1170's
  default placement, `docker run`) is refused in a `deploy` job at start: a cloud job has no docker
  daemon, so the stage's probes must be `CELL` probes.
- **Pre-flight**, each a check that fails INDETERMINATE with zero writes: the account has no user-managed
  key; the account holds no role on the probe account other than (for `deploy`) act-as; the probe identity
  is not this account. The `deploy` job also runs #1170's identity pre-flight before any `CELL` probe.

These checks catch a wrong launch (a `build` template given `deploy` arguments, a mixed-up stage), not
hostile code: in a `build` job the repository's steps run after kci's checks, with the same token. The
cloud's grants are the second guard, and for `build` and `fork` the one that holds: a `build` job whose
kci were somehow told to deploy would still hold no DEPLOY grant.

### Rotation

A stage identity holds no key, so there is no secret to rotate: each execution gets a fresh platform
token. Rotation is for replacing an account (a suspected compromise, a grant that went wrong):

- `kci bootstrap --level 3 --rotate <stage>/<role>` creates generation `n+1` (a new name, a new unique
  id), binds it as the render says, repoints the template to it, and then deletes generation `n` as
  "Teardown" deletes, once no execution of the template is running.
- **A party outside the cell that trusts a stage identity must key the trust on the account's unique id,
  not its email.** A deleted account's email can be taken again by a new account with a new unique id; a
  trust keyed on the email would accept it. Rotation changes the unique id, and the bootstrap's output says
  which trust to update.
- A stage secret's value is rotated by the administrator writing a new version; the next execution reads
  `latest`.

### Teardown and the closed world

The bootstrap verb (`kci bootstrap --level 3`, plan by default, the administrator's credentials) owns a
closed world of its own: **every object stamped `kci-bootstrap:v1 owner=<machine>/<cell>` with an item
`stage-job/...` or `stage-secret/...`, and every binding attributed to one**. The render is a pure function
of the cells file and the machine file. Applying it:

- creates what the render names and is missing; updates what drifted (a binding, a template's account,
  image or secret reference) back to the render;
- **deletes** what is stamped for this (machine, cell) and the render no longer names (a `stage_job`
  removed, a role a stage no longer has), in this order: the template (no new launch), then, once no
  execution of it is running (else INDETERMINATE, nothing deleted), every binding whose member is the
  account, then the account, then the stage secrets of that stage and the stage's prefixes in the two
  buckets. Bindings go before the account, so no policy keeps a `deleted:` member;
- **never** matches by name prefix, never deletes a level-1 or level-2 item (the probe identity, its deny,
  the results bucket), and never deletes another (machine, cell)'s item, though it shares the `kcb-`
  prefix;
- reads each deleted object back and expects not found.

The DEPLOY step's closed world and this one are disjoint by stamp: neither lists what the other stamps.

## The probe identity and the stage identities

| | probe identity (#1170) | stage identities (this design) |
|---|---|---|
| how many | one per cell | up to three per (cell, stage) |
| bootstrap | level 2 | level 3, which requires level 2 |
| grants | none; a deny policy names it alone | the table under "What each role may do", by condition and per resource |
| who creates its jobs | kci (`deploy`), one job per probe | bootstrap, one template per role; the launcher runs it |
| act-as needed by the caller | yes: the `deploy` identity acts as it | no: running a template needs none |
| results | a signed URL, one object, in the results bucket | its own create-only prefix in the stage results bucket |
| secrets | none (#1170 KD5) | by reference, `build` and `deploy` only |
| run id on executions | a label, per run | in the arguments and the result; the execution's name maps it |

**What they share:** the `CellJobs` port; G4's `job_json` as the one writer of a Run job, `template.labels`
included; the rule that a job's account is set explicitly, with a fake that falls back to a default
identity when it is not; the bootstrap verb; and, if Q-SJ7 is decided as recommended, the bootstrap stamp
namespace and the `kcb-` prefix.

**They stay disjoint**, checked from both sides: #1170's pre-flight refuses any allow binding naming the
probe identity, so a stage identity cannot be granted to it; this design's pre-flight refuses a stage
identity holding anything on the probe account beyond the `deploy` act-as, and a template whose account
is the probe's. The results buckets are separate, so a stage job can never create a probe's result object
(whose name is a hash of a predictable run id).

## Q13

Q13 restricts, on a `DERIVED` shape, a `uses` line on a workload that has `run_as`, and a `grant` resource,
because the node id of such an edge is not owned by its principal. **This design does not need Q13 lifted**:
a stage identity is a bootstrap item, never a resource of a list, so no `uses` line has it as principal and
no `grant` names it; its bindings are written by the bootstrap verb and attributed in the bootstrap
namespace. Two dependencies remain, both through G5, not through the identity:

- A `deploy` job applies the stage's resource list on GCP, so the kinds it can deploy are G4's and G5's,
  and G5 depends on U1 (Q13 decided as recommended).
- If an operator wanted a stage job modelled as a `kci.job` instance instead of a template, its own
  account would need grants, which on a `DERIVED` shape takes U1's `uses` input. This design does not do
  that, for the reasons under "Who creates it".

## What the policy asks that the cloud cannot enforce

Stated so that no one believes a guarantee that is not there:

- **Logs.** Every identity that writes logs (`roles/logging.logWriter`, which every workload holds through
  the implicit `cell LOGS WRITE` edge) can write any log name and any resource label in the project. A
  stage job's logs cannot be kept to "its own"; a reader must treat them as text, never as a verdict
  (#1170 reads results from an object for the same reason).
- **Per run.** IAM scopes a job to its stage's and role's prefix, never to its run: the run id is not
  known when the grant is written. A job could create an object under a later run's name. The result
  object's name therefore holds the execution's name (`CLOUD_RUN_EXECUTION`, unknown until the launch),
  and a reader checks the object's single generation, its `kci-run-id` metadata and its creation time
  after the execution's start, as #1170 does.
- **Whose grant.** `hasOnly` limits the roles a `deploy` identity can grant, not to whom (above).
- **Allow policies above the project.** A grant at the folder or organization to a stage identity is not
  read by the pre-flight; as #1170 says of the probe, reading allow policies cannot prove absence.

## PR split

The DEPLOY step's D1, G3, G4 and G5, and #1170's K6c and K6e, merge first where a row names them. "The
fake" is `kci_cloud_fake`'s `FakeCellJobs` (K6c) grown with templates: a template runs as its account
whatever the caller asks, `run` takes the overrides Run takes (arguments replaced, environment merged,
task count and timeout replaced; image, account and labels refused), a template with no account runs as
the fake's default identity, and a fake metadata server answers with the running template's account.
Each row names the planted defect that must turn its test red; the PR body records the red build.

| PR | packages | depends on | tests prove | planted mutant goes red |
|---|---|---|---|---|
| **SJ0** this doc | `docs/design/stage_job_identity.md`, `docs/index.md` | none | The link resolves under the `markdown_docs` lint (`komira//:docs`). No test of design content is possible for a docs-only PR. | the link to this doc misspelt in the index |
| **SJ1** cells file | `kci_cell` (`stage_job`, `secret`, level 3) | D1, K6c (level 2) | A golden parse; a red case for each cells-parser refusal under "The cells file". | `stage_job` accepted at level 2; a duplicate stage accepted |
| **SJ2** the model and the resolver | `kci_cloud` (`stage_jobs.mojo`: the roles of a (cell, stage) as a pure function of the machine and cells files, the names and the bootstrap stamp, `resolve_stage_job` on `CellJobs`, the bootstrap role table's shape); `kci_cloud_fake` (templates, overrides, default fallback, metadata); `kci_release_machine` (the cross-checks) | SJ1, K6c, G3 | Every refusal of `resolve_stage_job` and every machine-file cross-check, by name, with zero calls. The roles of a build-only stage, a deploying stage and a `PULL_REQUEST` stage. Two cells and two stages give disjoint names. A DEPLOY step over a cell holding stage items lists none of them as owned, and a resource list naming a `kcb-` object by `physical_name` is refused as foreign. A stage job's execution on the fake runs as the template's account although the launch names another. The policy's own cases: a launch naming `probe` is refused; a launch with no role is refused, not defaulted; the `build` and `deploy` templates of one stage are not interchangeable (each resolves to its own account). | `probe` accepted as a role word; a missing role defaulted to `build`; resolution keyed by (cell, role) without the stage (two stages resolve to one account); the bootstrap stamp decoded as a scope identity (the DEPLOY step reports the stage account as `leftover`); the foreign check skipped for `kcb-` (the adoption case adopts the stage account) |
| **SJ3** stage-job mode | `kci_cli` (`--stage-job`, `--credentials=metadata`, identity from the stamp, the role's steps, the environment and task-count refusals, the pre-flight); `docs/ci.md` | SJ2, D5 | On `FakeCloud` and the fake: a `build` identity asked for `--stage prod` is refused with zero calls; asked to run a DEPLOY step, refused by name; a `deploy` identity asked to run a BUILD step, refused; a `fork` job resolves no secret name (the environment holds none, and `kci` never reads one); `GOOGLE_APPLICATION_CREDENTIALS` set, a stray environment variable, and a task count of 2 are each refused before any step; an account with a user-managed key is INDETERMINATE with zero writes; a passing `deploy` job's summary holds secret names and no value. A DEPLOY step into a cell that names any `stage_job`, run outside stage-job mode, is refused at start with zero calls (Q-SJ8). A `deploy` job whose stage has a `RUNNER` probe is refused at start. | the stage taken from `--stage` instead of the stamp (the `prod` case runs); the role check removed (the build job applies); a `fork` template given the stage's secrets (the fork case finds a value); the environment check removed (the credentials-file case uses the file); the Q-SJ8 check removed (the runner's DEPLOY into a stage-job cell applies) |
| **SJ4** GCP | `kci_cloud_gcp` (the render of level 3 with its conditions, templates through G4's `job_json`, the bootstrap role table and its injectivity test, bootstrap attribution of bindings, the exclusive-project check, metadata credentials and `whoami`); the GCP emulator (run with overrides, a metadata server, conditions on names and `modifiedGrantsByRole`, user-managed keys) | G4, G5, K6e, SJ2 | SJ2's and SJ3's cases rerun on the emulator with the same assertions. A golden of each template's JSON (account set, one task, no retries, secret references for `build` and `deploy` only, labels in both places). A `deploy` identity's attempt to update a `kcb-` template, act as a `build` account, or grant a role outside the table is refused by the emulator. A project holding another cell's stamped account is refused at render and at start. A bootstrap binding is attributed to its item and not reported as an unmanaged difference; the same binding with its condition changed by one byte is. | the account dropped from the template (the emulator runs it as the default account; the identity case goes red); the `kcb-` exclusion dropped from the act-as condition (the `deploy` identity acts as `build`); the role table's `hasOnly` list widened by one role (the grant case is accepted); the exclusive-project check skipped (the shared-project case renders); attribution ignoring the condition (the changed-condition case is taken as ours) |
| **SJ5** the bootstrap verb | `kci_cli` (`kci bootstrap --level 3`, plan by default, `--apply`, `--rotate`), `kci_cloud` (the bootstrap closed world), `docs/ci.md` | SJ4 | On the fake and the emulator: plan makes zero writes; apply creates, a second apply is a NOOP; removing a `stage_job` deletes its template, bindings, account, secrets and prefixes in that order and reads each back as not found; another (machine, cell)'s `kcb-` items and the level-2 items are untouched; a running execution stops the delete, INDETERMINATE, nothing deleted; rotation yields a new unique id, the template runs as the new account, the old account is gone. | delete matched by `kcb-` prefix (another cell's account removed); the account deleted before its bindings (a `deleted:` member stays in a policy); the running-execution check dropped (the delete proceeds); rotation reusing the generation (the unique id is unchanged) |
| **SJ6** end to end | `kci_cli` tests over the emulator | SJ3, SJ5, I4, K6f | A stage on the emulator: the `build` job writes its handoff under its prefix, the `deploy` job reads it, publishes into the cell, applies a G5 graph and passes a `CELL` probe; the `build` job's attempt to write the registry and the `deploy` job's attempt to write another stage's prefix are refused by the emulator. | the `deploy` identity given the `build` role's staging write (a cross-stage write lands); the probe's act-as granted to `build` (`build` creates a probe job) |

Merge order: SJ0, SJ1 after D1 and K6c's level 2, SJ2, SJ3; SJ4 after G4, G5 and K6e; SJ5; SJ6 last.

Before SJ4 is called done, these are shown on a real project and recorded in its PR body, with the
operator's go for the spend:

1. Running a job needs no act-as on its account; creating or updating one does.
2. Run's overrides cannot change the image, the account or the labels.
3. A condition on the resource name is honoured for service accounts (create, delete, act-as), for Run
   jobs, services and worker pools, and for secrets' policies; for each type that does not, which grant
   loses its scope (Q-SJ10).
4. `modifiedGrantsByRole` `hasOnly` is honoured on the project's policy and on a secret's.
5. Run's execution cancel and get are authorized on the job, so a per-template grant suffices.
6. A metadata identity token's subject is the account's unique id.

## Decided

Nothing yet; every choice above that is not forced by the DEPLOY step or #1170 is a question below.

## Open questions (for the project owner; recommendation first)

| # | question | recommendation |
|---|---|---|
| Q-SJ1 | Who creates stage identities: bootstrap (a human verb), or a DEPLOY step? | Bootstrap level 3. A list cannot create the principal that applies it, the grants are not `uses` edges, and a new principal with deploy rights deserves the human step a cell gets. |
| Q-SJ2 | The image a stage job runs: fixed in the template (a new base release means rerunning bootstrap level 3 in each cell), or chosen per launch (a job created per launch, which needs create and act-as for the launcher)? | Fixed in the template; the launch contract refuses a request whose digest is not the template's. Create plus act-as on the `deploy` account is "run any image as the deploy identity", which no base-image policy can then bound. |
| Q-SJ3 | One project per cell at level 3? | Yes, checked at render and at start. Without it no condition can keep one cell's `deploy` identity off another cell's objects. |
| Q-SJ4 | Levels cumulative (3 requires 2), or a set of capabilities? | Cumulative. A `deploy` job runs `CELL` probes, and the disjointness check needs the probe identity. The cost: level 3 needs an organization, as level 2 does. |
| Q-SJ5 | A stage secret per (cell, stage, name), or per (cell, name) shared by stages? | Per (cell, stage, name). Sharing a value between two stages is then two secrets the administrator fills, and no stage reads another's. |
| Q-SJ6 | Teach the DEPLOY scope's attribution the bootstrap namespace, so a bootstrap binding is not reported as an unmanaged difference on every plan? | Yes, in SJ4: a third class, reported nowhere by DEPLOY and checked by the bootstrap verb. Today's rule would print the stage bindings on every plan, and the noise hides a real stranger. |
| Q-SJ7 | Should #1170's probe identity, deny and results bucket take the `kcb-` prefix and the bootstrap stamp too? | Yes, before K6e: one namespace and one prefix for every bootstrap item, so the `deploy` identity's conditions exclude them all with one rule. #1170 names none of them today. |
| Q-SJ8 | May one cell take deploys both from a runner (the level-1 identity) and from stage jobs? | No. kci enforces it from the cells file alone: in a cell with any `stage_job`, a DEPLOY or PUBLISH-into-cell step run outside stage-job mode is refused at start, so a runner's queue and the launcher's queue never apply into one cell at once. |
| Q-SJ9 | May a `fork` job write where the same stage's `build` job reads (its handoff and caches)? | No. A `fork` job writes only its result and `<stage>/fork/`, which no other role reads, so a pull request from another repository cannot poison what a same-repository pull request's build reads. |
| Q-SJ10 | If GCP does not honour a name condition for a resource type (real-project check 3): refuse level 3 on GCP, or accept the wider grant? | Refuse level 3 until a narrower form exists (a separate project for bootstrap items, or a deny on tagged resources). A `deploy` identity that can rewrite its stage's templates is not scoped. |
