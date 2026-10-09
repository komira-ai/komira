# =============================================================================
# kci_cloud_fake/metadata.mojo: what each fake shape refuses of a resource's
# metadata (`labels`, `physical_name`), as data.
# =============================================================================
#
# kci_cloud's metadata.mojo holds the rules every cloud shares (the label
# and name grammars, kci's own label space, one name per object, `adopt`
# needing a name). This file is the part that differs per cloud, carried by
# each shape as a value (`MetadataLimits`, `ProviderShape.metadata`), never
# chosen by a cloud's name:
#
#   * `label_cap`: how many labels (tags) one object carries on the cloud,
#     kci's own included (0: no cap). An author may write `label_cap -
#     KCI_LABELS_MAX` of them (kci writes at most `KCI_LABELS_MAX`).
#   * `names`: one `NameRule` per catalog field whose primary object's name
#     is narrower on the cloud than the portable grammar (fewer bytes at
#     most, more at least, letters and digits only), or that has NO name of
#     its own there (`none_reason`: the cloud assigns an id, or the kind is
#     named by what it already holds); a type with no row takes any name of
#     the portable grammar.
#   * a schedule FOLDED into its container job (a shape with
#     `schedule_folds`) has no object of its own, so it takes no name.
#
# The shapes, as the fakes model them (limits of the fake clouds, cited as
# this package's, `FAKE_CITATION`, like every other fake limit):
#   * `generic`   no cap, no rule.
#   * `aws`       50 tags an object; no name of its own for a DNS zone (a
#                 hosted zone is its domain and an assigned id), a
#                 certificate, a subscription, a network, a subnet or an IP
#                 address (each an assigned id or ARN); a bucket and a table
#                 at least 3 bytes, a registry at least 2.
#   * `gcp`       64 labels an object; a subscription has no object of its
#                 own (shapes.mojo); a service account 6 to 30 bytes, a
#                 service at most 49, a bucket, a queue and a topic at least
#                 3.
#   * `azure`     50 tags an object; a DNS zone is its domain; a service, a
#                 worker and a container job 2 to 32 bytes (a container app
#                 and a container apps job); a registry 5 to 50 letters and
#                 digits; a bucket and a service account at least 3.
#   * `onprem`    50 labels an object (the tags of a bucket, the tightest of
#                 its backings); a container job and a schedule at most 52
#                 bytes (a CronJob's name); a bucket at least 3.
# =============================================================================

from kci_cloud import (
    FIELD_BUCKET,
    FIELD_CERTIFICATE,
    FIELD_CONTAINER_JOB,
    FIELD_DNS_ZONE,
    FIELD_IP_ADDRESS,
    FIELD_NETWORK,
    FIELD_QUEUE,
    FIELD_REGISTRY,
    FIELD_SCHEDULE,
    FIELD_SERVICE,
    FIELD_SERVICE_ACCOUNT,
    FIELD_SUBNET,
    FIELD_SUBSCRIPTION,
    FIELD_TABLE,
    FIELD_TOPIC,
    FIELD_WORKER,
    FINDING_LIMIT,
    Finding,
    Firing,
    KCI_LABELS_MAX,
    body_field,
)
from kci_resource_proto.resource import Resource


comptime FAKE_CITATION = "kci_cloud_fake: reference limits"
"""The same text as `limits.FAKE_CITATION` (limits.mojo reads shapes.mojo,
which reads this file, so it cannot be imported here); a test pins the two
equal."""


struct NameRule(Copyable, Movable, Deinitable):
    """How one type's primary object is named on a shape: `min` to `max`
    bytes, letters and digits only when `letters_digits_only`; or, with
    `none_reason` written, no name an author may choose at all."""

    var field: Int
    var min: Int
    var max: Int
    var letters_digits_only: Bool
    var none_reason: String

    def __init__(
        out self,
        field: Int,
        min: Int = 1,
        max: Int = 63,
        letters_digits_only: Bool = False,
        none_reason: String = String(""),
    ):
        self.field = field
        self.min = min
        self.max = max
        self.letters_digits_only = letters_digits_only
        self.none_reason = none_reason

    def __init__(out self, *, copy: Self):
        self.field = copy.field
        self.min = copy.min
        self.max = copy.max
        self.letters_digits_only = copy.letters_digits_only
        self.none_reason = copy.none_reason.copy()


