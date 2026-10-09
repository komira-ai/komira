# =============================================================================
# kci_cloud/catalog.mojo: what the catalog DECLARES, as data a cloud
# adapter can read.
# =============================================================================
#
# One row per `Resource.body` arm of `kci.resource.v1`: the arm's field
# number (the key every cloud adapter reports coverage by), the type's name,
# its portability marker, the outputs it exposes to a `Ref`, the access
# verbs a `Uses` line may ask of it, its retention default, its primary
# role, and whether its primary object has a cloud name an author may write.
#
# THE CLOUD NAME (`takes_name`). `Resource.physical_name` names the primary
# object, and `Resource.adopt` takes over an existing object of that name
# (metadata.mojo). A `grant` (an edge: its objects are bindings, named by
# the principal and the target) and a `dns_record` (named by the DNS name
# and type it already writes) have no name of their own, on any cloud, so
# both are refused there at validate. A kind that has no name of its own on
# ONE cloud only (an IP address on one cloud is an allocation id) is that
# cloud's limit, not a row here.
#
# RETENTION. A data primitive has a VERSIONED retention default, used while
# `Resource.retention` is unset (KEEP for a table, a bucket, a secret and a
# registry, DELETE for a queue, a topic, a DNS zone, a DNS record, a
# certificate, a network, a subnet and an IP address). A type whose default is
# `RETENTION_NONE` takes no retention: it is deleted with its resource, and
# writing `retention` on it is refused at validate. Changing a default is a
# behaviour change for every stored list, so a default is never edited in
# place; a new default is a new catalog version.
#
# THE PRIMARY ROLE is the role a reference to the resource lands on, on every
# cloud: `run` for a workload (a service, a container job, a worker), `table`
# for a table, `bucket` for a
# bucket, `queue` for a queue, `secret` for a secret, `topic` for a topic,
# `sub` for a subscription, `identity` for a service account, `grant` for a
# grant, `zone` for a DNS zone, `record` for a DNS record, `cert` for a
# certificate, `schedule` for a schedule, `trigger` for an event trigger,
# `network` for a network, `subnet` for a subnet, `address` for an IP
# address, `registry` for a registry. A cloud adapter
# writes a dependency or an input on ANOTHER resource as that resource's id
# alone, and kci resolves it to `<id>/<primary role>` (deploy.lower_data), so
# an adapter lowers one resource without reading the others.
#
# ⚠ HAND-KEPT, BECAUSE THE GENERATED MOJO CANNOT ANSWER IT. The proto states
# portability and `exposes` as message options; the Mojo the codec emits does
# not surface message options (spike S3 of the catalog plan failed). So the
# two option columns are copied here from `resource.proto`, and the copy is
# the one thing in this package that can drift from the schema. What IS
# checked against generated code: the arm numbers (a body decoded from wire
# field N must map back to N, `test_catalog_arms_match_the_wire`), the output
# names (each must be a value of the generated `Output` enum) and the access
# names (of `Access`). Replacing the copy with a generator is a recorded
# decision for the owner, not something this file settles.
#
# A new arm in the proto without a row here is refused at run time by
# `body_field` (an unknown arm index raises), never mapped to a wrong type.
# =============================================================================

from kci_resource_proto.resource import Resource


comptime PORTABLE: Int = 1
"""Every complete cloud hosts this type (`kci.resource.v1.PORTABLE`)."""
comptime CLOUD_BOUND: Int = 2
"""Partial coverage is legitimate (`kci.resource.v1.CLOUD_BOUND`)."""

