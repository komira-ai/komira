# =============================================================================
# test_fake_bucket_retention.mojo
# =============================================================================
#
# The bucket primitive and retention, on the fake clouds.
#
# 1. THE KIT WITH A BUCKET ON EVERY SHAPE: the kci_cloud conformance kit (all
#    twelve steps) passes on the generic, aws, gcp, azure and onprem shapes, each under
#    a random id, on a graph with a bucket (retention DELETE, so the kit's
#    destroy may remove it), a service that uses it READ_WRITE and reads its
#    NAME, and a public service; the tampered node is the bucket.
# 2. A GOLDEN BUCKET LOWERING: on the generic shape, every modelled field with
#    its default filled in (expiry `never`, versioning `false`, tier
#    `STANDARD`) and the retention kci set; per shape, the provider kind
#    (`AWS::S3::Bucket`, `storage.googleapis.com/Bucket`,
#    `Microsoft.Storage/storageAccounts/blobServices/containers`,
#    `minio/Bucket`: an S3-API bucket on the cell's MinIO). A grant on a
#    bucket depends on `<id>/bucket`.
# 3. VALUES FLOW FROM A BUCKET: a service reading a bucket's NAME and ADDRESS
#    is created over the bucket's real values.
# 4. KEEP IS STAMPED AND DESTROY SKIPS IT: a bucket with no retention written
#    is KEEP; its object carries the retention mark `kci-retention=retain`
#    (a legal label, outside the identity; a service's reads `delete`),
#    `list_owned` reports it
#    retained, and destroy deletes everything else and leaves it.
# 5. THE KEEP GAP: re-using a KEEP bucket's id for a service turns the
#    bucket's node off. The bucket is LEFT BEHIND (reported in the outcome,
#    still live), never deleted. The same move with `retention: DELETE`
#    deletes it, so the path is really reached.
# 6. A KEEP BUCKET GONE FROM THE FILE is leftover: reported, not deleted.
# 7. A RETENTION CHANGE IS AN UPDATE: KEEP -> DELETE updates the bucket and
#    rewrites its `kci-retention` mark to `delete` in the same call (one
#    mark, never two); it is then deletable.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import decode_json
from kci_reconciler import (
    AppliedNode,
    CellScope,
    Creds,
    InMemoryStateStore,
    Label,
    Provenance,
    VERB_CREATE,
    VERB_DELETE,
    VERB_UPDATE,
)
from kci_cloud import (
    ApplyOutcome,
    Catalog,
    CellContext,
    Clouds,
    apply_resources,
    describe,
    destroy_resources,
    label_problems,
    lower_data,
    lowering_json,
    retained_by,
    retention_label_key,
    run_conformance,
)
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud_fake import FakeCloud, ProviderShape, fake_bucket_address, fake_bucket_name


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _ctx() -> CellContext:
    return CellContext(CellScope(String("shop"), String("blue"), Provenance(String("run-1"), String("rev-1"))))


def _done(outcome: ApplyOutcome) raises -> List[AppliedNode]:
    if outcome.error:
        raise Error(String("the apply stopped: ") + outcome.error.value())
    return outcome.applied.copy()


def _mark(labels: List[Label]) raises -> String:
    """The one `kci-retention` value `labels` carry; raises on two."""
    var key = retention_label_key()
    var got = String("(none)")
    var n = 0
    for i in range(len(labels)):
        if labels[i].key == key:
            got = labels[i].value.copy()
            n += 1
    if n > 1:
        raise Error(String("two retention marks"))
    return got^


