# The requests komira_aws_dynamodb builds, exactly: method, path, the
# awsJson 1.0 headers (X-Amz-Target `DynamoDB_20120810.<Operation>`,
# Content-Type `application/x-amz-json-1.0`) and the body, members in the
# model's order and an unset member absent. One or more rows per
# operation, in the shapes the Amazon DynamoDB API reference documents:
# items read, written, updated and deleted with expressions, a query page
# and a parallel scan segment, and a table created, described, updated,
# with its TTL and point-in-time recovery read and set, and deleted. Every
# AttributeValue type is sent once (`test_put_item_every_type`). The
# model's bounds are checked before a request exists.
from komira_aws_dynamodb.komira_aws_dynamodb import (
    DYNAMODB_CONTENT_TYPE,
    DYNAMODB_TARGET_PREFIX,
    DynamoDBAttributeDefinition,
    DynamoDBAttributeValue,
    DynamoDBCreateTableInput,
    DynamoDBDeleteItemInput,
    DynamoDBDeleteTableInput,
    DynamoDBDescribeContinuousBackupsInput,
    DynamoDBDescribeTableInput,
    DynamoDBDescribeTimeToLiveInput,
    DynamoDBGetItemInput,
    DynamoDBKeySchemaElement,
    DynamoDBPointInTimeRecoverySpecification,
    DynamoDBProvisionedThroughput,
    DynamoDBPutItemInput,
    DynamoDBQueryInput,
    DynamoDBScanInput,
    DynamoDBStreamSpecification,
    DynamoDBTag,
    DynamoDBTimeToLiveSpecification,
    DynamoDBUpdateContinuousBackupsInput,
    DynamoDBUpdateItemInput,
    DynamoDBUpdateTableInput,
    DynamoDBUpdateTimeToLiveInput,
    build_create_table_request,
    build_delete_item_request,
    build_delete_table_request,
    build_describe_continuous_backups_request,
    build_describe_table_request,
    build_describe_time_to_live_request,
    build_get_item_request,
    build_put_item_request,
    build_query_request,
    build_scan_request,
    build_update_continuous_backups_request,
    build_update_item_request,
    build_update_table_request,
    build_update_time_to_live_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


def _check_envelope(req: AwsRequest, op: String) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "DynamoDB_20120810." + op)
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.0")
    assert_equal(len(req.header_names), 2)


def _s(v: String) -> DynamoDBAttributeValue:
    var a = DynamoDBAttributeValue()
    a.set_s(v)
    return a^


def _n(v: String) -> DynamoDBAttributeValue:
    var a = DynamoDBAttributeValue()
    a.set_n(v)
    return a^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _key(pk: String) -> Dict[String, DynamoDBAttributeValue]:
    var k = Dict[String, DynamoDBAttributeValue]()
    k["pk"] = _s(pk)
    return k^


def test_wire_constants() raises:
    assert_equal(DYNAMODB_TARGET_PREFIX, "DynamoDB_20120810")
    assert_equal(DYNAMODB_CONTENT_TYPE, "application/x-amz-json-1.0")


# ---- items -------------------------------------------------------------------


def test_get_item() raises:
    var input = DynamoDBGetItemInput(String("routes"), _key(String("route#1")))
    input.set_consistent_read(True)
    var req = build_get_item_request(input)
    _check_envelope(req, String("GetItem"))
    assert_equal(
        req.body_text(),
        '{"TableName":"routes","Key":{"pk":{"S":"route#1"}},"ConsistentRead":true}',
    )


def test_get_item_projection() raises:
    var key = _key(String("r"))
    key["sk"] = _n(String("7"))
    var input = DynamoDBGetItemInput(String("routes"), key^)
    input.set_return_consumed_capacity(String("TOTAL"))
    input.set_projection_expression(String("#d, target"))
    var names = Dict[String, String]()
    names["#d"] = String("domain")
    input.set_expression_attribute_names(names^)
    var req = build_get_item_request(input)
    assert_equal(
        req.body_text(),
        '{"TableName":"routes","Key":{"pk":{"S":"r"},"sk":{"N":"7"}},'
        + '"ReturnConsumedCapacity":"TOTAL","ProjectionExpression":"#d, target",'
        + '"ExpressionAttributeNames":{"#d":"domain"}}',
    )


