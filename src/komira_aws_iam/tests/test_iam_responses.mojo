# The responses komira_aws_iam reads, exactly. An awsQuery answer is
# `<OpResponse><OpResult>...</OpResult><ResponseMetadata>...`, and each
# operation's members are read from its `<OpResult>` element (the model's
# resultWrapper), never from the root: lists of strings and of structures
# wrapped in `<member>`, timestamps in ISO 8601, an element the model does
# not declare skipped. An operation that declares no output reads nothing,
# whatever the body. Then the error document every IAM operation answers
# with, `<ErrorResponse><Error>`, read through komira_aws_core's
# aws_query_error: its code and message, and the request id.
#
# The bodies are in the form the IAM API reference documents for each
# operation, with documentation account ids and keys.
from komira_aws_iam.komira_aws_iam import (
    parse_add_client_id_to_open_id_connect_provider_response,
    parse_create_access_key_response,
    parse_create_role_response,
    parse_create_user_response,
    parse_delete_role_policy_response,
    parse_delete_role_response,
    parse_get_open_id_connect_provider_response,
    parse_get_role_policy_response,
    parse_get_role_response,
    parse_list_role_policies_response,
    parse_put_role_policy_response,
    parse_put_user_policy_response,
    parse_remove_client_id_from_open_id_connect_provider_response,
    parse_tag_role_response,
    parse_update_assume_role_policy_response,
)
from komira_aws_core import AwsResponse, HttpResult, aws_query_error, aws_response_error_code
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _NS = ' xmlns="https://iam.amazonaws.com/doc/2010-05-08/"'
comptime _META = (
    "<ResponseMetadata><RequestId>7a62c49f-347e-4fc4-9331-6e8eEXAMPLE</RequestId>"
    "</ResponseMetadata>"
)
# 2026-10-01T00:00:00Z.
comptime _OCT_1 = Float64(1790812800)


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


comptime _ROLE = (
    "<Role><Path>/</Path><RoleName>deploy</RoleName>"
    "<RoleId>AROADBQP57FF2AEXAMPLE</RoleId>"
    "<Arn>arn:aws:iam::123456789012:role/deploy</Arn>"
    "<CreateDate>2026-10-01T00:00:00Z</CreateDate>"
    "<AssumeRolePolicyDocument>%7B%22Statement%22%3A%5B%5D%7D</AssumeRolePolicyDocument>"
    "<MaxSessionDuration>3600</MaxSessionDuration>"
    "<Tags><member><Key>owner</Key><Value>ci</Value></member></Tags>"
    "<RoleLastUsed><Region>us-west-2</Region></RoleLastUsed>"
    "<NotInTheModel>skipped</NotInTheModel>"
    "</Role>"
)


def test_create_user() raises:
    var out = parse_create_user_response(
        _ok(
            String("CreateUser"),
            String(
                "<User><Path>/komira/</Path><UserName>smtp-relay</UserName>"
                "<UserId>AIDACKCEVSQ6C2EXAMPLE</UserId>"
                "<Arn>arn:aws:iam::123456789012:user/komira/smtp-relay</Arn>"
                "<CreateDate>2026-10-01T00:00:00Z</CreateDate></User>"
            ),
        )
    )
    var user = out.user.value().copy()
    assert_equal(user.path, "/komira/")
    assert_equal(user.user_name, "smtp-relay")
    assert_equal(user.user_id, "AIDACKCEVSQ6C2EXAMPLE")
    assert_equal(user.arn, "arn:aws:iam::123456789012:user/komira/smtp-relay")
    assert_equal(user.create_date, _OCT_1)
    assert_false(Bool(user.tags))


