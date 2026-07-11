# PortfolioOptimisersGUI.jl — Domain Glossary

The interactive workbench for [PortfolioOptimisers.jl](https://github.com/dcelisgarza/PortfolioOptimisers.jl): a locally-served web app in which a Julia-literate quant loads returns data, composes portfolio-construction pipelines, runs them, and compares results. This is a separate bounded context from the library itself — the library's glossary (its `CONTEXT.md`: Estimator, Result, Prior, Risk Measure, …) is consumed here unchanged; the terms below are the workbench's own.

## Language

### Session model

**Workspace**:
The unit a user opens, saves, and returns to. Holds exactly one dataset (a `ReturnsResult`), the Asset Sets defined over it, and any number of Strategies with their Runs. Comparing different datasets means different Workspaces.
_Avoid_: Project, session, document

**Strategy**:
A named, runnable pipeline configuration: prior + optimiser + risk measures + constraints. What the user edits in the workbench. A Strategy is configuration only — it holds no computed results.
_Avoid_: Pipeline, portfolio (a portfolio is the *output* weights, not the configuration), spec (that is its serialised form)

**Run**:
One execution of a Strategy against the Workspace's dataset: an immutable snapshot of the Strategy Spec at launch time plus the optimisation outputs (weights, prior result, status). Runs persist side-by-side for comparison. A frontier sweep is a structured family of Runs.
_Avoid_: Result (reserved for the library's Result structs), job, execution

### Configuration model

**Strategy Spec**:
The declarative, JSON-serialisable data tree (type names + field values) that fully describes a Strategy. The single intermediate representation behind everything: forms edit the Spec; the Spec is materialised into live estimators to run, written to disk to save, and rendered to a Julia script for Code Export.
_Avoid_: Config, model, IR

**Schema**:
The machine-readable description of one estimator type used to auto-generate its form: fields, types, defaults, admissible concrete types per abstract slot, and help text. Derived by reflection from the library, then overlaid by the Schema Registry.
_Avoid_: Metadata, form definition

**Schema Registry**:
The GUI-side, hand-maintained overlay on reflected Schemas: numeric ranges, display names, and common-vs-advanced field tiers. Lives entirely in this package; the library remains GUI-agnostic.
_Avoid_: Overrides file, annotations

**Code Export**:
Rendering a Strategy Spec (or a whole Run) as a standalone, runnable Julia script that reproduces the result with the library alone. The workbench's reproducibility contract.
_Avoid_: Script generation, transpilation

### Execution model

**Runner**:
The async execution layer: launches Runs on background tasks in the user's Julia session, reports per-Run status (queued / running / done / failed) and per-point sweep progress. Stopping is only honoured *between* sweep points; an in-flight solve cannot be killed (v1 limitation).

**Backend Detection**:
Discovering which JuMP solver packages the user has loaded in their session and offering exactly those in the Solver editor. The workbench bundles no solver backends.
