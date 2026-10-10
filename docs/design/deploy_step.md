# The DEPLOY step: cells, the GCP adapter, images into a cell, and deploy probes

Status: design, no code. It builds on the resource-model stack #682 (P8) → #690 (P9) → #696 (P10) →
#700 (P11, registry) → #719 (P12, labels, `physical_name`, `adopt`) → #722 (label budget) → #736 (C1,
composites expanded before validate) → #769 (C2/C3, `kci.job` and `kci.app` in `kci_composites`) → #814 (safe
adoption), and assumes that stack merges first. Related: #373, #374, #376.

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
- **Safe adoption.** It lands in the stack (#814); this document uses only its interface (see "How
  adoption plugs in"). The relabel of old `--` stamps (#376) stays out of scope.
- **The override document** (#772). A DEPLOY step can take an `overrides` field when that design
  lands; the name is held.
- **Multi-platform images.**

## What exists, and what is missing?

Checked against `main` and the stack head.

| piece | state |
|---|---|
| `kci_release_machine/graph.mojo` | DEPLOY is refused ("needs a newer kci"). The header already says a DEPLOY step names a cell, and the cell names its cloud, but neither has a field. A PR stage refuses any step that is not BUILD. A farm-connected stage refuses a PUBLISH step. |
| the machine file's name | **There is none.** `ReleaseMachine` holds `schema_version` and `stages`, and the parser refuses any other top-level field. Every stamp, the `(machine, cell)` scope and the registry name need one. |
| `kci_cloud/deploy.mojo` (stack) | `plan_resources`, `apply_resources` and `destroy_resources` all take `(clouds, cloud, ctx: CellContext, resources, creds, store, definitions)`. Before anything else happens, each one refuses a scope that is not owned, runs the adapter's `configure`, expands the composites and validates. Plan and apply also check the validation run id; destroy passes `check_validation_run=False`, because it writes no run-id label. `ApplyOutcome` carries `applied`, `landed`, `pending`, `error`, `leftover`, `left_behind` and `released`. **`plan_report` returns a `PlanReport` of `actions`, `adopted` and `released`**, and `plan_resources` its `actions` alone: the plan's `leftover` and `left_behind` are computed and dropped. `render_plan` (over `group_plan`) renders a plan. |
| `CellContext` | Holds a `CellScope` (machine, cell, provenance, adopt, validation run id), `settings`, `artifacts: List[ResolvedArtifact]` and `bootstrap_level`. **No code reads `bootstrap_level`.** |
| state store | `InMemoryStateStore` only. |
| adapters | `FakeCloud` and `FakeLimitedCloud` only. A fake's `bootstrap_resources` lists a state store and a `registry` (`<machine>-<cell>-images`, "where the cell pulls images by digest"). |
| `kci_cli` | Links none of `kci_cloud`, `kci_reconciler`, `kci_resource_proto` or `kci_composites`. `dispatch.mojo` is 737 lines and `graph.mojo` is 821, so the new code goes in new files. |
| `kci_api/result.mojo` | `landed[] pending[] failed outputs[] plan_hash security_relevant_changes[]` are reserved as top-level names and never emitted. |
| `kci_api/exit_codes.mojo` | 3 REFUSED, 4 FAILED (SAFE), 5 INDETERMINATE, 6 PARTIAL (UNSAFE), 7 VALIDATION_FAILED, 8 LEFT_BEHIND (reserved, has no outcome). |
| `kci_workflow_check` | R16: one workflow-level `concurrency:` (a push to main in `kci-release-main`, never cancelled in progress; a manual run in a group per ref), and **no job has a `concurrency:` of its own**. R4: `id-token: write` only on a job whose stage publishes to an OIDC channel or is farm-connected; no other job carries it. R15: a stage that is not `break_glass` runs only on a push to main. |
| `komira_oci`, `kci_publish_oci` | `LayoutPusher` and `OciCopier.copy_by_digest` exist. `publish_layout` takes the release set's digest and is called by `kci run` for a PUBLISH step into a cell (I3). |
| `oci_image` | Writes a layout plus `[digest]` and `[docker_archive]`. It has **no `[release]`** sub-target, and the release set reads only `[release]`. |
| `kci_validate` | Two kinds: `CONDA_INSTALL_SMOKE` (a hardened `docker run`, anonymous pull by digest) and `CONDA_INSTALL_ENV`. A validation may attach only to a PUBLISH step. `validations[].environment` is `ENV` or `CONTAINER`. |
| `komira_gcp_core` ADC | Reads `service_account` and `authorized_user`. It **refuses `external_account`** by name, which is the file a CI's OIDC-to-GCP exchange produces. |

**Where code and docs disagree.** Each of these is fixed by the PR named in the split below.

| where | says | is |
|---|---|---|
| `refs.proto` `StepOutput` | "an output of an earlier BUILD step of the same run" | The next cell deploys an image built by another job. A `StepOutput` resolves through the **release set** the stage is handed (same revision, built once), with `step` checked against the machine file. Fixed in I4. |
| `kci_cloud/labels.mojo` | "an IAM binding carries the identity as the first line of its description" | An IAM member binding has no description and no labels. The gcp fake stamps grants with in-memory labels, so the fake hides this. Fixed in G3. |
| `kci_cloud/labels.mojo` | a description carrier holds "the identity" | Kit step 3 also requires one retention mark and the run-id label on every node, so a description carrier must hold all three. Fixed in G4. |
| artifact type of an image | `OCI` (channel), `OCI_IMAGE` (`kci_publish_oci`), `oci-image` (`ArtifactNeed`) | There should be one word. It becomes `OCI`, the `kci_release_channel` constant. The writers are fixed in I1; the manifest reader, which refuses `OCI` today, in I2. |
| `kci_reconciler` (stack): the `CellScope` docstring, the ownership-rule comment in `ownership.mojo`, and the foreign refusal text `ownership.mojo` builds | `--adopt <id>`; the refusal tells the operator to pass `(--adopt <id>)` | After P12, adoption is the `adopt` field. There is no flag, and this design adds none. #814 fixes the refusal text, its test and every comment that named the flag (question Q10). |
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
| meaning | `CellScope.machine`. It is part of every stamp, so **renaming a machine orphans every object it owns**: the new name sees them as foreign and refuses. A rename is a migration that safe adoption does not cover: adoption takes over only an unstamped object, and an object stamped by the old name is a conflict. v1 has no rename. |
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
| `validation` | Optional. Only kind `DEPLOY_PROBE` is allowed on a DEPLOY step (from V1; before it, none is). |
| `platform`, `artifacts`, `channels`, `channel` | **Refused.** A platform is an OS plus a CPU and never names a cloud. Images come from the release set (see "Images into a cell"). |

### Refusals in the machine file

These are checked in the pure parser, in a new file `kci_release_machine/deploy.mojo`. D2 owns every
row not marked V1.

| refused | why |
|---|---|
| A DEPLOY step in a PULL_REQUEST stage | This is already refused. A PR's check builds and never deploys. |
| A DEPLOY step in a `farm_connected` stage | The job that holds a farm network credential must not also hold a cell's deploy identity, by the same reasoning that already refuses a PUBLISH step there. A PUBLISH into a cell is a PUBLISH step, so the existing rule already refuses it. |
| A DEPLOY step, or a PUBLISH into a cell, in a `break_glass` stage | A manual run then never reaches a step that writes into a cell, so only pushes to main do, one run at a time (see "One run at a time"). Question Q11. |
| A DEPLOY step, or a PUBLISH into a cell, in a machine with no `name` | The scope has no machine. |
| A missing `cell`, or a cell not in `cells` | |
| A missing `resources`, an absolute path, or `..` | |
| `platform`, `artifacts`, `channels` or `channel` on a DEPLOY step | See above. |
| A PUBLISH step naming both a `channel` and a `cell` (or both `channels` and `cells`), or a `cell` not in its `cells` | A PUBLISH names exactly one destination (see "Images into a cell"). |
| **Two DEPLOY steps, in any stages of one machine, naming the same cell** | The scope is `(machine, cell)`. A second step would see the first step's objects as `leftover`. |
| **D2:** a DEPLOY step in a stage that another stage names in `after`, with no exception | Its `set_hash` would be handed on without anything having checked the cell (see "Gating promotion"), and D2 has no probe to check it with. The refusal says "a promoted DEPLOY needs a `DEPLOY_PROBE`; probes land in V1". So no PR that merges before V1 (D5 included) can promote a cell nobody checked. |
| **V1:** the D2 rule above, relaxed to: a DEPLOY step in a stage that another stage names in `after` with no `DEPLOY_PROBE` validation | The same reason. V1 is where the probe kind exists, so V1 is where the rule can ask for one. |
| **V1:** a validation of another kind on a DEPLOY step, or a `DEPLOY_PROBE` validation on a BUILD or PUBLISH step | Until V1, `graph.mojo`'s existing rule ("a validation belongs to a PUBLISH step") refuses every validation on a DEPLOY step, and `DEPLOY_PROBE` is not a kind word. |

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
- Within one run, one DEPLOY step per cell (refused above). R9 already runs every step of a stage in
  the job named after the stage (a part job runs validations only), so a cell's PUBLISH and DEPLOY run
  in that one job, in step order. D6 adds only the probe rule and R4's handling of a PUBLISH into a
  cell (see "The workflow check").

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
2. **Release set.** As PUBLISH does today, require `--release-set-hash` and recompute it from
   `--release-dir`. A mismatch is REFUSED.
3. **Context.** Build the `CellContext`:
   - scope `machine` = the machine file's `name`, scope `cell` = the cell's name;
   - `Provenance(--run-id, --revision-id)`;
   - `validation_run_id` = None. A deploy into a long-lived cell is never stamped with a validation
     run id; that id belongs to what a validation causes to be created (see "Run id");
   - `settings` = the cell's settings;
   - `artifacts` = the verified release set's OCI members, resolved as described in "Images into a cell".
4. **Credentials.** Read them from the provider's standard variables only (see "Credentials").
   Run the adapter's `configure(ctx)` first, so it knows the cell's settings (GCP's `project`) before
   it reads anything; then `whoami` and `trust_check(creds, ctx.scope)`. Any finding is REFUSED.
   Steps 1 to 3 are local, so nothing reaches the cloud before the inputs are checked.
5. **Plan or apply.**
   - With `--plan`, call `plan_report`. A plan writes nothing to the store or the cloud. A plan
     with an unpinned image uses the existing `UNPINNED-NOT-A-DIGEST:` rendering. `--plan` is still
     refused on a release run, as today.
   - Without it, call `apply_resources`.
6. **Report.** Print the plan (`render_plan` on `--plan`, which marks adopted nodes and lists releases;
   `group_plan(actions)` otherwise) to stdout and to the summary file. Fill in the result
   keys below. Then run the step's validations, which see this run's recorded outputs.

Three `kci_cloud` changes come first, in D4:

- **A typed refusal.** Today `kci_cloud` raises refusals as text through `refusal_text`, and
  `ApplyOutcome.refused()` matches a message prefix. A refusal becomes a value carrying its findings,
  both for a refusal raised before any effect (validate, expansion, name and key changes) and for an
  engine refusal. Telling REFUSED from FAILED by message text is not a classification.
- **`plan_report` returns a `PlanReport`** (#814: `actions`, `adopted`, `released`). D4 adds
  `leftover` and `left_behind` to it, so a `--plan` can report what an apply would leave alone. Today
  those two are dropped. There is no second plan type.
- **Adoption refusals are typed too.** `FINDING_ADOPTION` findings (a missing or different adopted
  object, a marked object whose resource does not write `adopt`, a delete of an adopted object that
  is not ADOPT_DELETABLE, a replace of any adopted node) join the typed refusal. Apply's plan-first
  step stops matching the `REFUSED_TOKEN` prefix (deploy.mojo `apply_resources`) and asks the typed
  refusal instead.

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
| `released[]` | node ids | **New.** Adopted objects whose resource left the list, released by this apply: kci's labels and its record are dropped, and the object stays standing (`ApplyOutcome.released`). On `--plan`, the releases an apply would make (`PlanReport.released`). |
| `security_relevant_changes[]` | | Stays reserved and is not emitted until it is defined. An always-empty list would be a claim with no code behind it. |

### Outcome and exit

| situation | outcome | exit | retry |
|---|---|---|---|
| Any refusal above, an adapter `configure` or trust finding, an expansion or validate finding, a name or key change, a foreign or conflicting object, an adoption finding (`FINDING_ADOPTION`) (the typed refusal) | REFUSED | 3 | NEEDS_HUMAN |
| A read failed before the engine was called: `whoami` or `trust_check` (step 4), or the `list_owned` that `_prepare` runs to find removals, or a `read_existing` of an adopted node (`adoption_check`, in `_prepare`), or, on an apply with adopted nodes, its plan-first `plan_graph_owned` raising anything but the ownership refusal (a presence read), or the transport under any of them. A `trust_check` that answers with findings is REFUSED (first row); one whose read raises is this row | FAILED | 4 | SAFE |
| `--plan`, and `plan_graph_owned` raises an error that is not a typed refusal (a presence read failed). A plan writes nothing, so nothing landed | FAILED | 4 | SAFE |
| `lower_data` raised: the adapter's `lower` raised, or one of `lower_data`'s lowering-contract checks failed (a resource lowered to no nodes, a node whose id or owner is not its resource's, a node lowered twice, a desired field that is kci's metadata, no primary node to hold a `physical_name`). `lower_data` is the first call in `_prepare`, before its `list_owned` read, so nothing was read or written. It runs after validate and `check`, so it is a defect of kci or the adapter, not of the input, and is never the typed refusal | FAILED | 4 | NEEDS_HUMAN (a retry gives the same answer; `exit_codes.mojo` lets a verb give stronger advice than SAFE) |
| `realize_graph` raised: the adapter's `realize` raised, or a realized node did not keep the id, owner, `wanted` or retention `lower_data` set. Each verb calls it after `_prepare` (an apply with adopted nodes calls it twice: for its plan-first step, then for the apply), after the `list_owned` read and before `apply_graph_owned` or `plan_graph_owned`, so nothing was written. A defect, as in the row above, never the typed refusal | FAILED | 4 | NEEDS_HUMAN, as above |
| **Any error from `apply_graph_owned` that is not a typed refusal**, even with `landed` empty. This includes a failed presence read in `refuse_unless_owned`, which runs inside the engine before any change | PARTIAL | 6 | UNSAFE |
| An adopted object's release failed (after the engine's apply finished: `landed` holds every node, `pending` is empty, `released` lists those done before it). The object keeps its stamp and mark, and the next apply releases it again | PARTIAL | 6 | UNSAFE: `exit_codes.mojo` never lets a verb advise SAFE on exit 6, though the next apply only releases it again. D4 types it as a release failure, never by the `release of` prefix |
| `--plan`, or an apply that changed something | SUCCEEDED | 0 | SAFE |
| An apply where every action was a no-op | NOOP | 0 | SAFE |
| A `DEPLOY_PROBE` validation failed / could not tell | VALIDATION_FAILED / INDETERMINATE | 7 / 5 | NEEDS_HUMAN |

Six notes on this table.

- **An engine error with nothing landed is PARTIAL, not FAILED.** `ApplyOutcome.partial()` is false
  when `landed` is empty, but the failing node's own call (a create whose wait timed out) may have
  landed. Exit 4 promises that no effect landed, and kci cannot promise that here.
- **The FAILED row is only the reads made before `apply_graph_owned` is called.** The engine's own
  pre-flight (`refuse_unless_owned` in `kci_reconciler/cell_walk.mojo`) also reads before any change,
  but its error reaches kci as the same untyped engine error as a create that timed out, so it is
  PARTIAL. Telling the two apart needs the engine to type its pre-flight errors, which is not in v1.
- **The plan and apply paths differ.** `apply_resources` catches every engine error into `ApplyOutcome`, while `plan_report` lets `plan_graph_owned` raise. D4's typed refusal tells a raised refusal from a raised read error on both paths.
- **Two more raises.** `with_adopted` runs after `_prepare` and before the engine and raises out of
  `apply_resources`, so it would be FAILED; it raises only for a resource of no catalog type, which
  validate refuses first, so it cannot fire. `topo_sort` runs inside `apply_graph_owned` (and inside
  the plan), so its raise is an engine error: PARTIAL on apply, FAILED under `--plan`. Validate has
  no rule against a dependency cycle (two workloads each reading the other's URL), so that one can
  fire with nothing landed. D4 adds a graph finding for it, so such a graph is REFUSED before any
  read.
- **A replace of an adopted node is refused before any change, except one the plan cannot see.** A
  node the plan reports as known after apply is not read, and the engine's apply stops there with
  CONVERGE_REPLACE unsupported: the PARTIAL row, never a replace.
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
| `read_existing` | A get **by the cloud name** (`physical_name`) and the node's kind, never by node id. It reports present, stamped (`identity_of` on its labels or description), the kind in `LoweredNode.kind`'s vocabulary, the name, and each field of the shape it can read under the name `lower` writes. A field it cannot read is not reported (and so not compared). G4. |
| `release` | One label update (or, on a description carrier, one description patch) that drops every kci label or line (`kci_*`, `kci-*`, and the `kci:v<scheme>` identity line) and nothing else. Never a delete. It is atomic, or drops the adoption mark last (the trait's contract). G4. |
| `adopt_owned` (each descriptor's, not a trait method) | Writes the identity, the retention mark and `kci_adopted=true`, never a run id. G4. |
| `whoami` | The token's principal. This needs a token-info read, which no client has. No googleapis proto declares one, so G1 could not generate it: it is a hand-written read in `komira_gcp_core` or `komira_gcp_wif`, owed before G4. |
| `trust_render` / `trust_check` | Render, and then read back, the workload-identity provider and the binding of the cell's deploy identity. This needs a WIF provider `get`, which G1 generated in `komira_gcp_iam` at IAM **v1beta**: the pinned googleapis declares the workload identity pools only there. IAM also serves the resource at v1, and the v1beta file may not declare a newer provider field, so a field `trust_check` compares must be one that file declares. A trust check that cannot fail is not a check. |
| `bootstrap_resources` | The state store and the image registry, matching the fake. |
| `image_registry(ctx)` **(new, G3)** | The pull and push address of the cell's bootstrap registry. It is pure, computed from settings, machine and cell. |
| `registry_login(creds)` **(new, G3)** | The basic-auth user and secret a registry client presents. The user is the access-token convention. Plain strings, so `kci_cloud` does not depend on `komira_oci`. |

### First kinds: a container service, a background worker and a scheduled job

| catalog type | roles (shared shape) | GCP object | stamp carrier | client methods missing today |
|---|---|---|---|---|
| `service_account` | identity | IAM service account | **description** (no labels; 256 bytes) | `PatchServiceAccount`, not generated: its binding puts a field of the body in the path (`{service_account.name=...}`) with the whole request as the body (`body: "*"`), which the generator refuses; G4 needs that generator change first (a binding on an account uses IAM `Get/SetIamPolicy`, which exist) |
| `service` | identity, run, public | service account, Run Service, invoker member binding | labels on the Service; the binding is derived | Services `Get/SetIamPolicy` |
| `worker` | identity, run | service account, Run worker pool | labels | WorkerPools create/get/list/update/delete (question Q8) |
| `container_job` | identity, run | service account, Run Job | labels | Jobs `Get/SetIamPolicy` (needed for the schedule's invoke grant) |
| `schedule` (P9) | identity, schedule | service account, Cloud Scheduler job | **description** (a Scheduler job has no labels) | CloudScheduler `ListJobs` |
| a binding (one per edge: a `uses` line, the implicit `cell LOGS WRITE`, a trigger's CALL, a service's `public`) | `u-<h>`, `public` | a member binding through `setIamPolicy` on the project, a service account, a service, a job or a secret | **derived** | as above; the project's are Cloud Resource Manager `Get/SetIamPolicy`, which exist |
| `secret` | secret | Secret Manager secret | labels | `GetSecret`, `UpdateSecret`, `Get/SetIamPolicy` |

A binding is not a catalog type; it is what an edge lowers to. The catalog type `grant` (a `grant`
resource) is **not** a v1 kind on GCP: `check` refuses it on a `DERIVED` shape (see "Grants", Q13), the
same refusal the gcp fake makes.

G4 implements `service_account`, `container_job` and the bindings on the project and on a service account,
which is the least the kit can run on (see the PR split). G5 implements `service`, `worker`, `schedule`
and `secret`, and the bindings on a service, a job and a secret.

**The IAM role table.** One row per (target type, access verb); attribution reads it backwards, so it
must be injective, and G4's test says so. G4's rows:

| edge | binding on | IAM role | note |
|---|---|---|---|
| `uses <account> DESCRIBE` | the target service account | `roles/iam.serviceAccountViewer` | Slightly broader than DESCRIBE: it also reads the account's key metadata. |
| `cell LOGS WRITE` (implicit) | the project | `roles/logging.logWriter` | |

G5 adds a row per edge its kinds lower (CALL on a job, READ on a secret, `public` on a service), each
checked by G4's injectivity test.

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
description holds anything else is not stamped. So adopting a description carrier overwrites its
description, and releasing it leaves the description empty (question Q16). Validate refuses a node
whose lines exceed the kind's description limit (256 bytes for a service account), so a long
machine, cell or resource name fails before anything is created, not at create time.

An adopted object carries a mark line `kci_adopted=true` in place of the run-id line (an adoption
writes no run id). The mark line is 16 bytes and a run-id line 12 to 74, so the 256-byte check at
validate counts the mark line, not the run-id line, for an adopted node.

### Grants: the derived stamp (a reconciler decision, G3)

`refuse_unless_owned` checks every node, wanted or not. Every `service` lowers a `public` binding node,
and every resource that holds its own identity lowers the implicit `cell LOGS WRITE` edge, which on GCP
is a binding on the **project**, an object the cell does not stamp. Dropping kinds that cannot stamp
would therefore drop almost everything. Instead, a shape declares its grants' carrier as `DERIVED`, and
a binding's stamp is computed from what the cloud holds.

| rule | detail |
|---|---|
| attribution | A binding (target, member, IAM role) is attributed to a node when: its **member** is an identity stamped by this machine and cell, or `allUsers` on a public role; its **target** is an object stamped by this machine and cell, or the cell's project for a cell edge; and the IAM role maps back, through the adapter's table, to exactly one access verb (or, for a project binding, one cell resource and verb). The table must be injective. G4 owns the test that says so; G5's rows run through it. |
| node id | `<P>/u-<h>`, where `P` is the member identity's owner (read from its stamp) and `h` is `grants.mojo`'s hash of `P` and the target path (the target's owner, or `cell/<NAME>`). A public binding is `<T>/public`, where `T` is the target's owner. Both are pure functions of the cloud's objects. |
| retention and run id | Those of the node's owner: the member identity's description lines, or for a public binding the target's labels. Every node of a resource takes the resource's retention (`deploy.mojo`), so these equal the binding node's own. |
| v1 restriction | The node id is pure only when the owner of an edge is its principal. A `uses` line on a workload that has `run_as` (the node belongs to the workload, the member is the account) and a `grant` resource (the node belongs to the grant) break that. On a `DERIVED` shape, `check` refuses both, naming the fix: write the `uses` line on the account itself (question Q13). |
| not ours | A binding whose member is not this cell's, or whose IAM role is not in the table, is an unmanaged difference: reported, and never removed. A hand-made binding equal to a wanted one is ours, whoever wrote it, and is a no-op. |
| writing | An etag read-modify-write of the policy that adds or removes **only** members attributed to this cell. A foreign member on an adopted object is never removed. |
| the fake | The gcp fake stops stamping grants with labels and models the derived rule, `check` included. Then a green kit on the gcp fake means something for the real carriers. |
| the kit | Steps 3 and 12 read a `DERIVED` node's labels through the `live_labels` hook, which returns what attribution derives. The step 3 text says so. A new step 14, **foreign member**, uses a new `ConformanceTarget` hook after the shape of `race_next_create` and `raced`: `plant_foreign_member(node, member, role)` adds, out of band, `member` holding `role` to the binding behind lowered node `node`, and `member_present(node, member, role)` reads it back. `member` is the kit's word `FOREIGN` (an identity this cell does not stamp) or `CELL` (the node's own principal); `role` is `MAPPED` (a role the adapter's table maps to a verb) or `UNMAPPED`; the adapter turns each word into its own value. The kit plants a `FOREIGN`/`MAPPED` and a `CELL`/`UNMAPPED` member on a binding whose target is an owned object, and the same two on a cell-scope binding (a `cell` edge's node). It applies, and requires each to be reported as an unmanaged difference and `member_present` to stay true. The kit names no cloud; on GCP the cell-scope binding is the project's policy (G3's gcp fake, G4's emulator). A new step 15 is described under "Testing the adapter". (Step 13, adoption, came with #814.) |
| the docs | The false sentence in `labels.mojo` goes away. |

### How adoption plugs in (the interface P12 and #814 define)

| piece | used as |
|---|---|
| `Resource.adopt` + `physical_name` | The only way to adopt: `adopt` is the enum `Adoption` (ADOPT, ADOPT_DELETABLE). There is no CLI flag. `with_adopted` puts the **primary** node into `scope.adopt`. Before the plan, `read_existing` must find the object as declared. kci never replaces it, deletes it only under ADOPT_DELETABLE, and releases it when its resource leaves the list. |
| Each descriptor's adopt verb | It writes the stamp onto an object that has none: labels update, description patch, or Scheduler job update. It writes the identity, the retention and the adoption mark `kci_adopted=true`, never a run id. An update must keep labels it was not handed (kit step 13). |
| Non-primary roles | They are not adopted. An author adopting an existing service also declares and adopts its service account as a resource of its own. |
| `--` stamps (#376) | `kci run` can reach the adapter for a non-test cloud only after #376 lands, either as a relabel step or as a read-only proof per cell that no such stamp exists. |

### Credentials

| rule | detail |
|---|---|
| Source | `GOOGLE_APPLICATION_CREDENTIALS` only. **It is required.** kci does not fall back to the gcloud well-known file or the metadata server, so an operator's own login is never used without being named. |
| File types | `external_account` (a CI's OIDC token exchanged at STS, optionally impersonating the deploy identity) and `service_account`. `authorized_user` is refused for DEPLOY and PUBLISH (question Q6). |
| `external_account` | `komira_gcp_core`'s ADC chain refuses it, and **keeps refusing it**: `komira_gcp_wif` already depends on `komira_gcp_core`, so core cannot call into wif without a cycle. G2 adds the reader to `komira_gcp_wif`: it parses the file's text (given as a parameter; wif still reads no environment), takes the subject token from the file or URL its `credential_source` names, exchanges it through wif's STS form, and impersonates through IAM Credentials when the file names a `service_account_impersonation_url`. |
| Choosing the reader | `kci_cloud_gcp` (G4) reads `GOOGLE_APPLICATION_CREDENTIALS`, reads that file's `type`, and chooses: `external_account` goes to wif's reader; `service_account` goes to core's ADC chain, which, with the variable set, reads only that file and never falls back; any other type (`authorized_user` included) is REFUSED. |
| Lifetime | The adapter holds a caching token source, and `Creds` names it. An apply that outlives one access token keeps working. |
| In `argv` and logs | Never. `registry_login`'s secret goes to the OCI client in memory only. |

### Testing the adapter

| layer | proves | does not prove |
|---|---|---|
| Lowering golden over the shared shape | That gcp lowers as the fake does, byte for byte. | Wire behaviour. |
| Conformance kit over a **stateful GCP REST emulator** (test-only, behind `komira_http_core`'s `Connector`; Run, IAM, CRM, Scheduler and Secret Manager paths, with real error envelopes) | The adapter's real wire code against all 15 kit steps, including tamper, fail, race, plant-foreign, adoption, foreign member and born stamped, which a recorded transport cannot replay. | That GCP behaves like the emulator. |
| A live kit pass in a dedicated project | The real API. | It is an operator-run step that costs money, not a PR test. It is required before the adapter is called production-ready. |

**Kit step 15, born stamped (new, added in G3).** The kit has steps 1 to 13 today (13, adoption, came
with #814), and G3 adds step 14 (foreign member, above) and this one. A create that writes the
object and then writes the stamp in a second call leaves an unstamped object whenever the second
call never happens, and the next run then refuses that object as foreign. Step 15 makes that window observable:

- `ConformanceTarget` gains two hooks, after the shape of `race_next_create` and `raced`.
  `fail_after_create_of(node)` makes the create of lowered node `node` store the object exactly as
  the request carried it, then report an error to the caller (the wait timed out).
  `failed_after_create()` names the node it hit.
- The hook is armed per lowered **node**, not per provider kind: one kind can have several create
  paths. The gcp shape lowers every binding as kind `setIamPolicy`, yet a project binding and a
  service-account binding are written by different code. So the kit iterates **every node of `base`'s
  lowering that an apply creates**, from an emptied cloud each time, arms the hook for that node and
  applies `base`. The apply must stop with an error.
  The node `failed_after_create()` names must then pass step 3's label check as it stands, before
  anything else runs: its identity, one retention mark and the scope's run id, all from the create
  request alone.
- A re-apply under a new provenance must settle with no foreign refusal, and `creates_of` that node
  must not grow (the object is recognised as ours and is never created twice).

The fakes implement the hooks of steps 13 (`plant_like`), 14 and 15 in memory. G4's emulator implements them on its
create and policy paths, so the steps check the request bodies the adapter sent.

## Images into a cell, and promotion by digest

| stage step | does | uses |
|---|---|---|
| BUILD | `oci_image[release]` writes the layout plus an artifact manifest: type `OCI`, `sha256` = the hex of the image manifest digest, `file` = the layout directory. The release set folds that digest into `set_hash`. | `kci_artifact_manifest`, `kci_release_set` |
| PUBLISH with `cells` and `cell` (and no `channel`) | Loading the release directory already runs `verify_member` on every member (`kci_publish/inputs.mojo`), and after I2 that hashes the layout and ties its digest to the set. But `publish_layout` reads the layout from disk a second time, at push time. So it now takes the set member's digest and compares its own read with it; a layout that changed between that verify and the push is REFUSED before anything is sent (new in I3: `publish_layout` takes no expected digest today). It then pushes the layout to `image_registry(ctx)/<name>`, tagged with the full revision. `komira_oci`'s push already reads back (step 6, `_read_back`): a registry that serves another digest, or a tag that does not read back, is `PUSH_INDETERMINATE`, which `kci_publish_oci/arm.mojo` maps to INDETERMINATE, exit 5. | `kci_publish_oci.publish_layout`, `komira_oci` |
| DEPLOY into the same cell | Resolves each `Image{output: StepOutput}` to `image_registry(ctx)/<name>@<digest>` for the image's platform, mapped with `oci_platform_of`. | `CellContext.artifacts` |
| The next cell's PUBLISH, then its DEPLOY | The **same release set**, handed on by `set_hash` and never rebuilt, is pushed to the next cell's registry. The digest is checked at load (`verify_member`), again at the push (the layout `publish_layout` reads against the set, I3) and after it (`komira_oci`'s read-back against the pushed layout). The next DEPLOY therefore runs the bytes the previous cell validated. | the same code path |

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
  - A resource list may not adopt the bootstrap registry (question Q4). On GCP in v1, `registry` is
    not a hosted kind, so coverage refuses any such list at validate.
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

Two things differ from `container.mojo` today, and V2 changes both for the probe:

- **The container is named, and a timeout removes it.** `run_argv` gives the container no `--name`,
  and the timeout ends only the `docker` client process. The container keeps running after the client
  is gone, holding the work mount and reaching the target. A probe runs as
  `--name kci-probe-<validation run id>`, and on timeout kci runs `docker rm -f <that name>` with the
  same docker environment before it writes the row. A failed `rm -f` is said in the row's detail.
  - The name is scoped to one run: the validation run id is derived from `--run-id`, `--attempt` and
    the validation name (see "Run id"), so two runs, two attempts or two probes never share a name.
  - **Leftovers.** If kci itself is killed (SIGKILL), nobody runs the `rm -f`. Removing every
    `kci-probe-*` container at the next start is **not** safe: two runners can share one docker daemon,
    and a prefix match would kill another run's live probe. Instead the probe also carries
    `--label kci-probe-max-seconds=<timeout_seconds + 60>`: a **maximum duration**, not an absolute
    expiry, so the label holds no clock reading. The duration is counted from the **probe container's
    own start**, its `State.StartedAt` (a container that was created and never started is counted from
    its `Created`). At start, kci lists containers with that label, reads each one's `StartedAt` with
    `docker inspect` and the daemon's own clock with `docker info` (`SystemTime`), and removes only
    those whose elapsed time exceeds their label. Both readings come from the one daemon, so the
    runner's clock and any skew against it play no part. They are compared as instants, each with
    its offset parsed: `SystemTime` carries the daemon host's local offset (`+02:00`), while
    `StartedAt` and `Created` are UTC (`Z`). A container past its own maximum is one whose
    kci would already have removed it, so no live probe is touched.
- **The probe must not reach the link-local range.** `--network=bridge` reaches the IPv4 link-local range (RFC 3927), and
  on a runner hosted in a cloud that range holds the VM's metadata server, which hands out the runner
  VM's own credentials. The probe image is the operator's, but it talks to a freshly deployed service,
  so it must not hold a path to those. kci changes nothing on the host:
  - **A runner precondition, documented in `docs/ci.md`.** The operator sets standing host rules once,
    for example an `iptables -I DOCKER-USER -d <link-local range> -j REJECT` rule, so that no container on the
    host reaches the range. The range is not the only such address: the precondition also names the
    documented IPv6 metadata address `fd00:ec2::254` (an `ip6tables` rule, or IPv6 off on the docker
    bridge) and Azure's WireServer, `168.63.129.16`, on tcp 80 and 32526 only: docker forwards container
    DNS to that address's port 53 on Azure hosts, so it stays open. Only `169.254.169.254:80` is
    checked by the pre-flight below; the other rules are documented, not verified. kci never inserts or removes a rule, needs no
    privilege at run time and leaves nothing behind.
  - **A pre-flight, before every probe.** kci runs a throwaway container (`--rm`, the same hardening
    flags, the same `--network=bridge`) from a **digest-pinned helper image**, busybox, whose command
    is `nc -z -w <s> 169.254.169.254 80`. Nothing is mounted into the operator's image, and the
    operator's image needs no tools of its own.
  - **The pin.** `tools/build/platforms/table.bzl` already pins busybox, but as a static **binary**
    download (`assets.busybox`, an executable role), not as an image. The helper image is therefore a
    **new pin**: a new per-platform field, the image's linux/amd64 manifest digest
    (`<repo>@sha256:<hex>`), recorded the way `oci_base`'s digests are, with `none(...)` on a platform
    with no container validation and `pending(...)` until a platform is brought up. It reaches kci as a
    flag, `--preflight-image`, the way the pinned pixi reaches it today (`--pixi`, `--pixi-sha256`): a
    digest is required, a tag is REFUSED, and a run that selects a `DEPLOY_PROBE` without the flag is
    REFUSED at start. It is pulled anonymously by digest, as a probe image is. In CI the flag is passed
    where the pixi flags are: `.github/workflows/kci.yml`'s validation step (beside `--pixi`) and
    `release/validations/defs.bzl`'s argv, each from the platform row; V2 changes both.
  - **The exit-code contract.** `nc -z` exits 0 when the connect succeeds and 1 when it is refused or
    times out. Exit 0: the range is reachable, so the probe is INDETERMINATE and never runs. Exit 1:
    proceed. Anything else (the pull fails, docker exits 125, 126 or 127, the container is killed, or
    kci's own timeout around the pre-flight fires): the pre-flight cannot run, so the probe is
    INDETERMINATE and never runs. Only exit 1 lets a probe run.
  - **The `-w` path is untested, and fails safe.** No test drives `nc`'s own connect timeout (a host
    rule that drops instead of rejecting). If it exits 1 the probe runs, which is right: nothing
    answered. Any other exit is INDETERMINATE, and an `nc` that outlives `-w` is ended by kci's outer
    timeout, also INDETERMINATE. No path through it lets a reachable address pass.
  - **Testing it.** The mapping from the pre-flight's exit to the verdict is tested with the scripted
    runner (V2's row). The exit contract itself is a Buck2 test target in `kci_validate`, run on the
    farm: it starts the pinned busybox binary's `nc -l` on a loopback port and asserts that
    `nc -z -w 1` exits 0 against it and 1 against a closed port. That binary is the same upstream
    applet as the image's, not the image's own build; the image's run is shown on the first runner
    that executes a probe, and V2's PR body records one.
  - What the pre-flight proves is one address and one port. The rest of the range rests on the
    operator's rule; the pre-flight catches the rule being absent, not a rule with holes.
  - `CONDA_INSTALL_SMOKE` has the same exposure today: it runs a third-party package's install scripts
    on `--network=bridge`. The same pre-flight applies to it, in a follow-up after V2 (question Q15).

| condition | effect, outcome, exit |
|---|---|
| Every `expect` id has exactly one row with outcome `pass`, there are no other rows, and the exit is 0 | VALIDATED, SUCCEEDED |
| An `expect` id has no row, a row's id is not in `expect`, an id appears twice, a row is not `pass`, a line is malformed, or the exit is non-zero | VALIDATED, VALIDATION_FAILED, 7 |
| The timeout is reached | the client killed and the container removed by name; VALIDATION_FAILED, 7 |
| The pull fails, docker is missing, the container cannot start, or the pre-flight connect to `169.254.169.254:80` succeeds or cannot run | INDETERMINATE, 5, with a `skip_reason`; the probe never runs after a failed pre-flight; never a pass |
| The DEPLOY step did not succeed | NOT_REACHED |

A probe is **one** `validations[]` row, kind `DEPLOY_PROBE`, environment `CONTAINER`. Each `expect` id,
and each id the image wrote that is not in `expect`, is one `checks[]` entry of that row
(`{check: <id>, expected: "pass", got: <outcome, or "" when missing>, ok}`). It must stay one row:
`keep_set_hash_only_if_validated` (`kci_cli/start_checks.mojo`) keeps `set_hash` only when
`len(result.validations) == len(sel.validations)`, so a row per case would empty `set_hash` on every
passing run. The summary lists every check. A SUCCEEDED validation holds at least one check, all `ok`
(`result.mojo`), so an image that writes nothing cannot pass.

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
stage names in `after` must carry at least one `DEPLOY_PROBE` (refused above: D2 refuses every such
DEPLOY step until V1 brings the probe, then V1 requires one). The OCI digests are in
the set hash, so the next cell can then receive only the digests this cell validated.

## The workflow check

`kci_workflow_check` changes in D6. R16 does not change: it is what serializes a cell (see "One run
at a time").

| rule | change |
|---|---|
| R4 | R4 already puts `id-token: write` on a job exactly when its stage needs an identity token. `id_token_stages` gains every stage that holds a DEPLOY step or a PUBLISH into a cell, because kci authenticates to a cell from CI by OIDC only. A part job still carries no token: R9 already refuses one that does. **A PUBLISH into a cell names no channels file.** `id_token_stages` and `channels_paths` (`rules.mojo`) parse the channels file of every PUBLISH step today, so a cell PUBLISH would fail as "the channels file '' was not given". D6 makes both skip a PUBLISH into a cell, and counts that step as needing the token. Until D6 merges, a machine file holding a cell PUBLISH (which D2 is the first to parse) cannot run under GitHub Actions: `check_workflow_at_start` (`kci_cli/start_checks.mojo`) tries to read the channels file '' that `channels_paths` returns for it, fails, and stops the run INDETERMINATE, exit 5, before any step. It is not REFUSED. Outside GitHub Actions the check is skipped, as for every run. |
| part jobs (R9) | R9 already lets only the job named after the stage run steps, and makes every part job validation-only, with no environment and no `id-token: write`. So a cell's PUBLISH and DEPLOY can never be split apart, and D6 adds nothing for them. **New:** a part job's `--only validation:<name>` must not name a `DEPLOY_PROBE` that has a `target`. A part job holds neither the DEPLOY step's recorded outputs (they are in the main job's run) nor a token, so such a probe would be refused at start by `kci run` (see "Fields" above); the workflow check refuses the split before any run. A `DEPLOY_PROBE` with no `target` may still run in a part job. |

## PR split

The stack (#682 … #814) merges first. Every row names the planted defect that must turn its test red.
The PR body records the red build.

| PR | packages | depends on | tests prove | planted mutant goes red |
|---|---|---|---|---|
| **D0** | this doc, `release_machine.md`, `docs/index.md` | none | The new links (index, `release_machine.md`) resolve under the `markdown_docs` lint (`komira//:docs`, which the PR check builds). This is the existing link lint; no test of design content is possible for a docs-only PR. | the `deploy_step.md` link misspelt in `release_machine.md` |
| **D1** cells file | new `kci_cell`, `kci_api` formats (`kci.cells`) | none | A golden parse, and one red case per refusal listed under "Cells". | the duplicate-name check removed: the duplicate case parses |
| **D2** grammar | `kci_release_machine/{parse,deploy,graph}.mojo` | D1 | The machine `name` parses and every rule of "The machine name" has a red case; a machine file with DEPLOY parses, and so does a PUBLISH step with `cells` and `cell`; every row of "Refusals in the machine file" not marked V1 has a red case, including a DEPLOY step in a stage another stage names in `after`, refused with or without a `validation` block (the existing rule still refuses any validation on a DEPLOY step), and a PUBLISH naming both `channel` and `cell`. | `platform` allowed on DEPLOY; the one-destination check removed: the PUBLISH naming both parses; the same-cell check removed; DEPLOY allowed in a `farm_connected` stage; DEPLOY allowed in a `break_glass` stage; the promoted-stage refusal removed: a DEPLOY in a stage named in another's `after` parses |
| **D3** result keys | `kci_api/result.mojo`, the parser, `exit_codes` | none | A round trip of every step-row key. The parser refuses a FINISHED step row with `landed` non-empty and outcome FAILED, and a top-level `landed`. | the landed-with-FAILED check removed from the parser: that row parses; the top-level `landed` refusal removed: it goes to `ignored_keys` and the document parses |
| **D4** `kci_cloud` outcomes | `kci_cloud/deploy.mojo`, `kci_cloud/validate.mojo` (a dependency-cycle graph finding over reference cycles between resources; a cycle that only lowering's helper nodes create still reaches the engine), `kci_cloud_fake` tests | stack | Each refusal path (validate, expansion, key change, foreign, conflict), under `plan_report` and `apply_resources` both, yields the typed refusal with its findings; an engine fault, a raising `realize` and a broken lowering contract never do. Two services each reading the other's URL is the typed refusal under both, with zero calls on the fake. `plan_report` reports the `leftover` and `left_behind` an apply of the same graph reports. An adoption finding is the typed refusal under both verbs. A failed release is typed apart from an engine error. | the foreign refusal returned as an untyped error; a raising `realize` typed as a refusal; `leftover` dropped from `PlanReport`; the cycle finding removed: the apply returns `topo_sort`'s untyped engine error and the case goes red |
| **D5** wiring | `kci_cli/deploy_step.mojo`, `args`, `summary`, BUCK; `kci_cloud_fake` (four faults, constructor arguments after the shape of `fail_at_call`: `trust_check` raising, a presence read raising, `lower` returning a node owned by another resource, `realize` raising) | D2, D3, D4 | End to end on `FakeCloud` + `InMemoryStateStore`, in a stage no other stage is `after` (D2 refuses a promoted one): `--plan` writes nothing; apply, then a second run is all NOOP; a planted foreign object is REFUSED with `landed` empty; a planted mid-graph fault is PARTIAL/UNSAFE with `landed` + `pending`; a fault planted on the **first** mutating node, so `landed` is empty, is PARTIAL, exit 6, UNSAFE, with `pending` starting at that node; a `kci.app` instance plans to its primitives (golden); a wrong `--release-set-hash` is REFUSED; the scope's machine is the file's `name`; a `trust_check` that raises is FAILED, exit 4; a `--plan` whose presence read raises is FAILED, exit 4; a lowering-contract break in `lower_data` and a raising `realize` are each FAILED, exit 4, NEEDS_HUMAN. | `--plan` routed to apply (store non-empty); the set-hash recompute skipped; an engine error with `landed` empty mapped to FAILED (`ApplyOutcome.partial()` used as the classifier): the first-node case goes red; a raising `realize` given retry SAFE: its retry assertion goes red |
| **D6** workflow check | `kci_workflow_check` | D2, V1 | A DEPLOY stage's job carries `id-token: write` and is refused without it (R4 through `id_token_stages`); a stage that publishes into a cell likewise. A split DEPLOY stage whose part job runs `--only validation:<probe>` for a `DEPLOY_PROBE` with a `target` is refused naming R9; the same split for a probe with no `target` is accepted. A machine file with a PUBLISH into a cell, given no channels file at all, is checked: its stage is in `id_token_stages` and `channels_paths` is empty. | the DEPLOY arm removed from `id_token_stages`: the job without the token is accepted; the targeted-probe arm removed from `_check_split`: the refused split is accepted; the cell-PUBLISH skip removed from `id_token_stages`: the no-channels-file case raises |
| **G1** client methods | `komira_gcp_{run,iam,cloudscheduler,secretmanager,artifactregistry}`, token info, WIF provider `get` | none | One wire row per new method (path, verb, body). | one path template changed: its wire row goes red |
| **G2** external account | `komira_gcp_wif` only (a new `external_account` module; `sts.mojo`). `komira_gcp_core` is unchanged and its ADC still refuses `external_account` | none | `sts_exchange_form` takes the subject token type as a parameter instead of hard-coding `AWS_SUBJECT_TOKEN_TYPE`; the AWS caller passes that constant, and the new reader passes the file's `subject_token_type` (`urn:ietf:params:oauth:token-type:jwt` for an OIDC token). The AWS form's golden is unchanged byte for byte. Over `ScriptedConnector`: a file-sourced and a URL-sourced subject are each exchanged at STS with the jwt type and the file's audience, then impersonated through IAM Credentials when the file names an impersonation URL, and not when it names none; a file missing `audience`, `subject_token_type`, `token_url` or `credential_source` is refused naming the field. `test_env_source_only` still passes over the new module (the file text is a parameter). | the audience dropped from the STS form; the AWS type kept for every subject: the file-sourced form's golden goes red; impersonation skipped (the STS token returned as the access token): the impersonation case records no IAM Credentials request and goes red |
| **G3** shared lowering + derived stamp | `kci_cloud` (lifted shapes, the `DERIVED` carrier, kit steps 14 and 15 and their hooks `plant_foreign_member`, `member_present`, `fail_after_create_of`, `failed_after_create`, and the trait methods `image_registry` and `registry_login`), `kci_cloud_fake`, `kci_reconciler` | stack | The fake's lowering goldens are unchanged byte for byte. On the gcp fake: the kit passes, steps 3, 12, 13 and 15 included; a foreign member holding a mapped IAM role, and a cell member holding an unmapped one, are reported as unmanaged differences and kept (step 14); a `uses` line on a `run_as` workload and a `grant` resource are refused by `check`. **That refusal turns existing tests red, and G3 rewrites them.** `check` runs inside validate (`kci_cloud/validate.mojo`), and plan, apply and destroy all validate first, so every validate, plan, apply or destroy on the gcp shape over a graph holding a `grant` resource or a `uses` line on a `run_as` workload goes red, not only kit runs. The rule: a `grant` resource becomes a `uses` line on its principal (same target, same verb), and a `uses` line on a `run_as` workload moves onto the account it runs as. Each rewrite is a second graph that only the gcp run reads; no `_lowered` golden reads it (lowering never calls `check`), which keeps the goldens unchanged. By mechanism: **kit:** `test_fake_compute` section 2 (`_graph()`'s `reads` becomes `uses media READ` on `runner`; the bucket stays, since the gcp fake hosts one); `test_fake_provider_shapes`'s kit (`_full`'s `see` becomes `uses runner DESCRIBE` on `web`, kept in the roles-off graph, which empties `web`'s list today); `test_fake_registry`'s kit (`pull-images` becomes `uses images READ` on `puller`); `test_fake_secret`'s kit (`rot-db` becomes `uses db WRITE` on `rot`). **Lifecycle:** `test_deploy_lifecycle_e2e`'s three tests loop `_shapes()` (aws, gcp, azure) over `test_data/deploy_lifecycle_graph.json`, whose grant `reads` section 1a requires to raise no finding; the gcp run reads the rewritten graph, and the per-shape oracle that pins `reads` (`_pins`, and `_apply_and_check`'s `reads/grant` assertion) names `runner`'s edge node on gcp. **Apply loops:** `test_fake_provider_shapes`'s `_identity_graph`, applied on every shape by `test_the_identity_graph_applies_and_settles_on_every_shape`, has `api` running as `runner` with `uses store READ` (it moves onto `runner`) and the grant `see` (it becomes `uses runner DESCRIBE` on `nightly`); `test_fake_validation_run_tag` runs its kit on the generic fake only, but four tests apply `_full` on every shape (the tag on every cloud, outside a run, the destroy half of the invalid-id test, the tag naming its run), and `_full` holds `see` (`uses runner DESCRIBE` on `web`). Its `_covers_every_hosted_type` requires one resource per type `implemented()` lists, which on the gcp fake includes `grant`: G3 leaves `grant` out of that count on a shape whose grants are `DERIVED`, read from the shape, never from its name. **Refusal cases:** `test_fake_messaging`'s kit graph holds no grant; only its gcp case for a direct send changes, whose `pusher` is a `grant`: `pusher` then has two findings, the limit and the grant refusal, and the case asserts both (its `uses` twin, `direct`, is unchanged). `test_fake_secret`'s `test_a_reference_without_read_is_refused_on_every_shape` asserts the whole refusal text on every shape over a graph holding `rot-db`; its gcp run takes the rewritten graph. **Not affected:** `test_fake_kci_job` and `test_fake_kci_app` (gcp only lowers, for a golden); `test_fake_compute`'s `test_after_an_apply` (generic and aws); `_refused_before_any_create` (it asserts only that the joined refusal names `validation_run_id`); every other gcp run (no `grant` and no `run_as`). The fakes' `image_registry` equals their bootstrap registry's name, and differs for two cells. | the member check removed from attribution: the foreign member is taken as the cell's, so it is not reported as an unmanaged difference (or is removed as unwanted): step 14 red; `public` lowered with no invoker binding in the shared shape: the fake's lowering golden goes red; `image_registry` returning a constant: the two-cells case goes red; `check`'s `grant` refusal removed: the refusal case is accepted; `check`'s `run_as` + `uses` refusal removed: its refusal case is accepted |
| **G4** adapter, accounts, jobs and bindings | new `kci_cloud_gcp`, a test-only GCP emulator | G1, G2, G3 | The whole kit on the emulator. A graph of accounts alone cannot pass it: every resource that holds its own identity gets the implicit `cell LOGS WRITE` edge (the `kci_cloud/grants.mojo` header), which on GCP is a project binding; step 8 must delete a role; step 9 needs a node with a value reference, and only a workload's `env` makes one. So G4 implements `service_account` (the three description lines), `container_job` (a Run Job, labels; its CRUD methods exist), and the derived bindings on the project (CRM `Get/SetIamPolicy`) and on a service account (IAM `Get/SetIamPolicy`), with G4's rows of the IAM role table and its injectivity test. The kit's graph: accounts `peer` and `runner`, `runner` with `uses peer DESCRIBE`; a job `nightly` with its own identity whose `env` reads `peer`'s `NAME`; `changed` changes `nightly`'s command; `roles_off` drops `runner`'s `uses` line; `tamper_node` is `nightly/run`. Step 14 plants on `peer`'s policy and, as the cell-scope binding, on the project's. Step 15 arms each created node in turn: the accounts, the job, `runner`'s binding on `peer` and each `cell LOGS WRITE` project binding. Step 13 adopts a copy of `peer`, a service account and so a description carrier: G4 implements `read_existing`, `release`, `plant_like` and the mark line on the description. Also `configure`, `whoami`, `trust_check`, `image_registry`; a description over 256 bytes refused at validate; the credential choice (see "Credentials"): a `service_account` file reaches core's reader, an `external_account` file wif's, and an `authorized_user` file is REFUSED, as is an unset variable. | the service account created with an empty description and the three lines written by a second `PatchServiceAccount`: step 15, armed on an account's node, leaves an account with no description, so its step 3 check goes red; the mark line dropped by `PatchServiceAccount` on update: step 13 red; the retention line dropped (kit step 3); `authorized_user` passed through to core's ADC (which reads it): the refusal case goes red; G4's two rows mapped to one IAM role: the injectivity test goes red |
| **G5** workloads | `kci_cloud_gcp` | G4, U1 | The whole kit on the emulator, over a graph of its own in which every G5 kind and binding path has a node: a `secret` `token`; a `worker` `relay` with its own identity, two replicas, `secretEnv` `TOKEN` naming the `secret` resource `token` (the value reference step 9 needs: the run reads the secret's name as an input) and `uses token READ` (a binding on a secret); a `container_job` `nightly` with its own identity and a command; a `schedule` `tick`, cron `0 3 * * *`, targeting `nightly` (its implicit CALL edge is a binding on the job); a public `service` `api` with its own identity (its `public` node is the invoker binding on the service). `changed` changes `tick`'s cron; `roles_off` makes `api` internal (its `public` binding is deleted); `tamper_node` is `relay/run`. No `grant` resource and no `run_as`, so `check` refuses nothing. Step 14 plants on `token`'s policy and, as the cell-scope binding, on the project's (a `cell LOGS WRITE` node of an identity of its own, as in G4); step 15 arms every created node, the Scheduler job and the three new binding paths included. The role table, grown by G5's rows, stays injective. | the Scheduler description stamp dropped (kit step 3, on `tick`'s Scheduler node); the Scheduler job created without its description and patched after: step 15, armed on that node, red; the secret binding written to the project's policy instead of the secret's: attribution finds no binding on `token`, so step 3 finds no live object for `relay`'s READ node; two of G5's verbs mapped to one IAM role: G4's injectivity test goes red |
| **U1** a `uses` input on the built-ins (when Q13 is decided as recommended) | `kci_resource_proto` (`composite.proto`: a new `InputType` holding a list of `uses` lines, today the types are STRING, INT, BOOL, REF, IMAGE and VALUE_MAP; `resource.proto`: the `CompositeInstance` value that carries it, whose comment today refuses `uses` on an instance), `kci_cloud` (`compose.mojo`, `compose_bind.mojo`: the input bound to a component's `uses`; `compose_kci.mojo`: changed definitions are new versions, so `kci.job@2` and `kci.app@2` are new digest rows, and the `@1` rows and files stay, since a row is added and never edited), `kci_composites` (`kci.job` and `kci.app` declare it, bound to `account`; their docs stop telling authors to grant to `account`) | G3 | In `kci_cloud`'s compose tests: an instance's `uses` input lands, line for line, on the bound component and on no other; the new type bound to a field that is not a `uses` list is refused. In `kci_composites`' tests: both built-ins declare the input, bound to `account`, and the welded digest test holds `@1` and `@2` to their rows. On the gcp fake: a `kci.job` instance whose `uses` input reads a bucket validates with no finding (the line is on the account, so `check` refuses nothing), and the same edge written as a `grant` to the exported `account` is refused. | the binding put on `job` instead of `account`: the gcp case is refused by `check` (a `uses` line on a `run_as` workload) and goes red; the input dropped in expansion: the bind case finds no line on `account` |
| **I1** one type word, the writers | `kci_publish_oci`, `kci_cloud`, `kci_cloud_fake` | stack (it edits `kci_cloud_fake/clouds.mojo` and `kci_cloud` tests, which the stack rewrites) | `test_publish_oci_arm.mojo`'s type assertion compares with the literal `"OCI"` (the value of `kci_release_channel`'s `ARTIFACT_TYPE_OCI`; `kci_publish_oci` does not depend on that package), not with the arm's own constant, which today makes the check circular. Every `ArtifactNeed` a fake returns has kind `OCI`, asserted against the literal. | the arm keeps `OCI_IMAGE`: the publish test's literal assertion fails; a fake keeps `oci-image`: the `required_artifact` kind assertion fails |
| **I2** image in the release set | `tools/build/package` (`oci_image[release]`), `kci_artifact_manifest`, `kci_release_set` | I1 | The manifest reader accepts `OCI` (today `test_artifact_manifest.mojo` asserts it is refused; that case becomes an acceptance) and still refuses `OCI_IMAGE` and `oci-image`. `hello_image[release]` verifies, and its digest is in `set_hash`. A copy of its layout with one layer byte flipped is refused by `verify_member`. A directory is refused for CONDA. | the reader still refusing `OCI`: the acceptance case goes red; `verify_member` checks the manifest digest without hashing the blobs: the flipped-byte case verifies |
| **I3** PUBLISH into a cell | `kci_publish_oci` (`publish_layout` takes the set member's digest), `kci_publish`, `kci_cli` | I2, D1, D5, G3 | In `test_publish_oci_arm.mojo`, `publish_layout` called directly, with no `verify_member` in the path: given a valid layout whose manifest digest is not `expected_digest` (a second layout put where the verified one was, the change between verify and push), it is REFUSED, exit 3, with zero requests on the fake registry, under `plan` as well; the existing cases pass each layout's own digest and keep their outcomes. Through `kci run`: a push to `image_registry(ctx)` of the fake cell; a second push is NOOP. A registry that serves another digest at read-back is INDETERMINATE, exit 5: that is `komira_oci`'s step 6, and its own tests cover it; I3 asserts only the mapping through the cell path. | the digest comparison removed from `publish_layout`: the swapped layout is pushed (requests recorded) and the outcome is SUCCEEDED, not REFUSED. `verify_member` cannot catch it: that test never loads a release directory |
| **I4** resolve images in DEPLOY | `kci_cli/deploy_step.mojo`, `refs.proto` comment | I3 | `StepOutput` resolves to `registry/name@digest`; a `step` that is not a BUILD step, a `name` that step does not declare, a member missing from the set and a wrong platform are each REFUSED before any change. | resolving by `name` while ignoring `step`; resolving by name while ignoring platform |
| **V1** `DEPLOY_PROBE` grammar | `kci_release_machine`, `kci_api/verbs.mojo` | D2 | A red case per field rule; `CONDA_*` refused on DEPLOY, and `DEPLOY_PROBE` refused on BUILD and on PUBLISH; D2's promoted-stage refusal relaxed: a DEPLOY step in a stage named in another's `after` is refused with no probe and accepted with one. | a tag accepted as `image`; `DEPLOY_PROBE` accepted on PUBLISH; the relaxed rule accepting a promoted DEPLOY with no probe: the no-probe case parses |
| **V2** runner and verdict | `kci_validate` (the runner, the verdict, the pre-flight and its exit-contract farm test), `kci_cli/args` (`--preflight-image`), `tools/build/platforms/table.bzl` (the helper image's pin), `.github/workflows/kci.yml` and `release/validations/defs.bzl` (pass the flag, as they pass `--pixi`), `docs/ci.md` (the runner precondition) | V1 | Every row of the verdict table, with a scripted fake process runner; the argv golden keeps the hardening flags, `--network=bridge`, `--name kci-probe-<id>` and the `kci-probe-max-seconds` label. A run the runner times out is followed by `docker rm -f kci-probe-<id>` in the recorded calls. The pre-flight container, from the `--preflight-image` digest, runs before the probe in the recorded calls; its exit 1 lets the probe run, while exit 0, exit 125 and a pre-flight timeout each give INDETERMINATE and record no probe `docker run`; a tag given as `--preflight-image` is REFUSED. The sweep: with the scripted daemon's `SystemTime` at T, a labelled container started more than its maximum before T is removed, one started less is left, and one created and never started is measured from `Created`; the scripted runner's own clock is set an hour ahead of the daemon's, so a sweep on the wrong clock removes the young container; and with `SystemTime` written at `+02:00`, a container started 30 minutes before that instant (its `StartedAt` in `Z`) under a one-hour maximum is left, which a sweep that drops the offset (reading the local time as UTC, two hours later) would remove. The farm test of the exit contract (see "Running it"). Every case is one `checks[]` entry of the probe's one row. | a missing `expect` row treated as a pass; `--cap-drop=ALL` dropped from the argv; the `rm -f` on timeout dropped: the recorded calls end at the run; the pre-flight skipped: the connect-succeeds case records a probe run and is not INDETERMINATE; any non-zero pre-flight exit treated as a pass: the exit-125 case runs the probe; leftovers removed by name prefix, or aged by the runner's clock: the young container is removed; `SystemTime`'s offset ignored: the `+02:00` case removes the young container |
| **V3** wiring and gate | `kci_cli` | V2, D5 | A DEPLOY stage whose probe fails empties `set_hash` and exits 7; a passing probe keeps it; under `--plan` the probe is WOULD_VALIDATE; a target that no step output declares is REFUSED; a probe with a `target` selected without its DEPLOY step is REFUSED at start. `keep_set_hash_only_if_validated` is existing code, and `test_kci_ref_check.mojo` already proves it for a CONDA row; V3's mutants plant on V3's own wiring. | the DEPLOY step's probes left out of `sel.validations`: the function returns early (no validations selected) and hands `set_hash` on, so the failed-probe case keeps it; the probe's row written SUCCEEDED whatever the verdict: the failed-probe case exits 0 and keeps `set_hash` |

**Merge order.** The table is grouped by area, not by merge order: D6 depends on V1 and G5 on U1, each
listed later. The edges are exactly the "depends on" column: D2 after D1; D4, G3 and I1 after
the stack; D5 after D2, D3 and D4; D6 after D2 and V1; G4 after G1, G2 and G3; U1 after G3; G5 after
G4 and U1; I2 after I1; I3 after I2, D1, D5 and G3; I4 after I3; V1 after D2; V2 after V1; V3 after V2
and D5. D0, D1, D3, G1 and G2 depend on nothing. D5 does not depend on V1, and need not: until V1
merges, D2 refuses every DEPLOY step in a stage another stage is `after`, so no merge order lets a
promoted DEPLOY run without a probe. One order that respects every edge:

D0, D1, D3, G1, G2, (the stack), D4, G3, U1, I1, D2, V1, D5, D6, V2, G4, I2, I3, V3, I4, G5.

Rows with no edge between them can still edit the same files: I1, D4 and G3 all touch `kci_cloud`
and `kci_cloud_fake` (`clouds.mojo` and its tests). Whichever lands second resolves the conflict
with a new commit on its branch (a merge of `main`, never a rebase).

## Open questions (recommendation first)

| # | question | recommendation |
|---|---|---|
| Q1 | Should the resource file be proto3 JSON, or should a generic text-format decoder be written first? | JSON. It adds no code. A text-format decoder can come later as an alternative reader of the same message. |
| Q2 | Teardown: should a `--destroy` flag be added now, never on a release run? | No. Leave teardown to a human step until there is a durable store. A closed-world delete with only stamps as the record is not safe enough. |
| Q3 | Promotion: re-push the verified layout, or `OciCopier` from the previous cell? | Re-push. One code path, and no cross-cell read grant. Copy only when the release directory is gone. |
| Q4 | May a resource list adopt the cell's bootstrap registry (P12 `adopt`) so that its grants are declared? | Not in v1. The bootstrap owns it, and the adapter grants the cell's runtime pull. On GCP the rule is held by coverage (`registry` is not a v1 kind). The first adapter that hosts `registry` adds a validate finding for a `registry` whose `physical_name` is the bootstrap registry's derived name. |
| Q5 | A `DEPLOY_PROBE` image as a `StepOutput` (loaded from the release directory), and `secret_env` for a probe | Both later. Loading needs a docker-loadable form of the release member. `secret_env` needs a design for who holds the value, because the resource model's rule is that kci never holds a secret's value. |
| Q6 | `authorized_user` credentials for an operator running kci by hand | Refuse them. The operator impersonates the deploy identity through an `external_account` or service-account file. Only bootstrap runs with a person's own credentials. |
| Q7 | `bootstrap_level` has no reader. Keep it at `1`, or drop it? | Keep it, accepting only `1`, so the cells file does not change major when level 2 is defined. |
| Q8 | `worker` on GCP: wait for worker-pool client methods, or lower a worker as a Service with no ingress? | Use worker pools, as in the fake's shape. Changing the lowering means changing the shared shape first, never only in the adapter. |
| Q9 | Should apply emit `plan_hash` and take `--expect-plan-hash`, so that an approved plan is what runs? | Yes, after D5, with the engine returning the plan it executed. Without a plan job that holds read-only credentials it cannot be used, so it is not in v1. |
| Q10 | Should the stack's `--adopt <id>` wording be fixed in P12? It is in the `CellScope` docstring, the ownership-rule comment at the top of `ownership.mojo`, and the foreign refusal text `ownership.mojo` builds, which tells an operator to pass `(--adopt <id>)` (a `kci_reconciler` test asserts that text). The same word is in comments in `engine.mojo`, `resource.mojo`, `described_resource.mojo` and `erased_resource.mojo` (`kci_cloud/adapter.mojo` no longer has it at #814's head), and in two comments of `kci_reconciler/tests/test_ownership_and_cell_keys.mojo` (the file header's ownership list, and the comment above the adoption case). | Yes, all of them in one change. #814 fixed the refusal text, its test and every comment that named the flag (`ownership.mojo` rule list and `CellScope` docstring, `engine.mojo`, `resource.mojo`, `described_resource.mojo`, `erased_resource.mojo`, and two in the test file). No `--adopt` is left in the stack. |
| Q11 | Should a break-glass run be able to deploy? | Not in v1. A break-glass run sits in a group per ref and would race a push. It needs the cell lease; until then a fix reaches a cell through main. |
| Q12 | A re-run of an older workflow run rolls a cell back. Should kci refuse a revision older than the one the cell runs? | Yes, once the durable store records the deployed revision per cell. v1 documents it; the operator must not re-run an older run's deploy job. |
| Q13 | On a `DERIVED` shape, `uses` on a `run_as` workload and `grant` resources are refused. Lift this by owning such an edge's node by its principal? The built-in `kci.job` and `kci.app` make it pressing: their docs tell an author to grant to the exported `account` with a `grant` resource, and they take no `uses` input, so on GCP an instance's own identity can be granted nothing in v1. (Another identity calling the instance is fine: it writes `uses` on itself, naming the exported `job` or `api`.) | Not in v1 for plain resources. Changing node ownership changes ids on every cloud, so it is a reconciler design of its own, and writing the `uses` line on the account is an exact equivalent for a resource the author writes. For the built-ins it is not; recommend a `uses` input on both, bound to the `account` component, before G5 is called done, and decide it with the reconciler question. That is not only a `kci_composites` change: `composite.proto` has no input type that holds `uses` lines, so it needs a new one and expansion support (PR U1, which G5 depends on). |
| Q14 | Machine names are not globally unique. Two machine files with the same `name` (two repositories, or a second machine file run by hand) deploying into one cell compute the same stamps, so each would see the other's objects as its own and update or remove them. `CellScope.provenance` holds only a run id and a revision, is never part of the identity and is never compared, so it cannot tell them apart. How is a cell kept to one machine? | Make the cell's trust say which repository may deploy into it. Bootstrap writes the workload-identity provider's attribute condition for exactly one repository, and `trust_check` refuses a cell whose provider admits any other, or none named. `trust_check` compares the provider's attribute condition **byte for byte** with the canonical condition bootstrap writes for that repository; it never interprets CEL. A condition an operator rewrote by hand, even to an equivalent one, is a finding. Then from CI only that repository's runs can obtain the deploy identity. Inside one repository, R10 already holds every `kci run` of the release workflow to the one machine file being checked. A hand run is not covered; it is already unsupported against a cell CI deploys (see "One run at a time"). Adding the repository to provenance would not help while provenance is never compared. |
| Q15 | `CONDA_INSTALL_SMOKE` runs a third-party package's install scripts on `--network=bridge`, with the same reach into the link-local range as a probe. Should it take the probe's pre-flight? | Yes, in a follow-up after V2: it shares `container.mojo` and the pinned pre-flight image, and needs the same runner precondition in `docs/ci.md`. Until then the precondition is documented for every runner that runs a container validation. |
| Q16 | Adopting a description carrier (a service account, a Scheduler job) overwrites its description, and a release leaves it empty. Should kci refuse that? | Yes, at plan. GCP's `read_existing` reports `description`, and the lowering declares it empty for a description carrier, so a non-empty description is an adoption mismatch naming both sides. Nothing a human wrote is lost. |
