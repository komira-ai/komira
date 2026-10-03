"""The tiny restXml model this package generates a client from.

`model` is the label of the model file and `sha256` its digest, which
`aws-client-gen --model-sha256` requires. The digest is stated once, here,
and read by both packages that generate from the model: this one (pure mode,
compiled and tested) and the aws_codegen functional tests (the pure-mode
text golden). An edited model with a stale digest is refused by the generator.
"""

TINY_REST_XML = struct(
    model = "komira//tools/build/proto-codegen/aws_rest_xml:tiny_rest_xml.json",
    sha256 = "7f960b9d0f5a4c8b06d4f3338c525c68bef960651af9318bae43810df3675a49",
)
