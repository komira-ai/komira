# The generated `kci_environment_proto` package on the proto binary wire.
#
# The round trips show that every `Environment` field, both arms of each
# binding (Firestore/DynamoDB, GCS/S3) and every enum survive encode + decode
# with their exact values. They cannot see a field RENUMBERING: the encoder and
# the decoder are generated from the same numbers, so both move together and a
# round trip stays green. A field number is a wire contract, so
# `test_environment_field_numbers_on_the_wire` pins each one as literal bytes.
#
# Non-default values are used wherever a field is pinned: a decoder that lost
# a field returns its default, so a pinned default would stay green over a
# dropped field.

from std.testing import assert_equal, assert_true, assert_false

from komira_serde import encode_proto, decode_proto

from kci_environment_proto.environment import (
    Environment,
    Cloud,
    DirectApply,
    EnvironmentKind,
    DatastoreBinding,
    FirestoreBinding,
    DynamodbBinding,
    ObjectstoreBinding,
    GcsBinding,
    S3Binding,
    BuildSpec,
    EnvironmentComputeEnvironment,
)


def test_environment_roundtrips() raises:
    """A cloud Environment binding round-trips: name / cloud / account /
    region / direct_apply with the Cloud and DirectApply enums surviving as
    their exact ordinals, plus fields 11-15."""
    var env = Environment(
        String("staging"),
        Cloud(Cloud.CLOUD_GCP),
        String("example-staging"),
        String("us-central1"),
        DirectApply(DirectApply.DIRECT_APPLY_PIPELINE_ONLY),
        # The dev/test model fields are unset here; they have their own test
        # below.
        EnvironmentKind(EnvironmentKind.ENVIRONMENT_KIND_UNSPECIFIED),
        Int32(0),  # deploy_provider UNSPECIFIED
        Optional[DatastoreBinding](None),
        Optional[ObjectstoreBinding](None),
        Optional[BuildSpec](None),
        String("111122223333"),  # project_number (field 11)
        # release_channel (field 12): the channel this control plane aliases.
        String("beta"),
        # tenancy (field 13): the `Tenancy` ordinal contract carried as an
        # int32. 1 = CONTROL_PLANE, non-default deliberately.
        Int32(1),
        # stage (field 14): the cross-cloud stage one service registry serves.
        String("staging"),
        # compute_environment (field 15): every sub-field non-default. egress 2
        # = EGRESS_MODE_PRIVATE_WITH_PUBLIC_EGRESS (the mirrored ordinal).
        Optional[EnvironmentComputeEnvironment](
            EnvironmentComputeEnvironment(
                String("us-central1-a"), Int32(2), True
            )
        ),
    )
    var bytes = encode_proto[Environment](env)
    var back = decode_proto[Environment](bytes^)
    assert_equal(back.name, String("staging"), "env name")
    assert_equal(back.cloud.value, Cloud.CLOUD_GCP, "cloud GCP")
    assert_equal(back.account_ref, String("example-staging"), "account_ref")
    assert_equal(back.region, String("us-central1"), "region")
    assert_equal(
        back.direct_apply.value,
        DirectApply.DIRECT_APPLY_PIPELINE_ONLY,
        "direct_apply PIPELINE_ONLY",
    )
    assert_equal(
        back.project_number,
        String("111122223333"),
        "project_number survives (field 11)",
    )
    assert_equal(
        back.release_channel,
        String("beta"),
        "release_channel survives the wire (field 12): the declared channel"
        " alias is what gives a channel exactly one control plane",
    )
    assert_equal(
        Int(back.tenancy),
        1,
        "tenancy survives the wire (field 13). A dropped field 13 decodes back"
        " to 0 (UNSPECIFIED), which reads as an environment that declared no"
        " owner, and the deploy-time placement refusal fails CLOSED on it",
    )
    assert_equal(
        back.stage,
        String("staging"),
        "stage survives the wire (field 14). It is NOT the release channel"
        " (field 12): a channel is a bijection whose resolver raises on two"
        " environments declaring it, and a stage is many-to-one by"
        " construction. Two fields, two cardinalities, one wire record",
    )
    assert_true(
        Bool(back.compute_environment),
        "compute_environment survives the wire (field 15). A dropped block"
        " reads as an environment that declares NO compute environment, and"
        " the job manager then refuses every VM placement into it",
    )
    ref ce = back.compute_environment.value()
    assert_equal(
        ce.zone, String("us-central1-a"), "compute_environment.zone (1)"
    )
    assert_equal(
        Int(ce.egress),
        2,
        "compute_environment.egress (2): PRIVATE_WITH_PUBLIC_EGRESS",
    )
    assert_true(
        ce.admit_cp_validation,
        "compute_environment.admit_cp_validation (3): a dropped TRUE decodes"
        " as false, which un-admits the control-plane-owned test customer",
    )
    print("  test_environment_roundtrips: PASS")


