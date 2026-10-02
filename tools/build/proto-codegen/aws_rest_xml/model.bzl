"""The tiny restXml model this package generates a client from.

`model` is the label of the model file and `sha256` its digest, which
`aws-client-gen --model-sha256` requires. An edited model with a stale
digest is refused by the generator.
"""

TINY_REST_XML = struct(
    model = "komira//tools/build/proto-codegen/aws_rest_xml:tiny_rest_xml.json",
    sha256 = "fd69d3f2c272c77a8cd8988753abe43ac6ebade9d58ede0a945ba9d753160b5b",
)
