# =============================================================================
# test_cloud_shape_lower_data.mojo
# =============================================================================
#
# `lower_shape` (shape/lower.mojo) of every type that is not a workload or a
# trigger, on the built-in shapes, as data:
#
# 1. THE DATA TYPES on aws, gcp and azure: a bucket with its defaults written
#    out and one with every field; a table whose indexes and ttl are fields
#    of its one node, or (gcp) objects of their own, the ttl node turned off
#    when no ttl is written; a registry named and unnamed; a secret; a queue
#    with a dead letter, fed by two topics through subscriptions (aws: its
#    policy names both; gcp: a pull subscription on the first, the
#    subscriptions turned off and the private topic of a fed queue too); DNS (a record's
#    kind with its type in it on azure, a value that is a reference), a
#    certificate (gcp: its DNS authorization, for the name without `*.`);
#    a network (gcp: no range of its own), subnets with and without a zone
#    (aws keeps the zone), an IP address. Each is a golden line per node.
# 2. ONPREM lowers what it hosts and declares the rest NOT_YET.
# 3. NO USES LINE on a type that runs as nobody: every one of those
#    lowerings refuses one, naming the type and the resource.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    GrantEdge, LoweredNode, ProviderShape, body_field, edges_for, feeds_of, firings_of, lower_shape, shape_named,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](String('{"resource":[') + json + String("]}")).resource.copy()


def _node(n: LoweredNode) -> String:
    """`id kind[ (off)] <- deps | in: field=producer.OUTPUT | k=v ...`."""
    var s = n.id + String(" ") + n.kind
    if not n.wanted:
        s += String(" (off)")
    if len(n.depends_on) > 0:
        s += String(" <-")
        for d in n.depends_on:
            s += String(" ") + d
    for i in n.inputs:
        s += String(" | in: ") + i.field + String("=") + i.producer + String(".") + i.output
    for f in n.desired:
        s += String(" | ") + f.key + String("=") + f.value
    return s^


def _lowered(shape: ProviderShape, resources: List[Resource]) raises -> String:
    """Every resource of `resources` the shape hosts, lowered, one node per
    line; `<id>: NOT_YET` for a type it does not host."""
    var feeds = feeds_of(resources)
    var firings = firings_of(resources)
    var out = String("")
    for r in resources:
        if not shape.hosts(body_field(r)):
            out += r.id + String(": NOT_YET\n")
            continue
        for n in lower_shape(r, edges_for(resources, r), feeds, firings, String("edge"), shape):
            out += _node(n) + String("\n")
    return out^


def _diff(name: String, got: String, want: String) -> String:
    if got == want:
        return String("")
    return String("\n==== ") + name + String(" got:\n") + got


comptime _DATA = (
    '{"id":"b1","bucket":{}},'
    + '{"id":"b2","bucket":{"objectExpiryDays":30,"versioning":true,"tier":"ARCHIVE"}},'
    + '{"id":"t1","table":{"key":{"name":"k","partition":{"name":"id","type":"STRING"}},'
    + '"indexes":[{"name":"by_owner","partition":{"name":"owner","type":"STRING"},'
    + '"order":{"name":"at","type":"NUMBER"}}],"ttlField":"exp"}},'
    + '{"id":"t2","table":{"key":{"name":"k","partition":{"name":"id","type":"STRING"}}}},'
    + '{"id":"r1","registry":{"format":"OCI"},"physicalName":"imgs"},'
    + '{"id":"r2","registry":{"format":"OCI"}},'
    + '{"id":"s1","secret":{}},'
    + '{"id":"q1","queue":{"ackDeadline":"30s","deadLetter":{"resource":"q2"},"maxDeliveries":5}},'
    + '{"id":"q2","queue":{}},'
    + '{"id":"tp","topic":{}},'
    + '{"id":"sb","subscription":{"topic":{"resource":"tp"},"queue":{"resource":"q1"}}},'
    + '{"id":"tp2","topic":{}},{"id":"sb2","subscription":{"topic":{"resource":"tp2"},"queue":{"resource":"q1"}}},'
    + '{"id":"z","dnsZone":{"name":"example.com"}},'
    + '{"id":"z2","dnsZone":{"name":"example.org"},"physicalName":"org"},'
    + '{"id":"rec","dnsRecord":{"name":"www.example.com","zone":{"resource":"z"},"type":"A",'
    + '"values":[{"literal":"192.0.2.1"}],"ttl":"120s"}},'
    + '{"id":"rec2","dnsRecord":{"name":"ip.example.com","zone":{"resource":"z"},"type":"CNAME",'
    + '"values":[{"ref":{"resource":"ip1","standard":"ADDRESS"}}]}},'
    + '{"id":"c1","certificate":{"domains":["*.example.com","example.com"],"zone":{"resource":"z"}}},'
    + '{"id":"c2","certificate":{"domains":["api.example.com"],"zone":{"resource":"z"}},"physicalName":"apic"},'
    + '{"id":"net","network":{"ipv4Cidr":"198.51.100.0/24"}},'
    + '{"id":"sn","subnet":{"network":{"resource":"net"},"ipv4Cidr":"198.51.100.0/25","zone":2}},'
    + '{"id":"sn2","subnet":{"network":{"resource":"net"},"ipv4Cidr":"198.51.100.128/25"},"physicalName":"edge"},'
    + '{"id":"ip1","ipAddress":{}},'
    + '{"id":"ip2","ipAddress":{},"physicalName":"front"}'
)


