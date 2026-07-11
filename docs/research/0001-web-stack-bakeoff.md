# T1 — Web-stack bake-off: enumerate Julia-native options

Research asset for [#7](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/7), part of the wayfinder map [#6](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/6). Date: 2026-07-11. Julia 1.12.6, PortfolioOptimisers 0.25.

## Headline

1. **The dependency constraint that forced the last stack decision is gone.** ADR-0006 pivoted Genie/Stipple → Bonito because Genie's tree was *unsatisfiable* against PortfolioOptimisers. **Re-verified today: it resolves.** So does every other candidate. Pkg resolution is **no longer a discriminator** — the stack is now chosen on merit.
2. **Genie/Stipple is still ruled out — but on merit, not on deps.** Stipple's reactive model is *not recursively reactive over composite objects*, which is precisely our core data structure (a nested estimator tree).
3. **Strong prior art exists for the hardest part.** [StructEditor.jl](https://github.com/bradcarman/StructEditor.jl) builds forms from structs automatically — on **Bonito**, with **nested child structs** and an **abstract-type → concrete-subtype** pattern. It co-resolves with our full dep set.

**Recommendation: spike Bonito (+ ShoelaceWidgets, with StructEditor as prior art) in T2, with Oxygen + htmx as the named fallback.**

## Evidence: dependency resolution (re-verified, not inherited)

Isolated temp envs, `PortfolioOptimisers@0.25` + candidate, `Pkg.add` resolve-only:

| Stack | vs PO alone | vs **full GUI dep set**\* |
| --- | --- | --- |
| Bonito + PlotlyLight | ✅ RESOLVE_OK | — |
| **Genie + Stipple + StippleUI + StipplePlotly** | ✅ **RESOLVE_OK** | ✅ **FULLSET_OK** |
| Dash.jl | ✅ RESOLVE_OK | — |
| Oxygen (+HTTP) | ✅ RESOLVE_OK | — |
| Pluto + PlutoUI | ✅ RESOLVE_OK | — |
| Bonito + PlotlyLight + **StructEditor + ShoelaceWidgets** | — | ✅ **FULLSET_OK** |

\* full set = PortfolioOptimisers, ArgCheck, Clustering, ConcreteStructs, GraphRecipes, JuMP, StatsPlots.

> **ADR-0006 is void.** Its claim — "Genie's transitive tree is unsatisfiable against this package's dependencies; the two HTTP consumers cannot agree on a version" — no longer reproduces. Upstream compat has moved on. **Any future ADR must not cite it as a live constraint.**

## Scoring

Criteria from the ticket: **(A)** nested-form reactivity — can it drive dynamically-generated, deeply-nested forms with add/remove and concrete-subtype pickers that re-render reactively? **(B)** standalone-later deployability. **(C)** maintenance / single-language. **(D)** evidence from the `dev` spike.

### 1. Bonito (+ ShoelaceWidgets) — **recommended primary**

- **(A) Best fit.** Julia-side `Observable`s over a WebSocket; the UI is built by *Julia functions returning DOM*, so a **recursive `make_form(::T)` naturally mirrors a recursive type tree**. Re-rendering a subtree on a subtype change is a plain function call — no framework impedance.
- **Prior art is the story here.** StructEditor.jl already does struct→form on Bonito: `Bool`→checkbox, `Number/String/Symbol`→input, `Enum`→dropdown, `Vector`→tree view, and *"automatically builds control cards for child structs"*. Abstract fields (`examples/pets.jl`): dropdown of concretes → set field to a default-constructed concrete → **recurse `make_form`** → dialog. That is exactly the architecture our T5 needs.
- **Caveat (important, feeds T4/T5):** StructEditor's abstract handling is a **hand-written custom control per abstract type** (hardcoded `Dog`/`Cat`, an `ANIMAL_TYPES` dict) — *not* generic subtype enumeration. With PortfolioOptimisers' many abstract slots we must supply **generic enumeration** ourselves. StructEditor gives us the *shape*, not the whole solution.
- **ADR-0001's objection is dead.** It rejected Bonito because "most form widgets would be hand-rolled." [ShoelaceWidgets.jl](https://github.com/bradcarman/ShoelaceWidgets.jl) (Shoelace web components) supplies the widget set; and the forms are generated anyway.
- **(B)** Serves over HTTP to any browser; supports **static HTML export**; works in VS Code pane, Jupyter, Pluto, or a plain server. A future standalone app = Julia process serving Bonito (PackageCompiler-able). Door stays open.
- **(C)** Single-language Julia; moderate dep weight; actively maintained (release notes through Oct 2025), and it is WGLMakie's server — aligns with the deferred Makie milestone (ADR-0005).
- **(D)** `dev` proved `serve()` boots, HTTP 200, self-contained bundled JS, PlotlyLight chart renders. Its reported pains (frontier not displaying, "interactivity browser-only to verify") read as **app bugs and a verification-process gap**, not framework defects. The verification gap is real and must be designed for (see Risks).

### 2. Oxygen + htmx — **recommended fallback / challenger**

- **(A) Architecturally different, and genuinely viable.** Server-renders HTML fragments; htmx swaps them on interaction. Nesting is *naturally* recursive because you just render a recursive template server-side. **No reactive-model impedance at all.**
- **Cost:** no Julia-side reactive state model — you hand-wire endpoints/fragments for every interaction. More web plumbing, less Julia (ADR-0006 said the same). htmx is a small JS dependency, but all logic stays in Julia, so it honours "Julia-native".
- **(B)** Excellent — a bare HTTP server is the easiest thing to deploy standalone.
- **(C)** Lightest dep tree; most control; most manual work.
- **Use as fallback if** the T2 spike shows Bonito can't cleanly re-render dynamic nested subtrees.

### 3. Genie / Stipple — **rejected (on merit)**

- Dependency blocker is **gone**, and it has the best widget set (StippleUI/Quasar) and the strongest deployment story (full MVC framework).
- **But (A) is structurally wrong for us:** Stipple syncs a *flat reactive model* to a Vue client, and its docs state **composite objects are not recursively reactive** — changing a field of a nested composite will not reliably trigger a handler; you must replace the whole parent object. Our central object *is* a deep recursive composite. `@recur` handles looping over lists, not arbitrary recursive type trees.
- Also the heaviest tree and a Julia+Vue-template two-language surface.

### 4. Dash.jl — **rejected**

Plotly-native, but the callback model scales poorly to deeply nested *dynamic* forms (pattern-matching callbacks get painful fast), and Julia support is second-class. ADR-0001's assessment holds.

### 5. Pluto (+ PlutoUI) — **rejected as the app framework**

Reactive, but notebook-shaped and cell-based. It is not a distributable application shell, so it cannot become the later standalone app. (Fine as an *exploration* surface; not the workbench.)

## Risks / notes carried forward

- **Verification gap (from `dev`):** reactive forms, clicks, and Plotly rendering could not be checked headlessly, so bugs (frontier display) survived. Whatever stack wins, **T2/T8 must establish a browser-level verification loop** (headless browser driving the page), not just `curl` for HTTP 200. This is a process risk, not a stack risk — but it *caused* real defects.
- **Generic abstract-slot enumeration is ours to build** regardless of stack (feeds **T4**).
- **Typed JSON round-trip:** StructEditor serialises with a `"type"` field to recover the concrete subtype — directly relevant to the Spec-IR decision (**T6**).
- Whether to adopt StructEditor as a **dependency** or **copy its pattern** is a T5 decision (it is opinionated about dialogs/cards; our UX wants basic-visible/advanced-in-details).

## Sources

- [Bonito.jl](https://github.com/SimonDanisch/Bonito.jl) · [Interactions docs](https://simondanisch.github.io/Bonito.jl/stable/interactions.html) · [[ANN] Bonito.jl](https://discourse.julialang.org/t/ann-bonito-jl/132946)
- [StructEditor.jl](https://github.com/bradcarman/StructEditor.jl) · [[ANN] StructEditor.jl](https://discourse.julialang.org/t/ann-structeditor-jl-build-julia-applications-with-your-structs-automatically/137925)
- [Stipple.jl](https://github.com/GenieFramework/Stipple.jl) · [Stipple reactivity docs](https://learn.genieframework.com/framework/stipple.jl/docs/reactivity/) (the non-recursive-composite limitation)
- `dev` ADRs 0001, 0005, 0006.