comptime FIELD_SERVICE: Int = 10
"""`Resource.body` field number of `service`."""
comptime FIELD_CONTAINER_JOB: Int = 11
"""`Resource.body` field number of `container_job` (was `job`)."""
comptime FIELD_WORKER: Int = 12
"""`Resource.body` field number of `worker`."""
comptime FIELD_TABLE: Int = 13
"""`Resource.body` field number of `table`."""
comptime FIELD_BUCKET: Int = 14
"""`Resource.body` field number of `bucket`."""
comptime FIELD_QUEUE: Int = 15
"""`Resource.body` field number of `queue`."""
comptime FIELD_SECRET: Int = 16
"""`Resource.body` field number of `secret`."""
comptime FIELD_DNS_ZONE: Int = 18
"""`Resource.body` field number of `dns_zone`."""
comptime FIELD_SERVICE_ACCOUNT: Int = 20
"""`Resource.body` field number of `service_account`."""
comptime FIELD_TOPIC: Int = 21
"""`Resource.body` field number of `topic`."""
comptime FIELD_SCHEDULE: Int = 22
"""`Resource.body` field number of `schedule`."""
comptime FIELD_NETWORK: Int = 23
"""`Resource.body` field number of `network`."""
comptime FIELD_REGISTRY: Int = 24
"""`Resource.body` field number of `registry`."""
comptime FIELD_GRANT: Int = 25
"""`Resource.body` field number of `grant`."""
comptime FIELD_DNS_RECORD: Int = 26
"""`Resource.body` field number of `dns_record`."""
comptime FIELD_CERTIFICATE: Int = 27
"""`Resource.body` field number of `certificate`."""
comptime FIELD_SUBSCRIPTION: Int = 28
"""`Resource.body` field number of `subscription`."""
comptime FIELD_SUBNET: Int = 29
"""`Resource.body` field number of `subnet`."""
comptime FIELD_IP_ADDRESS: Int = 30
"""`Resource.body` field number of `ip_address`."""
comptime FIELD_EVENT_TRIGGER: Int = 31
"""`Resource.body` field number of `event_trigger`."""

comptime OUTPUT_URL = "URL"
comptime OUTPUT_HOST = "HOST"
comptime OUTPUT_ADDRESS = "ADDRESS"
comptime OUTPUT_NAME = "NAME"
comptime ACCESS_CALL = "CALL"
comptime ACCESS_READ = "READ"
comptime ACCESS_WRITE = "WRITE"
comptime ACCESS_READ_WRITE = "READ_WRITE"
comptime ACCESS_SEND = "SEND"
comptime ACCESS_RECEIVE = "RECEIVE"
comptime ACCESS_DESCRIBE = "DESCRIBE"

comptime RETENTION_NONE: Int = 0
"""The type takes no retention: deleted with its resource (a catalog row's
`retention_default`; the same number as `kci.resource.v1.RETENTION_UNSET`)."""
comptime RETENTION_DELETE: Int = 1
"""`kci.resource.v1.DELETE`."""
comptime RETENTION_KEEP: Int = 2
"""`kci.resource.v1.KEEP`."""

comptime ROLE_RUN = "run"
comptime ROLE_TABLE = "table"
comptime ROLE_BUCKET = "bucket"
comptime ROLE_QUEUE = "queue"
comptime ROLE_TOPIC = "topic"
comptime ROLE_SECRET = "secret"
"""A secret's one role: its container object."""
comptime ROLE_SUBSCRIPTION = "sub"
"""A subscription's role (8 bytes at most, like every role word)."""
comptime ROLE_ZONE = "zone"
"""A DNS zone's one role: the zone object."""
comptime ROLE_RECORD = "record"
"""A DNS record's role: its record set."""
comptime ROLE_CERT = "cert"
"""A certificate's primary role: the certificate object."""
comptime ROLE_IDENTITY = "identity"
"""The identity role: a service account's one object, and the PRIVATE
identity every workload lowers (turned off under `run_as`)."""
comptime ROLE_GRANT = "grant"
"""A grant resource's edge."""
comptime ROLE_SCHEDULE = "schedule"
"""A schedule's primary role: the scheduler's object."""
comptime ROLE_TRIGGER = "trigger"
"""An event trigger's primary role: the rule or subscription that delivers
the events."""
comptime ROLE_NETWORK = "network"
"""A network's one role: the network object."""
comptime ROLE_SUBNET = "subnet"
"""A subnet's one role: the subnet object."""
comptime ROLE_ADDRESS = "address"
"""An IP address's one role: the reserved address."""
comptime ROLE_REGISTRY = "registry"
"""A registry's one role: the registry (or repository) object."""


def retention_word(r: Int) -> String:
    if r == RETENTION_DELETE:
        return String("DELETE")
    if r == RETENTION_KEEP:
        return String("KEEP")
    if r == RETENTION_NONE:
        return String("none")
    return String(r)