def test_put_item_conditional() raises:
    var item = _key(String("route#1"))
    item["n"] = _n(String("3"))
    var input = DynamoDBPutItemInput(String("routes"), item^)
    input.set_condition_expression(String("attribute_not_exists(pk)"))
    var req = build_put_item_request(input)
    _check_envelope(req, String("PutItem"))
    assert_equal(
        req.body_text(),
        '{"TableName":"routes","Item":{"pk":{"S":"route#1"},"n":{"N":"3"}},'
        + '"ConditionExpression":"attribute_not_exists(pk)"}',
    )


def test_put_item_every_type() raises:
    # Each AttributeValue sets exactly one member, and the wire key is its
    # type: S, N, B (base64), SS, NS, BS, M, L, NULL, BOOL.
    var item = Dict[String, DynamoDBAttributeValue]()
    item["s"] = _s(String("text"))
    item["n"] = _n(String("-12.5E3"))
    var b = DynamoDBAttributeValue()
    b.set_b(_bytes(String("hi!")))
    item["b"] = b^
    var ss = DynamoDBAttributeValue()
    var ss_v: List[String] = [String("a"), String("b")]
    ss.set_ss(ss_v^)
    item["ss"] = ss^
    var ns = DynamoDBAttributeValue()
    var ns_v: List[String] = [String("1"), String("2.5")]
    ns.set_ns(ns_v^)
    item["ns"] = ns^
    var bs = DynamoDBAttributeValue()
    var bs_v = List[List[UInt8]]()
    bs_v.append(_bytes(String("a")))
    bs_v.append(List[UInt8]())
    bs.set_bs(bs_v^)
    item["bs"] = bs^
    var m = DynamoDBAttributeValue()
    var inner = Dict[String, DynamoDBAttributeValue]()
    inner["x"] = _n(String("1"))
    m.set_m(inner^)
    item["m"] = m^
    var l = DynamoDBAttributeValue()
    var lv = List[DynamoDBAttributeValue]()
    lv.append(_s(String("one")))
    var nested = DynamoDBAttributeValue()
    var nested_v = List[DynamoDBAttributeValue]()
    nested_v.append(_n(String("2")))
    nested.set_l(nested_v^)
    lv.append(nested^)
    l.set_l(lv^)
    item["l"] = l^
    var null = DynamoDBAttributeValue()
    null.set_null(True)
    item["null"] = null^
    var flag = DynamoDBAttributeValue()
    flag.set_bool(False)
    item["flag"] = flag^
    var req = build_put_item_request(DynamoDBPutItemInput(String("t"), item^))
    assert_equal(
        req.body_text(),
        '{"TableName":"t","Item":{"s":{"S":"text"},"n":{"N":"-12.5E3"},'
        + '"b":{"B":"aGkh"},"ss":{"SS":["a","b"]},"ns":{"NS":["1","2.5"]},'
        + '"bs":{"BS":["YQ==",""]},"m":{"M":{"x":{"N":"1"}}},'
        + '"l":{"L":[{"S":"one"},{"L":[{"N":"2"}]}]},"null":{"NULL":true},'
        + '"flag":{"BOOL":false}}}',
    )


