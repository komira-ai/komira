# =============================================================================
# test_cloud_shape_limits.mojo
# =============================================================================
#
# `shape_limits` (shape/lower.mojo): every limit a built-in shape refuses of
# one resource, from the shape's data, each with its text and its field:
#
# 1. ONE GRAPH ON EVERY SHAPE, each finding a golden line: a request timeout
#    and a job timeout above their caps, a scale whose max is below its min
#    (every shape); a cell edge of another resource's identity (onprem,
#    which folds cell edges); two indexes whose `ix-<h>` roles collide (gcp,
#    whose indexes are objects); more labels than the shape leaves the
#    author, a name a kind does not take, a name too short, a `-` in a name
#    of letters and digits, a name on a folded schedule; a queue fed twice,
#    a dead letter to a fed queue and a SEND to one (gcp's pull queues); a
#    certificate of two names or a wildcard (azure), or of a name its DNS
#    authorization does not cover (gcp); a cron naming both days (aws), a
#    schedule of a service (onprem), a second schedule of one job and one
#    not in UTC (azure); a GPU, a service that may scale to zero (onprem);
#    a subnet with no zone (aws), a service in a subnet (azure).
# 1b. A DEAD LETTER TO A QUEUE FED BY ONE TOPIC (gcp): one feed is enough.
# 2. WHAT IS NOT A LIMIT stays quiet: a resource with no type, a schedule
#    whose target is not in the list, a certificate with no name, the same
#    index name twice, a cell edge of the resource's own identity, a name on
#    a schedule that does not fold, and the edges of a resource that runs as
#    nobody (validate's finding, not a limit).
#
# The two index names were found by a birthday search: `role_hash` of
# "by_1412" and of "by_5285" are both "wfsep".
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Finding, KCI_LABELS_MAX, ProviderShape, feeds_of, firings_of, index_role, shape_limits, shape_named


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](String('{"resource":[') + json + String("]}")).resource.copy()


def _limits(shape: ProviderShape, resources: List[Resource]) -> String:
    """Every finding of every resource, one per line: `id field: reason`."""
    var feeds = feeds_of(resources)
    var firings = firings_of(resources)
    var out = String("")
    for r in resources:
        var f = List[Finding]()
        shape_limits(r, feeds, firings, shape, shape.name, f)
        for x in f:
            out += x.resource_id + String(" ") + x.field_path + String(": ") + x.reason + String("\n")
    return out^


def _diff(name: String, got: String, want: String) -> String:
    if got == want:
        return String("")
    return String("\n==== ") + name + String(" got:\n") + got


def _labels(n: Int) -> String:
    var s = String('"labels":{')
    for i in range(n):
        if i > 0:
            s += String(",")
        s += String('"l') + String(i) + String('":"v"')
    return s + String("}")


def _graph() -> String:
    return (
        String('{"id":"gr","grant":{"principal":{"resource":"api"},"cell":"LOGS","access":"WRITE"}},')
        + String('{"id":"jb","containerJob":{"image":{"digest":"sha256:j1"},"runAs":{"resource":"sa"},')
        + String('"timeout":"86401s","size":{"cpuMillis":500,"memoryMb":256,"gpus":1}},')
        + String('"uses":[{"cell":"METRICS","access":"WRITE"}]},')
        + String('{"id":"sa","serviceAccount":{}},')
        + String('{"id":"tb","table":{"key":{"name":"k","partition":{"name":"id","type":"STRING"}},"indexes":[')
        + String('{"name":"by_1412","partition":{"name":"a","type":"STRING"}},')
        + String('{"name":"by_5285","partition":{"name":"b","type":"STRING"}},')
        + String('{"name":"by_1412","partition":{"name":"c","type":"STRING"}}]}},')
        + String('{"id":"tb2","table":{"key":{"name":"k","partition":{"name":"id","type":"STRING"}},"indexes":[')
        + String('{"name":"by_x","partition":{"name":"a","type":"STRING"}},')
        + String('{"name":"by_x","partition":{"name":"b","type":"STRING"}}]}},')
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"requestTimeout":"3601s",')
        + String('"scale":{"min":5,"max":2},"network":{"resource":"sn"}},')
        + String('"uses":[{"target":{"resource":"q1"},"access":"SEND"},{"target":{"resource":"tb"},"access":"READ"},')
        + String('{"cell":"LOGS","access":"WRITE"},{"target":{"resource":"qd"},"access":"SEND"}]},')
        + String('{"id":"zero","service":{"image":{"digest":"sha256:z1"}},') + _labels(KCI_LABELS_MAX + 35) + String("},")
        + String('{"id":"z","dnsZone":{"name":"example.com"},"physicalName":"zone1"},')
        + String('{"id":"bk","bucket":{},"physicalName":"ab"},')
        + String('{"id":"rg","registry":{},"physicalName":"my-reg"},')
        + String('{"id":"tp","topic":{},"physicalName":"events"},')
        + String('{"id":"nobody","physicalName":"x"},')
        + String('{"id":"tp1","topic":{}},{"id":"tp2","topic":{}},{"id":"q1","queue":{}},')
        + String('{"id":"sb1","subscription":{"topic":{"resource":"tp1"},"queue":{"resource":"q1"}}},')
        + String('{"id":"sb2","subscription":{"topic":{"resource":"tp2"},"queue":{"resource":"q1"}}},')
        + String('{"id":"qd","queue":{"deadLetter":{"resource":"q1"}}},')
        + String('{"id":"c1","certificate":{"domains":["*.example.com","example.com"],"zone":{"resource":"z"}}},')
        + String('{"id":"c2","certificate":{"domains":["example.com","*.example.com","other.org"],')
        + String('"zone":{"resource":"z"}}},')
        + String('{"id":"c3","certificate":{"zone":{"resource":"z"}}},')
        + String('{"id":"s1","schedule":{"cron":"0 3 1 * 1","target":{"resource":"jb"}},"physicalName":"nightly"},')
        + String('{"id":"s2","schedule":{"cron":"0 4 * * *","timezone":"Europe/Paris","target":{"resource":"jb"}}},')
        + String('{"id":"s3","schedule":{"cron":"*/5 * * * *","target":{"resource":"api"}},"physicalName":"ping"},')
        + String('{"id":"bu","bucket":{},"uses":[{"cell":"LOGS","access":"WRITE"}]},')
        + String('{"id":"s4","schedule":{"cron":"0 5 * * *","target":{"resource":"gone"}}},')
        + String('{"id":"net","network":{"ipv4Cidr":"198.51.100.0/24"}},')
        + String('{"id":"sn","subnet":{"network":{"resource":"net"},"ipv4Cidr":"198.51.100.0/25"}}')
    )