def _verb(applied: List[AppliedNode], id: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == id:
            return applied[i].verb
    return -1


def _shapes() -> List[ProviderShape]:
    var l = List[ProviderShape]()
    l.append(ProviderShape.generic())
    l.append(ProviderShape.aws())
    l.append(ProviderShape.gcp())
    l.append(ProviderShape.azure())
    l.append(ProviderShape.onprem())
    return l^


def _reg(cloud: FakeCloud) raises -> Clouds:
    var reg = Clouds(Catalog.v1())
    reg.add(describe(cloud))
    return reg^


# ---- 1. the kit with a bucket ----------------------------------------------------------


def _storage(api_port: String, roles_on: Bool = True) -> String:
    """`roles_on` False makes api internal and removes web's grant on the
    bucket; web keeps reading the bucket's NAME (the kit's reference)."""
    var web_uses = String('"uses":[{"target":{"resource":"store"},"access":"READ_WRITE"}]},')
    var exposure = String('"public":{}')
    if not roles_on:
        web_uses = String('"uses":[]},')
        exposure = String('"internal":{}')
    return (
        String('{"resource":[')
        + String('{"id":"store","retention":"DELETE","bucket":{"versioning":true}},')
        + String('{"id":"web","service":{"image":{"digest":"sha256:c3"},"internal":{},"scale":{"min":1,"max":2},')
        + String('"env":{"STORE":{"ref":{"resource":"store","standard":"NAME"}}}},')
        + web_uses
        + String('{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":')
        + api_port
        + String(',"scale":{"min":1,"max":2},')
        + exposure
        + String("}}")
        + String("]}")
    )


def test_the_kit_with_a_bucket_on_every_shape() raises:
    var ids = List[String]()
    ids.append(String("p-1b44e0"))
    ids.append(String("p-6a02c9"))
    ids.append(String("p-d71f35"))
    ids.append(String("p-38be7a"))
    ids.append(String("p-c09d52"))
    var shapes = _shapes()
    assert_equal(len(shapes), len(ids), "one random id per shape")
    for s in range(len(shapes)):
        var cloud = FakeCloud(ids[s], shape=shapes[s].copy())
        var reg = _reg(FakeCloud(ids[s], shape=shapes[s].copy()))
        try:
            run_conformance(
                reg, cloud, _ctx(), _list(_storage("8080")), _list(_storage("9090")),
                _list(_storage("9090", False)), String("store/bucket"),
            )
        except e:
            raise Error(shapes[s].name + String(" shape: ") + String(e))
    print("  test_the_kit_with_a_bucket_on_every_shape: PASS")


# ---- 2. a golden bucket lowering --------------------------------------------------------


def _golden_graph() -> String:
    return String(
        '{"resource":['
        '{"id":"kept","bucket":{}},'
        '{"id":"logs","retention":"DELETE","bucket":{"objectExpiryDays":30,"versioning":true,"tier":"ARCHIVE"}}'
        "]}"
    )


def _golden(kind: String) -> String:
    return (
        String("[\n")
        + String('  {"id":"kept/bucket","owner":"kept","kind":"') + kind
        + String('","wanted":true,"retention":"keep","depends_on":[],"inputs":[],')
        + String('"desired":{"expiry_days":"never","versioning":"false","tier":"STANDARD","stores":"true"}},\n')
        + String('  {"id":"logs/bucket","owner":"logs","kind":"') + kind
        + String('","wanted":true,"retention":"delete","depends_on":[],"inputs":[],')
        + String('"desired":{"expiry_days":"30","versioning":"true","tier":"ARCHIVE","stores":"true"}}\n')
        + String("]")
    )


def test_golden_bucket_lowering_per_shape() raises:
    var kinds = List[String]()
    kinds.append(String("bucket"))
    kinds.append(String("AWS::S3::Bucket"))
    kinds.append(String("storage.googleapis.com/Bucket"))
    kinds.append(String("Microsoft.Storage/storageAccounts/blobServices/containers"))
    kinds.append(String("minio/Bucket"))
    var shapes = _shapes()
    assert_equal(len(shapes), len(kinds), "one bucket kind per shape")
    for s in range(len(shapes)):
        var cloud = FakeCloud(String("p-2c"), shape=shapes[s].copy())
        var got = lowering_json(lower_data(cloud, _list(_golden_graph())))
        assert_equal(got, _golden(kinds[s]), shapes[s].name)
        assert_equal(cloud.live_count(), 0, "lowering touched nothing")

    # A grant on a bucket hangs off the grantee's identity and depends on
    # the bucket's node.
    var aws = FakeCloud(String("p-2d"), shape=ProviderShape.aws())
    var nodes = lower_data(aws, _list(_storage("8080")))
    var found = False
    for i in range(len(nodes)):
        if nodes[i].id == "web/u-tx7pzu":
            found = True
            assert_equal(nodes[i].kind, "AWS::IAM::RolePolicy")
            assert_equal(len(nodes[i].depends_on), 2)
            assert_equal(nodes[i].depends_on[0], "web/identity")
            assert_equal(nodes[i].depends_on[1], "store/bucket", "the grant waits for the bucket")
            assert_equal(nodes[i].field(String("access")), "READ_WRITE")
    assert_true(found, "web's grant on the bucket is lowered")

    # On onprem a bucket is MinIO's, so the grant is a MinIO policy, with no
    # Kubernetes Role helper.
    var onprem = FakeCloud(String("p-2e"), shape=ProviderShape.onprem())
    var on = lower_data(onprem, _list(_storage("8080")))
    var policy = False
    for i in range(len(on)):
        if on[i].id == "web/u-tx7pzu":
            policy = True
            assert_equal(on[i].kind, "minio:policy")
            assert_equal(len(on[i].depends_on), 2, "the identity and the bucket, no helper")
        assert_true(on[i].id != "web/r-tx7pzu", "a MinIO grant has no Role helper")
    assert_true(policy, "web's grant on the bucket is a MinIO policy on onprem")
    print("  test_golden_bucket_lowering_per_shape: PASS")


# ---- 3. values flow from a bucket -------------------------------------------------------


def test_values_flow_from_a_bucket() raises:
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var store = InMemoryStateStore()
    var json = String(
        '{"resource":['
        '{"id":"media","bucket":{}},'
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{},'
        '"env":{"NAME":{"ref":{"resource":"media","standard":"NAME"}},'
        '"ADDR":{"ref":{"resource":"media","standard":"ADDRESS"}}}},'
        '"uses":[{"target":{"resource":"media"},"access":"READ"}]}'
        "]}"
    )
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(json), Creds.none(), store))
    var i = cloud.store[].find(String("api/run"))
    assert_true(i >= 0, "api/run was created")
    var digest = cloud.store[].digests[i].copy()
    assert_true(_has(digest, String("service.env.NAME=") + fake_bucket_name(String("media"))), digest)
    assert_true(_has(digest, String("service.env.ADDR=") + fake_bucket_address(String("media"))), digest)
    print("  test_values_flow_from_a_bucket: PASS")


