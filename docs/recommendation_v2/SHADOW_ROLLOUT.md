# Original staged rollout proposal — superseded

The user explicitly chose direct replacement after regression on 2026-09-09.
The plan below is retained as historical design, not current release status.
See `IMPLEMENTATION_STATUS.md` for the actual deployment and client boundary.

| Phase | Classifier | Filtering | Required evidence |
| --- | --- | --- | --- |
| 0 (current) | Offline tooling | Off | Exact embedding experiment, data review |
| 1 | Compatible model scores existing vectors once per version/hash | Off | Runtime parity, failure isolation, score coverage |
| 2 | On, with sampled shadow decisions | Off | V1 output equality, FP-style review, bounded logs |
| 3 | On | Explicit controlled cohort | Reviewed real holdout, supported client contract, rollback drill |
| 4 | On | Approved expansion | Acceptable measured error and operational results |

The proposed switches are independent: classifier scoring, shadow observation,
and `cross_school_gate_enabled`. They are **design names at this stage**, not
newly deployed or wired configuration. V1 rollout remains 0% and V1 shadow
remains enabled. Turning on V1 user traffic is a separate decision.

For Phase 2, sample only otherwise eligible/public forum candidates and log
post ID, origin school, viewer school, finite score or failure reason, model
version, threshold/policy version and would_allow. Avoid raw text and viewer
identifiers. Keep per-post diagnostics service-only, bounded and expiring;
aggregate counts should be the default operational view.

Required observability includes scored/error counts, model version,
probability histogram, percent above threshold, accepted/rejected foreign
candidates in shadow, missing-origin/vector and dimension-mismatch rates.
Specify denominators and distinguish unscored posts from low-scoring posts.
Never count lack of telemetry as zero failures.

Before Phase 3, test pre-ranking filtering, same-school immunity to failures,
edited/stale embeddings, model changes, session-policy invalidation, featured
overrides, legacy fallback and old clients. A service-only shadow session alone
does not prove parity with authenticated viewing because V1 has different
visibility checks for those contexts. Record both.

No numerical production acceptance boundary is invented here. A reviewer must
approve the real-holdout tradeoff, confidence bounds, label convention and
controlled rollout cohort. Synthetic scores cannot authorize filtering.