def test_environment_local_posture_roundtrips() raises:
    """A CLOUD_LOCAL / DIRECT_APPLY_ALLOWED dev environment (empty account and
    region) round-trips: the self-hosted laptop posture."""
    var env = Environment(
        String("dev-user"),
        Cloud(Cloud.CLOUD_LOCAL),
        String(""),
        String(""),
        DirectApply(DirectApply.DIRECT_APPLY_ALLOWED),
        EnvironmentKind(EnvironmentKind.ENVIRONMENT_KIND_UNSPECIFIED),
        Int32(0),
        Optional[DatastoreBinding](None),
        Optional[ObjectstoreBinding](None),
        Optional[BuildSpec](None),
        String(""),  # project_number (a pure-local environment has none)
        String(""),  # release_channel (a dev environment aliases none)
        # tenancy UNSPECIFIED (0): a laptop rung binds to no cloud account, so
        # it declares no owner. This arm pins 0 as a legal STORED value.
        Int32(0),
        # stage "": a laptop rung is in no stage. This arm pins "" as a legal
        # STORED value.
        String(""),
        # compute_environment ABSENT: a laptop rung places no customer VM.
        Optional[EnvironmentComputeEnvironment](None),
    )
    var bytes = encode_proto[Environment](env)
    var back = decode_proto[Environment](bytes^)
    assert_equal(back.name, String("dev-user"), "env name")
    assert_equal(back.cloud.value, Cloud.CLOUD_LOCAL, "cloud LOCAL")
    assert_equal(back.account_ref, String(""), "empty account_ref")
    assert_equal(
        back.direct_apply.value,
        DirectApply.DIRECT_APPLY_ALLOWED,
        "direct_apply ALLOWED",
    )
    print("  test_environment_local_posture_roundtrips: PASS")


