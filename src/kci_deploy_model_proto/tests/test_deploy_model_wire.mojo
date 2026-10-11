# =============================================================================
# test_deploy_model_wire.mojo
# =============================================================================
#
# The deploy model (`kci.deploy.v1`) on the protobuf binary wire: every field
# of every message, and every value of every enum.
#
# WHAT IS ASSERTED, AND WHAT EACH ONE CATCHES:
#   1. Each message is built with EVERY field set to a value that is not its
#      default, and its whole encoding is compared to bytes written out here
#      by hand: each record's tag (field number and wire type), length and
#      payload. A renumbered field, or a field whose type changes its wire
#      type, is protoc-legal and round-trips cleanly through the same
#      generated code; only a literal statement of the bytes fails on it.
#      The binary encoder writes fields in number order and every plain
#      field it is given, so the comparison is of the whole message. Each
#      value is built by naming every field, so a field added to or removed
#      from the .proto stops this file compiling.
#   2. The enum census: for every enum, each declared value's NAME maps to its
#      number and the number back to the name (a value renumbered, renamed or
#      moved fails), and the declared names, in declaration order, are stated
#      as one list (a value added or removed fails).
#   3. `DatastoreNeed` 3 is reserved (it was `DATASTORE_NEED_OBJECTSTORE`):
#      no declaration owns 3, and the old name is not a declared name.
#   4. The fully populated `DeploymentSpec` round-trips through the binary and
#      the proto3-JSON codecs to the same bytes.
#
# The numbers here are restated, deliberately: deriving them from the
# generated code would agree with it by construction and assert nothing.
# =============================================================================

from komira_proto_codec import (
    ProtoEnum,
    decode_json,
    decode_proto,
    encode_json,
    encode_proto,
)
from std.testing import assert_equal, assert_false, assert_true

from kci_deploy_model_proto.deploy_model import (
    BundleIndex,
    BundleIndexField,
    BundleIndexTable,
    ComputeIntent,
    ContainerSpec,
    DatastoreFamily,
    DatastoreImpl,
    DatastoreNeed,
    DeployLifecycle,
    DeployProvider,
    DeploymentSpec,
    EnvVar,
    InboundNeed,
    Label,
    NetworkIngress,
    PortSpec,
    SecretBinding,
    SecretCustody,
    StageIdentity,
)


# ---- byte helpers -------------------------------------------------------------