comptime _WANT_AWS = """jb container_job.timeout: above this cloud's job limit of 86400s
jb container_job.size.gpus: on cloud "aws" a workload cannot ask for a GPU: a service here is a Lambda function, which runs on no GPU, and an ECS task (a container job, a worker) has one only on a launch type with GPUs, which is not decided yet
api service.request_timeout: above this cloud's request limit of 3600s
api service.scale: max is below min
zero labels: on cloud "aws" an object carries 50 labels, 8 of them kci's: at most 42 of the author's; this resource writes 43
z physical_name: on cloud "aws" this kind has no name an author chooses: a hosted zone is its domain and an id the cloud assigns
bk physical_name: on cloud "aws" this kind's name is 3 to 63 bytes; "ab" is 2
s1 schedule.cron: on cloud "aws" a cron cannot name both a day of the month and a day of the week: EventBridge Scheduler's cron takes a day of the month or a day of the week, never both
sn subnet.zone: on cloud "aws" a subnet is in one zone: an EC2 subnet is in one availability zone; write its zone (1 to 3)
"""


comptime _WANT_GCP = """gr grant: cloud "gcp" derives a binding's stamp from its principal, so a binding cannot be owned by a grant resource: write a uses line on the principal instead (same target, same access)
jb container_job.timeout: above this cloud's job limit of 86400s
jb container_job.size.gpus: on cloud "gcp" a workload cannot ask for a GPU: which GPU this cloud attaches to a workload is not decided yet (a design decision that is still open), so no workload may ask for one
jb uses: cloud "gcp" derives a binding's stamp from its principal, so a uses line on a workload that runs as "sa" cannot be owned by the workload: write the uses line on "sa" itself
tb table.indexes: on cloud "gcp" each index is an object named by its role, and index "by_5285" has the role ix-wfsep of an earlier index; rename one of them
tb table.indexes: on cloud "gcp" each index is an object named by its role, and index "by_1412" has the role ix-wfsep of an earlier index; rename one of them
api service.request_timeout: above this cloud's request limit of 3600s
api service.scale: max is below min
api uses[0]: on cloud "gcp" queue "q1" is a pull subscription on topic "tp1" (subscription "sb1"), so nothing sends to it directly; send to "tp1"
bk physical_name: on cloud "gcp" this kind's name is 3 to 63 bytes; "ab" is 2
sb2 subscription.queue: on cloud "gcp" a queue is one pull subscription on one topic, and queue "q1" is already fed from topic "tp1" by "sb1"
qd queue.dead_letter: on cloud "gcp" a queue dead-letters to the private topic of its dead-letter queue, and "q1" has none: it is fed from topic "tp1"
c2 certificate.domains[2]: on cloud "gcp" a certificate is validated by one DNS authorization, for one name and its wildcard; "other.org" is neither "example.com" nor "*.example.com"
"""