def test_environment_dev_model_fields_roundtrip() raises:
    """The dev/test model fields survive the proto binary round-trip: kind
    (LOCAL), deploy_provider (K8S), the nested datastore -> firestore emulator
    binding (oneof `emulator_endpoint` + insecure + database), the
    objectstore -> gcs emulator binding, and build.in_pod."""
    var fb = FirestoreBinding(
        True,  # insecure
        # `database`, the second half of the Firestore address
        # (`projects/<project>/databases/<database>`). Non-empty on purpose.
        String("emulated-books"),
        2,  # oneof case 2 = emulator_endpoint arm
        Optional[String](None),  # project (unset)
        Optional[String](String("firestore-emulator:8080")),  # emulator_endpoint
    )
    var gb = GcsBinding(
        True,
        2,
        Optional[String](None),
        Optional[String](String("gcs-emulator:443")),
    )
    var env = Environment(
        String("local-gcp"),
        Cloud(Cloud.CLOUD_LOCAL),
        String(""),
        String(""),
        DirectApply(DirectApply.DIRECT_APPLY_ALLOWED),
        EnvironmentKind(EnvironmentKind.ENVIRONMENT_KIND_LOCAL),
        Int32(5),  # DEPLOY_PROVIDER_K8S
        Optional[DatastoreBinding](
            DatastoreBinding(
                Optional[FirestoreBinding](fb^), Optional[DynamodbBinding](None)
            )
        ),
        Optional[ObjectstoreBinding](
            ObjectstoreBinding(
                Optional[GcsBinding](gb^), Optional[S3Binding](None)
            )
        ),
        Optional[BuildSpec](BuildSpec(False)),  # in_pod = false (local build)
        String(""),  # project_number (a local environment has none)
        String(""),  # release_channel (a local rung aliases none)
        # tenancy CUSTOMER (2): the other non-zero ordinal, so the file
        # exercises both non-zero values of the closed set.
        Int32(2),
        String(""),  # stage: a local rung belongs to no stage
        Optional[EnvironmentComputeEnvironment](None),  # no customer VMs
    )
    var bytes = encode_proto[Environment](env)
    var back = decode_proto[Environment](bytes^)
    assert_equal(
        back.kind.value,
        EnvironmentKind.ENVIRONMENT_KIND_LOCAL,
        "kind LOCAL survives",
    )
    assert_equal(Int(back.deploy_provider), 5, "deploy_provider K8S survives")
    assert_true(Bool(back.datastore), "datastore binding present")
    assert_true(
        Bool(back.datastore.value().firestore), "firestore binding present"
    )
    assert_equal(
        back.datastore.value().firestore.value().emulator_endpoint.value(),
        String("firestore-emulator:8080"),
        "firestore emulator endpoint survives",
    )
    assert_true(
        back.datastore.value().firestore.value().insecure, "firestore insecure"
    )
    # The second half of the Firestore address survives the wire. Without
    # this, an encoder that dropped the field would make every environment
    # resolve an empty bookkeeping database, which the reader refuses: the
    # failure would surface as a refusal on a correctly authored registry
    # rather than as a serde bug.
    assert_equal(
        back.datastore.value().firestore.value().database,
        String("emulated-books"),
        "firestore bookkeeping database survives",
    )
    assert_equal(
        back.objectstore.value().gcs.value().emulator_endpoint.value(),
        String("gcs-emulator:443"),
        "gcs emulator endpoint survives",
    )
    assert_true(Bool(back.build), "build spec present")
    assert_false(back.build.value().in_pod, "build.in_pod=false survives")
    assert_equal(
        Int(back.tenancy),
        2,
        "tenancy CUSTOMER (2) survives field 13: the second non-zero ordinal,"
        " so an emitter that hardcoded the first would still fail here",
    )
    print("  test_environment_dev_model_fields_roundtrip: PASS")


def test_environment_aws_arms_roundtrip() raises:
    """The AWS arms round-trip: a CLOUD_AWS environment whose datastore is a
    DynamoDB table and whose object store is an S3 bucket. The GCP arms are
    left unset, so a decoder that read the wrong arm would come back empty."""
    var ddb = DynamodbBinding(
        False,  # insecure
        1,  # oneof case 1 = table arm
        Optional[String](String("example-routes")),
        Optional[String](None),
    )
    var s3 = S3Binding(
        False,
        1,  # oneof case 1 = bucket arm
        Optional[String](String("example-inbound")),
        Optional[String](None),
    )
    var env = Environment(
        String("staging-aws"),
        Cloud(Cloud.CLOUD_AWS),
        String("111122223333"),
        String("us-east-1"),
        DirectApply(DirectApply.DIRECT_APPLY_PIPELINE_ONLY),
        EnvironmentKind(EnvironmentKind.ENVIRONMENT_KIND_CLOUD),
        Int32(0),
        Optional[DatastoreBinding](
            DatastoreBinding(
                Optional[FirestoreBinding](None),
                Optional[DynamodbBinding](ddb^),
            )
        ),
        Optional[ObjectstoreBinding](
            ObjectstoreBinding(
                Optional[GcsBinding](None), Optional[S3Binding](s3^)
            )
        ),
        Optional[BuildSpec](None),
        String(""),
        String(""),
        Int32(2),
        String("staging"),
        Optional[EnvironmentComputeEnvironment](None),
    )
    var bytes = encode_proto[Environment](env)
    var back = decode_proto[Environment](bytes^)
    assert_equal(back.cloud.value, Cloud.CLOUD_AWS, "cloud AWS")
    assert_equal(
        back.kind.value, EnvironmentKind.ENVIRONMENT_KIND_CLOUD, "kind CLOUD"
    )
    ref ds = back.datastore.value()
    assert_false(Bool(ds.firestore), "the unset Firestore arm stays unset")
    assert_true(Bool(ds.dynamodb), "the DynamoDB arm survives")
    assert_equal(
        ds.dynamodb.value().table.value(),
        String("example-routes"),
        "dynamodb.table survives",
    )
    assert_false(
        Bool(ds.dynamodb.value().emulator_endpoint),
        "the other oneof arm stays unset",
    )
    ref obj = back.objectstore.value()
    assert_false(Bool(obj.gcs), "the unset GCS arm stays unset")
    assert_equal(
        obj.s3.value().bucket.value(),
        String("example-inbound"),
        "s3.bucket survives",
    )
    print("  test_environment_aws_arms_roundtrip: PASS")


