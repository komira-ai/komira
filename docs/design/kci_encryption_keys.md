# kci: an encryption key as a resource

A decision note for the kci resource model (`src/kci_resource_proto/resource.proto`, `src/kci_cloud`,
`src/kci_cloud_fake`). `Resource.body` 34 is held for an encryption key. This note says what the key is,
how "kci never deletes a key" is enforced, which verbs a grant gets, how other resources use the key, and
what bootstrap would have to create. Nothing here is built yet.

## Why a key is different

Delete means something different on every cloud, and on none of them is it a cheap undo:

| Cloud | What a delete does |
|---|---|
| AWS KMS | schedules deletion, 7 to 30 days later; after that the data it encrypted is unreadable |
| GCP Cloud KMS | only its versions can be destroyed; a key ring is never deleted |
| Azure Key Vault | soft-deletes; purge protection can forbid the purge |
| Vault transit | refused unless the key was marked `deletion_allowed` |

The only delete meaning shared by all four is "kci never deletes it". That is the R1 rule of the schema
header (identity, meaning and delete match on every cloud) applied to delete: the shared answer is no delete.

KEEP retention is not enough. KEEP is a policy: the engine's `destroy_graph` skips a `RETAIN_KEEP` node unless
`force_delete_data` is set, and that flag is the whole-project `--delete-data` teardown. A key kept only by
KEEP would be deleted by the first such teardown, and the data under it with it. The engine already has the
right mechanism: `RETAIN_UNDELETABLE` is a capability, no flag lifts it, and `destroy_graph` returns each
skipped node as an `UndeletableSkip` so the caller names the survivors (`src/kci_reconciler/engine.mojo`).
What is missing is the path from the catalog to it: `kci_cloud/deploy.mojo` `engine_retention` maps a catalog
retention only to `RETAIN_KEEP` or `RETAIN_DELETE`, and no catalog row can say "no delete".

## Primitive or attribute

| Option | What it is | Cost | Consequence |
|---|---|---|---|
| (a) a primitive | `encryption_key` at body 34, one symmetric key in the cell's region, 1:1 with the KMS kinds | the catalog delete capability below, the type, its lowering on every shaped fake | per-key grants; per-dataset keys possible; one undeletable object per key |
| (b) an attribute | data primitives get `encryption: PROVIDER \| CELL_KEY`; one key per cell, no key resource | small; but the cell key is still a new bootstrap obligation | no key lifecycle in kci at all; no per-dataset key; not 1:1 with a provider kind |
| (c) defer | body 34 stays held; provider-managed encryption only | none | a user who must hold their own keys cannot use kci's data primitives |

**Recommendation: (a), in two steps.** First the key and its grants; then its use by other resources, once the
question in "Using the key for another resource" is answered.

## How "kci never deletes a key" is enforced

One mechanism, built from parts that exist, so nothing branches on the cloud:

1. **Catalog.** `CatalogType` gains a delete capability, `deletable: Bool` (default True). The key's row says
   False and has `retention_default = RETENTION_NONE`, so `takes_retention()` is False and writing `retention`
   on a key is refused at validate by the existing check. The author cannot choose KEEP or DELETE for it.
2. **Lowering.** A non-deletable type's nodes realize as `RETAIN_UNDELETABLE` (a new arm in `deploy.mojo`
   `engine_retention`). Rollback and destroy skip them whatever `force_delete_data` says; `destroy_resources`
   returns them, and the command prints each one as a survivor with the cloud's own deletion procedure, for a
   human to run if they mean it.
3. **Leaving the file.** The adapter writes `kci-retention=retain` on every object of the type, so
   `list_owned` reports it RETAINED and the closed world leaves it behind instead of making it a node to
   delete. This needs a new arm in `src/kci_cloud/labels.mojo` `retention_label_value`, which today maps only
   `RETAIN_KEEP` and `RETAIN_DELETE` and raises on any other retention, beside the `deploy.mojo`
   `engine_retention` arm of step 2. A key whose id comes back into the file is still stamped with its
   identity, so it is the same key.
4. **Adapter.** The adapter's delete for the key role refuses. The engine requires the set it skips and the set
   whose delete refuses to be the same set; the conformance kit would check both on every shaped fake.
5. **Self-check.** The catalog refuses a row with `deletable: False` and any retention default but NONE.

Removing a key from the file never disables it either: disabling makes the data unreadable as surely as a
delete. A key leaves the file as a reported, live, still-billed object.

## Verbs

`Access` has no verb for a key, and READ or WRITE would misstate it (a key holds no data). Two choices:

- `ENCRYPT` and `DECRYPT` as two verbs: least privilege for a writer that must not read back. Cost: two new
  `Access` values and their grant rows on every cloud.
- one `USE`: simpler, but every user of the key can decrypt everything under it.

**Recommendation: ENCRYPT and DECRYPT.** The numbers come from the free ones; 10 is free today but the welded
tests pin it as undeclared, so declaring it moves that pin in the same change. A raw key policy (AWS) is
provider language and only comes through an override ([overrides](kci_overrides.md)); access to a key is only
ever a neutral grant.

The key's other fields: an optional rotation period (all four clouds rotate on a period). Protection level
(software or HSM) and multi-region keys differ per cloud, so they are override settings, not neutral fields.

## Using the key for another resource (customer-managed keys)

To encrypt a bucket, table or secret with the key, the provider's own service agent (the storage, database or
secret service) must be allowed to use the key, and on some clouds every reader must as well (AWS SSE-KMS
needs the caller's own decrypt permission). Today a grant's principal must be a kci identity
(`kci_cloud/grants.mojo`), so a "this bucket uses this key" edge has no principal to name. The likely shape is
a `Ref` field on each data primitive (`Bucket.encryption_key`) that the adapter lowers to a fixed helper role of
the data resource (the service agent's key grant), plus a rule that a grant of READ on an encrypted resource
also grants DECRYPT on its key where the cloud needs it. Each edge is printed like the implicit logs edge. This
is the second step and needs its own decision.

## The key's container, and bootstrap

GCP keys live in a key ring and Azure keys in a key vault; AWS has no container; Vault transit has its mount.
A key ring is undeletable on GCP, so it must never be a node a list owns. Options:

- **Bootstrap creates the cell's key container** (listed by the adapter's `bootstrap_resources`, nothing on
  AWS). Cost: a new bootstrap obligation on a human verb.
- **The admin creates it by hand** and names it in a cell setting the adapter validates in `configure`.
  Cost: one more manual step, printed by the bootstrap output.

**Recommendation: bootstrap creates it**, stated as a new bootstrap step, because a key without it cannot be
created at all and the container is one per cell, shared by every owner.

## Testing

A destroy with `force_delete_data` over a list holding a key leaves the key live and returns it in the skip
list; the planted mutant maps the key's row to `RETAIN_KEEP`, and that test goes red. A list that writes
`retention` on a key is refused at validate (mutant: drop the row's NONE default). A key removed from the file
is reported as left behind and never deleted (mutant: omit the retain mark).

## Open questions for the owner

1. Primitive (a), attribute (b) or defer (c)?
2. Is the delete capability column the enforcement, with `--delete-data` unable to lift it?
3. ENCRYPT and DECRYPT, or one USE?
4. Does bootstrap create the cell's key container, or does the admin, named in a cell setting?
5. Is customer-managed encryption of other resources a separate later decision, as recommended?
6. On-prem: which pluggable secrets provider also serves keys (the key type is NOT_YET there until one does)?
