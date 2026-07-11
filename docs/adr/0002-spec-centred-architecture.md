# Forms edit a declarative Strategy Spec, not live Julia objects

All GUI state for a Strategy is a JSON-serialisable data tree of type names + field values (the Strategy Spec). One representation, three consumers: (1) **run** — the Spec is materialised through the library's keyword constructors into live estimators and passed to `optimise`; (2) **persist** — Workspaces save as human-readable, diffable JSON; (3) **Code Export** — the Spec renders to a standalone Julia script, which is the reproducibility feature the target audience (Julia-literate quants) will actually trust.

## Considered Options

- **Live objects + JLD2 snapshots**: less indirection, but binary saves break across struct changes, and code export becomes a separate hand-written feature.
- **Code-as-storage** (the saved artifact is the generated script): transparent, but parsing Julia back into forms is far harder than parsing JSON.

## Consequences

- The Spec ↔ constructor ↔ script mappings are the core engine and get round-trip tests (spec → code → spec).
- Estimator forms are auto-generated from reflected Schemas plus a GUI-side Schema Registry (see ADR-0004), so the Spec's vocabulary is the library's own type tree.
