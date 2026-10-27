# `komira_kg_sources`

## Responsibility

The host-neutral half of source handling, from
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md).
A host fetches records of many kinds, keeps them as they came, and later lowers
each to the episodes the graph ingests. This package holds what that needs and
nothing that depends on a particular kind of record or service.

- `RawStore[Store]`: raw payloads on any `komira_objectstore` conditional-write
  store, one object per distinct payload, keyed by the hash of its bytes. The
  surface tag (an opaque string naming the kind of record) is metadata on the
  record, not part of its key.
- `PartitionBindingStore[Store]`: the one raw store prefix and the one lineage
  prefix a partition uses, with its source system, source kind and facet (opaque
  strings). The host passes the set of source systems it knows, and a bind of any
  other is refused.
- `RawSurfaceAdapter`, `AdapterRegistry`, `register`: a `SurfaceAdapter` that also
  names its tag and parses its record from raw bytes, and a registry that maps a
  tag to the adapter.
- `BIndex[Store]`: a brute-force cosine index over the episodes the registry
  lowers raw records to, with top-k search and the mapping from a hit back to its
  episode (`episode_of`).

No adapter for any kind of document or service ships here: each is a conformer of
`RawSurfaceAdapter` that lives with the host. The package reads no clock and no
environment, takes its models (`Embedder`) as arguments, and no pointer crosses
its API.

## API

Everything is exported from `komira_kg_sources`:

- `RawStore` (`put`, `get`, `find`, `has`, `list_hashes`), `RawRecord`, `RawPut`,
  `raw_content_hash`, `check_same_payload`, `encode_raw_record`,
  `decode_raw_record`.
- `PartitionBindingStore` (`bind`, `get`, `find`, `has`, `list_bindings`,
  `validate`), `PartitionBinding`, `encode_binding`, `decode_binding`.
- `RawSurfaceAdapter` (trait), `AdapterRegistry` (trait), `EmptyAdapterRegistry`,
  `RegisteredAdapter`, `register`.
- `BIndex` (`build`, `top_k`, `search`, `has_record`, `list_keys`, `read_record`),
  `BIndexHit`, `BIndexBuild`, `IndexRecord`, `IndexRow`, `episode_of`,
  `encode_index_record`, `decode_index_record`.

## Behaviour worth knowing

- **Once per content hash.** The key of a raw record is `fnv1a64_hex` of its
  payload. The same bytes put under two tags are one record: the first put keeps
  its tag and its time, and the second reports `created = False`.
- **Nothing is overwritten.** `put` and `bind` write with create-if-absent. When
  that loses to an existing object, the stored record is read back: the same
  content is a repeat, other content is an error (a hash collision for a raw
  record, another binding for a partition). A read of a raw record recomputes the
  hash and refuses a payload that does not hash to its name.
- **One binding per partition.** A partition binds one raw store and one lineage
  for good; the two prefixes must differ and neither may lie under the other. An
  identical second bind is a no-op. A different one is an error that names what
  is bound; the way to re-point is a new partition id. The sets of source systems
  (required), source kinds and facets (optional, empty means unconstrained) are
  checked when a binding is made.
- **A registry is a chain of types.** Adapters differ in type and Mojo has no trait
  object, so `register(registry, adapter)` returns a longer registry type. A tag is
  registered once (a duplicate, or an empty or over-long tag, is refused), and a
  tag nobody registered dispatches nothing: `lower_raw` returns no value and calls
  no adapter.
- **The index.** `build` visits the raw store, skips what is indexed, skips and
  counts records whose tag has no adapter or that lower to no episode, embeds the
  episodes of the rest and stores each record's rows as one object (a record is
  indexed whole or not at all). `top_k` scores every stored vector with cosine and
  returns the best `k`; equal scores come back raw key ascending, then position.
  There is no default dimension: the index is built with the embedder's.
- **Stored bytes are not trusted.** Every decoder checks a length against the
  bytes that remain by subtraction, allocates only after the check, refuses text
  that is not UTF-8 or is over 65536 bytes, an embedding that is not exactly the
  index's dimension, an unknown format version and bytes after the last field.