comptime _WANT_AWS = """b1/bucket AWS::S3::Bucket | expiry_days=never | versioning=false | tier=STANDARD | stores=true
b2/bucket AWS::S3::Bucket | expiry_days=30 | versioning=true | tier=ARCHIVE | stores=true
t1/table AWS::DynamoDB::Table | key=id:STRING | index.by_owner=owner:STRING/at:NUMBER | ttl=exp | named=true
t2/table AWS::DynamoDB::Table | key=id:STRING | ttl=none | named=true
r1/registry AWS::ECR::Repository | format=OCI | out.ADDRESS=registry.fake/imgs
r2/registry AWS::ECR::Repository | format=OCI | out.ADDRESS=registry.fake/r2
s1/secret AWS::SecretsManager::Secret | secret_named=true
q1/queue AWS::SQS::Queue <- q2 | ack_deadline=30s | dead_letter=q2 | max_deliveries=5 | addressed=queue
q1/policy AWS::SQS::QueuePolicy <- q1/queue tp tp2 | topics=tp,tp2
q2/queue AWS::SQS::Queue | ack_deadline=30s | dead_letter=none | max_deliveries=none | addressed=queue
q2/policy AWS::SQS::QueuePolicy (off) <- q2/queue | topics=none
tp/topic AWS::SNS::Topic | addressed=topic
sb/sub AWS::SNS::Subscription <- tp q1 q1/policy | topic=tp | queue=q1
tp2/topic AWS::SNS::Topic | addressed=topic
sb2/sub AWS::SNS::Subscription <- tp2 q1 q1/policy | topic=tp2 | queue=q1
z/zone AWS::Route53::HostedZone | domain=example.com | out.NAME=z-zone
z2/zone AWS::Route53::HostedZone | domain=example.org | out.NAME=org
rec/record AWS::Route53::RecordSet | in: zone=z.NAME | name=www.example.com | type=A | value.0=192.0.2.1 | ttl=120s | out.HOST=www.example.com
rec2/record AWS::Route53::RecordSet | in: zone=z.NAME | in: value.0=ip1.HOST | name=ip.example.com | type=CNAME | ttl=300s | out.HOST=ip.example.com
c1/cert AWS::CertificateManager::Certificate | in: zone=z.NAME | domain.0=*.example.com | domain.1=example.com | out.NAME=c1-cert
c2/cert AWS::CertificateManager::Certificate | in: zone=z.NAME | domain.0=api.example.com | out.NAME=apic
net/network AWS::EC2::VPC | ipv4_cidr=198.51.100.0/24 | out.NAME=net-network
sn/subnet AWS::EC2::Subnet | in: network=net.NAME | ipv4_cidr=198.51.100.0/25 | zone=2 | out.NAME=sn-subnet
sn2/subnet AWS::EC2::Subnet | in: network=net.NAME | ipv4_cidr=198.51.100.128/25 | out.NAME=edge
ip1/address AWS::EC2::EIP | version=IPV4 | out.ADDRESS=ip1.ip.fake
ip2/address AWS::EC2::EIP | version=IPV4 | out.ADDRESS=front.ip.fake
"""


