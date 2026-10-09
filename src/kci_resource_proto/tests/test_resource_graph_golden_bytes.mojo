# =============================================================================
# test_resource_graph_golden_bytes.mojo: the bytes of ten resource graphs,
# frozen, so protoc can read them.
# =============================================================================
#
# The other tests of this package hold `kci.resource.v1` to bytes written by
# hand here and to this package's own decoder. Neither is read by anything
# that did not come from this repository. This file freezes the bytes this
# package's encoder writes for ten composed graphs, as `.hex` fixtures; the
# `resource_graph_fixtures` check in BUCK has protoc (which learned the format
# from `resource.proto` alone) decode those bytes to the committed `.txtpb`,
# and encode that text to the committed `.canonical.hex`. A symmetric defect,
# one this encoder and this decoder share, round-trips here and is caught
# there.
#
# THE CORPUS. Each graph is authored as proto3 JSON, the form an author
# writes and the one kci reads (`decode_json[ResourceList]`), then encoded
# with `encode_proto`. Between them the ten graphs set every field of every
# message of `resource.proto` at least once, to a value other than its
# default (a field at its default is not on protoc's side of the wire, so it
# would check nothing), and every `Resource.body` arm:
#
#   service_graph   a public service (`api`): every `Service` field, an image
#                   by digest and platform, env values of all three `Value`
#                   arms, a secret pinned by store and version, a request
#                   timeout with nanoseconds, cell uses; its consumer (`web`):
#                   an internal service on an image from a build step, env
#                   refs by standard and by named output, `Scale.min` set to
#                   zero (presence: protoc must print it); the identity
#                   `api` runs as; and grants between them, one on a target
#                   and one on a cell.
#   job_bucket_graph  a container job (every `ContainerJob` field, a
#                   `command` among them), a second one with `max_retries`
#                   set to zero (presence again), a bucket
#                   and a table kept on delete (`Retention.KEEP`) with every
#                   `Bucket` and `Table` field, the job's identity, and three
#                   grants from it.
#   messaging_graph  a queue kept on delete with every `Queue` field set (an
#                   ack deadline, a dead-letter queue, max deliveries), its
#                   dead-letter queue, a topic, the subscription that feeds
#                   the queue from the topic, an identity that RECEIVEs from
#                   the queue, and a grant that lets it SEND to the topic.
#   secret_graph    a secret kept on delete and one deleted (`Retention`
#                   written both ways), a service that receives both by
#                   `SecretRef.secret` (one pinned to a version) and READs
#                   both, an identity that may READ_WRITE one, and a grant
#                   that lets it WRITE the other.
#   dns_graph       a DNS zone kept on delete (every `DnsZone` field), a
#                   service, a CNAME record that follows the service's HOST
#                   with a TTL (every `DnsRecord` field), an MX record with
#                   two values, and a certificate for the zone's name and
#                   its wildcard (every `Certificate` field), deleted with
#                   its resource.
#   compute_graph   a worker that RECEIVEs from a queue (every `Worker`
#                   field, a `Size` with `gpus`), the identity it runs as,
#                   the queue, and a service with a `command` and a GPU.
#   trigger_graph   a container job started by a schedule with a time zone,
#                   a service called by a schedule in UTC (every `Schedule`
#                   field), and a bucket whose new objects an event trigger
#                   delivers to the service (every `EventTrigger` field).
#   network_graph   a network kept on delete (every `Network` field), a
#                   subnet of it in a zone (every `Subnet` field), an IP
#                   address, and a service whose outbound connections leave
#                   through the subnet (`Service.network`) and that reads
#                   the address's ADDRESS.
#   registry_graph  a registry of OCI artifacts kept on delete (every
#                   `Registry` field), a container job that pushes to it
#                   (WRITE) and reads its ADDRESS, and an identity that
#                   pulls from it (READ) through a grant.
#   metadata_graph  a bucket kept on delete under a cloud name of the
#                   author's, adopted, with two labels (every metadata field
#                   of `Resource`), an identity with one label and a
#                   written-empty cloud name (presence: protoc must print
#                   it), and a grant that lets it READ the bucket.
#
# Map keys are authored in sorted order. protoc prints and re-encodes a map
# sorted by key, and this encoder writes a map in insertion order, so a
# sorted authoring is what lets LEG D compare the canonical bytes' re-encoding
# with the frozen bytes.
#
# WHAT IS ASSERTED, per graph:
#   LEG A  `encode_proto` of the graph is `<name>.hex`, byte for byte. Any
#          encoder change that moves a byte fails here, including one that
#          still round-trips.
#   LEG B  `<name>.hex` decodes, through this package, to the graph authored
#          (compared as proto3 JSON). LEG A alone would hold if the corpus
#          and the fixture were both replaced.
#   LEG C  the graph is not trivial: it holds the resources authored, and its
#          bytes are longer than its resource ids alone.
#   LEG D  `<name>.canonical.hex`, protoc's own encoding of the graph, decodes
#          through this package to the same graph: re-encoded, it is the
#          frozen `<name>.hex`. This is the direction a producer in another
#          language takes; protoc omits every default this encoder writes, so
#          the two byte strings differ and the decoder reads both.
#
# REGOLDING. `main` first prints each graph's bytes between
# `GOLDEN-BEGIN <name>` and `GOLDEN-END <name>`, pass or fail. Copy them to
# `tests/fixtures/graph/<name>.hex`; take `<name>.txtpb` from protoc's decode
# (the check's LEG 1 failure prints it) and `<name>.canonical.hex` from the
# `graph_<name>_canonical` target (BUCK says how). A moved `.hex` is a wire
# format change: read the diff before you overwrite it.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.resource import ResourceList


