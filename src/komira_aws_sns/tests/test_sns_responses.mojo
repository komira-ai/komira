# The responses komira_aws_sns reads, exactly. An awsQuery answer is
# `<OpResponse><OpResult>...</OpResult><ResponseMetadata>...`, and each
# operation's members are read from its `<OpResult>` element (the model's
# resultWrapper), never from the root: an attribute map as
# `<entry><key>..</key><value>..</value></entry>`, a list of structures
# wrapped in `<member>`, an element the model does not declare skipped. An
# operation that declares no output reads nothing, whatever the body. Then
# the error document every SNS operation answers with,
# `<ErrorResponse><Error>`, read through komira_aws_core's aws_query_error.
#
# The bodies are in the form the Amazon SNS API reference documents for
# each operation, with documentation account ids.
from komira_aws_sns.komira_aws_sns import (
    parse_create_topic_response,
    parse_delete_topic_response,
    parse_get_subscription_attributes_response,
    parse_get_topic_attributes_response,
    parse_list_subscriptions_by_topic_response,
    parse_set_subscription_attributes_response,
    parse_set_topic_attributes_response,
    parse_subscribe_response,
    parse_unsubscribe_response,
)
from komira_aws_core import AwsResponse, aws_query_error
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _NS = ' xmlns="https://sns.amazonaws.com/doc/2010-03-31/"'
comptime _META = (
    "<ResponseMetadata><RequestId>0a7e1a7b-0000-4000-8000-1234567890aa</RequestId>"
    "</ResponseMetadata>"
)
comptime _TOPIC = "arn:aws:sns:us-east-1:123456789012:bounces"


def _ok(op: String, result: String) -> AwsResponse:
    """`<op>Response` holding `<op>Result` with `result` inside, and the
    response metadata after it."""
    return AwsResponse.of_text(
        200,
        String("<")
        + op
        + "Response"
        + _NS
        + "><"
        + op
        + "Result>"
        + result
        + "</"
        + op
        + "Result>"
        + _META
        + "</"
        + op
        + "Response>",
    )


def _bare(op: String) -> AwsResponse:
    """The answer of an operation with no output: metadata only."""
    return AwsResponse.of_text(
        200, String("<") + op + "Response" + _NS + ">" + _META + "</" + op + "Response>"
    )


def test_create_topic() raises:
    var out = parse_create_topic_response(
        _ok(String("CreateTopic"), String("<TopicArn>") + _TOPIC + "</TopicArn>")
    )
    assert_equal(out.topic_arn.value(), _TOPIC)


def test_get_topic_attributes() raises:
    var out = parse_get_topic_attributes_response(
        _ok(
            String("GetTopicAttributes"),
            String(
                "<Attributes>"
                "<entry><key>Owner</key><value>123456789012</value></entry>"
                "<entry><key>Policy</key><value>{&quot;Statement&quot;:[]}</value></entry>"
                "<entry><key>SubscriptionsConfirmed</key><value>1</value></entry>"
                "<entry><key>TopicArn</key><value>arn:aws:sns:us-east-1:123456789012:bounces</value></entry>"
                "</Attributes>"
            ),
        )
    )
    var attrs = out.attributes.value().copy()
    assert_equal(len(attrs), 4)
    assert_equal(attrs[String("Owner")], "123456789012")
    # An entity in the text is read as the character it names.
    assert_equal(attrs[String("Policy")], '{"Statement":[]}')
    assert_equal(attrs[String("SubscriptionsConfirmed")], "1")
    assert_equal(attrs[String("TopicArn")], _TOPIC)


def test_subscribe() raises:
    var out = parse_subscribe_response(
        _ok(String("Subscribe"), String("<SubscriptionArn>pending confirmation</SubscriptionArn>"))
    )
    # An https endpoint's subscription is pending until it confirms.
    assert_equal(out.subscription_arn.value(), "pending confirmation")


