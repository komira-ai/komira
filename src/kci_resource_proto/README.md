# `kci_resource_proto`

## Responsibility

The kci resource catalog (`kci.resource.v1`) as protobuf messages and the
Mojo structs generated from them: what an author writes in a deploy step.
A `ResourceList` holds `Resource` entries; each has an author-chosen `id`,
the other resources it `uses` (a `Ref` plus an `Access`), a `retention`, its
metadata (`physical_name`, the cloud name of its primary object; `labels`,
the author's own; `adopt`, an `Adoption`: take over an existing object of
that name (`ADOPT`), and let kci delete it too (`ADOPT_DELETABLE`)), and
one `body` arm. Version 1 declares twenty primitives as body arms:
`service` (10), `container_job` (11), `worker` (12), `table` (13), `bucket`
(14), `queue` (15), `secret` (16), `dns_zone` (18), `service_account` (20),
`topic` (21), `schedule` (22), `network` (23), `registry` (24), `grant`
(25), `dns_record` (26), `certificate` (27), `subscription` (28), `subnet`
(29), `ip_address` (30) and `event_trigger` (31). Arm 80, `composite`, is
not a primitive: it is an INSTANCE of a composite (`CompositeInstance`), a
named graph of resources defined as data in the format of `composite.proto`
(`CompositeDefinition`, with its `Input`, `InputType`, `Binding`, `Presence`
and `OutputDecl`). Inside a definition a `Ref` names a component with
`local` or a REF input with `input`, a `Value` names a STRING, INT or BOOL
input with `input`, and a `Binding` writes an input into any other field of
a component (an image, a port, a cron, an env); a `Presence` makes a
component exist only when an input is set. An instance binds its inputs by
type: `input` (plain values and references), `image_input` (images) and
`map_input` (`ValueMap`s). Anywhere, a `Ref.path` reaches an exported
component of an instance. kci_cloud expands every instance into primitives
before validating a list; the definitions kci ships (`kci.job`, `kci.app`)
are data files of `kci_composites`.
Every other number the `.proto` headers list is
held: undeclared today, so it decodes as an unknown field, and declaring it
later is an addition. A `secret` resource is the container only; a workload
(a service, a container job or a worker) receives a secret by reference (`SecretRef`: by name, or a `secret`
resource of the list), never as a value.

The field numbers are the contract. `tests/test_resource_field_numbers.mojo`
pins every declared number as wire bytes (the messaging types in
`tests/test_resource_messaging_numbers.mojo`, the secret in
`tests/test_resource_secret_numbers.mojo`, the DNS zone, the DNS record and
the certificate in `tests/test_resource_dns_numbers.mojo`, the container
job, the worker, the `command` fields and `Size.gpus` in
`tests/test_resource_compute_numbers.mojo`, the schedule, the event trigger
and `SourceEvent` in `tests/test_resource_trigger_numbers.mojo`, the network,
the subnet, the IP address and `Service.network` in
`tests/test_resource_network_numbers.mojo`, the registry and
`ArtifactFormat` in `tests/test_resource_registry_numbers.mojo`,
`Resource.physical_name`, `labels`, `adopt`, `Adoption` and the reserved 9 in
`tests/test_resource_metadata_numbers.mojo`, and the bases of `Ref`,
`Value.input`, `CompositeInstance` and the messages of `composite.proto` in
`tests/test_resource_composite_numbers.mojo`, and `Binding`, `Presence`,
`ValueMap`, the instance's typed inputs and the typed `InputType` values in
`tests/test_resource_binding_numbers.mojo`), and
`tests/test_resource_held_numbers.mojo` and
`tests/test_held_numbers_are_unused.mojo` pin every held number as
undeclared.

## API

The schema is one package in files by message family, and each file is one
Mojo module of the same name: `kci_resource_proto.resource` (`Resource`,
`CompositeInstance`, `ResourceList`), `.refs` (`Ref`, `Value`, `Uses`,
`Access`, `Output`, `CellResource`, `Retention`, `Image`, `StepOutput`,
`SecretRef`, `Portability`), `.compute` (`Service`, `ContainerJob`,
`Worker`, `Size`, `Scale`), `.data` (`Table`, `Bucket`), `.identity`
(`ServiceAccount`, `Grant`), `.messaging` (`Queue`, `Topic`,
`Subscription`), `.secrets` (`Secret`), `.names` (`DnsZone`, `DnsRecord`,
`Certificate`), `.triggers` (`Schedule`, `EventTrigger`), `.networks`
(`Network`, `Subnet`, `IpAddress`), `.artifacts` (`Registry`) and
`.composite` (the format of a composite). Each message is a struct
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
    + '{"id":"nightly","containerJob":{"image":{"digest":"sha256-def"},'
    + '"command":["/bin/report"],"args":["--full"]}}'
    + "]}"
)
var lst = decode_json[ResourceList](text)
var back = decode_proto[ResourceList](encode_proto(lst))
assert_equal(len(back.resource), 2)
assert_equal(back.resource[0].id, "api")
assert_true(Bool(back.resource[0].service))
assert_true(not Bool(back.resource[0].container_job))
assert_equal(back.resource[0].service.value().port, UInt32(8080))
assert_equal(back.resource[0].service.value().health_path, "/healthz")
assert_equal(back.resource[1].container_job.value().command[0], "/bin/report")
assert_equal(back.resource[1].container_job.value().args[0], "--full")
```

A `grant` gives a principal an access to a target; the enum is stored by
number and rendered by name in JSON:

```mojo
from kci_resource_proto.refs import Access
from kci_resource_proto.resource import Resource
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
from kci_resource_proto.refs import SecretRef
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

