# The responses komira_aws_dynamodb decodes, one or more rows per
# operation, and the error forms DynamoDB answers with. The wire texts are
# written here from the Amazon DynamoDB API reference (the operations'
# response syntax and "Error handling with DynamoDB"), with made-up tables,
# keys and ids. Item rows cover every AttributeValue type decoded;
# timestamps are epoch seconds with a fraction, as DynamoDB sends them.
#
# Errors. A caller reads a failure through komira_aws_core's
# `aws_json_error_info` (the code from `X-Amzn-Errortype`, else from the
# body's `__type`, cut to the short name; the message from `message`; the
# request id from `x-amzn-RequestId`), then, knowing the code, decodes the
# modeled error shape: ConditionalCheckFailedException carries the item
# when the request asked for it (`ReturnValuesOnConditionCheckFailure`).
from komira_aws_dynamodb.komira_aws_dynamodb import (
    DynamoDBConditionalCheckFailedException,
    DynamoDBResourceNotFoundException,
    parse_create_table_response,
    parse_delete_item_response,
    parse_delete_table_response,
    parse_describe_continuous_backups_response,
    parse_describe_table_response,
    parse_describe_time_to_live_response,
    parse_get_item_response,
    parse_put_item_response,
    parse_query_response,
    parse_scan_response,
    parse_update_continuous_backups_response,
    parse_update_item_response,
    parse_update_table_response,
    parse_update_time_to_live_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


# ---- items -------------------------------------------------------------------


comptime _ITEM = (
    '{"Item":{"pk":{"S":"route#1"},"n":{"N":"3"},"tags":{"SS":["a","b"]},'
    + '"nums":{"NS":["1","2.5"]},"blob":{"B":"aGkh"},"blobs":{"BS":["YQ==",""]},'
    + '"meta":{"M":{"ok":{"BOOL":true},"none":{"NULL":true}}},'
    + '"list":{"L":[{"N":"1"},{"L":[{"S":"x"}]}]}},'
    + '"ConsumedCapacity":{"TableName":"routes","CapacityUnits":0.5}}'
)


def test_get_item_every_type() raises:
    var r = parse_get_item_response(_ok(String(_ITEM)))
    var item = r.item.value().copy()
    assert_equal(len(item), 8)
    assert_equal(item["pk"].s.value(), "route#1")
    assert_equal(item["n"].n.value(), "3")
    assert_equal(len(item["tags"].ss.value()), 2)
    assert_equal(item["tags"].ss.value()[1], "b")
    assert_equal(item["nums"].ns.value()[1], "2.5")
    var blob = item["blob"].b.value().copy()
    assert_equal(len(blob), 3)
    assert_equal(blob[0], UInt8(104))
    assert_equal(blob[2], UInt8(33))
    assert_equal(len(item["blobs"].bs.value()[0]), 1)
    assert_equal(len(item["blobs"].bs.value()[1]), 0)
    # M and L hold their values (one entry each when set).
    assert_equal(len(item["meta"].m), 1)
    assert_true(item["meta"].m[0]["ok"].bool.value())
    assert_true(item["meta"].m[0]["none"].null.value())
    assert_equal(len(item["list"].l), 1)
    ref lst = item["list"].l[0]
    assert_equal(len(lst), 2)
    assert_equal(lst[0].n.value(), "1")
    assert_equal(lst[1].l[0][0].s.value(), "x")
    # Exactly one member is set on a decoded value.
    assert_false(Bool(item["pk"].n))
    assert_equal(len(item["pk"].m), 0)
    var cap = r.consumed_capacity.value().copy()
    assert_equal(cap.table_name.value(), "routes")
    assert_equal(cap.capacity_units.value(), Float64(0.5))


def test_get_item_not_found() raises:
    # No item under the key: an empty object, so `item` is unset.
    var r = parse_get_item_response(_ok(String("{}")))
    assert_false(Bool(r.item))


def test_put_update_delete_item() raises:
    assert_false(Bool(parse_put_item_response(_ok(String("{}"))).attributes))
    var old = parse_put_item_response(_ok(String('{"Attributes":{"pk":{"S":"r"},"n":{"N":"2"}}}')))
    assert_equal(old.attributes.value()["n"].n.value(), "2")
    var upd = parse_update_item_response(_ok(String('{"Attributes":{"count":{"N":"8"}}}')))
    assert_equal(upd.attributes.value()["count"].n.value(), "8")
    var del_ = parse_delete_item_response(
        _ok(
            String(
                '{"Attributes":{"pk":{"S":"r"},"v":{"N":"2"}},'
                + '"ConsumedCapacity":{"TableName":"routes","CapacityUnits":1.0}}'
            )
        )
    )
    assert_equal(del_.attributes.value()["v"].n.value(), "2")
    assert_equal(del_.consumed_capacity.value().capacity_units.value(), Float64(1.0))


def test_query_page() raises:
    var r = parse_query_response(
        _ok(
            String(
                '{"Count":2,"Items":[{"pk":{"S":"t#1"},"ts":{"N":"150"}},'
                + '{"pk":{"S":"t#1"},"ts":{"N":"200"}}],"ScannedCount":2,'
                + '"LastEvaluatedKey":{"pk":{"S":"t#1"},"ts":{"N":"200"}}}'
            )
        )
    )
    assert_equal(r.count.value(), Int32(2))
    assert_equal(r.scanned_count.value(), Int32(2))
    var items = r.items.value().copy()
    assert_equal(len(items), 2)
    assert_equal(items[1]["ts"].n.value(), "200")
    assert_equal(r.last_evaluated_key.value()["ts"].n.value(), "200")


def test_query_last_page() raises:
    var r = parse_query_response(_ok(String('{"Count":0,"Items":[],"ScannedCount":0}')))
    assert_equal(len(r.items.value()), 0)
    assert_false(Bool(r.last_evaluated_key))


def test_scan_count() raises:
    # Select COUNT answers counts and no Items.
    var r = parse_scan_response(_ok(String('{"Count":42,"ScannedCount":1000}')))
    assert_equal(r.count.value(), Int32(42))
    assert_equal(r.scanned_count.value(), Int32(1000))
    assert_false(Bool(r.items))


# ---- tables ------------------------------------------------------------------


comptime _TABLE = (
    '{"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"}],'
    + '"TableName":"routes","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"}],'
    + '"TableStatus":"ACTIVE","CreationDateTime":1790812800.123,'
    + '"ProvisionedThroughput":{"NumberOfDecreasesToday":0,"ReadCapacityUnits":0,'
    + '"WriteCapacityUnits":0},"TableSizeBytes":1024,"ItemCount":3,'
    + '"TableArn":"arn:aws:dynamodb:us-east-1:123456789012:table/routes",'
    + '"TableId":"0bd3f1c2-0000-4000-8000-1234567890ab",'
    + '"BillingModeSummary":{"BillingMode":"PAY_PER_REQUEST",'
    + '"LastUpdateToPayPerRequestDateTime":1790812800.123},'
    + '"StreamSpecification":{"StreamEnabled":true,"StreamViewType":"NEW_AND_OLD_IMAGES"},'
    + '"LatestStreamArn":"arn:aws:dynamodb:us-east-1:123456789012:table/routes/stream/2026-10-01T00:00:00.000",'
    + '"DeletionProtectionEnabled":true,"FutureMember":{"x":1}}'
)


def test_describe_table() raises:
    var r = parse_describe_table_response(_ok('{"Table":' + String(_TABLE) + "}"))
    var t = r.table.value().copy()
    assert_equal(t.table_name.value(), "routes")
    assert_equal(t.table_status.value(), "ACTIVE")
    assert_equal(t.creation_date_time.value(), Float64(1790812800.123))
    assert_equal(t.table_size_bytes.value(), Int64(1024))
    assert_equal(t.item_count.value(), Int64(3))
    assert_equal(t.attribute_definitions.value()[0].attribute_type, "S")
    assert_equal(t.key_schema.value()[0].key_type, "HASH")
    assert_equal(t.provisioned_throughput.value().read_capacity_units.value(), Int64(0))
    assert_equal(t.billing_mode_summary.value().billing_mode.value(), "PAY_PER_REQUEST")
    assert_true(t.stream_specification.value().stream_enabled)
    assert_equal(
        t.stream_specification.value().stream_view_type.value(), "NEW_AND_OLD_IMAGES"
    )
    assert_true(t.deletion_protection_enabled.value())
    assert_true(t.latest_stream_arn.value().endswith("/stream/2026-10-01T00:00:00.000"))


def test_create_update_delete_table() raises:
    var c = parse_create_table_response(
        _ok('{"TableDescription":{"TableName":"routes","TableStatus":"CREATING"}}')
    )
    assert_equal(c.table_description.value().table_status.value(), "CREATING")
    var u = parse_update_table_response(
        _ok('{"TableDescription":' + String(_TABLE).replace('"ACTIVE"', '"UPDATING"') + "}")
    )
    assert_equal(u.table_description.value().table_status.value(), "UPDATING")
    var d = parse_delete_table_response(
        _ok('{"TableDescription":{"TableName":"routes","TableStatus":"DELETING","ItemCount":0}}')
    )
    assert_equal(d.table_description.value().table_status.value(), "DELETING")
    assert_equal(d.table_description.value().item_count.value(), Int64(0))


def test_time_to_live() raises:
    var d = parse_describe_time_to_live_response(
        _ok('{"TimeToLiveDescription":{"TimeToLiveStatus":"ENABLED","AttributeName":"expires_at"}}')
    )
    assert_equal(d.time_to_live_description.value().time_to_live_status.value(), "ENABLED")
    assert_equal(d.time_to_live_description.value().attribute_name.value(), "expires_at")
    var off = parse_describe_time_to_live_response(
        _ok('{"TimeToLiveDescription":{"TimeToLiveStatus":"DISABLED"}}')
    )
    assert_false(Bool(off.time_to_live_description.value().attribute_name))
    var u = parse_update_time_to_live_response(
        _ok('{"TimeToLiveSpecification":{"Enabled":true,"AttributeName":"expires_at"}}')
    )
    assert_true(u.time_to_live_specification.value().enabled)
    assert_equal(u.time_to_live_specification.value().attribute_name, "expires_at")


def test_continuous_backups() raises:
    comptime body = (
        '{"ContinuousBackupsDescription":{"ContinuousBackupsStatus":"ENABLED",'
        + '"PointInTimeRecoveryDescription":{"PointInTimeRecoveryStatus":"ENABLED",'
        + '"RecoveryPeriodInDays":7,"EarliestRestorableDateTime":1790812800,'
        + '"LatestRestorableDateTime":1790899200.5}}}'
    )
    var d = parse_describe_continuous_backups_response(_ok(String(body)))
    var cb = d.continuous_backups_description.value().copy()
    assert_equal(cb.continuous_backups_status, "ENABLED")
    var p = cb.point_in_time_recovery_description.value().copy()
    assert_equal(p.point_in_time_recovery_status.value(), "ENABLED")
    assert_equal(p.recovery_period_in_days.value(), Int32(7))
    assert_equal(p.earliest_restorable_date_time.value(), Float64(1790812800))
    assert_equal(p.latest_restorable_date_time.value(), Float64(1790899200.5))
    var u = parse_update_continuous_backups_response(_ok(String(body)))
    assert_equal(u.continuous_backups_description.value().continuous_backups_status, "ENABLED")


def test_refusals() raises:
    with assert_raises():
        _ = parse_get_item_response(_ok(String('{"Item":{"pk":{"S":"r"}')))
    # A member whose JSON type is not the model's.
    with assert_raises():
        _ = parse_query_response(_ok(String('{"Count":"two"}')))
    # A required member of a nested shape (KeySchemaElement's
    # AttributeName) whose JSON type is not the model's.
    with assert_raises():
        _ = parse_describe_table_response(
            _ok(String('{"Table":{"KeySchema":[{"AttributeName":1,"KeyType":"HASH"}]}}'))
        )


# ---- errors ------------------------------------------------------------------


def test_conditional_check_failed() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",'
            + '"message":"The conditional request failed","Item":{"pk":{"S":"r"},"v":{"N":"3"}}}'
        ),
    )
    resp.add_header(String("x-amzn-RequestId"), String("JLLBKQ8T7B0ES5PBCEMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ConditionalCheckFailedException")
    assert_equal(info.message, "The conditional request failed")
    assert_equal(info.request_id, "JLLBKQ8T7B0ES5PBCEMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    var e = DynamoDBConditionalCheckFailedException.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "The conditional request failed")
    assert_equal(e.item.value()["v"].n.value(), "3")


def test_resource_not_found() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException",'
            + '"message":"Requested resource not found"}'
        ),
    )
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ResourceNotFoundException")
    var e = DynamoDBResourceNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "Requested resource not found")


def test_error_type_header_wins() raises:
    var resp = AwsResponse.of_text(
        400,
        String('{"__type":"com.amazonaws.dynamodb.v20120810#ValidationException","message":"x"}'),
    )
    resp.add_header(String("X-Amzn-Errortype"), String("ThrottlingException:http://internal.amazon.com/"))
    assert_equal(aws_json_error_info(resp).code, "ThrottlingException")


def test_internal_server_error_without_a_body() raises:
    var info = aws_json_error_info(AwsResponse.of_text(500, String("")))
    assert_equal(info.status, 500)
    assert_equal(info.code, "")


def main() raises:
    test_get_item_every_type()
    test_get_item_not_found()
    test_put_update_delete_item()
    test_query_page()
    test_query_last_page()
    test_scan_count()
    test_describe_table()
    test_create_update_delete_table()
    test_time_to_live()
    test_continuous_backups()
    test_refusals()
    test_conditional_check_failed()
    test_resource_not_found()
    test_error_type_header_wins()
    test_internal_server_error_without_a_body()
    print("OK")