# =============================================================================
# The corpus. Every value below is published once its `.hex` is committed.
# =============================================================================

comptime _SERVICE_GRAPH = (
    '{"resource":['
    # The identity the public service runs as.
    + '{"id":"api-runner","retention":"DELETE","serviceAccount":{}},'
    # The public service. Every Service field is set.
    + '{"id":"api","retention":"DELETE",'
    + '"uses":[{"access":"WRITE","cell":"LOGS"},'
    + '{"access":"WRITE","cell":"METRICS"}],'
    + '"service":{'
    + '"image":{"digest":"sha256:5f1d0c9a","platform":"linux/amd64"},'
    + '"port":8443,'
    + '"args":["serve","--listen=:8443"],'
    + '"env":{"API_ORIGIN":{"ref":{"resource":"api","standard":"URL"}},'
    + '"LOG_LEVEL":{"literal":"info"},'
    + '"REGION":{"param":"region"}},'
    + '"size":{"cpuMillis":1500,"memoryMb":2048},'
    + '"scale":{"min":2,"max":12},'
    + '"healthPath":"/healthz",'
    + '"requestTimeout":"45.250s",'
    + '"maxConcurrency":80,'
    + '"public":{},'
    + '"secretEnv":{"DB_PASSWORD":{"name":"api-db-password",'
    + '"store":"primary","version":"7"}},'
    + '"runAs":{"resource":"api-runner"}}},'
    # Its consumer: internal, built from a step, scaled to zero.
    + '{"id":"web","retention":"DELETE",'
    + '"uses":[{"target":{"resource":"api","standard":"URL"},"access":"CALL"}],'
    + '"service":{'
    + '"image":{"output":{"step":"build-web","name":"image"},'
    + '"platform":"linux/arm64"},'
    + '"port":3000,'
    + '"args":["--upstream-from-env"],'
    + '"env":{"API_HOST":{"ref":{"resource":"api","standard":"HOST"}},'
    + '"API_URL":{"ref":{"resource":"api","named":"grpc-url"}}},'
    + '"scale":{"min":0,"max":4},'
    + '"internal":{},'
    + '"secretEnv":{"SESSION_KEY":{"name":"web-session-key"}}}},'
    # The grants between them: one on a target, one on a cell.
    + '{"id":"web-calls-api","grant":{"principal":{"resource":"web"},'
    + '"target":{"resource":"api","standard":"URL"},"access":"CALL"}},'
    + '{"id":"api-reads-artifacts","grant":{"principal":{"resource":"api-runner"},'
    + '"access":"DESCRIBE","cell":"ARTIFACTS"}}'
    + "]}"
)