# ---- 4. KEEP is stamped and destroy skips it ---------------------------------------------


def _kept_and_api() -> String:
    return String(
        '{"resource":['
        '{"id":"store","bucket":{}},'
        '{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}},'
        '"uses":[{"target":{"resource":"store"},"access":"READ"}]}'
        "]}"
    )


def test_keep_is_stamped_and_destroy_skips_it() raises:
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_kept_and_api()), Creds.none(), store))
    var kept_labels = cloud.live_labels(String("store/bucket"))
    assert_true(retained_by(kept_labels), "a KEEP bucket carries kci-retention=retain")
    assert_equal(_mark(kept_labels), "retain")
    assert_equal(len(label_problems(kept_labels)), 0, "the mark obeys the standard label rule")
    assert_equal(
        cloud.identity_of(kept_labels),
        _ctx().scope.stamp(String("store"), String("store/bucket")).identity(),
        "the mark is not part of the identity",
    )
    assert_false(retained_by(cloud.live_labels(String("api/run"))), "a service does not")
    assert_equal(_mark(cloud.live_labels(String("api/run"))), "delete", "a DELETE node's mark")
    var ctx = _ctx()
    var owned = cloud.list_owned(Creds.none(), ctx.scope)
    for k in range(len(owned)):
        assert_equal(
            owned[k].retained,
            owned[k].owner_node == "store/bucket",
            owned[k].owner_node + ": retained iff the KEEP bucket",
        )
    _ = destroy_resources(reg, cloud, _ctx(), _list(_kept_and_api()), Creds.none(), store)
    assert_equal(cloud.live_count(), 1, "only the kept bucket is left")
    assert_true(cloud.store[].find(String("store/bucket")) >= 0, "the KEEP bucket survives destroy")
    print("  test_keep_is_stamped_and_destroy_skips_it: PASS")


# ---- 5. the KEEP gap -------------------------------------------------------------------------


def _bucket(retention: String) -> String:
    var r = String("")
    if retention.byte_length() > 0:
        r = String('"retention":"') + retention + String('",')
    return String('{"resource":[{"id":"store",') + r + String('"bucket":{}}]}')


comptime _RETYPED = '{"resource":[{"id":"store","service":{"image":{"digest":"sha256:a1"},"internal":{}}}]}'