A `schedule` starts a container job (or calls a service) at the times its
cron names; `timezone` unset means UTC:

```mojo
from kci_resource_proto.resource import Resource
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal

var s = decode_json[Resource](
    String('{"id":"nightly-at-2","schedule":{"cron":"30 2 * * 1-5",')
    + '"target":{"resource":"nightly"}}}'
)
var back = decode_proto[Resource](encode_proto(s))
assert_equal(back.schedule.value().cron, "30 2 * * 1-5")
assert_equal(back.schedule.value().timezone, "")
assert_equal(back.schedule.value().target.value().resource, "nightly")
```

A `subnet` is cut from a `network`'s IPv4 range; its `zone` has presence, so
an unwritten zone is told apart from a written one:

```mojo
from kci_resource_proto.resource import Resource
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal, assert_false

var s = decode_json[Resource](
    String('{"id":"edge","subnet":{"network":{"resource":"core"},')
    + '"ipv4Cidr":"10.20.4.0/24"}}'
)
var back = decode_proto[Resource](encode_proto(s))
assert_equal(back.subnet.value().network.value().resource, "core")
assert_equal(back.subnet.value().ipv4_cidr, "10.20.4.0/24")
assert_false(Bool(back.subnet.value().zone))
```

A `registry` names the format of what it holds; its JSON names the value:

```mojo
from kci_resource_proto.artifacts import ArtifactFormat
from kci_resource_proto.resource import Resource
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal

var g = decode_json[Resource](String('{"id":"images","registry":{"format":"OCI"}}'))
var back = decode_proto[Resource](encode_proto(g))
assert_equal(back.registry.value().format.value, ArtifactFormat.OCI)
```

Every resource may carry metadata: the cloud name of its primary object
(`physical_name`, with presence), the author's labels (a map) and `adopt`
(an `Adoption`: `ADOPT` takes over an existing object of that name,
`ADOPT_DELETABLE` also lets kci delete it; kci never replaces an adopted
object):

```mojo
from kci_resource_proto.resource import Adoption, Resource
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal

var r = decode_json[Resource](
    String('{"id":"logs","physicalName":"acme-logs","labels":{"team":"data"},')
    + '"adopt":"ADOPT_DELETABLE","bucket":{}}'
)
var back = decode_proto[Resource](encode_proto(r))
assert_equal(back.physical_name.value(), "acme-logs")
assert_equal(back.labels["team"], "data")
assert_equal(back.adopt.value, Adoption.ADOPT_DELETABLE)
```

A composite definition is data. Its components are resources with ids local
to it; `Ref.local`, `Ref.path` and `Value.input` have presence (a field
named `from` is `from_` in Mojo, a keyword):

```mojo
from kci_resource_proto.composite import CompositeDefinition, InputType
from komira_proto_codec import decode_json, decode_proto, encode_proto
from std.testing import assert_equal, assert_false

var d = decode_json[CompositeDefinition](
    String('{"name":"acme.web","version":"1",')
    + '"input":[{"name":"domain","type":"INPUT_STRING"}],'
    + '"component":[{"id":"files","bucket":{}},'
    + '{"id":"api","service":{"image":{"digest":"sha256-abc"},'
    + '"env":{"DOMAIN":{"input":"domain"},'
    + '"FILES":{"ref":{"local":"files","standard":"NAME"}}}}}],'
    + '"output":[{"name":"files","from":{"local":"files","standard":"NAME"}}],'
    + '"export":["files"]}'
)
var back = decode_proto[CompositeDefinition](encode_proto(d))
assert_equal(back.input[0].type.value, InputType.INPUT_STRING)
ref env = back.component[1].service.value().env
assert_equal(env["DOMAIN"].input.value(), "domain")
assert_equal(env["FILES"].ref_.value().local.value(), "files")
assert_false(Bool(env["FILES"].ref_.value().path))
assert_equal(back.output[0].from_.value().local.value(), "files")
assert_equal(back.export[0], "files")
```