comptime _WANT_GCP = """b1/bucket storage.googleapis.com/Bucket | expiry_days=never | versioning=false | tier=STANDARD | stores=true
b2/bucket storage.googleapis.com/Bucket | expiry_days=30 | versioning=true | tier=ARCHIVE | stores=true
t1/table firestore.googleapis.com/Index | key=id:STRING | named=true
t1/ix-5ztee firestore.googleapis.com/Index | index=by_owner | path=owner:STRING/at:NUMBER
t1/ttl firestore.googleapis.com/Field <- t1/table | ttl=exp
t2/table firestore.googleapis.com/Index | key=id:STRING | named=true
t2/ttl firestore.googleapis.com/Field (off) <- t2/table | ttl=none
r1/registry artifactregistry.googleapis.com/Repository | format=OCI | out.ADDRESS=registry.fake/imgs
r2/registry artifactregistry.googleapis.com/Repository | format=OCI | out.ADDRESS=registry.fake/r2
s1/secret secretmanager.googleapis.com/Secret | secret_named=true
q1/topic pubsub.googleapis.com/Topic (off)
q1/queue pubsub.googleapis.com/Subscription <- q2/topic tp | ack_deadline=30s | dead_letter=q2 | max_deliveries=5 | topic=tp | addressed=queue
q2/topic pubsub.googleapis.com/Topic
q2/queue pubsub.googleapis.com/Subscription <- q2/topic | ack_deadline=30s | dead_letter=none | max_deliveries=none | topic=private | addressed=queue
tp/topic pubsub.googleapis.com/Topic | addressed=topic
sb/sub pubsub.googleapis.com/Subscription (off) <- tp q1 | topic=tp | queue=q1
tp2/topic pubsub.googleapis.com/Topic | addressed=topic
sb2/sub pubsub.googleapis.com/Subscription (off) <- tp2 q1 | topic=tp2 | queue=q1
z/zone dns.googleapis.com/ManagedZone | domain=example.com | out.NAME=z-zone
z2/zone dns.googleapis.com/ManagedZone | domain=example.org | out.NAME=org
rec/record dns.googleapis.com/ResourceRecordSet | in: zone=z.NAME | name=www.example.com | type=A | value.0=192.0.2.1 | ttl=120s | out.HOST=www.example.com
rec2/record dns.googleapis.com/ResourceRecordSet | in: zone=z.NAME | in: value.0=ip1.HOST | name=ip.example.com | type=CNAME | ttl=300s | out.HOST=ip.example.com
c1/dnsauth certificatemanager.googleapis.com/DnsAuthorization | domain=example.com
c1/authrec dns.googleapis.com/ResourceRecordSet <- c1/dnsauth | in: zone=z.NAME | for=example.com
c1/cert certificatemanager.googleapis.com/Certificate <- c1/dnsauth c1/authrec | in: zone=z.NAME | domain.0=*.example.com | domain.1=example.com | out.NAME=c1-cert
c2/dnsauth certificatemanager.googleapis.com/DnsAuthorization | domain=api.example.com
c2/authrec dns.googleapis.com/ResourceRecordSet <- c2/dnsauth | in: zone=z.NAME | for=api.example.com
c2/cert certificatemanager.googleapis.com/Certificate <- c2/dnsauth c2/authrec | in: zone=z.NAME | domain.0=api.example.com | out.NAME=apic
net/network compute.googleapis.com/Network | subnets=custom | out.NAME=net-network
sn/subnet compute.googleapis.com/Subnetwork | in: network=net.NAME | ipv4_cidr=198.51.100.0/25 | out.NAME=sn-subnet
sn2/subnet compute.googleapis.com/Subnetwork | in: network=net.NAME | ipv4_cidr=198.51.100.128/25 | out.NAME=edge
ip1/address compute.googleapis.com/Address | version=IPV4 | out.ADDRESS=ip1.ip.fake
ip2/address compute.googleapis.com/Address | version=IPV4 | out.ADDRESS=front.ip.fake
"""