def test_update_item() raises:
    var input = DynamoDBUpdateItemInput(String("routes"), _key(String("r")))
    input.set_return_values(String("ALL_NEW"))
    input.set_update_expression(String("SET #c = #c + :one"))
    input.set_condition_expression(String("attribute_exists(pk)"))
    var names = Dict[String, String]()
    names["#c"] = String("count")
    input.set_expression_attribute_names(names^)
    var values = Dict[String, DynamoDBAttributeValue]()
    values[":one"] = _n(String("1"))
    input.set_expression_attribute_values(values^)
    input.set_return_values_on_condition_check_failure(String("ALL_OLD"))
    var req = build_update_item_request(input)
    _check_envelope(req, String("UpdateItem"))
    assert_equal(
        req.body_text(),
        '{"TableName":"routes","Key":{"pk":{"S":"r"}},"ReturnValues":"ALL_NEW",'
        + '"UpdateExpression":"SET #c = #c + :one",'
        + '"ConditionExpression":"attribute_exists(pk)",'
        + '"ExpressionAttributeNames":{"#c":"count"},'
        + '"ExpressionAttributeValues":{":one":{"N":"1"}},'
        + '"ReturnValuesOnConditionCheckFailure":"ALL_OLD"}',
    )


def test_delete_item() raises:
    var input = DynamoDBDeleteItemInput(String("routes"), _key(String("r")))
    input.set_return_values(String("ALL_OLD"))
    input.set_condition_expression(String("v = :v"))
    var values = Dict[String, DynamoDBAttributeValue]()
    values[":v"] = _n(String("2"))
    input.set_expression_attribute_values(values^)
    var req = build_delete_item_request(input)
    _check_envelope(req, String("DeleteItem"))
    assert_equal(
        req.body_text(),
        '{"TableName":"routes","Key":{"pk":{"S":"r"}},"ReturnValues":"ALL_OLD",'
        + '"ConditionExpression":"v = :v","ExpressionAttributeValues":{":v":{"N":"2"}}}',
    )


def test_query_page() raises:
    var input = DynamoDBQueryInput(String("events"))
    input.set_index_name(String("by-time"))
    input.set_limit(Int32(25))
    input.set_consistent_read(False)
    input.set_scan_index_forward(False)
    var start = _key(String("t#1"))
    start["ts"] = _n(String("100"))
    input.set_exclusive_start_key(start^)
    input.set_key_condition_expression(String("pk = :p AND ts > :t"))
    var values = Dict[String, DynamoDBAttributeValue]()
    values[":p"] = _s(String("t#1"))
    values[":t"] = _n(String("0"))
    input.set_expression_attribute_values(values^)
    var req = build_query_request(input)
    _check_envelope(req, String("Query"))
    assert_equal(
        req.body_text(),
        '{"TableName":"events","IndexName":"by-time","Limit":25,'
        + '"ConsistentRead":false,"ScanIndexForward":false,'
        + '"ExclusiveStartKey":{"pk":{"S":"t#1"},"ts":{"N":"100"}},'
        + '"KeyConditionExpression":"pk = :p AND ts > :t",'
        + '"ExpressionAttributeValues":{":p":{"S":"t#1"},":t":{"N":"0"}}}',
    )


def test_scan_segment() raises:
    var input = DynamoDBScanInput(String("jobs"))
    input.set_limit(Int32(100))
    input.set_select(String("COUNT"))
    input.set_total_segments(Int32(4))
    input.set_segment(Int32(1))
    input.set_filter_expression(String("#s = :s"))
    var names = Dict[String, String]()
    names["#s"] = String("state")
    input.set_expression_attribute_names(names^)
    var values = Dict[String, DynamoDBAttributeValue]()
    values[":s"] = _s(String("queued"))
    input.set_expression_attribute_values(values^)
    input.set_consistent_read(True)
    var req = build_scan_request(input)
    _check_envelope(req, String("Scan"))
    assert_equal(
        req.body_text(),
        '{"TableName":"jobs","Limit":100,"Select":"COUNT","TotalSegments":4,'
        + '"Segment":1,"FilterExpression":"#s = :s",'
        + '"ExpressionAttributeNames":{"#s":"state"},'
        + '"ExpressionAttributeValues":{":s":{"S":"queued"}},"ConsistentRead":true}',
    )


# ---- tables ------------------------------------------------------------------


