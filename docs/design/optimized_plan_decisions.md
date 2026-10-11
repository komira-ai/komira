# Design: `OptimizedPlan`, comparisons and decided questions

Status: proposed, not built. These are §13 and §14 of [`optimized_plan.md`](optimized_plan.md), kept in their own
file so each file stays under 1,000 lines. Section numbers are that document's: `§10.x` is in
[`optimized_plan_udfs.md`](optimized_plan_udfs.md), `§15.x` in [`optimized_plan_sources.md`](optimized_plan_sources.md),
and every other `§n` is in `optimized_plan.md`.

---

## 13. Comparison with other systems

- **Trino** ([`PlanFragment`](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/sql/planner/PlanFragment.java)).
  The coordinator optimizes and fragments; workers only lower (`LocalExecutionPlanner`). That is the same split as
  here, except the optimizer runs on the coordinator. Coordinator and workers must run the same version: the
  equal-build option rejected in §9.8.
- **DataFusion** ([`datafusion.proto`](https://github.com/apache/datafusion/blob/main/datafusion/proto/proto/datafusion.proto)).
  The logical proto has no slots for optimizer decisions; the norm is to round-trip a logical plan and optimize it
  again. Decisions such as join partition mode exist only in the physical proto, which makes no compatibility
  promise across releases. *(My reading)* The lessons are to make decisions explicit fields and to reference UDFs by
  identity. Here the identity is a content digest, not a name (§10.3); §10.14 compares the UDF design with Spark
  Connect, Daft, Ray Data and Polars.
- **Spark Connect** ([overview](https://spark.apache.org/docs/latest/spark-connect-overview.html)). A thin client
  sends an unresolved plan, and the server analyzes and optimizes it. The opposite trade: version decoupling comes
  cheaply, and every plan is optimized server-side.
- **Substrait** ([`algebra.proto`](https://github.com/substrait-io/substrait/blob/main/proto/substrait/algebra.proto)).
  The precedent for `AggregationPhase` (our `mode`), per-relation advisory `Hint.Stats` (our `advice`), extension
  URIs for UDF identity, and `Plan.version` with a producer string (our `ProducerStamp`). It has no snapshot pins,
  no digest and no do-not-re-optimize contract.

---

## 14. Questions, now decided

Each question below was open in an earlier revision of `optimized_plan.md`. Each is now decided, and the design text
states the decision; the list keeps its numbering so references to it stay valid.

1. **`group_topk`.** Keep refusing it until an owner specifies its semantics (§5.2, §5.4).
2. **Scalar subqueries.** Host-side `SCALAR_FOLD` (§5.3); revisit only if the gap measured on TPC-H Q11, Q15 and Q22 is
   material. That benchmark, like every benchmark in this plan, runs on the build farm's existing benchmark support,
   not a harness of its own.
3. **Exchanges at the cut.** The cutter never adds an exchange the producer did not place. A producer that declared
   `host_count_max = 1` gets one host (§8.2).
4. **Keep the lowering or write an upgrade step** (§9.3). Decided per change, preferring kept lowering; an upgrade step
   only when keeping two lowerings would split an operator's code path.
5. **Supported CPython minors and Node majors.** Remote runs follow the producer's version: its CPython minor, 3.12 to
   3.14 at the first release, or its Node major. A release ships several bases, one per CPython minor and one per
   Node major (§10.11). A new minor is added soon after its upstream release, and one is dropped from new bases at its
   upstream end of life, and Node majors likewise. A plan recorded against a dropped version keeps running on the
   last base that shipped it (§10.12). Free-threaded builds are distinct ABI tags and are refused by name until a base ships one.
6. **Return types learned at run time.** Not shipped. Every return type is explicit in the plan (§10.5): a type hint
   or a verb argument in Python, a type value in TypeScript, and a refusal by name otherwise.
7. **Serializer acceptance across base releases.** Each base accepts its own serializer version and those of the bases
   it supersedes within one Python minor, proven by one corpus payload per version (§9.4). The Node capture format
   follows the same rule within one Node major, since each base carries one major.
8. **System libraries and JavaScript dependencies.** Dependencies live in the image, in the runtime's environment
   directory `/opt/env/<runtime>/` (Python's virtual environment is `/opt/env/komira/python/`), or, for pure
   JavaScript, bundled into the code layer under `/komira-code/`; a JavaScript package with a native addon is
   installed for the host's platform into `/opt/env/komira/node/` (§10.6). A dependency that needs a system library
   lands in the same environment directory: the image builder installs it into a relocatable prefix there, the
   worker, not the supervisor, gets it on its library path, and a library that cannot be relocated is refused by name
   at build time. *(Inferred: not yet tried against real packages.)*
9. **Aggregate state.** A fixed 64 MiB cap per group at the first release; a group over it fails by name (§10.2).
   Tuning the cap is komira-ai/komira#1148.
10. **Native UDFs** (Mojo, Rust, C, C++ and Zig, through the C ABI) ship at the first release, in-process by
    default, with the worker transport opt-in for crash isolation. The default holds because the supervisor's
    run-scoped heartbeat token never reaches the engine's process or user id (§10.10).