## Limits

- Listing reads the whole directory of the store and `top_k` reads every index
  object: the index is for a corpus a scan can cover, not a large one.
- The hash is a 64-bit non-cryptographic one. It is a key, not a proof of
  identity: the store compares bytes when two payloads meet under one key.
- Nothing here removes a raw record or a binding; erasure is the host's.

## Examples

A payload is stored once however many tags it arrives under:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg_sources import RawStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var store = RawStore[SharedInMemoryConditionalStore](
    SharedInMemoryConditionalStore(), "lake"
)
var payload = List[UInt8]()
payload.append(UInt8(104))
payload.append(UInt8(105))

var first = store.put("kind-a", payload, 100)
var second = store.put("kind-b", payload, 200)
assert_true(first.created)
assert_false(second.created)
assert_equal(first.content_hash, second.content_hash)
assert_equal(len(store.list_hashes()), 1)
assert_equal(store.get(first.content_hash).surface_tag, "kind-a")
```

A partition binds once, and a source system outside the host's set is refused:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_raises, assert_true
-->
```mojo
from komira_kg_sources import PartitionBinding, PartitionBindingStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var systems = List[String]()
systems.append("system-a")
var bindings = PartitionBindingStore[SharedInMemoryConditionalStore](
    SharedInMemoryConditionalStore(), "meta", systems^
)

var binding = PartitionBinding(
    "part-1", "system-a", "kind-1", "", "lake/raw-1", "lake/graph-1"
)
assert_true(bindings.bind(binding))
assert_false(bindings.bind(binding))
assert_equal(bindings.get("part-1").lineage_prefix, "lake/graph-1")

var elsewhere = PartitionBinding(
    "part-2", "system-z", "kind-1", "", "lake/raw-2", "lake/graph-2"
)
with assert_raises(contains="unknown source system 'system-z'"):
    _ = bindings.bind(elsewhere)

var moved = PartitionBinding(
    "part-1", "system-a", "kind-1", "", "lake/raw-9", "lake/graph-1"
)
with assert_raises(contains="a partition binds one raw store and one lineage"):
    _ = bindings.bind(moved)
```

An adapter for a made-up record type, registered under its tag, lowers raw
records for an index, and the nearest hit maps back to its episode:

```mojo module
from std.testing import assert_equal, assert_false, assert_true

from komira_kg import EpisodeInput, StubEmbedder
from komira_kg_sources import (
    BIndex,
    EmptyAdapterRegistry,
    RawSurfaceAdapter,
    RawStore,
    episode_of,
    register,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Mem = SharedInMemoryConditionalStore


@fieldwise_init
struct Note(Movable):
    """A made-up record: one line of text."""

    var text: String


struct NoteAdapter(RawSurfaceAdapter):
    comptime Source = Note

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "note"

    def parse(self, raw: List[UInt8]) raises -> Note:
        return Note(String(unsafe_from_utf8=Span(raw)))

    def lower(
        self, var source: Note, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        out.append(
            EpisodeInput("note:" + source.text, partition_id, source.text.copy(), 1, 1)
        )
        return out^


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _vec(a: Float64, b: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    out.append(b)
    return out^


def main() raises:
    var raw = RawStore[Mem](Mem(), "lake")
    _ = raw.put("note", _bytes("river"), 1)
    _ = raw.put("note", _bytes("stone"), 2)

    var embedder = StubEmbedder(2)
    embedder.add_vector("river", _vec(1, 0))
    embedder.add_vector("stone", _vec(0, 1))

    var registry = register(EmptyAdapterRegistry(), NoteAdapter())
    var index = BIndex[Mem](Mem(), "idx", 2)
    var report = index.build(raw, registry, embedder, "part-1")
    assert_equal(report.records_indexed, 2)

    var hits = index.top_k(_vec(0.1, 1), 1)
    assert_equal(len(hits), 1)
    assert_equal(hits[0].episode_uuid, "note:stone")
    assert_equal(episode_of(hits[0], raw, registry, "part-1").body, "stone")
```
