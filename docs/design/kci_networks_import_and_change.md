# kci: importing an existing network, and changing one, on any cloud

A decision note for the kci resource model. It assumes the neutral `network` and `subnet` primitives
(`Resource.body` 23 and 29): a network has one private IPv4 range (`ipv4_cidr`), a subnet names its network
by `Ref`, has its own range inside it and an optional zone, and a service names the subnet it leaves through.
This note decides what bringing an existing network under a list means, which changes kci makes in place, how a
range change is planned when the clouds cannot make it in place, and how peering works when the other side is
an account kci cannot reach. Nothing here is built yet.

## Two different asks: use a network, or take it over

Most users who "import" a network do not want kci to own it: a platform team owns the network, and the list
wants to place services in it. The engine's adoption is the other thing: `--adopt <id>` stamps an unstamped
object of a wanted name, and from then on it is the list's own, changed by apply and deleted by destroy
(`src/kci_reconciler/ownership.mojo`). Both are needed and they must not be confused:

| Verb | What kci does to the object | Closed world and destroy | Cost |
|---|---|---|---|
| **use** (reference) | reads it, never stamps, changes or deletes it; a subnet of the list may be cut from it, a service may be placed in it | never a node to delete; nothing the list does removes it | a reference form for `network` and `subnet`: the cloud name of an existing object, like `SecretRef.name` |
| **adopt** (take over) | stamps it and converges its mutable fields to the file | the list's own: removed from the file, it is deleted per its retention | `Resource` 6 `physical_name` (held: keep an existing cloud name), so the wanted name can equal the existing one |

Rules for adopt, the same on every cloud:

- The immutable fields must already match the file (the network's range, a subnet's range and zone). A
  mismatch refuses the run before any change, with the live and the written value, as a table's key does
  (`data.key_change_findings`). Adopt never turns into a replace.
- Only the named object is adopted. Subnets, routes or firewalls already in the network carry no stamp, so
  they stay foreign: kci neither lists them as its own nor deletes them, and a subnet of the list whose range
  overlaps one of them is refused by the cloud at create (the plan says so when the adapter can read them).
- An adopted network or subnet takes KEEP unless the author writes `retention`, whatever the type default
  (DELETE): a network that existed before kci should not vanish at the first destroy by default.

**Recommendation: both verbs, use first.** Use covers the common case with no ownership risk; adopt follows
with the rules above.

## Which fields change in place

| Field | AWS | GCP | Azure | Kubernetes (on-prem) |
|---|---|---|---|---|
| network range | primary range immutable; secondary ranges can be added | the network has no range of its own (kci's range is a check on its subnets) | address space can be added to, and shrunk when no subnet uses the part removed | no address-space object in core Kubernetes; depends on the network plug-in, undecided |
| subnet range | immutable | can be expanded in place, never shrunk | can change only while the subnet holds nothing | as above |
| subnet zone | immutable (subnets are zonal) | none (subnets are regional) | none (subnets are regional) | as above |
| tags and labels | mutable | mutable | mutable | mutable |

A neutral field must mean the same and fail the same everywhere, so the shared answer is the strictest: **the
network range, a subnet range and a subnet zone are immutable in kci**, checked like a table's key, before any
change. Growth is a later neutral field (additional ranges on a network), if it is wanted; GCP's in-place
expansion is at most an override setting ([overrides](kci_overrides.md)), never the meaning of the neutral
field.

## Planning a subnet range change

The engine has no replace in this version (`CONVERGE_REPLACE` raises), and the clouds cannot change a range in
place. A delete-then-create of the same subnet would also take down every service placed in it. So a changed
range is refused, and the plan names the steps instead:

1. Add a new subnet, under a new id, with the new range (it must not overlap the old one: the network and subnet
   primitives (P10) refuse overlapping subnet ranges within one network at validate).
2. Point each service's `network` at the new subnet and apply: the services move and the old subnet is empty.
3. Remove the old subnet from the file and apply: the closed world deletes it.

| Option | Cost | Consequence |
|---|---|---|
| (a) immutable; refuse with the three steps above | a refusal text, the key-change check reused | every cloud behaves the same; the author sees each step |
| (b) kci plans the three steps itself from one edit | a planner that rewrites ids and orders two applies | a hidden multi-step migration; a failure between steps leaves a state the file does not describe |
| (c) in place where the cloud can | per-cloud logic behind one field | the same edit succeeds on GCP and fails on AWS: the field's meaning depends on the cloud |

**Recommendation: (a).**

## Peering

Two networks of the same list, in one cell, are one concept on every cloud: a private path between them, with
non-overlapping ranges. It lowers to a fixed set of roles per cloud (AWS: the peering connection, its
acceptance and the routes on both sides; GCP and Azure: one peering object on each network), and deleting it
removes the path everywhere. That passes R1, so **same-list peering can be a neutral primitive** (a held
number is chosen when it is declared).

Peering to a network in another account (another project, subscription or tenant) is different: the accepting
side lives where kci holds no access, and kci never holds standing access there. The other network's identity
is the cloud's own (an account and network id, a project and network path, a resource id), so it is provider
language and comes through an override. The rules:

- The foreign network is written in full; no wildcard.
- kci creates its own side only. The accepting side is a human step in the other account, which the plan
  prints as commands (as the adapter's `trust_render` does for the deploy identity) and kci never runs.
- Until the other side accepts, apply reports the peering as waiting for its peer, not failed and not
  converged; the plan carries a banner naming the lateral path it opens.

| Option | Cost | Consequence |
|---|---|---|
| (a) same-list open; cross-account by override, written in full, human acceptance | the neutral type plus one override kind per cloud | no standing access; the path is visible in every plan |
| (b) same-list only | the neutral type | cross-account users wire it by hand, outside kci |
| (c) kci accepts with credentials for the other account | credentials kci must hold for an account it does not deploy to | standing access; refused by kci's trust model |

**Recommendation: (a).**

## Testing

Adopt with a mismatched range is refused before any change (mutant: compare the zone only); a used network is
never in `list_owned` and survives a `--delete-data` destroy (mutant: stamp it on read); a changed subnet range
is refused with the three steps (mutant: let the change through as an update; the fake cloud then reports a
drift the engine cannot converge); a cross-account peering left unaccepted plans as waiting (mutant: report it
converged).

## Open questions for the owner

1. Use (reference) and adopt both, use first?
2. Does an adopted network or subnet default to KEEP?
3. Range and zone immutable, with a refusal that names the steps (a)?
4. Is growing a network (additional ranges) wanted as a neutral field?
5. Same-list peering neutral, cross-account peering only by override with a human acceptance?
6. Is a peering that waits for its peer a successful apply, or one that exits non-zero until accepted?
7. On-prem: which network plug-in, if any, gives `network` and `subnet` an object to lower to?
