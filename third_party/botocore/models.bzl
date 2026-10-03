"""The botocore service models komira generates AWS clients from.

Each entry is one service's model in the botocore archive BUCK pins,
botocore/data/<service>/<api_version>/service-2.json, read from that archive
at build time. Nothing of botocore is committed here: taking a newer model is
bumping the archive's url and sha256 in BUCK, and the entries below.

`sha256` is the model file's own digest. The archive's sha256 already pins
these bytes; the entry exists because `aws-client-gen --model-sha256`
requires it, and the target `:<service>` refuses the model when the two
differ, so bumping the archive cannot leave a stale entry behind.

A consumer takes the model as `botocore_model("logs").model` and passes
`botocore_model("logs").sha256` as `--model-sha256`.
"""

BOTOCORE_MODELS = {
    # Amazon CloudWatch Logs.
    "logs": struct(
        api_version = "2014-03-28",
        sha256 = "b3c6eb36bc6e4975bdbab2592fcea79c21ce323c29ddb7f40ff1b0d0a5838c30",
    ),
}

def botocore_model_path(service):
    """The model's path in the archive, under its top directory."""
    return "botocore/data/{}/{}/service-2.json".format(service, BOTOCORE_MODELS[service].api_version)

def botocore_model(service):
    """The model target of `service` and the sha256 its consumer passes."""
    return struct(
        model = "komira//third_party/botocore:" + service,
        sha256 = BOTOCORE_MODELS[service].sha256,
    )