def test_create_table_on_demand() raises:
    var input = DynamoDBCreateTableInput(String("routes"))
    var defs = List[DynamoDBAttributeDefinition]()
    defs.append(DynamoDBAttributeDefinition(String("pk"), String("S")))
    defs.append(DynamoDBAttributeDefinition(String("sk"), String("N")))
    input.set_attribute_definitions(defs^)
    var schema = List[DynamoDBKeySchemaElement]()
    schema.append(DynamoDBKeySchemaElement(String("pk"), String("HASH")))
    schema.append(DynamoDBKeySchemaElement(String("sk"), String("RANGE")))
    input.set_key_schema(schema^)
    input.set_billing_mode(String("PAY_PER_REQUEST"))
    var stream = DynamoDBStreamSpecification(True)
    stream.set_stream_view_type(String("NEW_AND_OLD_IMAGES"))
    input.set_stream_specification(stream^)
    var tags = List[DynamoDBTag]()
    tags.append(DynamoDBTag(String("team"), String("platform")))
    input.set_tags(tags^)
    input.set_deletion_protection_enabled(True)
    var req = build_create_table_request(input)
    _check_envelope(req, String("CreateTable"))
    assert_equal(
        req.body_text(),
        '{"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"},'
        + '{"AttributeName":"sk","AttributeType":"N"}],"TableName":"routes",'
        + '"KeySchema":[{"AttributeName":"pk","KeyType":"HASH"},'
        + '{"AttributeName":"sk","KeyType":"RANGE"}],"BillingMode":"PAY_PER_REQUEST",'
        + '"StreamSpecification":{"StreamEnabled":true,"StreamViewType":"NEW_AND_OLD_IMAGES"},'
        + '"Tags":[{"Key":"team","Value":"platform"}],"DeletionProtectionEnabled":true}',
    )


def test_create_table_provisioned() raises:
    var input = DynamoDBCreateTableInput(String("t"))
    var defs = List[DynamoDBAttributeDefinition]()
    defs.append(DynamoDBAttributeDefinition(String("pk"), String("B")))
    input.set_attribute_definitions(defs^)
    var schema = List[DynamoDBKeySchemaElement]()
    schema.append(DynamoDBKeySchemaElement(String("pk"), String("HASH")))
    input.set_key_schema(schema^)
    input.set_billing_mode(String("PROVISIONED"))
    input.set_provisioned_throughput(DynamoDBProvisionedThroughput(Int64(5), Int64(5)))
    assert_equal(
        build_create_table_request(input).body_text(),
        '{"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"B"}],'
        + '"TableName":"t","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"}],'
        + '"BillingMode":"PROVISIONED",'
        + '"ProvisionedThroughput":{"ReadCapacityUnits":5,"WriteCapacityUnits":5}}',
    )


def test_describe_and_delete_table() raises:
    var d = build_describe_table_request(DynamoDBDescribeTableInput(String("routes")))
    _check_envelope(d, String("DescribeTable"))
    assert_equal(d.body_text(), '{"TableName":"routes"}')
    # A table may be named by its ARN.
    var arn = build_delete_table_request(
        DynamoDBDeleteTableInput(String("arn:aws:dynamodb:us-east-1:123456789012:table/routes"))
    )
    _check_envelope(arn, String("DeleteTable"))
    assert_equal(
        arn.body_text(),
        '{"TableName":"arn:aws:dynamodb:us-east-1:123456789012:table/routes"}',
    )


def test_update_table() raises:
    var input = DynamoDBUpdateTableInput(String("routes"))
    input.set_billing_mode(String("PROVISIONED"))
    input.set_provisioned_throughput(DynamoDBProvisionedThroughput(Int64(10), Int64(5)))
    var req = build_update_table_request(input)
    _check_envelope(req, String("UpdateTable"))
    assert_equal(
        req.body_text(),
        '{"TableName":"routes","BillingMode":"PROVISIONED",'
        + '"ProvisionedThroughput":{"ReadCapacityUnits":10,"WriteCapacityUnits":5}}',
    )
    var off = DynamoDBUpdateTableInput(String("routes"))
    off.set_deletion_protection_enabled(False)
    assert_equal(
        build_update_table_request(off).body_text(),
        '{"TableName":"routes","DeletionProtectionEnabled":false}',
    )


