# The requests komira_aws_iam builds, exactly: a POST to `/` whose form
# body (Content-Type `application/x-www-form-urlencoded; charset=utf-8`)
# starts `Action=<Operation>&Version=2010-05-08` and then names the input's
# members in the model's order, each value percent-encoded (every byte
# outside A-Z a-z 0-9 `-` `.` `_` `~`), an unset member absent and a list
# of structures written `<Name>.member.<i>.<Member>` from 1, as botocore's
# QuerySerializer writes them. One or more rows per operation, in the
# shapes the IAM API reference documents: a user given an access key and an
# inline policy, a role created, read, retrusted, given and relieved of an
# inline policy, tagged and deleted, and an OIDC provider's client ids.
from komira_aws_iam.komira_aws_iam import (
    IAM_API_VERSION,
    IAMAddClientIDToOpenIDConnectProviderRequest,
    IAMCreateAccessKeyRequest,
    IAMCreateRoleRequest,
    IAMCreateUserRequest,
    IAMDeleteRolePolicyRequest,
    IAMDeleteRoleRequest,
    IAMGetOpenIDConnectProviderRequest,
    IAMGetRolePolicyRequest,
    IAMGetRoleRequest,
    IAMListRolePoliciesRequest,
    IAMPutRolePolicyRequest,
    IAMPutUserPolicyRequest,
    IAMRemoveClientIDFromOpenIDConnectProviderRequest,
    IAMTag,
    IAMTagRoleRequest,
    IAMUpdateAssumeRolePolicyRequest,
    build_add_client_id_to_open_id_connect_provider_request,
    build_create_access_key_request,
    build_create_role_request,
    build_create_user_request,
    build_delete_role_policy_request,
    build_delete_role_request,
    build_get_open_id_connect_provider_request,
    build_get_role_policy_request,
    build_get_role_request,
    build_list_role_policies_request,
    build_put_role_policy_request,
    build_put_user_policy_request,
    build_remove_client_id_from_open_id_connect_provider_request,
    build_tag_role_request,
    build_update_assume_role_policy_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


# A trust policy and a permission policy, as a caller passes them, and the
# same bytes percent-encoded.
comptime _TRUST = (
    '{"Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},'
    '"Action":"sts:AssumeRole"}]}'
)
comptime _TRUST_ENC = (
    "%7B%22Statement%22%3A%5B%7B%22Effect%22%3A%22Allow%22%2C%22Principal%22%3A%7B%22Service"
    "%22%3A%22ecs-tasks.amazonaws.com%22%7D%2C%22Action%22%3A%22sts%3AAssumeRole%22%7D%5D%7D"
)
comptime _SEND = '{"Statement":[{"Effect":"Allow","Action":"ses:SendRawEmail","Resource":"*"}]}'
comptime _SEND_ENC = (
    "%7B%22Statement%22%3A%5B%7B%22Effect%22%3A%22Allow%22%2C%22Action%22%3A%22ses%3ASendRawEmail"
    "%22%2C%22Resource%22%3A%22%2A%22%7D%5D%7D"
)
comptime _OIDC = "arn:aws:iam::123456789012:oidc-provider/token.actions.example.com"
comptime _OIDC_ENC = "arn%3Aaws%3Aiam%3A%3A123456789012%3Aoidc-provider%2Ftoken.actions.example.com"


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
    var head = String("Action=") + op + "&Version=2010-05-08"
    assert_equal(String(text[byte = 0 : min(head.byte_length(), text.byte_length())]), head)
    return String(text[byte = head.byte_length() : text.byte_length()])


def _tags() -> List[IAMTag]:
    var tags = List[IAMTag]()
    tags.append(IAMTag(String("owner"), String("mail")))
    tags.append(IAMTag(String("cost center"), String("12")))
    return tags^


def test_api_version() raises:
    assert_equal(IAM_API_VERSION, "2010-05-08")


def test_create_user() raises:
    var input = IAMCreateUserRequest(String("smtp-relay"))
    input.set_path(String("/komira/"))
    input.set_tags(_tags())
    # Path before UserName (the model's order); tags as a wrapped list of
    # structures, its members named as the model names them.
    assert_equal(
        _body(build_create_user_request(input), String("CreateUser")),
        "&Path=%2Fkomira%2F&UserName=smtp-relay"
        + "&Tags.member.1.Key=owner&Tags.member.1.Value=mail"
        + "&Tags.member.2.Key=cost%20center&Tags.member.2.Value=12",
    )


def test_create_user_name_only() raises:
    assert_equal(
        _body(build_create_user_request(IAMCreateUserRequest(String("u"))), String("CreateUser")),
        "&UserName=u",
    )


def test_create_access_key() raises:
    var input = IAMCreateAccessKeyRequest()
    input.set_user_name(String("smtp-relay"))
    assert_equal(
        _body(build_create_access_key_request(input), String("CreateAccessKey")),
        "&UserName=smtp-relay",
    )
    # UserName is optional: without it, IAM answers for the caller itself.
    assert_equal(
        _body(build_create_access_key_request(IAMCreateAccessKeyRequest()), String("CreateAccessKey")),
        "",
    )


def test_put_user_policy() raises:
    var req = build_put_user_policy_request(
        IAMPutUserPolicyRequest(String("smtp-relay"), String("ses-send"), String(_SEND))
    )
    assert_equal(
        _body(req, String("PutUserPolicy")),
        String("&UserName=smtp-relay&PolicyName=ses-send&PolicyDocument=") + _SEND_ENC,
    )


def test_create_role() raises:
    var input = IAMCreateRoleRequest(String("deploy"), String(_TRUST))
    input.set_description(String("runs the deploy jobs"))
    input.set_max_session_duration(Int32(3600))
    var tags = List[IAMTag]()
    tags.append(IAMTag(String("owner"), String("ci")))
    input.set_tags(tags^)
    assert_equal(
        _body(build_create_role_request(input), String("CreateRole")),
        String("&RoleName=deploy&AssumeRolePolicyDocument=")
        + _TRUST_ENC
        + "&Description=runs%20the%20deploy%20jobs&MaxSessionDuration=3600"
        + "&Tags.member.1.Key=owner&Tags.member.1.Value=ci",
    )


def test_get_role() raises:
    assert_equal(
        _body(build_get_role_request(IAMGetRoleRequest(String("deploy"))), String("GetRole")),
        "&RoleName=deploy",
    )


def test_update_assume_role_policy() raises:
    var req = build_update_assume_role_policy_request(
        IAMUpdateAssumeRolePolicyRequest(String("deploy"), String(_TRUST))
    )
    assert_equal(
        _body(req, String("UpdateAssumeRolePolicy")),
        String("&RoleName=deploy&PolicyDocument=") + _TRUST_ENC,
    )


def test_put_role_policy() raises:
    var req = build_put_role_policy_request(
        IAMPutRolePolicyRequest(String("deploy"), String("ses-send"), String(_SEND))
    )
    assert_equal(
        _body(req, String("PutRolePolicy")),
        String("&RoleName=deploy&PolicyName=ses-send&PolicyDocument=") + _SEND_ENC,
    )


def test_get_role_policy() raises:
    var req = build_get_role_policy_request(IAMGetRolePolicyRequest(String("deploy"), String("ses-send")))
    assert_equal(_body(req, String("GetRolePolicy")), "&RoleName=deploy&PolicyName=ses-send")


def test_list_role_policies() raises:
    var input = IAMListRolePoliciesRequest(String("deploy"))
    input.set_marker(String("AAE+page/2="))
    input.set_max_items(Int32(100))
    assert_equal(
        _body(build_list_role_policies_request(input), String("ListRolePolicies")),
        "&RoleName=deploy&Marker=AAE%2Bpage%2F2%3D&MaxItems=100",
    )


def test_delete_role_policy() raises:
    var req = build_delete_role_policy_request(IAMDeleteRolePolicyRequest(String("deploy"), String("ses-send")))
    assert_equal(_body(req, String("DeleteRolePolicy")), "&RoleName=deploy&PolicyName=ses-send")


def test_delete_role() raises:
    assert_equal(
        _body(build_delete_role_request(IAMDeleteRoleRequest(String("deploy"))), String("DeleteRole")),
        "&RoleName=deploy",
    )


def test_tag_role() raises:
    var req = build_tag_role_request(IAMTagRoleRequest(String("deploy"), _tags()))
    assert_equal(
        _body(req, String("TagRole")),
        "&RoleName=deploy&Tags.member.1.Key=owner&Tags.member.1.Value=mail"
        + "&Tags.member.2.Key=cost%20center&Tags.member.2.Value=12",
    )


def test_get_open_id_connect_provider() raises:
    var req = build_get_open_id_connect_provider_request(IAMGetOpenIDConnectProviderRequest(String(_OIDC)))
    assert_equal(
        _body(req, String("GetOpenIDConnectProvider")),
        String("&OpenIDConnectProviderArn=") + _OIDC_ENC,
    )


def test_add_client_id_to_open_id_connect_provider() raises:
    var req = build_add_client_id_to_open_id_connect_provider_request(
        IAMAddClientIDToOpenIDConnectProviderRequest(String(_OIDC), String("sts.amazonaws.com"))
    )
    assert_equal(
        _body(req, String("AddClientIDToOpenIDConnectProvider")),
        String("&OpenIDConnectProviderArn=") + _OIDC_ENC + "&ClientID=sts.amazonaws.com",
    )


def test_remove_client_id_from_open_id_connect_provider() raises:
    var req = build_remove_client_id_from_open_id_connect_provider_request(
        IAMRemoveClientIDFromOpenIDConnectProviderRequest(String(_OIDC), String("old-audience"))
    )
    assert_equal(
        _body(req, String("RemoveClientIDFromOpenIDConnectProvider")),
        String("&OpenIDConnectProviderArn=") + _OIDC_ENC + "&ClientID=old-audience",
    )


def test_an_empty_required_name_is_refused() raises:
    # roleNameType has `min: 1`: an empty name is refused before a request
    # exists, naming the member.
    with assert_raises(contains="IAMGetRoleRequest.RoleName: the model states min length 1"):
        _ = build_get_role_request(IAMGetRoleRequest(String("")))


def main() raises:
    test_api_version()
    test_create_user()
    test_create_user_name_only()
    test_create_access_key()
    test_put_user_policy()
    test_create_role()
    test_get_role()
    test_update_assume_role_policy()
    test_put_role_policy()
    test_get_role_policy()
    test_list_role_policies()
    test_delete_role_policy()
    test_delete_role()
    test_tag_role()
    test_get_open_id_connect_provider()
    test_add_client_id_to_open_id_connect_provider()
    test_remove_client_id_from_open_id_connect_provider()
    test_an_empty_required_name_is_refused()
    print("OK")
