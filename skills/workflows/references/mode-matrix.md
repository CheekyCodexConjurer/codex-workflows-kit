# Mode Matrix

`$workflows mode=<MODE>` selects one row below. The matrix is
backend-neutral: the backend is resolved by `backend-policy.md`, and the role
labels `scout`, `researcher`, and `reviewer` name capabilities, not a
profile- or backend-specific requirement. A mode that authorizes change is
implemented by an edit-capable writer on the resolved backend, with the
parent owning integration, validation, and final approval. Cadence is
dynamic: use exactly the workers a front requires, with no fixed quotas.

| Mode | Delegation | Change | Done gate |
|---|---|---|---|
| `PLAN.AUTO` | scout when evidence requires | no | route and rationale proven |
| `PLAN` | scout | no | required evidence joined |
| `P.DEEP` | scout and/or researcher | no | phase graph and claim-map joined |
| `RESEARCH.DEEP` | researcher | no | research fronts joined |
| `IMPL.AUTO` | scout preflight | no | stops without implementation approval |
| `IMPL` | scout; reviewer on risk | authorized | scoped behavior validated |
| `IMPL.PHASE` | scout/reviewer at phase gates | authorized | each phase validated |
| `DELIVER.AUTO` | scout and reviewer | authorized | integrated freeze reviewed; never commit |
| `REVIEW` | reviewer | no | proven findings joined |
| `COMMIT` | scout when classification is material | index only | commit evidence complete; never push |
| `BUG.INV` | scout and/or researcher | no | evidence-backed hypotheses joined |
| `BUG.FIX` | scout and reviewer | authorized | regression check passes |
| `DEBUG` | scout/researcher; reviewer on repair | authorized | functional gate then clean gate |
| `REWORK` | scout and/or researcher | no | rework roadmap joined |
| `R.A.F.V` | reviewer and scout | authorized | repair batch revalidated; no commit |
| `TN.SKILL` | reviewer and scout | no | quality roadmap joined |

`sidecar-gate` is mandatory for non-trivial work, independent fronts,
shared/core contracts, or an explicit review/testing obligation. No-edit rows
never change files.