comptime _JOB_BUCKET_GRAPH = (
    '{"resource":['
    + '{"id":"nightly-runner","retention":"DELETE","serviceAccount":{}},'
    # The bucket, kept when the graph is deleted. Every Bucket field is set.
    + '{"id":"exports","retention":"KEEP",'
    + '"bucket":{"objectExpiryDays":400,"versioning":true,"tier":"INFREQUENT"}},'
    # A table, also kept. Every Table, AccessPath and Field field is set.
    + '{"id":"events","retention":"KEEP","table":{'
    + '"key":{"name":"by_tenant","partition":{"name":"tenant","type":"STRING"},'
    + '"order":{"name":"at","type":"NUMBER"}},'
    + '"indexes":[{"name":"by_digest",'
    + '"partition":{"name":"digest","type":"BYTES"},'
    + '"order":{"name":"seq","type":"NUMBER"}}],'
    + '"ttlField":"expires_at"}},'
    # A container job. Every ContainerJob field is set.
    + '{"id":"nightly","retention":"DELETE",'
    + '"uses":[{"target":{"resource":"exports","standard":"NAME"},'
    + '"access":"READ_WRITE"},'
    + '{"target":{"resource":"events","standard":"ADDRESS"},"access":"READ"},'
    + '{"access":"READ","cell":"ARTIFACTS"}],'
    + '"containerJob":{'
    + '"image":{"digest":"sha256:9e27b4aa","platform":"linux/arm64"},'
    + '"args":["export","--since=24h"],'
    + '"size":{"cpuMillis":4000,"memoryMb":8192},'
    + '"maxRetries":3,'
    + '"timeout":"5400s",'
    + '"env":{"BUCKET":{"ref":{"resource":"exports","standard":"ADDRESS"}},'
    + '"TENANT":{"param":"tenant"}},'
    + '"secretEnv":{"EXPORT_TOKEN":{"name":"export-token","version":"3"}},'
    + '"runAs":{"resource":"nightly-runner"},'
    + '"command":["/usr/bin/exporter","--quiet"]}},'
    # A job that is never retried: `maxRetries` zero, present.
    + '{"id":"reindex","retention":"DELETE","containerJob":{'
    + '"image":{"output":{"step":"build-reindex","name":"oci"}},'
    + '"maxRetries":0,'
    + '"runAs":{"resource":"nightly-runner"}}},'
    # The grants from the job's identity.
    + '{"id":"nightly-writes-exports","grant":{'
    + '"principal":{"resource":"nightly-runner"},'
    + '"target":{"resource":"exports","named":"bucket-uri"},'
    + '"access":"WRITE"}},'
    + '{"id":"nightly-reads-events","grant":{'
    + '"principal":{"resource":"nightly-runner"},'
    + '"target":{"resource":"events","standard":"NAME"},"access":"READ"}},'
    + '{"id":"nightly-writes-logs","grant":{'
    + '"principal":{"resource":"nightly-runner"},'
    + '"access":"WRITE","cell":"LOGS"}}'
    + "]}"
)