def portability_word(p: Int) -> String:
    if p == PORTABLE:
        return String("PORTABLE")
    if p == CLOUD_BOUND:
        return String("CLOUD_BOUND")
    return String("PORTABILITY_UNSET")


struct CatalogType(Copyable, Movable, Deinitable):
    """One resource type of the catalog."""

    var field: Int
    var name: String
    var portability: Int
    var exposes: List[String]
    var accepts: List[String]
    var retention_default: Int
    var primary_role: String
    var takes_name: Bool
    """Its primary object has a cloud name an author may write
    (`Resource.physical_name`, and so `Resource.adopt`)."""

    def __init__(
        out self,
        field: Int,
        name: String,
        portability: Int,
        var exposes: List[String],
        var accepts: List[String],
        retention_default: Int = RETENTION_NONE,
        primary_role: String = String(ROLE_RUN),
        takes_name: Bool = True,
    ):
        self.field = field
        self.name = name
        self.portability = portability
        self.exposes = exposes^
        self.accepts = accepts^
        self.retention_default = retention_default
        self.primary_role = primary_role
        self.takes_name = takes_name

    def __init__(out self, *, copy: Self):
        # Explicit: a struct with String and List fields that lives in a List
        # must not rely on a synthesized copy.
        self.field = copy.field
        self.name = copy.name.copy()
        self.portability = copy.portability
        self.exposes = copy.exposes.copy()
        self.accepts = copy.accepts.copy()
        self.retention_default = copy.retention_default
        self.primary_role = copy.primary_role.copy()
        self.takes_name = copy.takes_name

    def takes_retention(self) -> Bool:
        """True iff `Resource.retention` may be written on this type."""
        return self.retention_default != RETENTION_NONE

    def exposes_output(self, output: String) -> Bool:
        for i in range(len(self.exposes)):
            if self.exposes[i] == output:
                return True
        return False

    def accepts_access(self, access: String) -> Bool:
        for i in range(len(self.accepts)):
            if self.accepts[i] == access:
                return True
        return False