def _b(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _cat(*parts: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for p in parts:
        for b in p:
            out.append(b)
    return out^


def _framed(tag: List[UInt8], payload: List[UInt8]) -> List[UInt8]:
    """A length-delimited record; every payload here is shorter than 128
    bytes, so its length is one byte."""
    return _cat(tag, _b(len(payload)), payload)


def _expect(what: String, got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want), what + ": encoding length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": byte " + String(i))


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


# ---- the values: every field set, none at its default --------------------------


def _port() -> PortSpec:
    return PortSpec(name=String("p"), container_port=Int32(9))


def _env() -> EnvVar:
    return EnvVar(name=String("k"), value=String("v"))


def _container() -> ContainerSpec:
    var env = List[EnvVar]()
    env.append(_env())
    var ports = List[PortSpec]()
    ports.append(_port())
    return ContainerSpec(
        name=String("c"),
        image=String("i"),
        image_digest=String("g"),
        command=_one(String("m")),
        args=_one(String("a")),
        env=env^,
        cpu=String("u"),
        memory=String("y"),
        ports=ports^,
        accelerator=Int32(1),
    )


def _label() -> Label:
    return Label(key=String("k"), value=String("v"))


def _secret() -> SecretBinding:
    return SecretBinding(
        handle=String("h"),
        capability_node=String("c"),
        ensure=True,
        custody=SecretCustody.from_number(3),
    )


def _index_field() -> BundleIndexField:
    return BundleIndexField(col=String("c"), desc=True, array_contains=True)


def _index() -> BundleIndex:
    var fields = List[BundleIndexField]()
    fields.append(_index_field())
    return BundleIndex(name=String("x"), fields=fields^, scope=String("s"))


def _table() -> BundleIndexTable:
    var indexes = List[BundleIndex]()
    indexes.append(_index())
    return BundleIndexTable(table=String("t"), indexes=indexes^)


def _spec() -> DeploymentSpec:
    var containers = List[ContainerSpec]()
    containers.append(_container())
    var labels = List[Label]()
    labels.append(_label())
    var secrets = List[SecretBinding]()
    secrets.append(_secret())
    var ports = List[PortSpec]()
    ports.append(_port())
    var tables = List[BundleIndexTable]()
    tables.append(_table())
    return DeploymentSpec(
        name=String("n"),
        namespace=String("s"),
        containers=containers^,
        labels=labels^,
        account_ref=String("a"),
        compute=ComputeIntent.from_number(2),
        datastore=DatastoreNeed.from_number(4),
        secret_bindings=secrets^,
        provider=DeployProvider.from_number(7),
        runtime_identity=String("r"),
        stage_identity=StageIdentity.from_number(3),
        served_ports=ports^,
        lifecycle=DeployLifecycle.from_number(2),
        spot=True,
        prior_digest=Optional[String](String("d")),
        datastore_analytics_replica=True,
        keep_last_n=Optional[Int32](Int32(5)),
        datastore_family=DatastoreFamily.from_number(4),
        object_store_bucket=String("o"),
        inbound=InboundNeed.from_number(3),
        datastore_database=String("b"),
        datastore_index_tables=tables^,
    )


# ---- the pinned encodings -------------------------------------------------------
# A tag is (field number << 3) | wire type: wire type 0 is a varint, 2 is
# length-delimited. 0x0A = 1/2, 0x10 = 2/0, 0x12 = 2/2, 0x18 = 3/0, 0x1A = 3/2,
# 0x20 = 4/0, 0x22 = 4/2, ... From field 16 the tag is two bytes.


def _port_bytes() -> List[UInt8]:
    return _b(
        0x0A, 1, ord("p"),  # name = 1
        0x10, 9,  # container_port = 2
    )


def _env_bytes() -> List[UInt8]:
    return _b(
        0x0A, 1, ord("k"),  # name = 1
        0x12, 1, ord("v"),  # value = 2
    )


def _container_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("c")),  # name = 1
        _b(0x12, 1, ord("i")),  # image = 2
        _b(0x1A, 1, ord("g")),  # image_digest = 3
        _b(0x22, 1, ord("m")),  # command = 4
        _b(0x2A, 1, ord("a")),  # args = 5
        _framed(_b(0x32), _env_bytes()),  # env = 6
        _b(0x3A, 1, ord("u")),  # cpu = 7
        _b(0x42, 1, ord("y")),  # memory = 8
        _framed(_b(0x4A), _port_bytes()),  # ports = 9
        _b(0x50, 1),  # accelerator = 10
    )


def _label_bytes() -> List[UInt8]:
    return _b(
        0x0A, 1, ord("k"),  # key = 1
        0x12, 1, ord("v"),  # value = 2
    )


def _secret_bytes() -> List[UInt8]:
    return _b(
        0x0A, 1, ord("h"),  # handle = 1
        0x12, 1, ord("c"),  # capability_node = 2
        0x18, 1,  # ensure = 3
        0x20, 3,  # custody = 4
    )


def _index_field_bytes() -> List[UInt8]:
    return _b(
        0x0A, 1, ord("c"),  # col = 1
        0x10, 1,  # desc = 2
        0x18, 1,  # array_contains = 3
    )


def _index_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("x")),  # name = 1
        _framed(_b(0x12), _index_field_bytes()),  # fields = 2
        _b(0x1A, 1, ord("s")),  # scope = 3
    )


def _table_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("t")),  # table = 1
        _framed(_b(0x12), _index_bytes()),  # indexes = 2
    )