comptime _MESSAGING_GRAPH = (
    '{"resource":['
    # The receiver's identity: RECEIVE on the queue.
    + '{"id":"rx","serviceAccount":{},'
    + '"uses":[{"target":{"resource":"work"},"access":"RECEIVE"}]},'
    # The dead-letter queue, then the queue. Every Queue field is set.
    + '{"id":"dl","retention":"DELETE","queue":{}},'
    + '{"id":"work","retention":"KEEP","queue":{"ackDeadline":"45s",'
    + '"deadLetter":{"resource":"dl"},"maxDeliveries":7}},'
    # The topic, and the subscription that feeds the queue from it.
    + '{"id":"ev","retention":"DELETE","topic":{}},'
    + '{"id":"ev-work","subscription":{"topic":{"resource":"ev"},'
    + '"queue":{"resource":"work"}}},'
    # A grant: the identity may SEND to the topic.
    + '{"id":"rx-send","grant":{"principal":{"resource":"rx"},'
    + '"target":{"resource":"ev"},"access":"SEND"}}'
    + "]}"
)


comptime _SECRET_GRAPH = (
    '{"resource":['
    # Two secrets: one kept on delete, one deleted with its resource.
    + '{"id":"db","retention":"KEEP","secret":{}},'
    + '{"id":"token","retention":"DELETE","secret":{}},'
    # A service that receives both by reference and may READ both.
    + '{"id":"api","service":{"image":{"digest":"sha256:5ec2"},"internal":{},'
    + '"secretEnv":{"DB_PASSWORD":{"version":"2","secret":{"resource":"db"}},'
    + '"TOKEN":{"secret":{"resource":"token"}}}},'
    + '"uses":[{"target":{"resource":"db"},"access":"READ"},'
    + '{"target":{"resource":"token"},"access":"READ"}]},'
    # The identity that rotates them: READ_WRITE one, a grant to WRITE the other.
    + '{"id":"rotator","serviceAccount":{},'
    + '"uses":[{"target":{"resource":"token"},"access":"READ_WRITE"}]},'
    + '{"id":"rotator-db","grant":{"principal":{"resource":"rotator"},'
    + '"target":{"resource":"db"},"access":"WRITE"}}'
    + "]}"
)


comptime _DNS_GRAPH = (
    '{"resource":['
    # A zone, kept on delete.
    + '{"id":"site","retention":"KEEP","dnsZone":{"name":"example.com"}},'
    # The service the CNAME follows.
    + '{"id":"api","service":{"image":{"digest":"sha256:d0e5"},"internal":{}}},'
    # A CNAME to the service's HOST, with a TTL; an MX with two values.
    + '{"id":"www","dnsRecord":{"name":"www.example.com","zone":{"resource":"site"},'
    + '"type":"CNAME","values":[{"ref":{"resource":"api","standard":"HOST"}}],"ttl":"600s"}},'
    + '{"id":"mx","dnsRecord":{"name":"example.com","zone":{"resource":"site"},"type":"MX",'
    + '"values":[{"literal":"10 mail.example.com"},{"literal":"20 backup.example.com"}]}},'
    # A certificate for the zone's name and its wildcard, deleted with it.
    + '{"id":"tls","retention":"DELETE","certificate":{"domains":["example.com","*.example.com"],'
    + '"zone":{"resource":"site"}}}'
    + "]}"
)


comptime _COMPUTE_GRAPH = (
    '{"resource":['
    # The identity the worker runs as; the queue it receives from.
    + '{"id":"relay-runner","serviceAccount":{},'
    + '"uses":[{"target":{"resource":"work"},"access":"RECEIVE"}]},'
    + '{"id":"work","queue":{}},'
    # The worker. Every Worker field is set, and every Size field.
    + '{"id":"relay","worker":{'
    + '"image":{"digest":"sha256:7a11c0de","platform":"linux/amd64"},'
    + '"size":{"cpuMillis":500,"memoryMb":1024,"gpus":1},'
    + '"args":["--queue=work"],'
    + '"command":["/bin/relay","--drain"],'
    + '"env":{"MODE":{"literal":"drain"},'
    + '"QUEUE":{"ref":{"resource":"work","standard":"ADDRESS"}}},'
    + '"secretEnv":{"TOKEN":{"name":"relay-token"}},'
    + '"replicas":3,'
    + '"runAs":{"resource":"relay-runner"}}},'
    # A service with a command of its own and two GPUs per instance.
    + '{"id":"infer","service":{"image":{"digest":"sha256:1f2e3d4c"},'
    + '"size":{"cpuMillis":8000,"memoryMb":32768,"gpus":2},'
    + '"internal":{},"command":["/opt/serve","--model=/m"]}}'
    + "]}"
)

