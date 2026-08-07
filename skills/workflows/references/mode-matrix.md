# Mode Matrix

`$workflows mode=<MODE>` selects one row below. Sidecars are native and
read-only; the parent performs any authorized change.

| Mode | Sidecar | Change | Done gate |
|---|---|---|---|
| `PLAN.AUTO` | scout when evidence requires | no | route and rationale proven |
| `PLAN` | scout | no | required evidence joined |
| `P.DEEP` | scout and/or researcher | no | phase graph and claim-map joined |
| `RESEARCH.DEEP` | researcher | no | research fronts joined |
| `IMPL.AUTO` | scout preflight | no | stops without implementation approval |
| `IMPL` | scout; reviewer on risk | parent | scoped behavior validated |
| `IMPL.PHASE` | scout/reviewer at phase gates | parent | each phase validated |
| `DELIVER.AUTO` | scout and reviewer | parent | integrated freeze reviewed; never commit |
| `REVIEW` | reviewer | no | proven findings joined |
| `COMMIT` | scout when classification is material | index only | commit evidence complete; never push |
| `BUG.INV` | scout and/or researcher | no | evidence-backed hypotheses joined |
| `BUG.FIX` | scout and reviewer | parent | regression check passes |
| `DEBUG` | scout/researcher; reviewer on repair | parent | functional gate then clean gate |
| `REWORK` | scout and/or researcher | no | rework roadmap joined |
| `R.A.F.V` | reviewer and scout | parent | repair batch revalidated; no commit |
| `TN.SKILL` | reviewer and scout | no | quality roadmap joined |

`sidecar-gate` is mandatory for non-trivial work, independent fronts,
shared/core contracts, or an explicit review/testing obligation. No-edit rows
never change files.