def _spec_bytes() -> List[UInt8]:
    return _cat(
        _b(0x0A, 1, ord("n")),  # name = 1
        _b(0x12, 1, ord("s")),  # namespace = 2
        _framed(_b(0x1A), _container_bytes()),  # containers = 3
        _framed(_b(0x22), _label_bytes()),  # labels = 4
        _b(0x2A, 1, ord("a")),  # account_ref = 5
        _b(0x30, 2),  # compute = 6
        _b(0x38, 4),  # datastore = 7
        _framed(_b(0x42), _secret_bytes()),  # secret_bindings = 8
        _b(0x48, 7),  # provider = 9
        _b(0x52, 1, ord("r")),  # runtime_identity = 10
        _b(0x58, 3),  # stage_identity = 11
        _framed(_b(0x62), _port_bytes()),  # served_ports = 12
        _b(0x68, 2),  # lifecycle = 13
        _b(0x70, 1),  # spot = 14
        _b(0x7A, 1, ord("d")),  # prior_digest = 15
        _b(0x80, 0x01, 1),  # datastore_analytics_replica = 16
        _b(0x88, 0x01, 5),  # keep_last_n = 17
        _b(0x90, 0x01, 4),  # datastore_family = 18
        _b(0x9A, 0x01, 1, ord("o")),  # object_store_bucket = 19
        _b(0xA0, 0x01, 3),  # inbound = 20
        _b(0xAA, 0x01, 1, ord("b")),  # datastore_database = 21
        _framed(_b(0xB2, 0x01), _table_bytes()),  # datastore_index_tables = 22
    )


# ---- 1. every field of every message ---------------------------------------------


def test_leaf_message_bytes() raises:
    _expect("PortSpec", encode_proto(_port()), _port_bytes())
    _expect("EnvVar", encode_proto(_env()), _env_bytes())
    _expect("Label", encode_proto(_label()), _label_bytes())
    _expect("SecretBinding", encode_proto(_secret()), _secret_bytes())
    _expect(
        "BundleIndexField", encode_proto(_index_field()), _index_field_bytes()
    )


def test_nested_message_bytes() raises:
    _expect("ContainerSpec", encode_proto(_container()), _container_bytes())
    _expect("BundleIndex", encode_proto(_index()), _index_bytes())
    _expect("BundleIndexTable", encode_proto(_table()), _table_bytes())


def test_deployment_spec_bytes() raises:
    _expect("DeploymentSpec", encode_proto(_spec()), _spec_bytes())


# ---- 2. every value of every enum -------------------------------------------------


def _census[T: ProtoEnum & ImplicitlyDestructible](
    enum_name: String, names: List[String], numbers: List[Int], known: String
) raises:
    assert_equal(len(names), len(numbers), enum_name + ": census rows")
    var joined = String("")
    for i in range(len(names)):
        var at = enum_name + "." + names[i]
        assert_equal(T.from_json_name(names[i]).number(), numbers[i], at)
        assert_equal(T.from_number(numbers[i]).json_name(), names[i], at)
        assert_true(T.is_known_json_name(names[i]), at + " is declared")
        if i > 0:
            joined += ","
        joined += names[i]
    assert_equal(known, joined, enum_name + ": the declared values")