struct Catalog(Copyable, Movable, Deinitable):
    """The types a graph may contain, keyed by body field number."""

    var types: List[CatalogType]

    def __init__(out self):
        self.types = List[CatalogType]()

    def __init__(out self, *, copy: Self):
        self.types = copy.types.copy()

    def add(mut self, var t: CatalogType) raises:
        if t.portability != PORTABLE and t.portability != CLOUD_BOUND:
            raise Error(
                String("catalog: type '")
                + t.name
                + String("' has no portability marking; UNSET is never legal")
            )
        if self.index_of(t.field) >= 0:
            raise Error(
                String("catalog: field ") + String(t.field) + String(" declared twice")
            )
        self.types.append(t^)

    def index_of(self, field: Int) -> Int:
        for i in range(len(self.types)):
            if self.types[i].field == field:
                return i
        return -1

    def name_of(self, field: Int) -> String:
        var i = self.index_of(field)
        if i < 0:
            return String("field ") + String(field)
        return self.types[i].name.copy()

    @staticmethod
    def v1() raises -> Catalog:
        """`kci.resource.v1` as declared today: `service`, `container_job`,
        `worker`, `table`, `bucket`, `queue`, `secret`, `dns_zone`,
        `service_account`, `topic`, `schedule`, `network`, `registry`,
        `grant`, `dns_record`, `certificate`, `subscription`, `subnet`,
        `ip_address` and `event_trigger`."""
        var c = Catalog()
        var svc_out = List[String]()
        svc_out.append(String(OUTPUT_URL))
        svc_out.append(String(OUTPUT_HOST))
        var call = List[String]()
        call.append(String(ACCESS_CALL))
        c.add(
            CatalogType(FIELD_SERVICE, String("service"), PORTABLE, svc_out^, call.copy())
        )
        # A container job exposes nothing; CALL on it is "may start a run of
        # it". A worker exposes nothing and accepts no verb: it answers no
        # request and is started by nobody (it runs always). Both are deleted
        # with their resource, as a service is.
        c.add(CatalogType(FIELD_CONTAINER_JOB, String("container_job"), PORTABLE, List[String](), call^))
        c.add(CatalogType(FIELD_WORKER, String("worker"), PORTABLE, List[String](), List[String]()))
        # A table exposes its cloud name; its items are read and written, its
        # definition DESCRIBEd. Kept by default, as a bucket.
        var table_out = List[String]()
        table_out.append(String(OUTPUT_NAME))
        var table_access = List[String]()
        table_access.append(String(ACCESS_READ))
        table_access.append(String(ACCESS_WRITE))
        table_access.append(String(ACCESS_READ_WRITE))
        table_access.append(String(ACCESS_DESCRIBE))
        c.add(
            CatalogType(
                FIELD_TABLE,
                String("table"),
                PORTABLE,
                table_out^,
                table_access^,
                retention_default=RETENTION_KEEP,
                primary_role=String(ROLE_TABLE),
            )
        )
        var bucket_out = List[String]()
        bucket_out.append(String(OUTPUT_NAME))
        bucket_out.append(String(OUTPUT_ADDRESS))
        var data = List[String]()
        data.append(String(ACCESS_READ))
        data.append(String(ACCESS_WRITE))
        data.append(String(ACCESS_READ_WRITE))
        c.add(
            CatalogType(
                FIELD_BUCKET,
                String("bucket"),
                PORTABLE,
                bucket_out^,
                data^,
                retention_default=RETENTION_KEEP,
                primary_role=String(ROLE_BUCKET),
            )
        )
        # A service account exposes its cloud name and may be DESCRIBEd; it
        # is deleted with its resource.
        var acct_out = List[String]()
        acct_out.append(String(OUTPUT_NAME))
        var describe = List[String]()
        describe.append(String(ACCESS_DESCRIBE))
        c.add(
            CatalogType(
                FIELD_SERVICE_ACCOUNT,
                String("service_account"),
                PORTABLE,
                acct_out^,
                describe^,
                primary_role=String(ROLE_IDENTITY),
            )
        )
        # A grant is an edge: it exposes nothing, accepts nothing, and has
        # no cloud name of its own (its objects are bindings).
        c.add(
            CatalogType(
                FIELD_GRANT,
                String("grant"),
                PORTABLE,
                List[String](),
                List[String](),
                primary_role=String(ROLE_GRANT),
                takes_name=False,
            )
        )
        # Messaging. A queue and a topic expose their cloud name and address
        # and hold messages, so they take retention (DELETE by default). A
        # queue is sent to and received from; a topic is only sent to (its
        # messages are received from the queues subscribed to it). A
        # subscription is an edge, like a grant: it exposes and accepts
        # nothing, and is deleted with its resource.
        var addressed = List[String]()
        addressed.append(String(OUTPUT_NAME))
        addressed.append(String(OUTPUT_ADDRESS))
        var send = List[String]()
        send.append(String(ACCESS_SEND))
        var send_receive = send.copy()
        send_receive.append(String(ACCESS_RECEIVE))
        c.add(
            CatalogType(
                FIELD_QUEUE,
                String("queue"),
                PORTABLE,
                addressed.copy(),
                send_receive^,
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_QUEUE),
            )
        )
        c.add(
            CatalogType(
                FIELD_TOPIC,
                String("topic"),
                PORTABLE,
                addressed^,
                send^,
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_TOPIC),
            )
        )
        # A secret is the container of a value: it exposes its cloud name;
        # its value is READ (by the workload that receives it) and WRITTEN
        # (a new version, by the identity that keeps it). Deleting it deletes
        # every version, so it is kept by default, as a bucket.
        var secret_out = List[String]()
        secret_out.append(String(OUTPUT_NAME))
        var secret_access = List[String]()
        secret_access.append(String(ACCESS_READ))
        secret_access.append(String(ACCESS_WRITE))
        secret_access.append(String(ACCESS_READ_WRITE))
        c.add(
            CatalogType(
                FIELD_SECRET,
                String("secret"),
                PORTABLE,
                secret_out^,
                secret_access^,
                retention_default=RETENTION_KEEP,
                primary_role=String(ROLE_SECRET),
            )
        )
        c.add(
            CatalogType(
                FIELD_SUBSCRIPTION,
                String("subscription"),
                PORTABLE,
                List[String](),
                List[String](),
                primary_role=String(ROLE_SUBSCRIPTION),
            )
        )
        # Names. A DNS zone and a certificate expose their cloud name, a DNS
        # record its HOST (the name it answers for). Each holds what the
        # author wrote rather than data kci cannot recreate, so each takes
        # retention with the default DELETE. None accepts a verb: changing a
        # zone's records is MANAGE, which is held, and a certificate is used
        # by the edge that serves it, not through a grant.
        var zone_out = List[String]()
        zone_out.append(String(OUTPUT_NAME))
        c.add(
            CatalogType(
                FIELD_DNS_ZONE,
                String("dns_zone"),
                PORTABLE,
                zone_out.copy(),
                List[String](),
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_ZONE),
            )
        )
        var record_out = List[String]()
        record_out.append(String(OUTPUT_HOST))
        c.add(
            CatalogType(
                FIELD_DNS_RECORD,
                String("dns_record"),
                PORTABLE,
                record_out^,
                List[String](),
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_RECORD),
                # A record set is named by its DNS name and type.
                takes_name=False,
            )
        )
        c.add(
            CatalogType(
                FIELD_CERTIFICATE,
                String("certificate"),
                PORTABLE,
                zone_out^,
                List[String](),
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_CERT),
            )
        )
        # Triggers. A schedule and an event trigger start or call their
        # target through a private identity of their own (grants.mojo): they
        # expose nothing, accept no verb (nothing is granted on a trigger),
        # and are deleted with their resource.
        c.add(
            CatalogType(
                FIELD_SCHEDULE,
                String("schedule"),
                PORTABLE,
                List[String](),
                List[String](),
                primary_role=String(ROLE_SCHEDULE),
            )
        )
        c.add(
            CatalogType(
                FIELD_EVENT_TRIGGER,
                String("event_trigger"),
                PORTABLE,
                List[String](),
                List[String](),
                primary_role=String(ROLE_TRIGGER),
            )
        )
        # Networks. A network and a subnet expose their cloud name, an IP
        # address the address itself. Each holds what the author wrote (a
        # range, a reserved address), so each takes retention with the
        # default DELETE. None runs as an identity or accepts a verb: placing
        # a workload in a subnet is a field of the workload, not a grant.
        var net_out = List[String]()
        net_out.append(String(OUTPUT_NAME))
        c.add(
            CatalogType(
                FIELD_NETWORK,
                String("network"),
                PORTABLE,
                net_out.copy(),
                List[String](),
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_NETWORK),
            )
        )
        c.add(
            CatalogType(
                FIELD_SUBNET,
                String("subnet"),
                PORTABLE,
                net_out^,
                List[String](),
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_SUBNET),
            )
        )
        var ip_out = List[String]()
        ip_out.append(String(OUTPUT_ADDRESS))
        c.add(
            CatalogType(
                FIELD_IP_ADDRESS,
                String("ip_address"),
                PORTABLE,
                ip_out^,
                List[String](),
                retention_default=RETENTION_DELETE,
                primary_role=String(ROLE_ADDRESS),
            )
        )
        # A registry exposes its ADDRESS (the name a client pushes and pulls
        # an image as). Its artifacts are pulled (READ) and pushed (WRITE).
        # Deleting it deletes every artifact in it, so it is kept by
        # default, as a bucket.
        var registry_out = List[String]()
        registry_out.append(String(OUTPUT_ADDRESS))
        var registry_access = List[String]()
        registry_access.append(String(ACCESS_READ))
        registry_access.append(String(ACCESS_WRITE))
        registry_access.append(String(ACCESS_READ_WRITE))
        c.add(
            CatalogType(
                FIELD_REGISTRY,
                String("registry"),
                PORTABLE,
                registry_out^,
                registry_access^,
                retention_default=RETENTION_KEEP,
                primary_role=String(ROLE_REGISTRY),
            )
        )
        return c^