comptime _WANT_AZURE = """jb container_job.timeout: above this cloud's job limit of 86400s
jb container_job.size.gpus: on cloud "azure" a workload cannot ask for a GPU: which GPU this cloud attaches to a workload is not decided yet (a design decision that is still open), so no workload may ask for one
api service.request_timeout: above this cloud's request limit of 3600s
api service.scale: max is below min
api service.network: on cloud "azure" a service cannot be placed in a subnet: a container app joins a network through its environment, which the cell holds, never one app at a time
zero labels: on cloud "azure" an object carries 50 labels, 8 of them kci's: at most 42 of the author's; this resource writes 43
z physical_name: on cloud "azure" this kind has no name an author chooses: a DNS zone is named by its domain
bk physical_name: on cloud "azure" this kind's name is 3 to 63 bytes; "ab" is 2
rg physical_name: on cloud "azure" this kind's name is letters and digits only: "my-reg" holds '-'
c1 certificate.domains: on cloud "azure" a certificate covers one name; write one certificate per name
c1 certificate.domains[0]: on cloud "azure" a certificate cannot be a wildcard
c2 certificate.domains: on cloud "azure" a certificate covers one name; write one certificate per name
s1 physical_name: on cloud "azure" a schedule of a container job is the job's own schedule: it has no object to name
s2 schedule.target: on cloud "azure" a container job's schedule is a setting of the job, and "jb" already has one: "s1"
s2 schedule.timezone: on cloud "azure" a container job's schedule is read in UTC: a container app job's schedule is a cron read in UTC, with no time zone of its own; write the cron in UTC
"""


comptime _WANT_ONPREM = """gr grant: on cloud "onprem" a grant to the cell's LOGS is a setting of the identity it is for; write it on "api" itself
jb container_job.timeout: above this cloud's job limit of 86400s
jb uses[0]: on cloud "onprem" a grant to the cell's METRICS is a setting of the identity it is for; write it on "sa" itself
jb container_job.size.gpus: on cloud "onprem" a workload cannot ask for a GPU: which GPU this cloud attaches to a workload is not decided yet (a design decision that is still open), so no workload may ask for one
api service.request_timeout: above this cloud's request limit of 3600s
api service.scale: max is below min
zero service.scale.min: on cloud "onprem" a service cannot scale to zero: a service is a plain Deployment, which keeps at least one instance: whether scaling to zero is part of a service's meaning is an open question (Q21: a plain Deployment, Knative Serving or the KEDA HTTP add-on); write scale.min 1 or more
zero labels: on cloud "onprem" an object carries 50 labels, 8 of them kci's: at most 42 of the author's; this resource writes 43
bk physical_name: on cloud "onprem" this kind's name is 3 to 63 bytes; "ab" is 2
s1 physical_name: on cloud "onprem" a schedule of a container job is the job's own schedule: it has no object to name
s2 schedule.target: on cloud "onprem" a container job's schedule is a setting of the job, and "jb" already has one: "s1"
s3 schedule.target: on cloud "onprem" a schedule cannot call a service: a schedule that calls a service runs a caller image the cell pins, and what an onprem cell installs at bootstrap is an open question (Q28)
"""


comptime _WANT_GENERIC = """jb container_job.timeout: above this cloud's job limit of 86400s
api service.request_timeout: above this cloud's request limit of 3600s
api service.scale: max is below min
"""


def test_every_limit_on_every_shape() raises:
    var res = _list(_graph())
    var miss = String("")
    miss += _diff(String("aws"), _limits(shape_named(String("aws")), res), String(_WANT_AWS))
    miss += _diff(String("gcp"), _limits(shape_named(String("gcp")), res), String(_WANT_GCP))
    miss += _diff(String("azure"), _limits(shape_named(String("azure")), res), String(_WANT_AZURE))
    miss += _diff(String("onprem"), _limits(shape_named(String("onprem")), res), String(_WANT_ONPREM))
    miss += _diff(String("generic"), _limits(ProviderShape.generic(), res), String(_WANT_GENERIC))
    assert_equal(index_role(String("by_1412")), index_role(String("by_5285")))
    assert_equal(miss, "")


def test_dead_letter_to_a_queue_fed_once() raises:
    """A dead-letter queue fed by exactly one topic has no private topic: one feed is enough to refuse it."""
    var res = _list(
        String('{"id":"tp3","topic":{}},{"id":"q3","queue":{}},')
        + String('{"id":"sb3","subscription":{"topic":{"resource":"tp3"},"queue":{"resource":"q3"}}},')
        + String('{"id":"qd3","queue":{"deadLetter":{"resource":"q3"}}}')
    )
    var want = String(
        'qd3 queue.dead_letter: on cloud "gcp" a queue dead-letters to the private topic of its dead-letter queue,'
        ' and "q3" has none: it is fed from topic "tp3"\n'
    )
    assert_equal(_limits(shape_named(String("gcp")), res), want)


def main() raises:
    test_every_limit_on_every_shape()
    test_dead_letter_to_a_queue_fed_once()
