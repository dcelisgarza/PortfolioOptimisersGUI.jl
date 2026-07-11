# Form-schema metadata lives in the GUI, not the library

The generic form generator reflects Schemas from the library at startup (`subtypes()` for pickers, default-constructed instances for initial values, docstrings for help text). What reflection cannot supply — numeric ranges, display names, common-vs-advanced field tiers — lives in a hand-maintained Schema Registry inside this package. PortfolioOptimisers itself stays completely GUI-agnostic; adding an estimator there never requires a GUI-shaped change.

Rejected alternative: a metadata/trait API in the library (single source of truth, but a permanent GUI maintenance burden on every library PR). Fallback tier regardless of registry coverage: submit the form and surface the library's `@argcheck` `PortfolioOptimisersError`s in the UI.

## Consequences

- The registry can drift as the library evolves; CI checks that every registry entry still matches a real type and field.
