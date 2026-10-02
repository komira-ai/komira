# =============================================================================
# komira_aws_core/tests/test_shared_config.mojo
# =============================================================================
#
# The shared config and credentials file parser and its locations: section
# rules of each file, the default-profile spellings, merging, comments,
# continuation lines, refusals that name the file and line but never quote
# it, and the AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE / HOME / AWS_PROFILE
# selection. Hermetic: MapEnv and MapFiles only.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    MapEnv,
    MapFiles,
    load_profiles,
    parse_profile_file,
    select_profile,
    shared_file_paths,
)


comptime _SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"


def _refused(text: String, is_config: Bool, needle: String) raises:
    try:
        _ = parse_profile_file(text, is_config, String("/cfg"))
    except e:
        var msg = String(e)
        assert_true(msg.find(needle) >= 0, msg)
        assert_true(msg.find(_SECRET) < 0, "a refusal quoted the secret")
        return
    raise Error("expected a refusal containing: " + needle)


def test_config_sections() raises:
    var text = String(
        "# comment\n"
        "; another comment\n"
        "[default]\n"
        "region = us-east-1\n"
        "[profile dev]\n"
        "region=eu-west-1   # trailing comment\n"
        "role_arn = arn:aws:iam::123456789012:role/dev;not-a-comment\n"
        "[ profile   spaced  ]\n"
        "region = ap-south-1\n"
        "[bare]\n"
        "region = us-west-1\n"
        "[sso-session corp]\n"
        "sso_region = us-east-1\n"
        "[services local]\n"
        "region = nowhere\n"
        "[profilenoseparator]\n"
        "region = nowhere\n"
    )
    var s = parse_profile_file(text, True, String("/cfg"))
    assert_equal(len(s.profiles), 3)
    assert_equal(s.profile("default").get("region"), "us-east-1")
    assert_equal(s.profile("dev").get("region"), "eu-west-1")
    # ';' or '#' not preceded by whitespace is part of the value.
    assert_equal(
        s.profile("dev").get("role_arn"),
        "arn:aws:iam::123456789012:role/dev;not-a-comment",
    )
    assert_equal(s.profile("spaced").get("region"), "ap-south-1")
    # A bare [name] in the config file is not a profile; neither are the
    # sso-session and services sections.
    assert_false(s.has_profile("bare"))
    assert_false(s.has_profile("corp"))
    assert_false(s.has_profile("sso-session corp"))
    assert_false(s.has_profile("local"))
    assert_false(s.has_profile("profilenoseparator"))


def test_profile_default_wins_over_bare_default() raises:
    var a = parse_profile_file(
        String("[profile default]\nregion = a\n[default]\nregion = b\n"),
        True,
        String("/cfg"),
    )
    assert_equal(a.profile("default").get("region"), "a")
    var b = parse_profile_file(
        String("[default]\nregion = b\n[profile default]\nregion = a\n"),
        True,
        String("/cfg"),
    )
    assert_equal(b.profile("default").get("region"), "a")
    assert_equal(len(b.profiles), 1)


def test_credentials_sections() raises:
    var text = String(
        "[default]\n"
        "aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n"
        "aws_secret_access_key = " + _SECRET + "\n"
        "[profile ignored]\n"
        "aws_access_key_id = AKIDIGNORED\n"
        "[dev]\n"
        "aws_access_key_id = AKIDDEV\n"
    )
    var s = parse_profile_file(text, False, String("/creds"))
    assert_equal(s.profile("default").get("aws_secret_access_key"), _SECRET)
    assert_equal(s.profile("dev").get("aws_access_key_id"), "AKIDDEV")
    # The credentials file never uses the "profile " prefix.
    assert_false(s.has_profile("ignored"))
    assert_false(s.has_profile("profile ignored"))


