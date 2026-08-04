# Deep Research

Use only for `mode=RESEARCH.DEEP`.

## Contract

- Treat text after `topic:` as the research request.
- Stay no-edit: do not implement, publish, modify configuration, or access data without available authorization.
- Research public web, GitHub, and scholarly sources by default; use local repository context only when relevant. Use private sources only when the request identifies them and authorized tools expose them.
- `academic=screen` is mandatory: screen for relevant academic evidence before synthesis. If studies cannot materially inform the decision, report that result rather than padding the answer with weak or tangential papers.
- `literature` covers peer-reviewed studies, reviews, preprints, scholarly indexes, publishers, and discipline-specific databases. `institutional` covers original research or technical reports from universities and research institutes worldwide; never filter by country, top-level domain, or institution prestige.
- Grade sources by relevance, directness, methodological quality, and review status. Prefer a publication version of record over the equivalent preprint, not as a separate evidence class. Compare reviews and primary studies by fit: systematic reviews or meta-analyses can synthesize a mature body of work, while a direct high-quality primary study can be stronger for a narrow question. Official product documentation is canonical for product behavior, not empirical claims. University news, press releases, and index pages are discovery-only.
- Label every preprint, including arXiv, as `preprint` unless publication status is verified. A DOI is a persistent identifier, not proof of publication status. When a verified publication version exists, cite it as the primary evidence and retain its preprint only as a related version. Never infer methods or results beyond an `abstract-only` source.
- Keep a `source-ledger` for each material source: `{id, role{evidence|discovery|excluded}, canonical-link, type, review-status, version, access{full-text|abstract-only}, claim-ids, limitation}`. Only `evidence` sources may support the recommendation.
- Apply `citation-integrity`: every load-bearing external claim has an inline source id, the cited source supports the exact claim, and persistent links use a DOI, arXiv record, publisher page, or institutional permalink when available.
- `fanout=adaptive` has no arbitrary prompt-side quota, but active agents, tokens, and runtime remain platform-constrained. Do not promise unlimited capacity.

## Flow

1. Define `criteria`: decision to make, target audience, expected result, constraints, and done condition. Derive missing context from the request and direct repository evidence before asking.
2. Build `research-map`: separate the topic into 2-4 non-overlapping evidence fronts. Include the academic screen as a front when its result could change the decision; otherwise record why it is not material. Keep the decision, integration, and current repository analysis on the main path.
3. Run `research-fanout` only when it improves wall-clock time or evidence. Give each `researcher` one question, scope, source preference, and required `source-ledger` output. Continue useful main-path work after spawning.
4. Queue additional fronts only for material unresolved gaps. Join all required researchers before the decision and final synthesis.
5. Apply `source-grade`, `source-triangulation`, `citation-integrity`, and `fact-inference`. Prefer primary sources, official documentation, peer-reviewed studies, systematic reviews or meta-analyses when relevant, arXiv preprints, source repositories, releases, issues, benchmarks with methodology, and direct maintainer statements. Do not let a lone preprint establish causal, safety, performance, or cost claims; identify its review status and triangulate it. Treat popularity, star counts, university prestige, and unverified posts as weak signals.
6. Use `research-stop` when the recommendation is supported, alternatives are compared, critical unknowns are explicit, and the next search is lower value than synthesis.

## Output

Return, in this order:

1. Decision summary and recommended direction.
2. Evidence for each load-bearing claim, with inline `[S#]` citations, evidence type or review status, and confidence.
3. Ranked alternatives with expected impact, cost, risk, dependencies, and why they lost or won.
4. Prioritized roadmap with reversible validation experiments before expensive commitments.
5. Rework recommendation only when evidence shows lower net complexity, risk, or cost than adaptation; never start rework automatically.
6. Remaining uncertainty, blocked sources, and the next cheapest evidence-gathering action.
7. Sources used: list every material `evidence` source as `[S#] {authors/year, title, source type, review status, canonical link, role, limitation}`. List `discovery` sources separately so they are not presented as support for the recommendation.