comptime _TRIGGER_GRAPH = (
    '{"resource":['
    # What the triggers start and call, and the bucket whose events they
    # deliver.
    + '{"id":"nightly","containerJob":{'
    + '"image":{"digest":"sha256:0b7e5a11","platform":"linux/amd64"}}},'
    + '{"id":"thumbs","service":{"image":{"digest":"sha256:9c41d2e8"},'
    + '"port":8080,"internal":{}}},'
    + '{"id":"uploads","bucket":{"versioning":true}},'
    # Every Schedule field: a job started at 02:30 Paris time on weekdays,
    # and a service called every quarter hour in UTC.
    + '{"id":"nightly-at-2","schedule":{"cron":"30 2 * * 1-5",'
    + '"timezone":"Europe/Paris","target":{"resource":"nightly"}}},'
    + '{"id":"warm-thumbs","schedule":{"cron":"*/15 * * * *",'
    + '"target":{"resource":"thumbs"}}},'
    # Every EventTrigger field.
    + '{"id":"on-upload","eventTrigger":{"source":{"resource":"uploads"},'
    + '"event":"OBJECT_CREATED","target":{"resource":"thumbs"}}}'
    + "]}"
)

comptime _NETWORK_GRAPH = (
    '{"resource":['
    # Every Network field, kept on delete.
    + '{"id":"core","retention":"KEEP","network":{"ipv4Cidr":"10.20.0.0/16"}},'
    # Every Subnet field.
    + '{"id":"edge","subnet":{"network":{"resource":"core"},'
    + '"ipv4Cidr":"10.20.4.0/24","zone":2}},'
    + '{"id":"ingress-ip","ipAddress":{}},'
    # A service whose outbound connections leave through the subnet.
    + '{"id":"api","service":{"image":{"digest":"sha256:7a3c9e10"},'
    + '"env":{"PUBLIC_IP":{"ref":{"resource":"ingress-ip","standard":"ADDRESS"}}},'
    + '"internal":{},"network":{"resource":"edge"}}}'
    + "]}"
)

comptime _REGISTRY_GRAPH = (
    '{"resource":['
    # Every Registry field, kept on delete.
    + '{"id":"images","retention":"KEEP","registry":{"format":"OCI"}},'
    # A container job that pushes to it and reads its ADDRESS.
    + '{"id":"builder","uses":[{"target":{"resource":"images"},"access":"WRITE"}],'
    + '"containerJob":{"image":{"digest":"sha256:5e1f0a22"},'
    + '"env":{"REGISTRY":{"ref":{"resource":"images","standard":"ADDRESS"}}}}},'
    # An identity that pulls from it, through a grant.
    + '{"id":"puller","serviceAccount":{}},'
    + '{"id":"pull-images","grant":{"principal":{"resource":"puller"},'
    + '"target":{"resource":"images"},"access":"READ"}}'
    + "]}"
)

comptime _METADATA_GRAPH = (
    '{"resource":['
    # Every metadata field of Resource, on a bucket kept on delete.
    + '{"id":"logs","retention":"KEEP","physicalName":"acme-logs",'
    + '"labels":{"team":"data","tier":"gold"},"adopt":true,"bucket":{}},'
    # A written-empty cloud name (presence) and one label.
    + '{"id":"reader","physicalName":"","labels":{"team":"data"},"serviceAccount":{}},'
    + '{"id":"read-logs","grant":{"principal":{"resource":"reader"},'
    + '"target":{"resource":"logs"},"access":"READ"}}'
    + "]}"
)


