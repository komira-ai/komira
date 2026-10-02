"""The AWS SigV4 signing test suite in the aws-c-auth archive BUCK pins.

aws-c-auth carries the official suite at tests/aws-signing-test-suite/v4:
one directory per case, each holding the same ten files. BUCK extracts
exactly those files, so a case is listed here or not extracted at all;
nothing of the suite is committed to this repository. The archive's sha256
pins every byte, and //src/komira_aws_core's test_sigv4_test_suite refuses a
case directory missing any of the ten files and a case count other than its
own, so neither list can shrink without a red build.
"""

SIGV4_SUITE_DIR = "tests/aws-signing-test-suite/v4"

SIGV4_CASES = [
    "get-header-key-duplicate",
    "get-header-value-multiline",
    "get-header-value-order",
    "get-header-value-trim",
    "get-relative-normalized",
    "get-relative-relative-normalized",
    "get-relative-relative-unnormalized",
    "get-relative-unnormalized",
    "get-slash-dot-slash-normalized",
    "get-slash-dot-slash-unnormalized",
    "get-slash-normalized",
    "get-slash-pointless-dot-normalized",
    "get-slash-pointless-dot-unnormalized",
    "get-slash-unnormalized",
    "get-slashes-normalized",
    "get-slashes-unnormalized",
    "get-space-normalized",
    "get-space-unnormalized",
    "get-unreserved",
    "get-utf8",
    "get-vanilla",
    "get-vanilla-empty-query-key",
    "get-vanilla-query",
    "get-vanilla-query-order-encoded",
    "get-vanilla-query-order-key-case",
    "get-vanilla-query-unreserved",
    "get-vanilla-utf8-query",
    "get-vanilla-with-session-token",
    "post-header-key-case",
    "post-header-key-sort",
    "post-header-value-case",
    "post-sts-header-after",
    "post-sts-header-before",
    "post-vanilla",
    "post-vanilla-empty-query-value",
    "post-vanilla-query",
    "post-x-www-form-urlencoded",
    "post-x-www-form-urlencoded-parameters",
]

# The files of every case: its request, its signing context, and the
# expected canonical request, string to sign, signature and signed request
# for header signing and for query signing.
SIGV4_CASE_FILES = [
    "context.json",
    "header-canonical-request.txt",
    "header-signature.txt",
    "header-signed-request.txt",
    "header-string-to-sign.txt",
    "query-canonical-request.txt",
    "query-signature.txt",
    "query-signed-request.txt",
    "query-string-to-sign.txt",
    "request.txt",
]

def sigv4_suite_files():
    return ["{}/{}/{}".format(SIGV4_SUITE_DIR, c, f) for c in SIGV4_CASES for f in SIGV4_CASE_FILES]
