# The DEPLOY step: cells, the GCP adapter, images into a cell, and deploy probes

Status: design, no code. It builds on the resource-model stack #682 (P8) → #690 (P9) → #696 (P10) →
#700 (P11, registry) → #719 (P12, labels, `physical_name`, `adopt`) → #722 (label budget) → #736 (C1,
composites expanded before validate) → #769 (C2/C3, `kci.job` and `kci.app` in `kci_composites`), and
assumes that stack merges first. Related: #373, #374, #376.

## What is it for, and what is out of scope?

An operator runs kci to deploy their own services into their own cells. Today kci can build and
publish, but it cannot deploy. This document covers what it needs to deploy:

1. **A machine name, a cell and a DEPLOY step** that `kci run` plans and applies.
2. **A GCP adapter**, which is the first real `CloudAdapter`.
3. **Images.** An image is published into a cell's registry, and the same digest is promoted to the
   next cell.
4. **A `DEPLOY_PROBE` validation** that can gate promotion.

Out of scope, each with its own design:

- **A durable state store and a cell lease.** In v1 the cloud's stamps are the record. Two runs into
  one cell are kept apart by the release workflow's one-run-at-a-time rule (see "One run at a time").
  kci takes no lock.
- **A destroy verb.**
- **Safe adoption.** This document uses only its interface; see the GCP adapter section. That
  includes the relabel of old `--` stamps (#376).
- **The override document** (#772). A DEPLOY step can take an `overrides` field when that design
  lands; the name is held.
- **Multi-platform images.**

## What exists, and what is missing?

Checked against `main` and the stack head.

| piece | state |
|---|---|
| `kci_release_machine/graph.mojo` | DEPLOY is refused ("needs a newer kci"). The header already says a DEPLOY step names a cell, and the cell names its cloud, but neither has a field. A PR stage refuses any step that is not BUILD. A farm-connected stage refuses a PUBLISH step. |
| the machine file's name | **There is none.** `ReleaseMachine` holds `schema_version` and `stages`, and the parser refuses any other top-level field. Every stamp, the `(machine, cell)` scope and the registry name need one. |
| `kci_cloud/deploy.mojo` (stack) | `plan_resources`, `apply_resources` and `destroy_resources` all take `(clouds, cloud, ctx: CellContext, resources, creds, store, definitions)`. Before anything else happens, each one refuses a scope that is not owned, checks the validation run id, runs the adapter's `configure`, expands the composites and validates. `ApplyOutcome` carries `applied`, `landed`, `pending`, `error`, `leftover` and `left_behind`. **`plan_resources` returns only the change actions**: its `leftover` and `left_behind` are computed and dropped. `group_plan` renders a plan. |
| `CellContext` | Holds a `CellScope` (machine, cell, provenance, adopt, validation run id), `settings`, `artifacts: List[ResolvedArtifact]` and `bootstrap_level`. **No code reads `bootstrap_level`.** |
| state store | `InMemoryStateStore` only. |
| adapters | `FakeCloud` and `FakeLimitedCloud` only. A fake's `bootstrap_resources` lists a state store and a `registry` (`<machine>-<cell>-images`, "where the cell pulls images by digest"). |
| `kci_cli` | Links none of `kci_cloud`, `kci_reconciler`, `kci_resource_proto` or `kci_composites`. `dispatch.mojo` is 737 lines and `graph.mojo` is 821, so the new code goes in new files. |
| `kci_api/result.mojo` | `landed[] pending[] failed outputs[] plan_hash security_relevant_changes[]` are reserved as top-level names and never emitted. |
| `kci_api/exit_codes.mojo` | 3 REFUSED, 4 FAILED (SAFE), 5 INDETERMINATE, 6 PARTIAL (UNSAFE), 7 VALIDATION_FAILED, 8 LEFT_BEHIND (reserved, has no outcome). |
| `kci_workflow_check` | R16: one workflow-level `concurrency:` (a push to main in `kci-release-main`, never cancelled in progress; a manual run in a group per ref), and **no job has a `concurrency:` of its own**. R4: `id-token: write` only on a job whose stage publishes to an OIDC channel or is farm-connected; no other job carries it. R15: a stage that is not `break_glass` runs only on a push to main. |
| `komira_oci`, `kci_publish_oci` | `LayoutPusher` and `OciCopier.copy_by_digest` exist. `publish_layout` is not wired; it says "an image step needs a cell". |
| `oci_image` | Writes a layout plus `[digest]` and `[docker_archive]`. It has **no `[release]`** sub-target, and the release set reads only `[release]`. |
| `kci_validate` | Two kinds: `CONDA_INSTALL_SMOKE` (a hardened `docker run`, anonymous pull by digest) and `CONDA_INSTALL_ENV`. A validation may attach only to a PUBLISH step. `validations[].environment` is `ENV` or `CONTAINER`. |
| `komira_gcp_core` ADC | Reads `service_account` and `authorized_user`. It **refuses `external_account`** by name, which is the file a CI's OIDC-to-GCP exchange produces. |

**Where code and docs disagree.** Each of these is fixed by the PR named in the split below.

| where | says | is |
|---|---|---|
| `refs.proto` `StepOutput` | "an output of an earlier BUILD step of the same run" | The next cell deploys an image built by another job. A `StepOutput` resolves through the **release set** the stage is handed (same revision, built once), with `step` checked against the machine file. Fixed in I4. |
| `kci_cloud/labels.mojo` | "an IAM binding carries the identity as the first line of its description" | An IAM member binding has no description and no labels. The gcp fake stamps grants with in-memory labels, so the fake hides this. Fixed in G3. |
| `kci_cloud/labels.mojo` | a description carrier holds "the identity" | Kit step 3 also requires one retention mark and the run-id label on every node, so a description carrier must hold all three. Fixed in G4. |
| artifact type of an image | `OCI` (channel), `OCI_IMAGE` (`kci_publish_oci`), `oci-image` (`ArtifactNeed`) | There should be one word. It becomes `OCI`, the `kci_release_channel` constant. Fixed in I1. |
| `CellScope` docstring (stack) | `--adopt <id>` | After P12, adoption is the `adopt` field. There is no flag, and this design adds none. |
| `docs/design/release_machine.md` | the driver is `komira_ci`; channels and conda packages are held | The driver is `kci`, and channels and conda publishing exist. Fixed with this document. |

## The machine name

A machine file gains a top-level `name`, written before the first `stage`:

```textproto
schema_version: 1
name: "shop"
stage { ... }
```

| rule | detail |
|---|---|
| grammar | The step-name grammar (`[a-z][a-z0-9-]*`, at most `STEP_NAME_MAX_BYTES` = 63, not ending in `-`). It is written verbatim as the `kci_machine` label value, so the 63-byte label budget holds. |
| required | When the machine holds a DEPLOY step or a PUBLISH step into a cell. Optional otherwise, so an existing machine file (komira's own has none) parses unchanged and the format keeps major 1. |
| set twice, or after a `stage` | Refused. |
| meaning | `CellScope.machine`. It is part of every stamp, so **renaming a machine orphans every object it owns**: the new name sees them as foreign and refuses. A rename is a migration that needs safe adoption; v1 has none. |
| derived names | A name the adapter derives from machine and cell (the bootstrap registry's `<machine>-<cell>-images`, at most 63 bytes on GCP) is the adapter's `configure` finding, not the parser's. |

## Cells

A cell is one closed world: one cloud, one place, owned by one machine. Cells are declared in a
**cells file**, format `kci.cells`, following the channels-file precedent. A step names the file and
picks one cell from it, the same way a PUBLISH step names `channels` and picks one `channel`.

```textproto
schema_version: 1
cell {
  name: "staging"
  cloud: "gcp"
  setting { key: "project" value: "example-staging" }
  setting { key: "region" value: "europe-west1" }
  bootstrap_level: 1
}
```

| field | rule |
|---|---|
| `name` | The step-name grammar, unique in the file. It is `CellScope.cell` and part of every stamp. |
| `cloud` | A `CloudId` word, required. Whether this kci was built with that cloud is checked by `kci run` (`Clouds.resolve`), not by the parser. |
| `setting` | Repeated key and value, each key at most once. kci does not interpret them: the adapter's `configure` reports unknown or missing keys as findings. For GCP, `project` and `region` are required. |
| `bootstrap_level` | An integer, required. The operator writes it after running bootstrap. **v1 accepts only `1`**, because no code reads the field and no second level is defined (question Q7). |

The parser lives in a new package, `src/kci_cell`. It depends on the lexer and `kci_api` only, never on
`kci_cloud`. Every refusal starts `cells file: line N:`. It refuses:

- an unknown field;
- a scalar set twice;
- a duplicate cell name or setting key;
- an empty `cloud`;
- a name outside the grammar;
- a `bootstrap_level` other than 1;
- a file with no cell;
- a `schema_version` that is missing or of another major.

## The DEPLOY step

### Fields

```textproto
step {
  name: "deploy"
  kind: DEPLOY
  cells: "release/cells.textproto"
  cell: "staging"
  resources: "deploy/app.json"
  definitions: "deploy/defs/queue_worker.json"
  validation { ... }                      # DEPLOY_PROBE only, see below
}
```

| field | rule |
|---|---|
| `cells`, `cell` | Required. The cell must be in the file. |
| `resources` | Required. A relative path with no `..`, holding a proto3-JSON `ResourceList` (`decode_json[T]`). There is no text-format decoder into generated messages, so JSON costs no code (question Q1). |
| `definitions` | Repeated and optional. Each is a proto3-JSON `CompositeDefinition`. The built-in `kci.job` and `kci.app` come from `kci_composites` and are always passed. A file that redefines a built-in name is refused. |
| `validation` | Optional. Only kind `DEPLOY_PROBE` is allowed on a DEPLOY step. |
| `platform`, `artifacts`, `channels`, `channel` | **Refused.** A platform is an OS plus a CPU and never names a cloud. Images come from the release set (see "Images into a cell"). |

### Refusals in the machine file

These are checked in the pure parser, in a new file `kci_release_machine/deploy.mojo`.

| refused | why |
|---|---|
| A DEPLOY step in a PULL_REQUEST stage | This is already refused. A PR's check builds and never deploys. |
| A DEPLOY step in a `farm_connected` stage | The job that holds a farm network credential must not also hold a cell's deploy identity, by the same reasoning that already refuses a PUBLISH step there. A PUBLISH into a cell is a PUBLISH step, so the existing rule already refuses it. |
| A DEPLOY step, or a PUBLISH into a cell, in a `break_glass` stage | A manual run then never reaches a step that writes into a cell, so only pushes to main do, one run at a time (see "One run at a time"). Question Q11. |
| A DEPLOY step, or a PUBLISH into a cell, in a machine with no `name` | The scope has no machine. |
| A missing `cell`, or a cell not in `cells` | |
| A missing `resources`, an absolute path, or `..` | |
| `platform`, `artifacts`, `channels` or `channel` on a DEPLOY step | See above. |
| **Two DEPLOY steps, in any stages of one machine, naming the same cell** | The scope is `(machine, cell)`. A second step would see the first step's objects as `leftover`. |
| A validation of another kind on a DEPLOY step, or a `DEPLOY_PROBE` validation on a BUILD or PUBLISH step | |
| A DEPLOY step with no `DEPLOY_PROBE` validation in a stage that another stage names in `after` | Its `set_hash` would be handed on without anything having checked the cell (see "Gating promotion"). |

### One run at a time

v1 has no cell lease, so something else must keep two applies into one cell apart. A job-level
concurrency group per cell is not that thing: R16 refuses a job's own `concurrency:`, because GitHub
replaces a pending job in a group with a newer one, which would silently drop a deploy.

The design uses what R15 and R16 already guarantee:

- A step that writes into a cell (a DEPLOY, or a PUBLISH into a cell) sits only in a stage that is not
  `break_glass` (refused above). R15 makes such a stage's job run only on a push to main.
- R16 runs every push to main in the one workflow-level group `kci-release-main`, never cancelled in
  progress. Two pushes therefore never apply at the same time.
- A newer push replaces only a **pending** run, and a pending run has written nothing. The newer
  revision's resource list is the whole desired state, so dropping the older pending run loses no
  change. This is the replacement R16 already accepts for a release.
- Within one run, one DEPLOY step per cell (refused above), and D6 keeps a cell's PUBLISH and DEPLOY in
  one job (see "The workflow check").

What remains, said in the summary and in `docs/ci.md`:

- An operator running kci by hand, outside CI, is serialized with nothing. Running `kci run` without
  `--plan` against a cell that CI also deploys is unsupported until there is a lease.
- A re-run of an older workflow run's deploy job applies the older revision's resource list, which
  rolls the cell back (question Q12).

### What `kci run` does for a DEPLOY step

The code goes in a new file, `kci_cli/deploy_step.mojo`. It is generic over
`[S: CloudAdapter, St: StateStore]`. The binary's `main` lists the adapters it was built with.

1. **Load.** Read the cells file, the resource file and the definitions. Resolve `cell.cloud` with
   `Clouds.resolve`. If this kci was not built with that cloud, REFUSED.
2. **Credentials.** Read them from the provider's standard variables only (see "Credentials").
   Then run `whoami` and `trust_check`. Any finding is REFUSED.
3. **Context.** Build the `CellContext`:
   - scope `machine` = the machine file's `name`, scope `cell` = the cell's name;
   - `Provenance(--run-id, --revision-id)`;
   - `validation_run_id` = None. A deploy into a long-lived cell is never stamped with a validation
     run id; that id belongs to what a validation causes to be created (see "Run id");
   - `settings` = the cell's settings;
   - `artifacts` = the release set's OCI members, resolved as described in "Images into a cell".
4. **Release set.** As PUBLISH does today, require `--release-set-hash` and recompute it from
   `--release-dir`. A mismatch is REFUSED.
5. **Plan or apply.**
   - With `--plan`, call `plan_resources`. A plan writes nothing to the store or the cloud. A plan
     with an unpinned image uses the existing `UNPINNED-NOT-A-DIGEST:` rendering. `--plan` is still
     refused on a release run, as today.
   - Without it, call `apply_resources`.
6. **Report.** Print `group_plan(actions)` to stdout and to the summary file. Fill in the result
   keys below. Then run the step's validations, which see this run's recorded outputs.

Two `kci_cloud` changes come first, in D4:

- **A typed refusal.** Today `kci_cloud` raises refusals as text through `refusal_text`, and
  `ApplyOutcome.refused()` matches a message prefix. A refusal becomes a value carrying its findings,
  both for a refusal raised before any effect (validate, expansion, name and key changes) and for an
  engine refusal. Telling REFUSED from FAILED by message text is not a classification.
- **`plan_resources` returns a `PlanOutcome`** of `actions`, `leftover` and `left_behind`, so a
  `--plan` can report what an apply would leave alone. Today the last two are dropped.

### The result document

Every key is additive inside major 1 (`kci_api/result.mojo`). The keys sit **on the step row**
(`steps[]`), not at the top level: a stage can hold DEPLOY steps for several cells, and a top-level
list could not say which cell a node is in. The top-level reservation of these names is replaced by
this one in D3. The step row also gains `cell` and `cloud`.

| key on the step row | shape | when |
|---|---|---|
| `landed[]` | `{node, verb}` | After an apply. These are live in the cell. |
| `pending[]` | node ids, in apply order | After an apply that stopped. The first entry is the node that failed. |
| `failed` | `{node, verb, fault_domain, message}` | After an apply with an engine error. The message never holds a credential. |
| `outputs[]` | `{resource, output, value}` | After an apply. Only declared outputs that are not secret (URL, ADDRESS). |
| `plan_hash` | sha256 hex over the canonical JSON of the change actions, sorted by node id | On `--plan` only. `ApplyOutcome` carries no action list, and computing one beside the apply would need a second `list_owned` that can race. An apply emits it once the engine returns the plan it executed (question Q9). |
| `leftover[]` | node ids | **New.** Objects owned by resources the file no longer names. kci reports them and never deletes them. On `--plan` and apply. |
| `left_behind[]` | node ids | **New.** Retained objects the file no longer lowers. kci reports them and never deletes them. On `--plan` and apply. |
| `security_relevant_changes[]` | | Stays reserved and is not emitted until it is defined. An always-empty list would be a claim with no code behind it. |

### Outcome and exit

| situation | outcome | exit | retry |
|---|---|---|---|
| Any refusal above, an adapter `configure` or trust finding, an expansion or validate finding, a name or key change, a foreign or conflicting object (the typed refusal) | REFUSED | 3 | NEEDS_HUMAN |
| A read failed before the engine's first mutating call (`list_owned`, `whoami`, transport) | FAILED | 4 | SAFE |
| **Any engine error after apply started that is not a typed refusal**, even with `landed` empty | PARTIAL | 6 | UNSAFE |
| `--plan`, or an apply that changed something | SUCCEEDED | 0 | SAFE |
| An apply where every action was a no-op | NOOP | 0 | SAFE |
| A `DEPLOY_PROBE` validation failed / could not tell | VALIDATION_FAILED / INDETERMINATE | 7 / 5 | NEEDS_HUMAN |

Two notes on this table.

- **An engine error with nothing landed is PARTIAL, not FAILED.** `ApplyOutcome.partial()` is false
  when `landed` is empty, but the failing node's own call (a create whose wait timed out) may have
  landed. Exit 4 promises that no effect landed, and kci cannot promise that here.
- **`leftover` and `left_behind` do not change the outcome.** The summary lists them and says kci will
  not delete them. Exit 8 stays reserved for a destroy verb.

### What v1 does not do

| not done | consequence, said in the summary and in `docs/ci.md` |
|---|---|
| No destroy verb | Removing a resource from the file leaves it as `leftover`. Teardown is a human step (question Q2). |
| No durable store | The cloud's stamps are the record. Removal needs both a record and a stamp, so nothing removed from the file is deleted. |
| No cell lease | Only pushes to main deploy, one run at a time (see "One run at a time"). A hand-run apply is serialized with nothing. |
| No deploy on a break-glass run | A fix from a branch reaches a cell only through main (question Q11). |

## The GCP adapter

The new package is `src/kci_cloud_gcp`, holding `GcpCloud: CloudAdapter` with `complete()` False.
Each provider kind is one `ResourceDescriptor`, wrapped in `DescribedResource`. Each verb runs the
generated async client on a blocking runtime and waits on the long-running operation.

### Conformance: what each trait method answers

| method | GCP answer |
|---|---|
| `implemented` / `absences` | The kinds in the table below are implemented. Every other catalog type is NOT_YET if PORTABLE and ABSENT_BY_DESIGN if CLOUD_BOUND, each named exactly once. |
| `configure` | `project` and `region` are required. Any other key is a finding. So is a derived name over its limit (the registry's). |
| `check` | The findings of the derived grant stamp (see "Grants"). |
| `lower` | **The shared shape lowering**, lifted out of `kci_cloud_fake` (G3). It is not a second lowering written by hand. |
| `realize` | One descriptor per provider kind (table below). |
| `label_rule` / `identity_of` | Labels where the object takes labels. A description where it does not (service account, Scheduler job; see "Description carriers"). A binding's stamp is derived (see "Grants"). |
| `list_owned` | A list call per kind, filtered by stamp. Bindings are read from the policies of owned targets and of the project. |
| `whoami` | The token's principal. This needs a token-info read, which no client has today (G1). |
| `trust_render` / `trust_check` | Render, and then read back, the workload-identity provider and the binding of the cell's deploy identity. This needs a WIF provider `get` (G1). A trust check that cannot fail is not a check. |
| `bootstrap_resources` | The state store and the image registry, matching the fake. |
| `image_registry(ctx)` **(new)** | The pull and push address of the cell's bootstrap registry. It is pure, computed from settings, machine and cell. |
| `registry_login(creds)` **(new)** | The basic-auth user and secret a registry client presents. The user is the access-token convention. Plain strings, so `kci_cloud` does not depend on `komira_oci`. |

### First kinds: a container service, a background worker and a scheduled job

| catalog type | roles (shared shape) | GCP object | stamp carrier | client methods missing today |
|---|---|---|---|---|
| `service_account` | identity | IAM service account | **description** (no labels; 256 bytes) | `PatchServiceAccount` |
| `service` | identity, run, public | service account, Run Service, invoker member binding | labels on the Service; the binding is derived | Services `Get/SetIamPolicy` |
| `worker` | identity, run | service account, Run worker pool | labels | WorkerPools create/get/list/update/delete (question Q8) |
| `container_job` | identity, run | service account, Run Job | labels | Jobs `Get/SetIamPolicy` (needed for the schedule's invoke grant) |
| `schedule` (P9) | identity, schedule | service account, Cloud Scheduler job | **description** (a Scheduler job has no labels) | CloudScheduler `ListJobs` |
| `grant` (one per `uses` edge) | `u-<h>` | a member binding through `setIamPolicy` on the project, a service, a job or a secret | **derived** | as above |
| `secret` | secret | Secret Manager secret | labels | `GetSecret`, `UpdateSecret`, `Get/SetIamPolicy` |

Not in v1:

- `table`. Indexes and the TTL field have no carrier and no Admin client.
- `bucket`. List and patch methods are missing.
- `registry` as a resource. The image registry is a bootstrap item.
- `queue`, network and DNS.

### Description carriers

Kit step 3 requires every live node to decode to its identity, to carry exactly one retention mark,
and to carry the scope's run-id label (or none). An object without labels carries all three in its
description, one per line:

```text
kci:v<scheme> owner=<machine>/<cell>/<resource>/<role>
kci-retention=<retain|delete>
kci-run-id=<id>
```

The third line appears only when the scope has a validation run id. `identity_of` and the kit's
`live_labels` hook read these lines back as labels. The description is kci's whole: an object whose
description holds anything else is not stamped. Validate refuses a node whose lines exceed the kind's
description limit (256 bytes for a service account), so a long machine, cell or resource name fails
before anything is created, not at create time.

### Grants: the derived stamp (a reconciler decision, G3)

`refuse_unless_owned` checks every node, wanted or not. Every `service` lowers a `public` binding node,
and every resource that holds its own identity lowers the implicit `cell LOGS WRITE` edge, which on GCP
is a binding on the **project**, an object the cell does not stamp. Dropping kinds that cannot stamp
would therefore drop almost everything. Instead, a shape declares its grants' carrier as `DERIVED`, and
a binding's stamp is computed from what the cloud holds.

| rule | detail |
|---|---|
| attribution | A binding (target, member, IAM role) is attributed to a node when: its **member** is an identity stamped by this machine and cell, or `allUsers` on a public role; its **target** is an object stamped by this machine and cell, or the cell's project for a cell edge; and the IAM role maps back, through the adapter's table, to exactly one access verb (or, for a project binding, one cell resource and verb). The table must be injective, and G5 tests that it is. |
| node id | `<P>/u-<h>`, where `P` is the member identity's owner (read from its stamp) and `h` is `grants.mojo`'s hash of `P` and the target path (the target's owner, or `cell/<NAME>`). A public binding is `<T>/public`, where `T` is the target's owner. Both are pure functions of the cloud's objects. |
| retention and run id | Those of the node's owner: the member identity's description lines, or for a public binding the target's labels. Every node of a resource takes the resource's retention (`deploy.mojo`), so these equal the binding node's own. |
| v1 restriction | The node id is pure only when the owner of an edge is its principal. A `uses` line on a workload that has `run_as` (the node belongs to the workload, the member is the account) and a `grant` resource (the node belongs to the grant) break that. On a `DERIVED` shape, `check` refuses both, naming the fix: write the `uses` line on the account itself (question Q13). |
| not ours | A binding whose member is not this cell's, or whose IAM role is not in the table, is an unmanaged difference: reported, and never removed. A hand-made binding equal to a wanted one is ours, whoever wrote it, and is a no-op. |
| writing | An etag read-modify-write of the policy that adds or removes **only** members attributed to this cell. A foreign member on an adopted object is never removed. |
| the fake | The gcp fake stops stamping grants with labels and models the derived rule, `check` included. Then a green kit on the gcp fake means something for the real carriers. |
| the kit | Steps 3 and 12 read a `DERIVED` node's labels through the `live_labels` hook, which returns what attribution derives. The step 3 text says so. A new step 13, **foreign member**, plants a foreign member and an unmapped IAM role on an owned target and on the project, applies, and requires both to be reported and left in place. |
| the docs | The false sentence in `labels.mojo` goes away. |

### How adoption plugs in (the interface P12 defines)

| piece | used as |
|---|---|
| `Resource.adopt` + `physical_name` | The only way to adopt. There is no CLI flag. `with_adopted` puts the **primary** node into `scope.adopt`. |
| Each descriptor's adopt verb | It writes the stamp onto an object that has none: labels update, description patch, or Scheduler job update. It writes the identity and retention, never a run id. |
| Non-primary roles | They are not adopted. An author adopting an existing service also declares and adopts its service account as a resource of its own. |
| `--` stamps (#376) | `kci run` can reach the adapter for a non-test cloud only after #376 lands, either as a relabel step or as a read-only proof per cell that no such stamp exists. |

### Credentials

| rule | detail |
|---|---|
| Source | `GOOGLE_APPLICATION_CREDENTIALS` only. **It is required.** kci does not fall back to the gcloud well-known file or the metadata server, so an operator's own login is never used without being named. |
| File types | `external_account` (a CI's OIDC token exchanged at STS, optionally impersonating the deploy identity) and `service_account`. `authorized_user` is refused for DEPLOY and PUBLISH (question Q6). |
| `external_account` | The ADC chain refuses it today. G2 adds a reader: the subject token from a file or a URL, the exchange through `komira_gcp_wif`'s STS form, and impersonation through IAM Credentials. |
| Lifetime | The adapter holds a caching token source, and `Creds` names it. An apply that outlives one access token keeps working. |
| In `argv` and logs | Never. `registry_login`'s secret goes to the OCI client in memory only. |

### Testing the adapter

| layer | proves | does not prove |
|---|---|---|
| Lowering golden over the shared shape | That gcp lowers as the fake does, byte for byte. | Wire behaviour. |
| Conformance kit over a **stateful GCP REST emulator** (test-only, behind `komira_http_core`'s `Connector`; Run, IAM, CRM, Scheduler and Secret Manager paths, with real error envelopes) | The adapter's real wire code against all 13 kit steps, including tamper, fail, race, plant-foreign and foreign member, which a recorded transport cannot replay. | That GCP behaves like the emulator. |
| A live kit pass in a dedicated project | The real API. | It is an operator-run step that costs money, not a PR test. It is required before the adapter is called production-ready. |

## Images into a cell, and promotion by digest

| stage step | does | uses |
|---|---|---|
| BUILD | `oci_image[release]` writes the layout plus an artifact manifest: type `OCI`, `sha256` = the hex of the image manifest digest, `file` = the layout directory. The release set folds that digest into `set_hash`. | `kci_artifact_manifest`, `kci_release_set` |
| PUBLISH with `cells` and `cell` (and no `channel`) | Pushes each OCI member's verified layout to `image_registry(ctx)/<name>`, then reads the pushed manifest back and requires its digest to equal the release set's. The tag is the full revision, as `publish_layout` already does. | `kci_publish_oci.publish_layout`, `komira_oci` |
| DEPLOY into the same cell | Resolves each `Image{output: StepOutput}` to `image_registry(ctx)/<name>@<digest>` for the image's platform, mapped with `oci_platform_of`. | `CellContext.artifacts` |
| The next cell's PUBLISH, then its DEPLOY | The **same release set**, handed on by `set_hash` and never rebuilt, is pushed to the next cell's registry. The digest is checked before the push (layout against the set) and after it (read-back against the set). The next DEPLOY therefore runs the bytes the previous cell validated. | the same code path |

**How a `StepOutput` resolves.** Both fields are checked; neither is ignored.

- `step` must name a BUILD step of this machine file, in any stage, and `name` must be an artifact that
  step's `artifacts` file declares, of type `OCI`. This is checked against the machine file, so a
  typo is REFUSED before any change, even under `--plan`.
- The release set must hold a member of that name whose platform is the image's. A release member is
  keyed by artifact name and records no producing step, which is why `step` is checked against the
  machine file and not against the set.
- Anything else is REFUSED before any change. I4 rewrites the `refs.proto` comment to say this.

These rules hold throughout:

- **A PUBLISH step names exactly one destination.** It names `channel` (a public or consumer-facing
  release channel, as today) or `cell` (the cell's private registry), never both.
  - The cell's registry address is computed from the cell and is never written down a second time.
  - The push identity is the cell's deploy identity, which the adapter's trust check verifies.
- **The cell's image registry is a bootstrap item, not a resource of the list.**
  - In a stage, PUBLISH runs before DEPLOY, so a registry declared in that stage's graph would not yet
    exist when the push runs.
  - P11's `Registry` is for registries that a cell's workloads write to and read from at run time.
  - A resource list that names the bootstrap registry is refused as foreign, unless it adopts it
    (question Q4).
- **The release-set member for `OCI` is a directory.** `verify_member` accepts a directory for this one
  type only, and verifies it with `read_oci_layout`, which hashes every blob. Every other type stays
  one regular file.
- **Promotion re-pushes, it does not copy.** The next cell's identity never needs read access to the
  previous cell's registry. `OciCopier.copy_by_digest` stays for the case where the release directory
  has expired (question Q3).
- **Images are linux/amd64 only**, as `oci_image` builds them.

## The `DEPLOY_PROBE` validation kind

The kind word is `DEPLOY_PROBE`, not `CONTAINER`: `CONTAINER` is already a value of
`validations[].environment` (where a validation ran), and a `CONDA_INSTALL_SMOKE` row already reports
it. A probe's row reports environment `CONTAINER` too.

### Fields

| field | rule |
|---|---|
| `name`, `kind: DEPLOY_PROBE` | As for the existing kinds. |
| `image` | **v1 accepts a digest only** (`<repo>@sha256:<hex>`), pulled anonymously with `kci_validate`'s existing empty `DOCKER_CONFIG`. A tag is refused. A `StepOutput` image is question Q5. |
| `args` | Repeated. kci appends `--validation-run-id=<id>`, and `--target-url=<value>` when `target` is set. Configuration goes in flags, never in the environment. |
| `target` | Optional `{resource, output}`. It must name a declared output of this step's resource list (URL or ADDRESS). It is read from this run's recorded outputs only, never from the cloud. A run that selects the probe without also selecting its DEPLOY step (`--only validation:<name>` alone) is REFUSED at start: the job that runs a probe alone holds no cell credential (kci.yml's validation jobs carry no identity token), and the probe would otherwise need one. Under `--plan` the probe is WOULD_VALIDATE. |
| `timeout_seconds` | Required, from 1 to 3600. |
| `expect` | Repeated case ids, `[a-z0-9_-]+`, at least one, no repeats. |

Allowed on a DEPLOY step. The `graph.mojo` rule becomes: `CONDA_*` on PUBLISH, `DEPLOY_PROBE` on
DEPLOY. There is no `secret_env` in v1 (question Q5).

### Running it

The run reuses `container.mojo`'s command line: `--read-only`, `--cap-drop=ALL`, `no-new-privileges`,
`--pull=never` after a digest pull, and no environment passed through. The one writable mount is
`/work`, and the image writes `/work/out/results.jsonl`, one `{id, outcome, detail}` per line.
**kci decides the verdict; the image never does.**

| condition | effect, outcome, exit |
|---|---|
| Every `expect` id has exactly one row with outcome `pass`, there are no other rows, and the exit is 0 | VALIDATED, SUCCEEDED |
| An `expect` id has no row, a row's id is not in `expect`, an id appears twice, a row is not `pass`, a line is malformed, or the exit is non-zero | VALIDATED, VALIDATION_FAILED, 7 |
| The timeout is reached | killed; VALIDATION_FAILED, 7 |
| The pull fails, docker is missing, or the container cannot start | INDETERMINATE, 5, with a `skip_reason`; never a pass |
| The DEPLOY step did not succeed | NOT_REACHED |

Each case becomes its own row in the result document and in the summary. An image that writes
nothing therefore cannot pass.

### Run id

kci derives the validation run id from `--run-id`, `--attempt` and the validation name, and keeps it
inside `is_valid_validation_run_id` (`[a-z0-9_-]`, at most 63 bytes).

- The id is recorded in the validation's row and passed as a flag to the container.
- The DEPLOY step's own scope **does not** carry it, because a long-lived cell must not be swept by
  run id.
- What the system under test creates because of the probe is what carries the id. So
  `labels.mojo`'s "No kci verb sets the scope's validation run id yet" stays true after this design.
  A future short-lived validation cell would be the first verb that sets it.

### Gating promotion

There is no second gate. `keep_set_hash_only_if_validated` already hands on `set_hash` only when every
selected validation is VALIDATED and SUCCEEDED, and the next stage refuses an empty hash. The
`DEPLOY_PROBE` rows of a DEPLOY step count the same as the `CONDA_*` rows of a PUBLISH step.

That function returns early when a run selects no validations, and then hands `set_hash` on
unconditionally. So the claim "the next cell receives only digests this cell validated" holds only
when the stage carries a probe. The machine file makes it hold: a DEPLOY step in a stage that another
stage names in `after` must carry at least one `DEPLOY_PROBE` (refused above). The OCI digests are in
the set hash, so the next cell can then receive only the digests this cell validated.

## The workflow check

`kci_workflow_check` changes in D6. R16 does not change: it is what serializes a cell (see "One run
at a time").

| rule | change |
|---|---|
| R4 | `id-token: write` is also required on, and only on, the job of a stage that holds a DEPLOY step or a PUBLISH into a cell: kci authenticates to a cell from CI by OIDC only. `id_token_stages` gains these stages; a validation-only part job still carries no token. |
| part jobs (R9) | The part job that runs a DEPLOY step also runs every PUBLISH into the same cell of its stage, and every `DEPLOY_PROBE` with a `target` on that step. Parts of one stage run in parallel, so a split would let a DEPLOY start before its images were pushed, or a probe run without the outputs it reads. |

## PR split

The stack (#682 … #769) merges first. Every row names the planted defect that must turn its test red.
The PR body records the red build.

| PR | packages | depends on | tests prove | planted mutant goes red |
|---|---|---|---|---|
| **D0** | this doc, `release_machine.md`, `docs/index.md` | none | The new links (index, `release_machine.md`) resolve under the `markdown_docs` lint (`komira//:docs`, which the PR check builds). This is the existing link lint; no test of design content is possible for a docs-only PR. | the `deploy_step.md` link misspelt in `release_machine.md` |
| **D1** cells file | new `kci_cell`, `kci_api` formats (`kci.cells`) | none | A golden parse, and one red case per refusal listed under "Cells". | the duplicate-name check removed: the duplicate case parses |
| **D2** grammar | `kci_release_machine/{parse,deploy,graph}.mojo` | D1 | The machine `name` parses and every rule of "The machine name" has a red case; a machine file with DEPLOY parses; every row of "Refusals in the machine file" has a red case. | `platform` allowed on DEPLOY; the same-cell check removed; DEPLOY allowed in a `farm_connected` stage; DEPLOY allowed in a `break_glass` stage |
| **D3** result keys | `kci_api/result.mojo`, the parser, `exit_codes` | none | A round trip of every step-row key. The parser refuses a FINISHED step row with `landed` non-empty and outcome FAILED, and a top-level `landed`. | an engine error with `landed` empty mapped to FAILED |
| **D4** `kci_cloud` outcomes | `kci_cloud/deploy.mojo`, `kci_cloud_fake` tests | stack | Each refusal path (validate, expansion, key change, foreign, conflict) yields the typed refusal with its findings, and an engine fault never does. `plan_resources` reports the `leftover` and `left_behind` an apply of the same graph reports. | the foreign refusal returned as an untyped error; `leftover` dropped from `PlanOutcome` |
| **D5** wiring | `kci_cli/deploy_step.mojo`, `args`, `summary`, BUCK | D2, D3, D4 | End to end on `FakeCloud` + `InMemoryStateStore`: `--plan` writes nothing; apply, then a second run is all NOOP; a planted foreign object is REFUSED with `landed` empty; a planted mid-graph fault is PARTIAL/UNSAFE with `landed` + `pending`; a `kci.app` instance plans to its primitives (golden); a wrong `--release-set-hash` is REFUSED; the scope's machine is the file's `name`. | `--plan` routed to apply (store non-empty); the set-hash recompute skipped |
| **D6** workflow check | `kci_workflow_check` | D2 | A DEPLOY stage's job carries `id-token: write` and is refused without it; a validation-only part job is refused with it; a part split that separates a cell's PUBLISH from its DEPLOY is refused. | the R4 arm for DEPLOY stages removed; the part-split check removed |
| **G1** client methods | `komira_gcp_{run,iam,cloudscheduler,secretmanager,artifactregistry}`, token info, WIF provider `get` | none | One wire row per new method (path, verb, body). | one path template changed: its wire row goes red |
| **G2** external account | `komira_gcp_core` ADC, `komira_gcp_wif` | none | A file- or URL-sourced subject is exchanged at STS (fake connector), then impersonation; the env names read are still the documented set. | the audience dropped from the STS form |
| **G3** shared lowering + derived stamp | `kci_cloud` (lifted shapes, the `DERIVED` carrier, kit step 13), `kci_cloud_fake`, `kci_reconciler` | stack | The fake's lowering goldens are unchanged byte for byte. On the gcp fake: the kit passes, steps 3 and 12 included; a foreign member and an unmapped role are reported and kept (step 13); a `uses` line on a `run_as` workload and a `grant` resource are refused by `check`. | the member check removed from attribution: the foreign member is deleted (step 13 red) |
| **G4** adapter + service account | new `kci_cloud_gcp`, a test-only GCP emulator | G1, G2, G3 | The kit on the emulator for `service_account` (the three description lines), plus `configure`, `whoami`, `trust_check`, `image_registry`; a description over 256 bytes refused at validate. | the stamp written in a second call after create (kit "stamp born with the object" step); the retention line dropped (kit step 3) |
| **G5** workloads | `kci_cloud_gcp` | G4 | The kit for `service`, `worker`, `container_job`, `schedule`, `grant` and `secret`; the IAM role table is injective. | `public` lowered with no invoker binding (lowering golden); the Scheduler description stamp dropped (kit labels step); two verbs mapped to one IAM role (injectivity test) |
| **I1** one type word | `kci_release_channel`, `kci_publish_oci`, `kci_cloud` | none | The manifest reader accepts `OCI` and refuses `OCI_IMAGE` and `oci-image`. | the arm keeps `OCI_IMAGE`: the publish row's type assertion fails |
| **I2** image in the release set | `tools/build/package` (`oci_image[release]`), `kci_artifact_manifest`, `kci_release_set` | I1 | `hello_image[release]` verifies, and its digest is in `set_hash`. A directory is refused for CONDA. | one layer byte flipped: verification still passes |
| **I3** PUBLISH into a cell | `kci_publish`, `kci_cli`, `kci_cloud` (two trait methods) | I2, D1, D5 | A push to the fake cell registry; the read-back digest equals the set; a second push is NOOP. | the read-back comparison removed: a registry that rewrites the manifest is accepted |
| **I4** resolve images in DEPLOY | `kci_cli/deploy_step.mojo`, `refs.proto` comment | I3 | `StepOutput` resolves to `registry/name@digest`; a `step` that is not a BUILD step, a `name` that step does not declare, a member missing from the set and a wrong platform are each REFUSED before any change. | resolving by `name` while ignoring `step`; resolving by name while ignoring platform |
| **V1** `DEPLOY_PROBE` grammar | `kci_release_machine`, `kci_api/verbs.mojo` | D2 | A red case per field rule; `CONDA_*` refused on DEPLOY and `DEPLOY_PROBE` refused on PUBLISH; a promoted DEPLOY stage without a probe refused. | a tag accepted as `image`; the promoted-stage probe check removed |
| **V2** runner and verdict | `kci_validate` | V1 | Every row of the verdict table, with a scripted fake process runner; the argv golden keeps the hardening flags. | a missing `expect` row treated as a pass; `--cap-drop=ALL` dropped from the argv |
| **V3** wiring and gate | `kci_cli` | V2, D5 | A failed probe row empties `set_hash`; under `--plan` it is WOULD_VALIDATE; a target that no step output declares is REFUSED; a probe with a `target` selected without its DEPLOY step is REFUSED at start. | `keep_set_hash_only_if_validated` counting VALIDATED regardless of outcome |

**Merge order.** D1, D3 and D4 can merge in parallel with the G1, G2 and I1 group. D2 merges after D1;
D5 after D2, D3 and D4; D6 after D2; I3 after D5; I4 after I3; V3 after V2 and D5. G4 needs G1, G2 and
G3, and G5 follows G4. No PR depends on a later one.

## Open questions (recommendation first)

| # | question | recommendation |
|---|---|---|
| Q1 | Should the resource file be proto3 JSON, or should a generic text-format decoder be written first? | JSON. It adds no code. A text-format decoder can come later as an alternative reader of the same message. |
| Q2 | Teardown: should a `--destroy` flag be added now, never on a release run? | No. Leave teardown to a human step until there is a durable store. A closed-world delete with only stamps as the record is not safe enough. |
| Q3 | Promotion: re-push the verified layout, or `OciCopier` from the previous cell? | Re-push. One code path, and no cross-cell read grant. Copy only when the release directory is gone. |
| Q4 | May a resource list adopt the cell's bootstrap registry (P12 `adopt`) so that its grants are declared? | Not in v1. The bootstrap owns it, and the adapter grants the cell's runtime pull. |
| Q5 | A `DEPLOY_PROBE` image as a `StepOutput` (loaded from the release directory), and `secret_env` for a probe | Both later. Loading needs a docker-loadable form of the release member. `secret_env` needs a design for who holds the value, because the resource model's rule is that kci never holds a secret's value. |
| Q6 | `authorized_user` credentials for an operator running kci by hand | Refuse them. The operator impersonates the deploy identity through an `external_account` or service-account file. Only bootstrap runs with a person's own credentials. |
| Q7 | `bootstrap_level` has no reader. Keep it at `1`, or drop it? | Keep it, accepting only `1`, so the cells file does not change major when level 2 is defined. |
| Q8 | `worker` on GCP: wait for worker-pool client methods, or lower a worker as a Service with no ingress? | Use worker pools, as in the fake's shape. Changing the lowering means changing the shared shape first, never only in the adapter. |
| Q9 | Should apply emit `plan_hash` and take `--expect-plan-hash`, so that an approved plan is what runs? | Yes, after D5, with the engine returning the plan it executed. Without a plan job that holds read-only credentials it cannot be used, so it is not in v1. |
| Q10 | Should the stack's `CellScope` docstring (`--adopt <id>`) be fixed in P12? | Yes. That docstring belongs to the stack, not to this design. |
| Q11 | Should a break-glass run be able to deploy? | Not in v1. A break-glass run sits in a group per ref and would race a push. It needs the cell lease; until then a fix reaches a cell through main. |
| Q12 | A re-run of an older workflow run rolls a cell back. Should kci refuse a revision older than the one the cell runs? | Yes, once the durable store records the deployed revision per cell. v1 documents it; the operator must not re-run an older run's deploy job. |
| Q13 | On a `DERIVED` shape, `uses` on a `run_as` workload and `grant` resources are refused. Lift this by owning such an edge's node by its principal? | Not in v1. Changing node ownership changes ids on every cloud, so it is a reconciler design of its own. Writing the `uses` line on the account is an exact equivalent today. |
