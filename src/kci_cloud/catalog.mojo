# =============================================================================
# kci_cloud/catalog.mojo: what the catalog DECLARES, as data a cloud
# adapter can read.
# =============================================================================
#
# One row per `Resource.body` arm of `kci.resource.v1`: the arm's field
# number (the key every cloud adapter reports coverage by), the type's name,
# its portability marker, the outputs it exposes to a `Ref`, and the access
# verbs a `Uses` line may ask of it.
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
comptime FIELD_JOB: Int = 11
"""`Resource.body` field number of `job`."""

comptime OUTPUT_URL = "URL"
comptime OUTPUT_HOST = "HOST"
comptime ACCESS_CALL = "CALL"


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

    def __init__(
        out self,
        field: Int,
        name: String,
        portability: Int,
        var exposes: List[String],
        var accepts: List[String],
    ):
        self.field = field
        self.name = name
        self.portability = portability
        self.exposes = exposes^
        self.accepts = accepts^

    def __init__(out self, *, copy: Self):
        # Explicit: a struct with String and List fields that lives in a List
        # must not rely on a synthesized copy.
        self.field = copy.field
        self.name = copy.name.copy()
        self.portability = copy.portability
        self.exposes = copy.exposes.copy()
        self.accepts = copy.accepts.copy()

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
        """`kci.resource.v1` as declared today: `service` and `job`."""
        var c = Catalog()
        var svc_out = List[String]()
        svc_out.append(String(OUTPUT_URL))
        svc_out.append(String(OUTPUT_HOST))
        var call = List[String]()
        call.append(String(ACCESS_CALL))
        c.add(
            CatalogType(FIELD_SERVICE, String("service"), PORTABLE, svc_out^, call.copy())
        )
        # A job exposes nothing; CALL on a job is "may start a run of it".
        c.add(CatalogType(FIELD_JOB, String("job"), PORTABLE, List[String](), call^))
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
    l.append(BodyArm(FIELD_JOB, String("job")))
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