def _empty_environment() -> Environment:
    """Every field at its proto3 default, so it encodes to zero bytes."""
    return Environment(
        String(""),
        Cloud(Cloud.CLOUD_UNSPECIFIED),
        String(""),
        String(""),
        DirectApply(DirectApply.DIRECT_APPLY_UNSPECIFIED),
        EnvironmentKind(EnvironmentKind.ENVIRONMENT_KIND_UNSPECIFIED),
        Int32(0),
        Optional[DatastoreBinding](None),
        Optional[ObjectstoreBinding](None),
        Optional[BuildSpec](None),
        String(""),
        String(""),
        Int32(0),
        String(""),
        Optional[EnvironmentComputeEnvironment](None),
    )


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def _hex(bytes: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var d = String(digits)
    var out = String("")
    for b in bytes:
        var hi = Int(b >> 4)
        var lo = Int(b & 0x0F)
        out += String(" ") + String(d[byte=hi : hi + 1]) + String(
            d[byte=lo : lo + 1]
        )
    return out


def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    if len(needle) == 0 or len(needle) > len(hay):
        return False
    for i in range(len(hay) - len(needle) + 1):
        var ok = True
        for j in range(len(needle)):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _check_bytes(
    mut fails: List[String],
    what: String,
    base: List[UInt8],
    env: Environment,
    want: List[UInt8],
) raises:
    """`want` (tag + payload) appears in `env`'s encoding and NOT in `base`,
    the encoding with every field at its default, so the segment is the one
    this field produced. The generated encoder also writes default-valued
    fields, so the check is on the segment, not on the whole message."""
    var got = encode_proto[Environment](env)
    if _contains(base, want):
        fails.append(
            what
            + String(": the all-default encoding already holds")
            + _hex(want)
        )
    elif not _contains(got, want):
        fails.append(
            what
            + String(": encoded")
            + _hex(got)
            + String(", want")
            + _hex(want)
        )


def test_environment_field_numbers_on_the_wire() raises:
    """Each `Environment` field, set alone, encodes as its tag byte
    (`(number << 3) | wiretype`) followed by its payload, so a renumbered
    field or a changed wire type fails here by name."""
    var fails = List[String]()
    var base = encode_proto[Environment](_empty_environment())

    # 'x' = 0x78. LEN fields carry wiretype 2, varint fields wiretype 0.
    var e1 = _empty_environment()
    e1.name = String("x")
    _check_bytes(fails, "name (1)", base, e1, _b(0x0A, 0x01, 0x78))
    var e2 = _empty_environment()
    e2.cloud = Cloud(Cloud.CLOUD_AWS)
    _check_bytes(fails, "cloud (2)", base, e2, _b(0x10, 0x02))
    var e3 = _empty_environment()
    e3.account_ref = String("x")
    _check_bytes(fails, "account_ref (3)", base, e3, _b(0x1A, 0x01, 0x78))
    var e4 = _empty_environment()
    e4.region = String("x")
    _check_bytes(fails, "region (4)", base, e4, _b(0x22, 0x01, 0x78))
    var e5 = _empty_environment()
    e5.direct_apply = DirectApply(DirectApply.DIRECT_APPLY_PIPELINE_ONLY)
    _check_bytes(fails, "direct_apply (5)", base, e5, _b(0x28, 0x02))
    var e6 = _empty_environment()
    e6.kind = EnvironmentKind(EnvironmentKind.ENVIRONMENT_KIND_LOCAL)
    _check_bytes(fails, "kind (6)", base, e6, _b(0x30, 0x02))
    var e7 = _empty_environment()
    e7.deploy_provider = Int32(5)
    _check_bytes(fails, "deploy_provider (7)", base, e7, _b(0x38, 0x05))
    # datastore (8) -> DatastoreBinding.dynamodb (2) -> DynamodbBinding.table
    # (1).
    var e8 = _empty_environment()
    e8.datastore = Optional[DatastoreBinding](
        DatastoreBinding(
            Optional[FirestoreBinding](None),
            Optional[DynamodbBinding](
                DynamodbBinding(
                    True,  # insecure, set so no field of it is a default
                    1,
                    Optional[String](String("x")),
                    Optional[String](None),
                )
            ),
        )
    )
    # The binding's own bytes are 5 in any field order (insecure 3 = 2
    # bytes, the table arm 1 = 3 bytes), so the outer lengths are fixed.
    _check_bytes(
        fails,
        "datastore (8) / dynamodb (2) (tags + lengths)",
        base,
        e8,
        _b(0x42, 0x07, 0x12, 0x05),
    )
    _check_bytes(
        fails,
        "datastore (8) / dynamodb (2) / table (1)",
        base,
        e8,
        _b(0x0A, 0x01, 0x78),
    )
    _check_bytes(
        fails,
        "datastore (8) / dynamodb (2) / insecure (3)",
        base,
        e8,
        _b(0x18, 0x01),
    )
    # objectstore (9) -> ObjectstoreBinding.s3 (2) -> S3Binding.bucket (1).
    var e9 = _empty_environment()
    e9.objectstore = Optional[ObjectstoreBinding](
        ObjectstoreBinding(
            Optional[GcsBinding](None),
            Optional[S3Binding](
                S3Binding(
                    True,  # insecure, set so no field of it is a default
                    1,
                    Optional[String](String("x")),
                    Optional[String](None),
                )
            ),
        )
    )
    # The binding's own bytes are 5 in any field order (insecure 3 = 2
    # bytes, the bucket arm 1 = 3 bytes), so the outer lengths are fixed.
    _check_bytes(
        fails,
        "objectstore (9) / s3 (2) (tags + lengths)",
        base,
        e9,
        _b(0x4A, 0x07, 0x12, 0x05),
    )
    _check_bytes(
        fails,
        "objectstore (9) / s3 (2) / bucket (1)",
        base,
        e9,
        _b(0x0A, 0x01, 0x78),
    )
    _check_bytes(
        fails,
        "objectstore (9) / s3 (2) / insecure (3)",
        base,
        e9,
        _b(0x18, 0x01),
    )
    var e10 = _empty_environment()
    e10.build = Optional[BuildSpec](BuildSpec(True))
    _check_bytes(
        fails, "build (10) / in_pod (1)", base, e10, _b(0x52, 0x02, 0x08, 0x01)
    )
    var e11 = _empty_environment()
    e11.project_number = String("x")
    _check_bytes(fails, "project_number (11)", base, e11, _b(0x5A, 0x01, 0x78))
    var e12 = _empty_environment()
    e12.release_channel = String("x")
    _check_bytes(fails, "release_channel (12)", base, e12, _b(0x62, 0x01, 0x78))
    var e13 = _empty_environment()
    e13.tenancy = Int32(2)
    _check_bytes(fails, "tenancy (13)", base, e13, _b(0x68, 0x02))
    var e14 = _empty_environment()
    e14.stage = String("x")
    _check_bytes(fails, "stage (14)", base, e14, _b(0x72, 0x01, 0x78))
    # compute_environment (15) with zone (1) "x", egress (2) = 2 and
    # admit_cp_validation (3) = true: 3 + 2 + 2 = 7 payload bytes.
    var e15 = _empty_environment()
    e15.compute_environment = Optional[EnvironmentComputeEnvironment](
        EnvironmentComputeEnvironment(String("x"), Int32(2), True)
    )
    _check_bytes(
        fails,
        "compute_environment (15) / zone (1), egress (2), admit (3)",
        base,
        e15,
        _b(0x7A, 0x07, 0x0A, 0x01, 0x78, 0x10, 0x02, 0x18, 0x01),
    )

    if len(fails) > 0:
        var msg = String("field numbers changed on the wire:")
        for f in fails:
            msg += String("\n  ") + f
        raise Error(msg)
    print("  test_environment_field_numbers_on_the_wire: PASS")


def main() raises:
    test_environment_roundtrips()
    test_environment_local_posture_roundtrips()
    test_environment_dev_model_fields_roundtrip()
    test_environment_aws_arms_roundtrip()
    test_environment_field_numbers_on_the_wire()