@fieldwise_init
struct BodyArm(Copyable, Movable, Deinitable):
    """One arm of the `Resource.body` oneof: its field number and its name."""

    var field: Int
    var name: String


def body_arms() -> List[BodyArm]:
    """The `Resource.body` arms, in DECLARATION ORDER: entry `k` is the arm
    the generated struct records as position `k + 1`. One row per declared
    arm; a new arm is one new row here, at its declaration position, pinned
    against wire bytes by `test_catalog_arms_match_the_wire`."""
    var l = List[BodyArm]()
    l.append(BodyArm(FIELD_SERVICE, String("service")))
    l.append(BodyArm(FIELD_CONTAINER_JOB, String("container_job")))
    l.append(BodyArm(FIELD_WORKER, String("worker")))
    l.append(BodyArm(FIELD_TABLE, String("table")))
    l.append(BodyArm(FIELD_BUCKET, String("bucket")))
    l.append(BodyArm(FIELD_QUEUE, String("queue")))
    l.append(BodyArm(FIELD_SECRET, String("secret")))
    l.append(BodyArm(FIELD_DNS_ZONE, String("dns_zone")))
    l.append(BodyArm(FIELD_SERVICE_ACCOUNT, String("service_account")))
    l.append(BodyArm(FIELD_TOPIC, String("topic")))
    l.append(BodyArm(FIELD_SCHEDULE, String("schedule")))
    l.append(BodyArm(FIELD_NETWORK, String("network")))
    l.append(BodyArm(FIELD_REGISTRY, String("registry")))
    l.append(BodyArm(FIELD_GRANT, String("grant")))
    l.append(BodyArm(FIELD_DNS_RECORD, String("dns_record")))
    l.append(BodyArm(FIELD_CERTIFICATE, String("certificate")))
    l.append(BodyArm(FIELD_SUBSCRIPTION, String("subscription")))
    l.append(BodyArm(FIELD_SUBNET, String("subnet")))
    l.append(BodyArm(FIELD_IP_ADDRESS, String("ip_address")))
    l.append(BodyArm(FIELD_EVENT_TRIGGER, String("event_trigger")))
    return l^


