# The requests komira_aws_sns builds, exactly: a POST to `/` whose form
# body (Content-Type `application/x-www-form-urlencoded; charset=utf-8`)
# starts `Action=<Operation>&Version=2010-03-31` and then names the input's
# members in the model's order, each value percent-encoded (every byte
# outside A-Z a-z 0-9 `-` `.` `_` `~`), an unset member absent, a map
# written `<Name>.entry.<i>.key` / `.value` in the caller's insertion order
# and a list of structures `<Name>.member.<i>.<Member>`, as botocore's
# QuerySerializer writes them. One or more rows per operation, in the
# shapes the Amazon SNS API reference documents: a topic created with
# attributes and tags, read, given an attribute and deleted; an endpoint
# subscribed, its subscription listed, read, given a filter policy and
# removed.
from komira_aws_sns.komira_aws_sns import (
    SNS_API_VERSION,
    SNSCreateTopicInput,
    SNSDeleteTopicInput,
    SNSGetSubscriptionAttributesInput,
    SNSGetTopicAttributesInput,
    SNSListSubscriptionsByTopicInput,
    SNSSetSubscriptionAttributesInput,
    SNSSetTopicAttributesInput,
    SNSSubscribeInput,
    SNSTag,
    SNSUnsubscribeInput,
    build_create_topic_request,
    build_delete_topic_request,
    build_get_subscription_attributes_request,
    build_get_topic_attributes_request,
    build_list_subscriptions_by_topic_request,
    build_set_subscription_attributes_request,
    build_set_topic_attributes_request,
    build_subscribe_request,
    build_unsubscribe_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal


comptime _TOPIC = "arn:aws:sns:us-east-1:123456789012:bounces"
comptime _TOPIC_ENC = "arn%3Aaws%3Asns%3Aus-east-1%3A123456789012%3Abounces"
comptime _SUB = "arn:aws:sns:us-east-1:123456789012:bounces:4f6a0c1e-0000-4000-8000-1234567890ab"
comptime _SUB_ENC = (
    "arn%3Aaws%3Asns%3Aus-east-1%3A123456789012%3Abounces%3A"
    "4f6a0c1e-0000-4000-8000-1234567890ab"
)
comptime _FILTER = '{"eventType":["Bounce"]}'
comptime _FILTER_ENC = "%7B%22eventType%22%3A%5B%22Bounce%22%5D%7D"


def _body(req: AwsRequest, op: String) raises -> String:
    """The form body after `Action=<op>&Version=...`, once the envelope is
    checked: a POST to `/` with the form Content-Type as its only header."""
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(
        req.header(String("Content-Type")),
        "application/x-www-form-urlencoded; charset=utf-8",
    )
    assert_equal(len(req.header_names), 1)
    var text = req.body_text()
    var head = String("Action=") + op + "&Version=2010-03-31"
    assert_equal(String(text[byte = 0 : min(head.byte_length(), text.byte_length())]), head)
    return String(text[byte = head.byte_length() : text.byte_length()])


def test_api_version() raises:
    assert_equal(SNS_API_VERSION, "2010-03-31")


def test_create_topic() raises:
    var input = SNSCreateTopicInput(String("bounces"))
    var attrs = Dict[String, String]()
    attrs["DisplayName"] = String("mail bounces")
    attrs["Policy"] = String('{"Statement":[]}')
    input.set_attributes(attrs^)
    var tags = List[SNSTag]()
    tags.append(SNSTag(String("owner"), String("mail")))
    input.set_tags(tags^)
    # The map's entries in the caller's insertion order, numbered from 1;
    # the tags a wrapped list of structures.
    assert_equal(
        _body(build_create_topic_request(input), String("CreateTopic")),
        "&Name=bounces"
        + "&Attributes.entry.1.key=DisplayName&Attributes.entry.1.value=mail%20bounces"
        + "&Attributes.entry.2.key=Policy&Attributes.entry.2.value=%7B%22Statement%22%3A%5B%5D%7D"
        + "&Tags.member.1.Key=owner&Tags.member.1.Value=mail",
    )


def test_create_topic_name_only() raises:
    assert_equal(
        _body(build_create_topic_request(SNSCreateTopicInput(String("bounces"))), String("CreateTopic")),
        "&Name=bounces",
    )


def test_delete_topic() raises:
    assert_equal(
        _body(build_delete_topic_request(SNSDeleteTopicInput(String(_TOPIC))), String("DeleteTopic")),
        String("&TopicArn=") + _TOPIC_ENC,
    )


def test_get_topic_attributes() raises:
    var req = build_get_topic_attributes_request(SNSGetTopicAttributesInput(String(_TOPIC)))
    assert_equal(_body(req, String("GetTopicAttributes")), String("&TopicArn=") + _TOPIC_ENC)


def test_set_topic_attributes() raises:
    var input = SNSSetTopicAttributesInput(String(_TOPIC), String("DisplayName"))
    input.set_attribute_value(String("mail bounces"))
    assert_equal(
        _body(build_set_topic_attributes_request(input), String("SetTopicAttributes")),
        String("&TopicArn=") + _TOPIC_ENC + "&AttributeName=DisplayName&AttributeValue=mail%20bounces",
    )


def test_subscribe() raises:
    var input = SNSSubscribeInput(String(_TOPIC), String("https"))
    input.set_endpoint(String("https://hooks.example.com/sns"))
    var attrs = Dict[String, String]()
    attrs["RawMessageDelivery"] = String("true")
    input.set_attributes(attrs^)
    input.set_return_subscription_arn(True)
    assert_equal(
        _body(build_subscribe_request(input), String("Subscribe")),
        String("&TopicArn=")
        + _TOPIC_ENC
        + "&Protocol=https&Endpoint=https%3A%2F%2Fhooks.example.com%2Fsns"
        + "&Attributes.entry.1.key=RawMessageDelivery&Attributes.entry.1.value=true"
        + "&ReturnSubscriptionArn=true",
    )


def test_subscribe_a_queue() raises:
    var input = SNSSubscribeInput(String(_TOPIC), String("sqs"))
    input.set_endpoint(String("arn:aws:sqs:us-east-1:123456789012:bounces"))
    assert_equal(
        _body(build_subscribe_request(input), String("Subscribe")),
        String("&TopicArn=")
        + _TOPIC_ENC
        + "&Protocol=sqs&Endpoint=arn%3Aaws%3Asqs%3Aus-east-1%3A123456789012%3Abounces",
    )


def test_list_subscriptions_by_topic() raises:
    var first = build_list_subscriptions_by_topic_request(SNSListSubscriptionsByTopicInput(String(_TOPIC)))
    assert_equal(_body(first, String("ListSubscriptionsByTopic")), String("&TopicArn=") + _TOPIC_ENC)
    var input = SNSListSubscriptionsByTopicInput(String(_TOPIC))
    input.set_next_token(String("AAEaZ+next/page="))
    assert_equal(
        _body(build_list_subscriptions_by_topic_request(input), String("ListSubscriptionsByTopic")),
        String("&TopicArn=") + _TOPIC_ENC + "&NextToken=AAEaZ%2Bnext%2Fpage%3D",
    )


def test_get_subscription_attributes() raises:
    var req = build_get_subscription_attributes_request(SNSGetSubscriptionAttributesInput(String(_SUB)))
    assert_equal(_body(req, String("GetSubscriptionAttributes")), String("&SubscriptionArn=") + _SUB_ENC)


def test_set_subscription_attributes() raises:
    var input = SNSSetSubscriptionAttributesInput(String(_SUB), String("FilterPolicy"))
    input.set_attribute_value(String(_FILTER))
    assert_equal(
        _body(build_set_subscription_attributes_request(input), String("SetSubscriptionAttributes")),
        String("&SubscriptionArn=") + _SUB_ENC + "&AttributeName=FilterPolicy&AttributeValue=" + _FILTER_ENC,
    )


def test_unsubscribe() raises:
    var req = build_unsubscribe_request(SNSUnsubscribeInput(String(_SUB)))
    assert_equal(_body(req, String("Unsubscribe")), String("&SubscriptionArn=") + _SUB_ENC)


def main() raises:
    test_api_version()
    test_create_topic()
    test_create_topic_name_only()
    test_delete_topic()
    test_get_topic_attributes()
    test_set_topic_attributes()
    test_subscribe()
    test_subscribe_a_queue()
    test_list_subscriptions_by_topic()
    test_get_subscription_attributes()
    test_set_subscription_attributes()
    test_unsubscribe()
    print("OK")