def test_list_subscriptions_by_topic() raises:
    var out = parse_list_subscriptions_by_topic_response(
        _ok(
            String("ListSubscriptionsByTopic"),
            String(
                "<Subscriptions>"
                "<member><TopicArn>arn:aws:sns:us-east-1:123456789012:bounces</TopicArn>"
                "<Protocol>https</Protocol>"
                "<SubscriptionArn>arn:aws:sns:us-east-1:123456789012:bounces:4f6a0c1e</SubscriptionArn>"
                "<Owner>123456789012</Owner>"
                "<Endpoint>https://hooks.example.com/sns</Endpoint></member>"
                "<member><TopicArn>arn:aws:sns:us-east-1:123456789012:bounces</TopicArn>"
                "<Protocol>sqs</Protocol>"
                "<SubscriptionArn>PendingConfirmation</SubscriptionArn></member>"
                "</Subscriptions>"
                "<NextToken>AAEaZ+next/page=</NextToken>"
            ),
        )
    )
    var subs = out.subscriptions.value().copy()
    assert_equal(len(subs), 2)
    assert_equal(subs[0].topic_arn.value(), _TOPIC)
    assert_equal(subs[0].protocol.value(), "https")
    assert_equal(subs[0].subscription_arn.value(), "arn:aws:sns:us-east-1:123456789012:bounces:4f6a0c1e")
    assert_equal(subs[0].owner.value(), "123456789012")
    assert_equal(subs[0].endpoint.value(), "https://hooks.example.com/sns")
    assert_equal(subs[1].protocol.value(), "sqs")
    assert_false(Bool(subs[1].endpoint))
    assert_equal(out.next_token.value(), "AAEaZ+next/page=")


def test_list_subscriptions_by_topic_none() raises:
    var out = parse_list_subscriptions_by_topic_response(
        _ok(String("ListSubscriptionsByTopic"), String("<Subscriptions/>"))
    )
    assert_equal(len(out.subscriptions.value()), 0)
    assert_false(Bool(out.next_token))


def test_get_subscription_attributes() raises:
    var out = parse_get_subscription_attributes_response(
        _ok(
            String("GetSubscriptionAttributes"),
            String(
                "<Attributes>"
                "<entry><key>RawMessageDelivery</key><value>true</value></entry>"
                "<entry><key>PendingConfirmation</key><value>false</value></entry>"
                "</Attributes>"
                "<NotInTheModel>skipped</NotInTheModel>"
            ),
        )
    )
    var attrs = out.attributes.value().copy()
    assert_equal(len(attrs), 2)
    assert_equal(attrs[String("RawMessageDelivery")], "true")
    assert_equal(attrs[String("PendingConfirmation")], "false")


def test_operations_with_no_output_read_nothing() raises:
    _ = parse_delete_topic_response(_bare(String("DeleteTopic")))
    _ = parse_set_topic_attributes_response(_bare(String("SetTopicAttributes")))
    _ = parse_set_subscription_attributes_response(_bare(String("SetSubscriptionAttributes")))
    _ = parse_unsubscribe_response(_bare(String("Unsubscribe")))
    _ = parse_unsubscribe_response(AwsResponse.of_text(200, String("")))


def test_a_response_without_its_result_element_is_refused() raises:
    with assert_raises(contains="holds no <CreateTopicResult> element"):
        _ = parse_create_topic_response(
            AwsResponse.of_text(
                200, String("<CreateTopicResponse><TopicArn>") + _TOPIC + "</TopicArn></CreateTopicResponse>"
            )
        )


def test_the_error_document() raises:
    var e = aws_query_error(
        AwsResponse.of_text(
            404,
            String("<ErrorResponse")
            + _NS
            + "><Error><Type>Sender</Type><Code>NotFound</Code>"
            + "<Message>Topic does not exist</Message></Error>"
            + "<RequestId>0a7e1a7b-0000-4000-8000-1234567890ab</RequestId></ErrorResponse>",
        )
    )
    assert_equal(e.status, 404)
    assert_equal(e.code, "NotFound")
    assert_equal(e.message, "Topic does not exist")
    assert_equal(e.request_id, "0a7e1a7b-0000-4000-8000-1234567890ab")
    assert_true(String(e.to_error(String("SNS.DeleteTopic"))).find("NotFound") > 0)


def test_an_authorization_error() raises:
    var e = aws_query_error(
        AwsResponse.of_text(
            403,
            "<ErrorResponse><Error><Type>Sender</Type><Code>AuthorizationError</Code>"
            + "<Message>User is not authorized to perform SNS:Subscribe</Message></Error>"
            + "<RequestId>r-1</RequestId></ErrorResponse>",
        )
    )
    assert_equal(e.code, "AuthorizationError")
    assert_equal(e.message, "User is not authorized to perform SNS:Subscribe")


def main() raises:
    test_create_topic()
    test_get_topic_attributes()
    test_subscribe()
    test_list_subscriptions_by_topic()
    test_list_subscriptions_by_topic_none()
    test_get_subscription_attributes()
    test_operations_with_no_output_read_nothing()
    test_a_response_without_its_result_element_is_refused()
    test_the_error_document()
    test_an_authorization_error()
    print("OK")
