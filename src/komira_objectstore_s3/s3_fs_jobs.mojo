# =============================================================================
# komira_objectstore_s3/s3_fs_jobs.mojo -- the concurrent requests of S3Fs
# =============================================================================
#
# `S3SpanJobs` (the coalesced requests of one prefetch) and `S3PartJobs` (the
# held parts of one upload) are the `InflightJobs` S3Fs hands to
# `run_bounded_inflight` (inflight.mojo). Job `j` runs on worker `w` over
# store `w` of the file system, which no other thread uses while the jobs
# run; what each job writes (its ranges' bytes of the call's buffer, its slot
# of the answers) no other job writes. The pointers are borrowed for the
# call: `run_bounded_inflight` returns only after every thread has joined.
# =============================================================================

from std.memory import Pointer

from komira_aws_core import AwsClock, AwsCredsSource
from komira_buffer.byte_view import ByteView
from komira_http_core.transport.io_stream import Connector
from komira_objectstore.coalesce import CoalescePlan

from .inflight import InflightJobs
from .store import S3Store, S3UploadedPart


struct S3SpanJobs[
    C: Connector,
    T: AwsCredsSource & Copyable,
    K: AwsClock & Copyable & Deinitable,
    so: MutOrigin,
    po: MutOrigin,
    dsto: MutOrigin,
](InflightJobs):
    """The coalesced requests `first..` of a plan, job `j` being request
    `first + j`, each sent on its worker's store into the call's buffer."""

    var stores: Pointer[List[S3Store[Self.C, Self.T, Self.K]], Self.so]
    var plan: Pointer[CoalescePlan, Self.po]
    var dst: ByteView[mut=True, Self.dsto]
    var bucket: String
    var key: String
    var etag: String
    var first: Int

    def __init__(
        out self,
        stores: Pointer[List[S3Store[Self.C, Self.T, Self.K]], Self.so],
        plan: Pointer[CoalescePlan, Self.po],
        dst: ByteView[mut=True, Self.dsto],
        bucket: String,
        key: String,
        etag: String,
        first: Int,
    ):
        self.stores = stores
        self.plan = plan
        self.dst = dst
        self.bucket = bucket
        self.key = key
        self.etag = etag
        self.first = first

    def run_job(self, worker: Int, job: Int) raises:
        # Worker `worker` is the only thread using store `worker`, and each
        # request writes only the bytes of its own ranges into `dst`
        # (`S3Store.fetch_span_into`); the plan's ranges do not overlap in
        # `dst`, so two requests never write one byte.
        _ = self.stores[][worker].fetch_span_into(
            self.bucket,
            self.key,
            self.plan[].coalesced[self.first + job],
            self.dst,
            self.etag,
        )


struct S3PartJobs[
    C: Connector,
    T: AwsCredsSource & Copyable,
    K: AwsClock & Copyable & Deinitable,
    so: MutOrigin,
    bo: MutOrigin,
    oo: MutOrigin,
](InflightJobs):
    """Parts of one upload, job `j` being part number `first_number + j`
    with body `bodies[j]`, each sent on its worker's store; its answer is
    written to `answers[j]`."""

    var stores: Pointer[List[S3Store[Self.C, Self.T, Self.K]], Self.so]
    var bodies: Pointer[List[List[UInt8]], Self.bo]
    var answers: Pointer[List[Optional[S3UploadedPart]], Self.oo]
    var bucket: String
    var key: String
    var upload_id: String
    var first_number: Int

    def __init__(
        out self,
        stores: Pointer[List[S3Store[Self.C, Self.T, Self.K]], Self.so],
        bodies: Pointer[List[List[UInt8]], Self.bo],
        answers: Pointer[List[Optional[S3UploadedPart]], Self.oo],
        bucket: String,
        key: String,
        upload_id: String,
        first_number: Int,
    ):
        self.stores = stores
        self.bodies = bodies
        self.answers = answers
        self.bucket = bucket
        self.key = key
        self.upload_id = upload_id
        self.first_number = first_number

    def run_job(self, worker: Int, job: Int) raises:
        # Worker `worker` is the only thread using store `worker`, and job
        # `job` is the only one writing `answers[job]`.
        var part = self.stores[][worker].upload_part(
            self.bucket, self.key, self.upload_id, self.first_number + job, self.bodies[][job]
        )
        self.answers[][job] = Optional[S3UploadedPart](part^)
