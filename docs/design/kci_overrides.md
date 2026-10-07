# kci: overrides, the escape hatch for what is cloud-specific

A decision note for the kci resource model. The decided part: the open schema (`kci.resource.v1`,
`src/kci_resource_proto/resource.proto`) stays cloud-agnostic, with resources named by concept, so one list
deploys to any cloud. A cloud-specific resource or setting comes through an explicit override, never through a
vendor word in the agnostic schema. Raw IAM bindings and custom roles have no agnostic primitive; they are
overrides. This note proposes the override's shape, how it is validated and lowered, how it meets the closed
world, retention and ownership, and how a list that uses one is marked as no longer portable. Nothing here is
built yet; every provider-specific family (firewall, NAT, edge parts, raw IAM, raw event rules, a key's
protection level, cross-account peering) waits on it.

## Two kinds of override

- A **setting** tunes one resource of the list on one cloud: a field the neutral type does not have (a
  bucket's storage class, a service's CPU architecture, a key's protection level). It names its target by
  resource id. Like the schema's per-cloud extensions, it may tune and never change meaning: it adds no role,
  removes none, and sets no field the neutral type already decides.
- A **resource** adds one provider object that no neutral type covers (a firewall rule, an IAM binding, a
  custom role). It has an id of its own in the list's id namespace and is a node of the graph like any other.

## Where it lives

| Option | Shape | Cost | Consequence |
|---|---|---|---|
| (a) extension fields 50-53 and the provider arms | each primitive message gets one typed per-cloud message per built-in cloud; provider resources take `Resource.body` 100-899 | every primitive message and the header promise change; the agnostic file imports every vendor file | vendor words in the agnostic schema, which the decision excludes |
| (b) inside each resource | the held `Resource` 5 becomes `repeated Override`, body 90 the resource form | typing it needs either vendor arms in the agnostic file or an untyped payload (`Any`, bytes), which the header forbids | the portable list and its overrides are one document; a portable reader still decodes vendor fields |
| (c) a separate override document | a deploy step carries its resource list and, beside it, zero or more override sets, in a package of their own (`kci.override.v1`) | one new file and package per cloud vocabulary; the step format names the sets | the resource list stays byte-for-byte portable; everything cloud-specific is in one place a reader can see |

**Recommendation: (c).** Extension fields 50-53 do not become the carrier. They were never declared, so they
move from held to `reserved` in the change that lands overrides, together with `Resource` 5 (the per-cloud
settings map) and the provider ranges 100-899; whether body 90 (the raw escape hatch) is retired the same way
is an open question.

The proposed shape, in `kci.override.v1`:

```proto
message OverrideSet {
  string cloud = 1;                 // a built-in cloud id, resolved like --cloud
  repeated Override override = 2;
}
message Override {
  string id = 1;                    // a resource override's own id; empty for a setting
  string target = 2;                // a setting's resource id; empty for a resource
  oneof vocabulary {                // one per built-in cloud vocabulary, each in its own file
    ...
  }
}
```

Each vocabulary file (one per built-in cloud, plus the fake clouds' own for tests) holds one message per
neutral type it tunes and one per provider kind it adds. The clouds are compiled in, so the vocabulary list is
closed; an adapter declares which vocabulary it reads, and no code compares a cloud id by name.

## Validation and lowering

Validate runs before anything is created, as for the resource list:

1. The set's cloud resolves to a built-in cloud. A set for another cloud than the cell's is not applied (see
   "Portability").
2. Each override's vocabulary is the one the set's cloud reads; any other is refused.
3. A setting's target is a resource of the list, and the setting's message is the one for the target's type.
   Two settings for one target are refused.
4. A resource override's id is unique across the list and its sets. Its `Ref` fields resolve to resources of the
   list. A neutral resource never refers to an override: the list must stand alone on any cloud.
5. The adapter's `check` validates the payload and returns every finding, as it does for a resource.

Lowering: a setting is handed to `lower` with its target, as the grant edges and feeds are, and may change the
desired fields of the target's fixed roles only. A resource override lowers to nodes `<override id>/<role>`,
owned by the override id, and goes through the same lowering contract and role budget as any resource. The plan
prints every override, setting and resource alike, under the cloud it is for.

## Closed world, retention and ownership

- **Closed world.** A resource override's objects are stamped like any others. Removed from the set, its nodes
  are turned off and deleted; a setting removed reverts its fields to the adapter's defaults as an update, or is
  refused before any change when the cloud cannot change that field in place.
- **Retention.** Each provider kind in a vocabulary carries the same catalog columns as a neutral type: whether
  it takes retention, its default, and whether kci can delete it at all (the delete capability of the
  [encryption key note](kci_encryption_keys.md)). An undeletable kind (a GCP key ring) is never an override resource: bootstrap
  creates it, or a list refers to it by name.
- **Ownership.** One owner per object holds here too. A kind that is shared project-wide (API enablement, one
  OIDC provider per issuer) cannot be an override resource; it is a bootstrap item or referenced by name.

## Raw IAM bindings and custom roles

A binding and a custom role are resource overrides of each cloud's vocabulary (an IAM member binding and a
custom role on GCP, a policy and its attachment on AWS, a role assignment and definition on Azure, a role
binding on Kubernetes). The rules, kept in the vocabulary data and not in a branch on the cloud:

- The principal is a `Ref` to an identity of the list (a service account, or a service or job with no
  `run_as`), or a foreign principal written in full and shown as a trust edge in the plan.
- The scope is a `Ref` to an object the list owns, or a custom role of the same set. Project, account,
  subscription and cluster scope are refused, and so is each vocabulary's list of admin roles (owner and editor,
  `AdministratorAccess`, User Access Administrator, `cluster-admin`), unless the stage opts in with a named field
  of the machine file. Organisation-level custom roles are refused.
- The edge is printed beside the neutral grants, so a reader of the plan sees every permission the list gives.

## Portability

A resource list is always portable. A step stops being portable when one of its override sets holds a resource
override, because the graph then depends on an object that exists on one cloud only. The proposed rule:

- A step with a resource override deploys only to clouds it has a set for. On a cell of any other cloud the
  step is refused before anything is created, naming the clouds it has sets for. An empty set for a cloud is
  the author's explicit statement that the list needs nothing extra there.
- A set holding only settings does not bind: a setting cannot change meaning, so on another cloud it is skipped,
  and the plan says it was skipped.
- Validate reports the step as `portable`, or `cloud-bound: <clouds>` with the count of overrides.

## Testing

The fake clouds get a vocabulary of their own, so the mechanism is tested on every shaped fake without a real
cloud. Each refusal above gets a test that writes the defect and expects it refused before any create (planted
mutant: drop the check; the test goes red). A resource override removed from the set is deleted by the next
apply (mutant: skip override nodes in the closed-world pass); a step bound to one cloud is refused on another
(mutant: ignore sets for other clouds).

## Open questions for the owner

1. The separate override document (c), with extension fields 50-53, `Resource` 5 and the provider ranges
   moved to `reserved`?
2. Is body 90, the raw escape hatch, retired too, or kept for an untyped form?
3. May a neutral resource ever depend on an override resource (a service on a firewall rule), or only the
   reverse, as proposed?
4. Is the portability rule right: resource overrides bind, settings do not, an empty set opts a cloud in?
5. The name of the machine-file field that opts a stage in to broad IAM scope and admin roles.