def test_time_to_live() raises:
    var d = build_describe_time_to_live_request(DynamoDBDescribeTimeToLiveInput(String("routes")))
    _check_envelope(d, String("DescribeTimeToLive"))
    assert_equal(d.body_text(), '{"TableName":"routes"}')
    var u = build_update_time_to_live_request(
        DynamoDBUpdateTimeToLiveInput(
            String("routes"), DynamoDBTimeToLiveSpecification(True, String("expires_at"))
        )
    )
    _check_envelope(u, String("UpdateTimeToLive"))
    assert_equal(
        u.body_text(),
        '{"TableName":"routes","TimeToLiveSpecification":{"Enabled":true,'
        + '"AttributeName":"expires_at"}}',
    )


def test_continuous_backups() raises:
    var d = build_describe_continuous_backups_request(
        DynamoDBDescribeContinuousBackupsInput(String("routes"))
    )
    _check_envelope(d, String("DescribeContinuousBackups"))
    assert_equal(d.body_text(), '{"TableName":"routes"}')
    var spec = DynamoDBPointInTimeRecoverySpecification(True)
    spec.set_recovery_period_in_days(Int32(7))
    var u = build_update_continuous_backups_request(
        DynamoDBUpdateContinuousBackupsInput(String("routes"), spec^)
    )
    _check_envelope(u, String("UpdateContinuousBackups"))
    assert_equal(
        u.body_text(),
        '{"TableName":"routes","PointInTimeRecoverySpecification":'
        + '{"PointInTimeRecoveryEnabled":true,"RecoveryPeriodInDays":7}}',
    )


# ---- the model's bounds --------------------------------------------------------


def test_model_bounds() raises:
    with assert_raises(contains="DynamoDBGetItemInput.TableName: the model states min length 1"):
        _ = build_get_item_request(DynamoDBGetItemInput(String(""), _key(String("r"))))
    var q = DynamoDBQueryInput(String("t"))
    q.set_limit(Int32(0))
    with assert_raises(contains="DynamoDBQueryInput.Limit: the model states min value 1"):
        _ = build_query_request(q)
    var ix = DynamoDBQueryInput(String("t"))
    ix.set_index_name(String("ab"))
    with assert_raises(contains="DynamoDBQueryInput.IndexName: the model states min length 3"):
        _ = build_query_request(ix)
    var seg = DynamoDBScanInput(String("t"))
    seg.set_total_segments(Int32(1000001))
    with assert_raises(contains="DynamoDBScanInput.TotalSegments: the model states max value 1000000"):
        _ = build_scan_request(seg)
    var pitr = DynamoDBPointInTimeRecoverySpecification(True)
    pitr.set_recovery_period_in_days(Int32(36))
    with assert_raises(
        contains="DynamoDBPointInTimeRecoverySpecification.RecoveryPeriodInDays: the model states max value 35"
    ):
        _ = build_update_continuous_backups_request(
            DynamoDBUpdateContinuousBackupsInput(String("t"), pitr^)
        )
    var ct = DynamoDBCreateTableInput(String("t"))
    ct.set_key_schema(List[DynamoDBKeySchemaElement]())
    with assert_raises(contains="DynamoDBCreateTableInput.KeySchema: the model states min size 1"):
        _ = build_create_table_request(ct)
    var ttl = DynamoDBUpdateTimeToLiveInput(String("t"), DynamoDBTimeToLiveSpecification(True, String("")))
    with assert_raises(contains="DynamoDBTimeToLiveSpecification.AttributeName: the model states min length 1"):
        _ = build_update_time_to_live_request(ttl)


def main() raises:
    test_wire_constants()
    test_get_item()
    test_get_item_projection()
    test_put_item_conditional()
    test_put_item_every_type()
    test_update_item()
    test_delete_item()
    test_query_page()
    test_scan_segment()
    test_create_table_on_demand()
    test_create_table_provisioned()
    test_describe_and_delete_table()
    test_update_table()
    test_time_to_live()
    test_continuous_backups()
    test_model_bounds()
    print("OK")