def test_merge_repeat_and_continuation() raises:
    var text = String(
        "orphan = before any section\n"
        "[profile a]\n"
        "region = one\n"
        "s3 =\n"
        "  max_concurrent_requests = 20\n"
        "  addressing_style = path\n"
        "[profile b]\n"
        "region = b\n"
        "[profile a]\n"
        "region = two\n"
        "\n"
        "\r\n"
        "output = json\r\n"
    )
    var s = parse_profile_file(text, True, String("/cfg"))
    assert_equal(len(s.profiles), 2)
    # A repeated section merges; the repeated key's last value wins.
    assert_equal(s.profile("a").get("region"), "two")
    # CRLF line ends are accepted.
    assert_equal(s.profile("a").get("output"), "json")
    assert_equal(
        s.profile("a").get("s3"),
        "\nmax_concurrent_requests = 20\naddressing_style = path",
    )
    assert_false(s.profile("a").has("orphan"))


def test_refusals_name_file_and_line_never_the_text() raises:
    _refused(
        String("[default]\naws_secret_access_key " + _SECRET + "\n"),
        False,
        "expected 'key = value' at /cfg:2",
    )
    _refused(String("[default\nregion = x\n"), True, "no ']') at /cfg:1")
    _refused(String("[default] trailing\n"), True, "text after a section header at /cfg:1")
    _refused(String("[default]\n= " + _SECRET + "\n"), False, "empty key at /cfg:2")
    _refused(
        String("[default]\n  " + _SECRET + "\n"),
        False,
        "continuation line with no property at /cfg:2",
    )
    # A comment after a section header is fine.
    var ok = parse_profile_file(
        String("[default] # note\nregion = x\n"), True, String("/cfg")
    )
    assert_equal(ok.profile("default").get("region"), "x")


def test_locations_and_merge_precedence() raises:
    var env = MapEnv()
    env.set("HOME", "/home/u")
    var p = shared_file_paths(env)
    assert_equal(p.config_file, "/home/u/.aws/config")
    assert_equal(p.credentials_file, "/home/u/.aws/credentials")

    env.set("AWS_CONFIG_FILE", "~/elsewhere/config")
    env.set("AWS_SHARED_CREDENTIALS_FILE", "/abs/credentials")
    p = shared_file_paths(env)
    assert_equal(p.config_file, "/home/u/elsewhere/config")
    assert_equal(p.credentials_file, "/abs/credentials")

    # No HOME: the default locations cannot be formed, so no file is read.
    var bare = MapEnv()
    var q = shared_file_paths(bare)
    assert_equal(q.config_file, "")
    assert_equal(q.credentials_file, "")
    var nofiles = MapFiles()
    var none = load_profiles(bare, nofiles)
    assert_equal(len(none.profiles), 0)
    assert_equal(len(nofiles.reads), 0)

    # The credentials file wins over the config file for the same setting.
    var files = MapFiles()
    files.put(
        "/home/u/elsewhere/config",
        "[profile dev]\nregion = eu-west-1\naws_access_key_id = FROMCONFIG\n",
    )
    files.put("/abs/credentials", "[dev]\naws_access_key_id = FROMCREDS\n")
    var s = load_profiles(env, files)
    assert_equal(s.profile("dev").get("aws_access_key_id"), "FROMCREDS")
    assert_equal(s.profile("dev").get("region"), "eu-west-1")

    # A missing file is an empty file.
    var only = MapFiles()
    only.put("/abs/credentials", "[x]\nregion = y\n")
    var t = load_profiles(env, only)
    assert_equal(len(t.profiles), 1)


def test_profile_selection() raises:
    var env = MapEnv()
    var c = select_profile(String(""), env)
    assert_equal(c.name, "default")
    assert_false(c.named)
    env.set("AWS_PROFILE", "dev")
    c = select_profile(String(""), env)
    assert_equal(c.name, "dev")
    assert_true(c.named)
    # The explicit parameter wins over AWS_PROFILE.
    c = select_profile(String("prod"), env)
    assert_equal(c.name, "prod")
    assert_true(c.named)


def main() raises:
    test_config_sections()
    test_profile_default_wins_over_bare_default()
    test_credentials_sections()
    test_merge_repeat_and_continuation()
    test_refusals_name_file_and_line_never_the_text()
    test_locations_and_merge_precedence()
    test_profile_selection()
    print("OK")