def _l(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(x)
    return out^


def _n(*xs: Int) -> List[Int]:
    var out = List[Int]()
    for x in xs:
        out.append(x)
    return out^


def test_enum_census() raises:
    _census[ComputeIntent](
        "ComputeIntent",
        _l(
            "COMPUTE_INTENT_UNSPECIFIED",
            "COMPUTE_INTENT_SERVERLESS",
            "COMPUTE_INTENT_SERVERFUL",
        ),
        _n(0, 1, 2),
        ComputeIntent.known_json_names(),
    )
    _census[DatastoreNeed](
        "DatastoreNeed",
        _l(
            "DATASTORE_NEED_UNSPECIFIED",
            "DATASTORE_NEED_NONE",
            "DATASTORE_NEED_SERVERLESS",
            "DATASTORE_NEED_DEDICATED",
        ),
        _n(0, 1, 2, 4),
        DatastoreNeed.known_json_names(),
    )
    _census[DatastoreFamily](
        "DatastoreFamily",
        _l(
            "DATASTORE_FAMILY_UNSPECIFIED",
            "DATASTORE_FAMILY_NONE",
            "DATASTORE_FAMILY_DOCUMENT_DB",
            "DATASTORE_FAMILY_OBJECT_STORE",
            "DATASTORE_FAMILY_DOCUMENT_DB_AND_OBJECT_STORE",
        ),
        _n(0, 1, 2, 3, 4),
        DatastoreFamily.known_json_names(),
    )
    _census[DatastoreImpl](
        "DatastoreImpl",
        _l(
            "DATASTORE_IMPL_NONE",
            "DATASTORE_IMPL_CLOUD_SERVERLESS_DB",
            "DATASTORE_IMPL_OBJECT_STORE_SQL",
            "DATASTORE_IMPL_DEDICATED_DB",
        ),
        _n(0, 1, 2, 3),
        DatastoreImpl.known_json_names(),
    )
    _census[InboundNeed](
        "InboundNeed",
        _l(
            "INBOUND_NEED_UNSPECIFIED",
            "INBOUND_NEED_WEBHOOK",
            "INBOUND_NEED_POLL",
            "INBOUND_NEED_CLIENT",
        ),
        _n(0, 1, 2, 3),
        InboundNeed.known_json_names(),
    )
    _census[NetworkIngress](
        "NetworkIngress",
        _l(
            "NETWORK_INGRESS_UNSPECIFIED",
            "NETWORK_INGRESS_PUBLIC",
            "NETWORK_INGRESS_INTERNAL",
            "NETWORK_INGRESS_INTERNAL_AND_LOAD_BALANCER",
        ),
        _n(0, 1, 2, 3),
        NetworkIngress.known_json_names(),
    )
    _census[DeployProvider](
        "DeployProvider",
        _l(
            "DEPLOY_PROVIDER_UNSPECIFIED",
            "DEPLOY_PROVIDER_CLOUD_RUN",
            "DEPLOY_PROVIDER_LAMBDA",
            "DEPLOY_PROVIDER_FUNCTIONS",
            "DEPLOY_PROVIDER_ECS",
            "DEPLOY_PROVIDER_K8S",
            "DEPLOY_PROVIDER_GCE_VM",
            "DEPLOY_PROVIDER_LOCAL_COMPOSE",
        ),
        _n(0, 1, 2, 3, 4, 5, 6, 7),
        DeployProvider.known_json_names(),
    )
    _census[StageIdentity](
        "StageIdentity",
        _l(
            "STAGE_IDENTITY_UNSPECIFIED",
            "STAGE_IDENTITY_BUILD",
            "STAGE_IDENTITY_DEPLOY",
            "STAGE_IDENTITY_PLACEMENT",
        ),
        _n(0, 1, 2, 3),
        StageIdentity.known_json_names(),
    )
    _census[DeployLifecycle](
        "DeployLifecycle",
        _l(
            "DEPLOY_LIFECYCLE_UNSPECIFIED",
            "DEPLOY_LIFECYCLE_EPHEMERAL",
            "DEPLOY_LIFECYCLE_PERSISTENT",
        ),
        _n(0, 1, 2),
        DeployLifecycle.known_json_names(),
    )
    _census[SecretCustody](
        "SecretCustody",
        _l(
            "SECRET_CUSTODY_UNSPECIFIED",
            "SECRET_CUSTODY_CUSTOMER",
            "SECRET_CUSTODY_OPERATOR",
            "SECRET_CUSTODY_PLATFORM_MINTED",
        ),
        _n(0, 1, 2, 3),
        SecretCustody.known_json_names(),
    )


# ---- 3. the reserved DatastoreNeed value -----------------------------------------


def test_datastore_need_3_is_reserved() raises:
    assert_equal(
        DatastoreNeed.from_number(3).json_name(),
        "3",
        "a declaration owns DatastoreNeed 3, which is reserved",
    )
    assert_false(
        DatastoreNeed.is_known_json_name("DATASTORE_NEED_OBJECTSTORE"),
        "the reserved name DATASTORE_NEED_OBJECTSTORE is declared again",
    )


# ---- 4. round trips -----------------------------------------------------------


def test_round_trips() raises:
    var want = _spec_bytes()
    _expect(
        "binary round trip",
        encode_proto(decode_proto[DeploymentSpec](encode_proto(_spec()))),
        want,
    )
    _expect(
        "proto3-JSON round trip",
        encode_proto(decode_json[DeploymentSpec](encode_json(_spec()))),
        want,
    )


def main() raises:
    print("test_leaf_message_bytes")
    test_leaf_message_bytes()
    print("test_nested_message_bytes")
    test_nested_message_bytes()
    print("test_deployment_spec_bytes")
    test_deployment_spec_bytes()
    print("test_enum_census")
    test_enum_census()
    print("test_datastore_need_3_is_reserved")
    test_datastore_need_3_is_reserved()
    print("test_round_trips")
    test_round_trips()
    print("test_deploy_model_wire: PASS")