def test_create_access_key() raises:
    var out = parse_create_access_key_response(
        _ok(
            String("CreateAccessKey"),
            String(
                "<AccessKey><UserName>smtp-relay</UserName>"
                "<AccessKeyId>AKIAIOSFODNN7EXAMPLE</AccessKeyId>"
                "<Status>Active</Status>"
                "<SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY</SecretAccessKey>"
                "<CreateDate>2026-10-01T00:00:00Z</CreateDate></AccessKey>"
            ),
        )
    )
    assert_equal(out.access_key.user_name, "smtp-relay")
    assert_equal(out.access_key.access_key_id, "AKIAIOSFODNN7EXAMPLE")
    assert_equal(out.access_key.status, "Active")
    assert_equal(out.access_key.secret_access_key, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY")
    assert_equal(out.access_key.create_date.value(), _OCT_1)


def _check_role(role_name: String, arn: String, create_date: Float64) raises:
    assert_equal(role_name, "deploy")
    assert_equal(arn, "arn:aws:iam::123456789012:role/deploy")
    assert_equal(create_date, _OCT_1)


def test_create_role() raises:
    var out = parse_create_role_response(_ok(String("CreateRole"), String(_ROLE)))
    _check_role(out.role.role_name, out.role.arn, out.role.create_date)
    assert_equal(out.role.path, "/")
    assert_equal(out.role.role_id, "AROADBQP57FF2AEXAMPLE")
    assert_equal(out.role.max_session_duration.value(), Int32(3600))


def test_get_role() raises:
    var out = parse_get_role_response(_ok(String("GetRole"), String(_ROLE)))
    _check_role(out.role.role_name, out.role.arn, out.role.create_date)
    # IAM sends a policy document percent-encoded, and it is returned as
    # sent: botocore decodes it in a handler of its own, not in its parser.
    assert_equal(
        out.role.assume_role_policy_document.value(),
        "%7B%22Statement%22%3A%5B%5D%7D",
    )
    var tags = out.role.tags.value().copy()
    assert_equal(len(tags), 1)
    assert_equal(tags[0].key, "owner")
    assert_equal(tags[0].value, "ci")
    assert_equal(out.role.role_last_used.value().region.value(), "us-west-2")
    assert_false(Bool(out.role.role_last_used.value().last_used_date))
    assert_false(Bool(out.role.description))


def test_get_role_policy() raises:
    var out = parse_get_role_policy_response(
        _ok(
            String("GetRolePolicy"),
            String(
                "<RoleName>deploy</RoleName><PolicyName>ses-send</PolicyName>"
                "<PolicyDocument>%7B%22Statement%22%3A%5B%5D%7D</PolicyDocument>"
            ),
        )
    )
    assert_equal(out.role_name, "deploy")
    assert_equal(out.policy_name, "ses-send")
    assert_equal(out.policy_document, "%7B%22Statement%22%3A%5B%5D%7D")


def test_list_role_policies() raises:
    var out = parse_list_role_policies_response(
        _ok(
            String("ListRolePolicies"),
            String(
                "<PolicyNames><member>ses-send</member><member>logs-read</member></PolicyNames>"
                "<IsTruncated>true</IsTruncated><Marker>AAE+page/2=</Marker>"
            ),
        )
    )
    assert_equal(len(out.policy_names), 2)
    assert_equal(out.policy_names[0], "ses-send")
    assert_equal(out.policy_names[1], "logs-read")
    assert_true(out.is_truncated.value())
    assert_equal(out.marker.value(), "AAE+page/2=")


def test_list_role_policies_last_page() raises:
    var out = parse_list_role_policies_response(
        _ok(String("ListRolePolicies"), String("<PolicyNames/><IsTruncated>false</IsTruncated>"))
    )
    assert_equal(len(out.policy_names), 0)
    assert_false(out.is_truncated.value())
    assert_false(Bool(out.marker))


def test_get_open_id_connect_provider() raises:
    var out = parse_get_open_id_connect_provider_response(
        _ok(
            String("GetOpenIDConnectProvider"),
            String(
                "<Url>token.actions.example.com</Url>"
                "<ClientIDList><member>sts.amazonaws.com</member><member>other</member></ClientIDList>"
                "<ThumbprintList><member>990f4193972f2becf12ddeda5237f9c952f20d9e</member></ThumbprintList>"
                "<CreateDate>2026-10-01T00:00:00Z</CreateDate>"
                "<Tags/>"
            ),
        )
    )
    assert_equal(out.url.value(), "token.actions.example.com")
    var ids = out.client_id_list.value().copy()
    assert_equal(len(ids), 2)
    assert_equal(ids[0], "sts.amazonaws.com")
    assert_equal(ids[1], "other")
    assert_equal(out.thumbprint_list.value()[0], "990f4193972f2becf12ddeda5237f9c952f20d9e")
    assert_equal(out.create_date.value(), _OCT_1)
    assert_equal(len(out.tags.value()), 0)


def test_operations_with_no_output_read_nothing() raises:
    _ = parse_add_client_id_to_open_id_connect_provider_response(
        _bare(String("AddClientIDToOpenIDConnectProvider"))
    )
    _ = parse_delete_role_response(_bare(String("DeleteRole")))
    _ = parse_delete_role_policy_response(_bare(String("DeleteRolePolicy")))
    _ = parse_put_role_policy_response(_bare(String("PutRolePolicy")))
    _ = parse_put_user_policy_response(_bare(String("PutUserPolicy")))
    _ = parse_remove_client_id_from_open_id_connect_provider_response(
        _bare(String("RemoveClientIDFromOpenIDConnectProvider"))
    )
    _ = parse_tag_role_response(_bare(String("TagRole")))
    _ = parse_update_assume_role_policy_response(_bare(String("UpdateAssumeRolePolicy")))
    _ = parse_delete_role_response(AwsResponse.of_text(200, String("")))


def test_a_response_without_its_result_element_is_refused() raises:
    # Members at the root are not read as the result: botocore finds the
    # result by its wrapper and nowhere else.
    with assert_raises(contains="holds no <GetRoleResult> element"):
        _ = parse_get_role_response(
            AwsResponse.of_text(200, String("<GetRoleResponse>") + _ROLE + "</GetRoleResponse>")
        )


def test_the_error_document() raises:
    var body = (
        String("<ErrorResponse")
        + _NS
        + "><Error><Type>Sender</Type><Code>EntityAlreadyExists</Code>"
        + "<Message>Role with name deploy already exists.</Message></Error>"
        + "<RequestId>4c1b2a3d-0000-4000-8000-1234567890aa</RequestId></ErrorResponse>"
    )
    var resp = AwsResponse.of_text(409, body)
    var e = aws_query_error(resp)
    assert_equal(e.status, 409)
    assert_equal(e.code, "EntityAlreadyExists")
    assert_equal(e.message, "Role with name deploy already exists.")
    assert_equal(e.request_id, "4c1b2a3d-0000-4000-8000-1234567890aa")
    # The retry classifier reads the same code (not one it retries).
    var bytes = List[UInt8]()
    bytes.extend(Span(body.as_bytes()))
    assert_equal(aws_response_error_code(HttpResult(409, bytes^)), "EntityAlreadyExists")


def test_a_missing_entity() raises:
    var e = aws_query_error(
        AwsResponse.of_text(
            404,
            "<ErrorResponse><Error><Type>Sender</Type><Code>NoSuchEntity</Code>"
            + "<Message>The role with name gone cannot be found.</Message></Error>"
            + "<RequestId>r-1</RequestId></ErrorResponse>",
        )
    )
    assert_equal(e.code, "NoSuchEntity")
    assert_equal(e.request_id, "r-1")


def main() raises:
    test_create_user()
    test_create_access_key()
    test_create_role()
    test_get_role()
    test_get_role_policy()
    test_list_role_policies()
    test_list_role_policies_last_page()
    test_get_open_id_connect_provider()
    test_operations_with_no_output_read_nothing()
    test_a_response_without_its_result_element_is_refused()
    test_the_error_document()
    test_a_missing_entity()
    print("OK")