struct MetadataLimits(Copyable, Movable, Deinitable):
    """A shape's metadata limits (the file header)."""

    var label_cap: Int
    var names: List[NameRule]

    def __init__(out self, label_cap: Int = 0, var names: List[NameRule] = List[NameRule]()):
        self.label_cap = label_cap
        self.names = names^

    def __init__(out self, *, copy: Self):
        self.label_cap = copy.label_cap
        self.names = copy.names.copy()

    def rule_of(self, field: Int) -> Optional[NameRule]:
        for i in range(len(self.names)):
            if self.names[i].field == field:
                return self.names[i].copy()
        return None

    def author_labels_max(self) -> Int:
        """How many labels an author may write (-1: no cap)."""
        if self.label_cap == 0:
            return -1
        return self.label_cap - KCI_LABELS_MAX

    @staticmethod
    def aws() -> MetadataLimits:
        var n = List[NameRule]()
        n.append(NameRule(FIELD_DNS_ZONE, none_reason=String("a hosted zone is its domain and an id the cloud assigns")))
        n.append(NameRule(FIELD_CERTIFICATE, none_reason=String("a certificate is an ARN the cloud assigns")))
        n.append(NameRule(FIELD_SUBSCRIPTION, none_reason=String("a subscription is an ARN the cloud assigns")))
        n.append(NameRule(FIELD_NETWORK, none_reason=String("a VPC is an id the cloud assigns")))
        n.append(NameRule(FIELD_SUBNET, none_reason=String("a subnet is an id the cloud assigns")))
        n.append(NameRule(FIELD_IP_ADDRESS, none_reason=String("an Elastic IP is an allocation id the cloud assigns")))
        n.append(NameRule(FIELD_BUCKET, min=3))
        n.append(NameRule(FIELD_TABLE, min=3))
        n.append(NameRule(FIELD_REGISTRY, min=2))
        return MetadataLimits(50, n^)

    @staticmethod
    def gcp() -> MetadataLimits:
        var n = List[NameRule]()
        n.append(
            NameRule(
                FIELD_SUBSCRIPTION,
                none_reason=String("a subscription has no object of its own: it is the topic its queue is on"),
            )
        )
        n.append(NameRule(FIELD_SERVICE_ACCOUNT, min=6, max=30))
        n.append(NameRule(FIELD_SERVICE, max=49))
        n.append(NameRule(FIELD_BUCKET, min=3))
        n.append(NameRule(FIELD_QUEUE, min=3))
        n.append(NameRule(FIELD_TOPIC, min=3))
        return MetadataLimits(64, n^)

    @staticmethod
    def azure() -> MetadataLimits:
        var n = List[NameRule]()
        n.append(NameRule(FIELD_DNS_ZONE, none_reason=String("a DNS zone is named by its domain")))
        n.append(NameRule(FIELD_SERVICE, min=2, max=32))
        n.append(NameRule(FIELD_WORKER, min=2, max=32))
        n.append(NameRule(FIELD_CONTAINER_JOB, min=2, max=32))
        n.append(NameRule(FIELD_REGISTRY, min=5, max=50, letters_digits_only=True))
        n.append(NameRule(FIELD_BUCKET, min=3))
        n.append(NameRule(FIELD_SERVICE_ACCOUNT, min=3))
        return MetadataLimits(50, n^)

    @staticmethod
    def onprem() -> MetadataLimits:
        var n = List[NameRule]()
        n.append(NameRule(FIELD_CONTAINER_JOB, max=52))
        n.append(NameRule(FIELD_SCHEDULE, max=52))
        n.append(NameRule(FIELD_BUCKET, min=3))
        return MetadataLimits(50, n^)


def fake_physical_name(r: Resource) -> String:
    """The author's cloud name of `r`'s primary object, or empty."""
    if r.physical_name:
        return r.physical_name.value().copy()
    return String("")


def _folds(r: Resource, firings: List[Firing]) -> Bool:
    """`r` is a schedule whose target is a container job."""
    if not r.schedule:
        return False
    for i in range(len(firings)):
        if firings[i].schedule == r.id and firings[i].target_field == FIELD_CONTAINER_JOB:
            return True
    return False


def metadata_limits(
    r: Resource,
    firings: List[Firing],
    limits: MetadataLimits,
    schedule_folds: Bool,
    cloud: String,
    mut out: List[Finding],
):
    """The shape's metadata limits (file header) on `r`."""
    var most = limits.author_labels_max()
    if most >= 0 and len(r.labels) > most:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("labels"),
                String("on cloud \"") + cloud + String("\" an object carries ") + String(limits.label_cap)
                + String(" labels, ") + String(KCI_LABELS_MAX) + String(" of them kci's: at most ")
                + String(most) + String(" of the author's; this resource writes ") + String(len(r.labels)),
                String(FAKE_CITATION),
            )
        )
    if not r.physical_name:
        return
    ref name = r.physical_name.value()
    if schedule_folds and _folds(r, firings):
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("physical_name"),
                String("on cloud \"") + cloud
                + String("\" a schedule of a container job is the job's own schedule: it has no object to name"),
                String(FAKE_CITATION),
            )
        )
        return
    var field: Int
    try:
        field = body_field(r)
    except:
        return  # a graph finding
    var rule = limits.rule_of(field)
    if not rule:
        return
    ref nr = rule.value()
    if nr.none_reason.byte_length() > 0:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("physical_name"),
                String("on cloud \"") + cloud + String("\" this kind has no name an author chooses: ") + nr.none_reason,
                String(FAKE_CITATION),
            )
        )
        return
    var n = name.byte_length()
    if n < nr.min or n > nr.max:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("physical_name"),
                String("on cloud \"") + cloud + String("\" this kind's name is ") + String(nr.min) + String(" to ")
                + String(nr.max) + String(" bytes; \"") + name + String("\" is ") + String(n),
                String(FAKE_CITATION),
            )
        )
    if nr.letters_digits_only and name.find("-") >= 0:
        out.append(
            Finding(
                FINDING_LIMIT,
                r.id,
                String("physical_name"),
                String("on cloud \"") + cloud + String("\" this kind's name is letters and digits only: \"") + name
                + String("\" holds '-'"),
                String(FAKE_CITATION),
            )
        )