# =============================================================================
# The `.hex` format (tools/build/mojo/README.md, "Wire fixtures"): lowercase,
# 32 bytes a line, no offsets, so a one-byte change is one changed line.
# =============================================================================

comptime _FIXTURE_DIR = "fixtures/"
comptime _HEX_BYTES_PER_LINE = 32


def _nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(bytes)):
        out += _nibble(bytes[i] >> 4)
        out += _nibble(bytes[i] & 0xF)
        if i % _HEX_BYTES_PER_LINE == _HEX_BYTES_PER_LINE - 1:
            out += "\n"
    if len(bytes) % _HEX_BYTES_PER_LINE != 0:
        out += "\n"
    return out^


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + 10
    raise Error(
        "resource graph golden: a `.hex` fixture holds a non-hex byte "
        + String(Int(c))
    )


def _from_hex(text: String) raises -> List[UInt8]:
    var nibbles = List[UInt8]()
    for c in text.as_bytes():
        if (
            c == UInt8(ord(" "))
            or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r"))
            or c == UInt8(ord("\t"))
        ):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error(
            "resource graph golden: a `.hex` fixture has an odd number of"
            + " hex digits ("
            + String(len(nibbles))
            + ")"
        )
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(file: String) raises -> List[UInt8]:
    """`fixtures/<file>`, staged by BUCK's `test_data` under the test's
    current directory."""
    var path = _FIXTURE_DIR + file
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        raise Error(
            "resource graph golden: fixture `"
            + path
            + "` is missing. For a new graph, the GOLDEN block printed above"
            + " is its content; otherwise something removed a committed"
            + " fixture, and protoc now reads one graph fewer."
        )
    return _from_hex(text)


def _assert_same_bytes(
    got: List[UInt8], want: List[UInt8], what: String
) raises:
    """Equal length, then the first differing offset (-1: none)."""
    assert_equal(
        len(got),
        len(want),
        what + ": the lengths differ (" + String(len(got)) + " vs "
        + String(len(want)) + " bytes)",
    )
    var first = -1
    for i in range(len(want)):
        if got[i] != want[i]:
            first = i
            break
    var at = first if first >= 0 else 0
    assert_equal(
        first,
        -1,
        what
        + ": first difference at offset "
        + String(first)
        + " (got "
        + String(Int(got[at]))
        + ", want "
        + String(Int(want[at]))
        + ")",
    )


# =============================================================================
# The legs
# =============================================================================


def _assert_frozen(name: String, json: String, n_resources: Int) raises:
    var graph = decode_json[ResourceList](json)
    var authored = encode_json(graph)
    var bytes = encode_proto(graph)

    # LEG C: the graph holds what was authored, and its bytes are more
    # than its ids.
    assert_equal(
        len(graph.resource),
        n_resources,
        name + ": LEG C: the graph decoded from its JSON holds the wrong"
        + " number of resources",
    )
    var id_bytes = 0
    for i in range(len(graph.resource)):
        id_bytes += graph.resource[i].id.byte_length()
    assert_true(
        len(bytes) > 4 * id_bytes,
        name + ": LEG C: " + String(len(bytes)) + " bytes for "
        + String(id_bytes) + " bytes of resource ids: the bodies are missing",
    )

    # LEG A: the encoder's bytes are the frozen bytes.
    var want = _read_fixture(name + ".hex")
    _assert_same_bytes(
        bytes,
        want,
        name
        + ": LEG A: encode_proto no longer writes "
        + name
        + ".hex. That is a wire format change; if it was meant, regold"
        + " from the GOLDEN block above and redo the .txtpb and"
        + " .canonical.hex",
    )

    # LEG B: the frozen bytes (not the bytes just encoded) mean the graph.
    var back = decode_proto[ResourceList](want^)
    assert_equal(
        encode_json(back),
        authored,
        name + ": LEG B: " + name + ".hex decodes to a different graph than"
        + " the one authored",
    )

    # LEG D: protoc's encoding of the same graph is read back to it.
    var canonical = _read_fixture(name + ".canonical.hex")
    assert_true(
        len(canonical) < len(bytes),
        name + ": LEG D: " + name + ".canonical.hex is not shorter than "
        + name + ".hex. protoc omits every default this encoder writes,"
        + " so its bytes are shorter; equal or longer means they are not"
        + " protoc's encoding of this graph",
    )
    var foreign = decode_proto[ResourceList](canonical^)
    assert_equal(
        encode_json(foreign),
        authored,
        name + ": LEG D: this package reads protoc's encoding of the graph"
        + " as a different graph",
    )
    _assert_same_bytes(
        encode_proto(foreign),
        bytes,
        name + ": LEG D: protoc's encoding of the graph, read here and"
        + " written again, is not the frozen bytes",
    )
    print("  " + name + ": PASS")


