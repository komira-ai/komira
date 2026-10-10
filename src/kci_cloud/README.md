# kci_cloud

The clouds of kci's deploy side: the layer between the resource catalog
(`kci_resource_proto`, what an author can deploy) and the reconcile engine
(`kci_reconciler`, which applies a graph of nodes). A cloud is the deploy
target of a cell, named by an opaque `CloudId`; it is not a platform (an OS
and a CPU). The package names no cloud. It holds:

- the catalog's types as data (`Catalog.v1()`: each type's body field
  number, portability, exposed outputs, accepted access, default retention
  and primary role);
- the `CloudAdapter` trait every cloud built into kci implements (an
  internal module boundary, not a plugin interface) and `Clouds`, the closed
  list of built-in clouds, in which every cloud declares every catalog type;
- the validate phase: the cloud-independent graph findings
  (`graph_findings`: ids, references, identities and grants, data,
  messaging, secret and DNS rules) plus each cloud's coverage and limit
  findings, collected in one pass and rendered by `refusal_text`;
- the label rule (`encode_label_value`, the `kci-retention` mark, the
  validation-run label);
- plan / apply / destroy (`plan_resources`, `apply_resources`,
  `destroy_resources`), which validate before lowering anything, and the
  conformance kit every cloud runs (`run_conformance`).

It reaches no cloud itself: an adapter does. The working in-memory clouds
that exercise every part of it are in `kci_cloud_fake`.

## Examples

The catalog says what each body arm of a resource is:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_cloud import ACCESS_CALL, FIELD_QUEUE, FIELD_SERVICE, FIELD_TABLE, PORTABLE, RETENTION_KEEP, Catalog, portability_word, retention_word

var catalog = Catalog.v1()
for i in range(len(catalog.types)):  # every row is found by its own body arm
    assert_equal(catalog.index_of(catalog.types[i].field), i)
assert_equal(catalog.name_of(FIELD_SERVICE), "service")
assert_equal(catalog.name_of(FIELD_QUEUE), "queue")
ref service = catalog.types[catalog.index_of(FIELD_SERVICE)]
assert_equal(service.portability, PORTABLE)
assert_equal(service.accepts[0], ACCESS_CALL)
ref table = catalog.types[catalog.index_of(FIELD_TABLE)]
assert_equal(table.retention_default, RETENTION_KEEP)  # data is kept by default
assert_equal(retention_word(RETENTION_KEEP), "KEEP")
assert_equal(portability_word(PORTABLE), "PORTABLE")
```

The graph findings are the half of validate no cloud is needed for. A queue
with a dead-letter queue must also say after how many deliveries a message
moves there; every finding names the resource and the field, and
`refusal_text` is the one rendering of a refused graph:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_cloud import Catalog, CloudId, graph_findings, refusal_text
from kci_resource_proto.resource import ResourceList
from komira_proto_codec import decode_json

var good = decode_json[ResourceList](
    '{"resource":['
    '{"id":"work","queue":{"maxDeliveries":5,"deadLetter":{"resource":"dlq"}}},'
    '{"id":"dlq","queue":{}}'
    ']}'
)
assert_equal(len(graph_findings(Catalog.v1(), good.resource)), 0)

var bad = decode_json[ResourceList](
    '{"resource":['
    '{"id":"work","queue":{"deadLetter":{"resource":"dlq"}}},'
    '{"id":"dlq","queue":{}}'
    ']}'
)
var findings = graph_findings(Catalog.v1(), bad.resource)
assert_equal(len(findings), 1)
assert_equal(findings[0].resource_id, "work")
assert_equal(findings[0].field_path, "queue.max_deliveries")
var text = refusal_text(CloudId("example"), findings)
assert_true(text.startswith(
    "kci: cannot apply this graph to cloud \"example\". Nothing was created.\n"
    "  resource \"work\" field queue.max_deliveries: dead_letter and max_deliveries go together"
), text)
```

Every object kci creates carries the retention mark, and a node id becomes
a label value under one rule (`/` is written `_`, so a raw `_` is refused):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_cloud import decode_label_value, encode_label_value, retention_label_key

assert_equal(retention_label_key(), "kci-retention")
assert_equal(encode_label_value("api/run"), "api_run")
assert_equal(decode_label_value("api_run"), "api/run")
var why = String()
try:
    _ = encode_label_value("api_run")
except e:
    why = String(e)
assert_equal(
    why,
    "label value \"api_run\" holds '_', which the rule writes for '/'; a segment may not hold it",
)
```
