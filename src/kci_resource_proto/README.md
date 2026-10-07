# `kci_resource_proto`

## Responsibility

The kci resource catalog (`kci.resource.v1`) as protobuf messages and the
Mojo structs generated from them: what an author writes in a deploy step.
A `ResourceList` holds `Resource` entries; each has an author-chosen `id`,
the other resources it `uses` (a `Ref` plus an `Access`), a `retention`, and
one `body` arm. Version 1 declares thirteen primitives as body arms:
`service` (10), `job` (11), `table` (13), `bucket` (14), `queue` (15),
`secret` (16), `dns_zone` (18), `service_account` (20), `topic` (21),
`grant` (25), `dns_record` (26), `certificate` (27) and `subscription` (28).
Every other number the header of `resource.proto` lists is
held: undeclared today, so it decodes as an unknown field, and declaring it
later is an addition. A `secret` resource is the container only; a service
or a job receives a secret by reference (`SecretRef`: by name, or a `secret`
resource of the list), never as a value.

The field numbers are the contract. `tests/test_resource_field_numbers.mojo`
pins every declared number as wire bytes (the messaging types in
`tests/test_resource_messaging_numbers.mojo`, the secret in
`tests/test_resource_secret_numbers.mojo`, the DNS zone, the DNS record and
the certificate in `tests/test_resource_dns_numbers.mojo`), and
`tests/test_resource_held_numbers.mojo` and
`tests/test_held_numbers_are_unused.mojo` pin every held number as
undeclared.

## API

The Mojo module is `kci_resource_proto.resource`. Each message is a struct
that conforms to `komira_proto_codec`'s `Serializable`, so `encode_proto`
and `decode_proto` (and `encode_json` / `decode_json`, the proto3 JSON form
with camelCase names) read and write it. A message field, a oneof arm and a
proto3 `optional` field are each an `Optional`; a `repeated` field is a
`List`; a `map` field is a `Dict`; an enum is a struct whose `value` is its
number.

## Examples

Every example below runs as a test when the package is built.

A deploy step's list in its JSON form, decoded, carried as binary, and
read back by field name:

```mojo
from kci_resource_proto.resource import ResourceList
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal, assert_true

var text = (
    String('{"resource":[')
    + '{"id":"api","service":{"image":{"digest":"sha256-abc"},'
    + '"port":8080,"healthPath":"/healthz"}},'
    + '{"id":"nightly","job":{"image":{"digest":"sha256-def"},'
    + '"args":["report"]}}'
    + "]}"
)
var lst = decode_json[ResourceList](text)
var back = decode_proto[ResourceList](encode_proto(lst))
assert_equal(len(back.resource), 2)
assert_equal(back.resource[0].id, "api")
assert_true(Bool(back.resource[0].service))
assert_true(not Bool(back.resource[0].job))
assert_equal(back.resource[0].service.value().port, UInt32(8080))
assert_equal(back.resource[0].service.value().health_path, "/healthz")
assert_equal(back.resource[1].job.value().args[0], "report")
```

A `grant` gives a principal an access to a target; the enum is stored by
number and rendered by name in JSON:

```mojo
from kci_resource_proto.resource import Access, Resource
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from std.testing import assert_equal, assert_true

var g = decode_json[Resource](
    String('{"id":"see","grant":{"principal":{"resource":"runner"},')
    + '"target":{"resource":"store"},"access":"READ_WRITE"}}'
)
var back = decode_proto[Resource](encode_proto(g))
ref grant = back.grant.value()
assert_equal(grant.principal.value().resource, "runner")
assert_equal(grant.target.value().resource, "store")
assert_equal(grant.access.value, Access.READ_WRITE)
assert_true('"access":"READ_WRITE"' in encode_json(back))
```

`SecretRef.store` and `SecretRef.version` have presence: an unset field is
absent, never confused with a written empty string.

```mojo
from kci_resource_proto.resource import SecretRef
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal, assert_false, assert_true

var latest = decode_json[SecretRef]('{"name":"db-password"}')
var back = decode_proto[SecretRef](encode_proto(latest))
assert_equal(back.name, "db-password")
assert_false(Bool(back.store))
assert_false(Bool(back.version))

var pinned = decode_json[SecretRef]('{"name":"db-password","version":""}')
var back2 = decode_proto[SecretRef](encode_proto(pinned))
assert_true(Bool(back2.version))
assert_equal(back2.version.value(), "")
```