def _print_golden(name: String, json: String) raises:
    """The block a fixture is copied from. `main` prints every graph's block
    before any leg runs, so a missing fixture of the first graph does not
    hide the block of the second."""
    print("GOLDEN-BEGIN " + name)
    print(_to_hex_lines(encode_proto(decode_json[ResourceList](json))), end="")
    print("GOLDEN-END " + name)


def test_service_graph_bytes_are_frozen() raises:
    _assert_frozen("service_graph", _SERVICE_GRAPH, 5)


def test_job_bucket_graph_bytes_are_frozen() raises:
    _assert_frozen("job_bucket_graph", _JOB_BUCKET_GRAPH, 8)


def test_messaging_graph_bytes_are_frozen() raises:
    _assert_frozen("messaging_graph", _MESSAGING_GRAPH, 6)


def test_secret_graph_bytes_are_frozen() raises:
    _assert_frozen("secret_graph", _SECRET_GRAPH, 5)


def test_dns_graph_bytes_are_frozen() raises:
    _assert_frozen("dns_graph", _DNS_GRAPH, 5)


def test_compute_graph_bytes_are_frozen() raises:
    _assert_frozen("compute_graph", _COMPUTE_GRAPH, 4)


def test_trigger_graph_bytes_are_frozen() raises:
    _assert_frozen("trigger_graph", _TRIGGER_GRAPH, 6)


def test_network_graph_bytes_are_frozen() raises:
    _assert_frozen("network_graph", _NETWORK_GRAPH, 4)


def test_registry_graph_bytes_are_frozen() raises:
    _assert_frozen("registry_graph", _REGISTRY_GRAPH, 4)


def test_metadata_graph_bytes_are_frozen() raises:
    _assert_frozen("metadata_graph", _METADATA_GRAPH, 3)


def main() raises:
    print("test_resource_graph_golden_bytes")
    _print_golden("service_graph", _SERVICE_GRAPH)
    _print_golden("job_bucket_graph", _JOB_BUCKET_GRAPH)
    _print_golden("messaging_graph", _MESSAGING_GRAPH)
    _print_golden("secret_graph", _SECRET_GRAPH)
    _print_golden("dns_graph", _DNS_GRAPH)
    _print_golden("compute_graph", _COMPUTE_GRAPH)
    _print_golden("trigger_graph", _TRIGGER_GRAPH)
    _print_golden("network_graph", _NETWORK_GRAPH)
    _print_golden("registry_graph", _REGISTRY_GRAPH)
    _print_golden("metadata_graph", _METADATA_GRAPH)
    test_service_graph_bytes_are_frozen()
    test_job_bucket_graph_bytes_are_frozen()
    test_messaging_graph_bytes_are_frozen()
    test_secret_graph_bytes_are_frozen()
    test_dns_graph_bytes_are_frozen()
    test_compute_graph_bytes_are_frozen()
    test_trigger_graph_bytes_are_frozen()
    test_network_graph_bytes_are_frozen()
    test_registry_graph_bytes_are_frozen()
    test_metadata_graph_bytes_are_frozen()
    print("ALL kci.resource.v1 GRAPH GOLDEN-BYTES TESTS PASSED")