comptime _WANT_AZURE = """b1/bucket Microsoft.Storage/storageAccounts/blobServices/containers | expiry_days=never | versioning=false | tier=STANDARD | stores=true
b2/bucket Microsoft.Storage/storageAccounts/blobServices/containers | expiry_days=30 | versioning=true | tier=ARCHIVE | stores=true
t1/table Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers | key=id:STRING | index.by_owner=owner:STRING/at:NUMBER | ttl=exp | named=true
t2/table Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers | key=id:STRING | ttl=none | named=true
r1/registry Microsoft.ContainerRegistry/registries | format=OCI | out.ADDRESS=registry.fake/imgs
r2/registry Microsoft.ContainerRegistry/registries | format=OCI | out.ADDRESS=registry.fake/r2
s1/secret Microsoft.KeyVault/vaults/secrets | secret_named=true
q1/queue Microsoft.ServiceBus/namespaces/queues <- q2 | ack_deadline=30s | dead_letter=q2 | max_deliveries=5 | addressed=queue
q2/queue Microsoft.ServiceBus/namespaces/queues | ack_deadline=30s | dead_letter=none | max_deliveries=none | addressed=queue
tp/topic Microsoft.ServiceBus/namespaces/topics | addressed=topic
sb/sub Microsoft.ServiceBus/namespaces/topics/subscriptions <- tp q1 | topic=tp | queue=q1
tp2/topic Microsoft.ServiceBus/namespaces/topics | addressed=topic
sb2/sub Microsoft.ServiceBus/namespaces/topics/subscriptions <- tp2 q1 | topic=tp2 | queue=q1
z/zone Microsoft.Network/dnsZones | domain=example.com | out.NAME=z-zone
z2/zone Microsoft.Network/dnsZones | domain=example.org | out.NAME=org
rec/record Microsoft.Network/dnsZones/A | in: zone=z.NAME | name=www.example.com | type=A | value.0=192.0.2.1 | ttl=120s | out.HOST=www.example.com
rec2/record Microsoft.Network/dnsZones/CNAME | in: zone=z.NAME | in: value.0=ip1.HOST | name=ip.example.com | type=CNAME | ttl=300s | out.HOST=ip.example.com
c1/cert Microsoft.App/managedEnvironments/managedCertificates | in: zone=z.NAME | domain.0=*.example.com | domain.1=example.com | out.NAME=c1-cert
c2/cert Microsoft.App/managedEnvironments/managedCertificates | in: zone=z.NAME | domain.0=api.example.com | out.NAME=apic
net/network Microsoft.Network/virtualNetworks | ipv4_cidr=198.51.100.0/24 | out.NAME=net-network
sn/subnet Microsoft.Network/virtualNetworks/subnets | in: network=net.NAME | ipv4_cidr=198.51.100.0/25 | out.NAME=sn-subnet
sn2/subnet Microsoft.Network/virtualNetworks/subnets | in: network=net.NAME | ipv4_cidr=198.51.100.128/25 | out.NAME=edge
ip1/address Microsoft.Network/publicIPAddresses | version=IPV4 | out.ADDRESS=ip1.ip.fake
ip2/address Microsoft.Network/publicIPAddresses | version=IPV4 | out.ADDRESS=front.ip.fake
"""


comptime _WANT_ONPREM = """b1/bucket minio/Bucket | expiry_days=never | versioning=false | tier=STANDARD | stores=true
b2/bucket minio/Bucket | expiry_days=30 | versioning=true | tier=ARCHIVE | stores=true
t1: NOT_YET
t2: NOT_YET
r1: NOT_YET
r2: NOT_YET
s1/secret vault:kv-v2/metadata | secret_named=true
q1: NOT_YET
q2: NOT_YET
tp: NOT_YET
sb: NOT_YET
tp2: NOT_YET
sb2: NOT_YET
z: NOT_YET
z2: NOT_YET
rec: NOT_YET
rec2: NOT_YET
c1: NOT_YET
c2: NOT_YET
net: NOT_YET
sn: NOT_YET
sn2: NOT_YET
ip1: NOT_YET
ip2: NOT_YET
"""