def test_a_kept_bucket_turned_off_is_left_behind() raises:
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_bucket(String(""))), Creds.none(), store))
    var outcome = apply_resources(reg, cloud, _ctx(), _list(String(_RETYPED)), Creds.none(), store)
    var applied = _done(outcome)
    assert_true(cloud.store[].find(String("store/bucket")) >= 0, "the KEEP bucket is NOT deleted")
    assert_true(_verb(applied, String("store/bucket")) != VERB_DELETE, "no delete was issued")
    assert_equal(len(outcome.left_behind), 1, "it is reported")
    assert_equal(outcome.left_behind[0], "store/bucket")
    assert_equal(_verb(applied, String("store/run")), VERB_CREATE, "the new service is created")

    # The control: the same move with retention DELETE deletes the bucket.
    var ctl = FakeCloud()
    var ctl_store = InMemoryStateStore()
    _ = _done(apply_resources(reg, ctl, _ctx(), _list(_bucket(String("DELETE"))), Creds.none(), ctl_store))
    var gone = apply_resources(reg, ctl, _ctx(), _list(String(_RETYPED)), Creds.none(), ctl_store)
    assert_equal(_verb(_done(gone), String("store/bucket")), VERB_DELETE, "a DELETE bucket turned off is deleted")
    assert_equal(len(gone.left_behind), 0)
    assert_true(ctl.store[].find(String("store/bucket")) < 0)
    print("  test_a_kept_bucket_turned_off_is_left_behind: PASS")


# ---- 6. a KEEP bucket gone from the file -----------------------------------------------------


def test_a_kept_bucket_gone_from_the_file_is_leftover() raises:
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_kept_and_api()), Creds.none(), store))
    var only_api = String(
        '{"resource":[{"id":"api","service":{"image":{"digest":"sha256:a1"},"internal":{}}}]}'
    )
    var outcome = apply_resources(reg, cloud, _ctx(), _list(only_api), Creds.none(), store)
    _ = _done(outcome)
    assert_true(cloud.store[].find(String("store/bucket")) >= 0, "not deleted")
    var reported = False
    for i in range(len(outcome.leftover)):
        if outcome.leftover[i] == "store/bucket":
            reported = True
    assert_true(reported, "reported as leftover")
    print("  test_a_kept_bucket_gone_from_the_file_is_leftover: PASS")


# ---- 7. a retention change is an update -------------------------------------------------------


def test_a_retention_change_is_an_update() raises:
    var cloud = FakeCloud()
    var reg = _reg(FakeCloud())
    var store = InMemoryStateStore()
    _ = _done(apply_resources(reg, cloud, _ctx(), _list(_bucket(String(""))), Creds.none(), store))
    assert_true(retained_by(cloud.live_labels(String("store/bucket"))))
    var flip = _done(apply_resources(reg, cloud, _ctx(), _list(_bucket(String("DELETE"))), Creds.none(), store))
    assert_equal(_verb(flip, String("store/bucket")), VERB_UPDATE, "KEEP -> DELETE is an update")
    var labels = cloud.live_labels(String("store/bucket"))
    assert_false(retained_by(labels), "the update rewrote the mark")
    assert_equal(_mark(labels), "delete", "one mark, now delete")
    assert_equal(len(labels), 7, "the six identity labels and the one mark")
    var back = _done(apply_resources(reg, cloud, _ctx(), _list(_bucket(String("KEEP"))), Creds.none(), store))
    assert_equal(_verb(back, String("store/bucket")), VERB_UPDATE, "DELETE -> KEEP is an update")
    assert_true(retained_by(cloud.live_labels(String("store/bucket"))), "and stamps retain again")
    assert_equal(_mark(cloud.live_labels(String("store/bucket"))), "retain")
    print("  test_a_retention_change_is_an_update: PASS")


def main() raises:
    print("test_fake_bucket_retention")
    # The KEEP gap first: a probe that breaks retention must show it red.
    test_a_kept_bucket_turned_off_is_left_behind()
    test_the_kit_with_a_bucket_on_every_shape()
    test_golden_bucket_lowering_per_shape()
    test_values_flow_from_a_bucket()
    test_keep_is_stamped_and_destroy_skips_it()
    test_a_kept_bucket_gone_from_the_file_is_leftover()
    test_a_retention_change_is_an_update()
    print("ALL kci_cloud_fake BUCKET AND RETENTION TESTS PASSED")