def body_field(r: Resource) raises -> Int:
    """The `Resource.body` field number of `r`'s set arm. The generated
    struct records the arm by its 1-based position in the oneof; this is the
    one place that maps position to field number (through `body_arms`).
    No arm set, and an arm beyond the table, both raise: a new arm in the
    proto without a row is refused, never mapped to a wrong type."""
    var arm = r._oneof0_case
    var arms = body_arms()
    if arm == 0:
        var names = String("")
        for i in range(len(arms)):
            if i > 0:
                names += String(", ")
            names += arms[i].name
        raise Error(
            String("resource '")
            + r.id
            + String("' has no type: exactly one of ")
            + names
            + String(" must be set")
        )
    if arm < 0 or arm > len(arms):
        raise Error(
            String("resource '")
            + r.id
            + String("': body arm ")
            + String(arm)
            + String(" is not in this kci's catalog table")
        )
    return arms[arm - 1].field


def effective_retention(catalog: Catalog, r: Resource) raises -> Int:
    """`r`'s retention: `Resource.retention` when written, else its type's
    versioned default (`RETENTION_NONE` for a type that takes none). Raises
    for a resource with no type, or a type outside `catalog`."""
    var field = body_field(r)
    var t = catalog.index_of(field)
    if t < 0:
        raise Error(
            String("resource '")
            + r.id
            + String("': type field ")
            + String(field)
            + String(" is not in the catalog")
        )
    var written = r.retention.value
    if written != RETENTION_NONE:
        return written
    return catalog.types[t].retention_default


def primary_node(catalog: Catalog, resources: List[Resource], id: String) raises -> String:
    """The node a reference to resource `id` lands on:
    `<id>/<primary role of its type>`. Raises for an id not in `resources`
    (validate refuses such a reference first)."""
    for i in range(len(resources)):
        if resources[i].id == id:
            var t = catalog.index_of(body_field(resources[i]))
            if t < 0:
                break
            return id + String("/") + catalog.types[t].primary_role
    raise Error(
        String("a reference to \"")
        + id
        + String("\" names no resource of the catalog in this list")
    )