comptime _WANT_GENERIC = """b1/bucket bucket | expiry_days=never | versioning=false | tier=STANDARD | stores=true
b2/bucket bucket | expiry_days=30 | versioning=true | tier=ARCHIVE | stores=true
t1/table table | key=id:STRING | index.by_owner=owner:STRING/at:NUMBER | ttl=exp | named=true
t2/table table | key=id:STRING | ttl=none | named=true
r1/registry registry | format=OCI | out.ADDRESS=registry.fake/imgs
r2/registry registry | format=OCI | out.ADDRESS=registry.fake/r2
s1/secret secret | secret_named=true
q1/queue queue <- q2 | ack_deadline=30s | dead_letter=q2 | max_deliveries=5 | addressed=queue
q2/queue queue | ack_deadline=30s | dead_letter=none | max_deliveries=none | addressed=queue
tp/topic topic | addressed=topic
sb/sub subscription <- tp q1 | topic=tp | queue=q1
tp2/topic topic | addressed=topic
sb2/sub subscription <- tp2 q1 | topic=tp2 | queue=q1
z/zone zone | domain=example.com | out.NAME=z-zone
z2/zone zone | domain=example.org | out.NAME=org
rec/record record | in: zone=z.NAME | name=www.example.com | type=A | value.0=192.0.2.1 | ttl=120s | out.HOST=www.example.com
rec2/record record | in: zone=z.NAME | in: value.0=ip1.HOST | name=ip.example.com | type=CNAME | ttl=300s | out.HOST=ip.example.com
c1/cert certificate | in: zone=z.NAME | domain.0=*.example.com | domain.1=example.com | out.NAME=c1-cert
c2/cert certificate | in: zone=z.NAME | domain.0=api.example.com | out.NAME=apic
net/network network | ipv4_cidr=198.51.100.0/24 | out.NAME=net-network
sn/subnet subnet | in: network=net.NAME | ipv4_cidr=198.51.100.0/25 | out.NAME=sn-subnet
sn2/subnet subnet | in: network=net.NAME | ipv4_cidr=198.51.100.128/25 | out.NAME=edge
ip1/address address | version=IPV4 | out.ADDRESS=ip1.ip.fake
ip2/address address | version=IPV4 | out.ADDRESS=front.ip.fake
"""


def test_the_data_types_lower_by_their_shape() raises:
    var res = _list(String(_DATA))
    var miss = String("")
    miss += _diff(String("aws"), _lowered(shape_named(String("aws")), res), String(_WANT_AWS))
    miss += _diff(String("gcp"), _lowered(shape_named(String("gcp")), res), String(_WANT_GCP))
    miss += _diff(String("azure"), _lowered(shape_named(String("azure")), res), String(_WANT_AZURE))
    miss += _diff(String("onprem"), _lowered(shape_named(String("onprem")), res), String(_WANT_ONPREM))
    miss += _diff(String("generic"), _lowered(ProviderShape.generic(), res), String(_WANT_GENERIC))
    assert_equal(miss, "")


def test_no_uses_line_on_a_type_that_runs_as_nobody() raises:
    var uses = String(',"uses":[{"target":{"resource":"b1"},"access":"READ"}]}')
    var bodies = [
        String('"bucket":{}'), String('"table":{"key":{"name":"k","partition":{"name":"id","type":"STRING"}}}'),
        String('"queue":{}'), String('"topic":{}'),
        String('"subscription":{"topic":{"resource":"tp"},"queue":{"resource":"q2"}}'), String('"secret":{}'),
        String('"registry":{}'), String('"dnsZone":{"name":"example.com"}'),
        String('"dnsRecord":{"name":"a.example.com","zone":{"resource":"z"},"type":"A","values":[{"literal":"1.2.3.4"}]}'),
        String('"certificate":{"domains":["a.example.com"],"zone":{"resource":"z"}}'),
        String('"network":{"ipv4Cidr":"198.51.100.0/24"}'),
        String('"subnet":{"network":{"resource":"net"},"ipv4Cidr":"198.51.100.0/25"}'), String('"ipAddress":{}'),
    ]
    var got = String("")
    var gcp = shape_named(String("gcp"))
    for b in bodies:
        var r = _list(String('{"id":"x",') + b + uses)[0].copy()
        try:
            _ = lower_shape(r, List[GrantEdge](), feeds_of(List[Resource]()), firings_of(List[Resource]()), String(""), gcp)
            got += String("lowered\n")
        except e:
            got += String(e) + String("\n")
    var want = String("")
    for t in [
        "bucket", "table", "queue", "topic", "subscription", "secret", "registry", "dns_zone", "dns_record",
        "certificate", "network", "subnet", "ip_address",
    ]:
        want += String("fake: ") + t + String(" \"x\" has uses lines; validate refuses them\n")
    assert_equal(got, want)


def main() raises:
    test_the_data_types_lower_by_their_shape()
    test_no_uses_line_on_a_type_that_runs_as_nobody()
