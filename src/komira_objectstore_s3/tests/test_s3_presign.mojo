# S3PresignSigner: presigned S3 URLs as komira_objectstore's ObjectUrlSigner.
#
# Each URL is compared byte for byte with one whose signature was computed by
# an independent SigV4 query-signing implementation (written from AWS's
# "Authenticating Requests: Using Query Parameters" page, fake keys, the
# fixed clock below; that implementation reproduces the signature AWS
# publishes there for its own example). Two shapes: a virtual-hosted GET on
# AWS's endpoint for us-east-1, and a path-style PUT on a custom endpoint
# with a temporary credential, whose token rides in the query and is signed,
# and a key with a space, encoded once. Then the signer's refusals: a TTL
# outside komira_objectstore's 1 s to 1 h, an empty key.
from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_objectstore.presign import PRESIGN_MAX_TTL_SECONDS
from komira_objectstore_s3 import S3Config, S3PresignSigner


comptime _NOW = 1790000000  # 20260921T141320Z


def test_virtual_hosted_get() raises:
    var signer = S3PresignSigner[StaticCredsSource, FixedClock](
        "examplebucket",
        S3Config.aws("us-east-1"),
        StaticCredsSource(
            AwsCredential(
                String("AKIAIOSFODNN7EXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        FixedClock(_NOW),
    )
    assert_equal(signer.signer_cloud(), "s3")
    var url = signer.presign_download("test.txt", 3600)
    assert_equal(url.method, "GET")
    assert_equal(url.expires_unix_seconds, Int64(_NOW + 3600))
    assert_equal(len(url.required_headers), 0)
    assert_equal(
        url.url,
        "https://examplebucket.s3.us-east-1.amazonaws.com/test.txt"
        "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
        "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260921%2Fus-east-1%2Fs3%2Faws4_request"
        "&X-Amz-Date=20260921T141320Z"
        "&X-Amz-SignedHeaders=host"
        "&X-Amz-Expires=3600"
        "&X-Amz-Signature=6798df2c76303ed78e600fe26fee836b2fc1bbe2eb7209fd5c778b0d47d8a347",
    )


def test_path_style_put_with_a_session_token() raises:
    var signer = S3PresignSigner[StaticCredsSource, FixedClock](
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String("tok/en+1="),
            )
        ),
        FixedClock(_NOW),
    )
    var url = signer.presign_unchecked("PUT", "data/a b.parquet", 900)
    assert_equal(url.method, "PUT")
    assert_equal(
        url.url,
        "http://127.0.0.1:9000/lake/data/a%20b.parquet"
        "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
        "&X-Amz-Credential=AKIDEXAMPLE%2F20260921%2Fus-east-1%2Fs3%2Faws4_request"
        "&X-Amz-Date=20260921T141320Z"
        "&X-Amz-SignedHeaders=host"
        "&X-Amz-Expires=900"
        "&X-Amz-Security-Token=tok%2Fen%2B1%3D"
        "&X-Amz-Signature=45393b7658e04734a64206e7d9c082e707842d0d081a28bb7e023512597d8fbf",
    )
    # presign_upload is the same URL behind komira_objectstore's TTL check.
    assert_equal(signer.presign_upload("data/a b.parquet", 900).url, url.url)


def test_refusals() raises:
    var signer = S3PresignSigner[StaticCredsSource, FixedClock](
        "lake",
        S3Config.aws("us-east-1"),
        StaticCredsSource(AwsCredential(String("AKID"), String("secret"), String(""))),
        FixedClock(_NOW),
    )
    with assert_raises(contains="refusing a TTL of 0s"):
        _ = signer.presign_download("k", 0)
    with assert_raises(contains="refusing a TTL of 3601s"):
        _ = signer.presign_upload("k", PRESIGN_MAX_TTL_SECONDS + 1)
    with assert_raises(contains="refusing to sign an empty key"):
        _ = signer.presign_download("", 60)
    with assert_raises(contains="only GET and PUT"):
        _ = signer.presign_unchecked("DELETE", "k", 60)
    with assert_raises(contains="the bucket is empty"):
        _ = S3PresignSigner[StaticCredsSource, FixedClock](
            "",
            S3Config.aws("us-east-1"),
            StaticCredsSource(AwsCredential(String("AKID"), String("secret"), String(""))),
            FixedClock(_NOW),
        )


def main() raises:
    test_virtual_hosted_get()
    test_path_style_put_with_a_session_token()
    test_refusals()
    print("OK")
