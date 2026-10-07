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
`botocore_model("logs").sha256` as `--model-sha256`. The service's endpoint
ruleset, `endpoint-rule-set-1.json` beside the model, is
`botocore_model("logs").endpoint_rules`, and the partition table its
`aws.partition` reads (`botocore/data/partitions.json`) is
`botocore_model("logs").partitions`. Both are sub-targets of BUCK's
`:endpoint_rules`, the one place the archive's endpoint files are read
(`botocore_endpoint_file`).
"""

BOTOCORE_MODELS = {
    # Amazon API Gateway v2 (//src/komira_aws_apigatewayv2). Its endpoint
    # prefix and signing name are `apigateway`; the directory is
    # `apigatewayv2`.
    "apigatewayv2": struct(
        api_version = "2018-11-29",
        sha256 = "fdb831dc9be4cb380b42e21525a1a7e6e379958b7d8a3df7fd71c6c7f50df47c",
    ),
    # Amazon CloudWatch (//src/komira_aws_metrics), whose GetMetricData
    # reader is hand-written; generating it from this model is a follow-up
    # (the AWS generator chooses `json` from the model's `protocols`, whose
    # first entry is smithy-rpc-v2-cbor). Its test_cloudwatch_model checks the
    # reader's constants against this model and its endpoint against the
    # service's endpoint tests. Its endpoint prefix and signing name are
    # `monitoring`.
    "cloudwatch": struct(
        api_version = "2010-08-01",
        sha256 = "c217274ee4301d6a1a826db9f0d2095c181c4c29e5f97360d84929006ea079dc",
    ),
    # Amazon DynamoDB (//src/komira_aws_dynamodb).
    "dynamodb": struct(
        api_version = "2012-08-10",
        sha256 = "c9ee3a42d8c16be98f1029d368f0b6e7f62a47305c8f80cd6dd5318d6e4984c0",
    ),
    # Amazon DynamoDB Streams (//src/komira_aws_dynamodbstreams).
    "dynamodbstreams": struct(
        api_version = "2012-08-10",
        sha256 = "95cd147c971cd46365849c08e8c596bfd557b31a448b0bbf494d91f65d0ac62f",
    ),
    # Amazon EC2 (//src/komira_aws_ec2), an ec2Query client of twelve of its
    # operations. Its latest api version; botocore keeps the
    # older ones beside it.
    "ec2": struct(
        api_version = "2016-11-15",
        sha256 = "ce3cdb5d329b380286bf5ffb312cb02ad3728916228d08143971d2f62e10e5df",
    ),
    # Amazon ECR (//src/komira_aws_ecr).
    "ecr": struct(
        api_version = "2015-09-21",
        sha256 = "3df743678897ac26e9ca4b8a04bf3007fcadf887feb3e71a50131c874cfbe757",
    ),
    # Amazon ECS (//src/komira_aws_ecs).
    "ecs": struct(
        api_version = "2014-11-13",
        sha256 = "44e0fd74d3dd8f629bb5a2259635721806ac4c2daf17c62d38160544daf9bb3c",
    ),
    # AWS Identity and Access Management (//src/komira_aws_iam), an awsQuery
    # client of a global service.
    "iam": struct(
        api_version = "2010-05-08",
        sha256 = "15c70eaeb15bda321fbf0e9a0db35036d67c6ccd34d38acbcad3a086b89251c5",
    ),
    # AWS Lambda (//src/komira_aws_lambda).
    "lambda": struct(
        api_version = "2015-03-31",
        sha256 = "ff0091ee22af3ea4c1c8e7521245ebc917d68250050d62e8462c78e404f914c0",
    ),
    # Amazon CloudWatch Logs (//src/komira_aws_logs), also the worked
    # example of mojo_aws_client's docstring (//tools/build/cloud:aws.bzl).
    "logs": struct(
        api_version = "2014-03-28",
        sha256 = "b3c6eb36bc6e4975bdbab2592fcea79c21ce323c29ddb7f40ff1b0d0a5838c30",
    ),
    # Amazon Route 53 (//src/komira_aws_route53).
    "route53": struct(
        api_version = "2013-04-01",
        sha256 = "29dae1683f6128df6cad788a27af0e1aa1ce0e71a99e99b1c4e4d6f24e2b159b",
    ),
    # Amazon S3 (//src/komira_aws_s3). Its ruleset and endpoint test cases
    # are also run through komira_aws_core's interpreter and a generated
    # test client, whose bindings are checked against this model.
    "s3": struct(
        api_version = "2006-03-01",
        sha256 = "429763d64912af5edae4c7a0f20a8ac3e6fecf734cde5fc465016bc8badcdef9",
    ),
    # Amazon EventBridge Scheduler (//src/komira_aws_scheduler).
    "scheduler": struct(
        api_version = "2021-06-30",
        sha256 = "428fbc6d766436e7b5394010e98987af0c738980ccab60d541dd5e5720e643e1",
    ),
    # AWS Secrets Manager (//src/komira_aws_secretsmanager).
    "secretsmanager": struct(
        api_version = "2017-10-17",
        sha256 = "d568532fb0db48e0ce9c3c30b6f48aae734e1657105043990ef699ec48656671",
    ),
    # Amazon SES, the classic API (//src/komira_aws_ses), an awsQuery client
    # of its receipt rules, which SES API v2 does not have. Its endpoint
    # prefix is `email` and its signing name `ses`, as v2's.
    "ses": struct(
        api_version = "2010-12-01",
        sha256 = "78f98dc6c5f4b83a60ba84091f5b76dd14b01a8a37be52cad384430b2a08b862",
    ),
    # Amazon SES API v2 (//src/komira_aws_sesv2). Its endpoint prefix is
    # `email` and its signing name `ses`.
    "sesv2": struct(
        api_version = "2019-09-27",
        sha256 = "523f615366822edad2a31f43b3a93e2fcf582ee1f483176cabf939ec6bd77d23",
    ),
    # Amazon SNS (//src/komira_aws_sns), an awsQuery client.
    "sns": struct(
        api_version = "2010-03-31",
        sha256 = "a89df7db9dc5e766cb8ad5d21175c9cc28baf7cabc20ebf8f8a6dd5a2f5a7d2b",
    ),
    # Amazon SQS (//src/komira_aws_sqs).
    "sqs": struct(
        api_version = "2012-11-05",
        sha256 = "282d08c85a2003ab91ed400a81339fe81952e446ae40a599877705903e870c0f",
    ),
}

def _api_version(service):
    if service in BOTOCORE_MODELS:
        return BOTOCORE_MODELS[service].api_version
    fail("botocore service `{}` is not in BOTOCORE_MODELS".format(service))

def botocore_model_path(service):
    """The model's path in the archive, under its top directory."""
    return "botocore/data/{}/{}/service-2.json".format(service, _api_version(service))

BOTOCORE_PARTITIONS_PATH = "botocore/data/partitions.json"

def botocore_endpoint_rules_path(service):
    """The path of the service's endpoint ruleset in the archive."""
    return "botocore/data/{}/{}/endpoint-rule-set-1.json".format(service, _api_version(service))

def botocore_endpoint_tests_path(service):
    """The path of botocore's endpoint test cases for the service."""
    return "tests/functional/endpoint-rules/{}/endpoint-tests-1.json".format(service)

def botocore_endpoint_file(path):
    """The `:endpoint_rules` sub-target of one archive path."""
    return "komira//third_party/botocore:endpoint_rules[{}]".format(path)

def botocore_model(service):
    """The model target of `service`, the sha256 its consumer passes, and
    the service's endpoint ruleset and the partition table."""
    return struct(
        model = "komira//third_party/botocore:" + service,
        sha256 = BOTOCORE_MODELS[service].sha256,
        endpoint_rules = botocore_endpoint_file(botocore_endpoint_rules_path(service)),
        partitions = botocore_endpoint_file(BOTOCORE_PARTITIONS_PATH),
    )
