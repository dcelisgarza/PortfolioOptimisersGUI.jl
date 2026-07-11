# T2 — Stack bake-off spike: the v1 web stack is Bonito

Asset for [#8](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/8), part of the wayfinder map [#6](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/6). Date: 2026-07-11. Julia 1.12.6, PortfolioOptimisers 0.25, Bonito 4.x, Clarabel.

Spike code: [`spike/t2-nested-form/spike.jl`](../../spike/t2-nested-form/spike.jl) — **throwaway**, delete once T5/T8 supersede it.

## Decision

**Bonito is the v1 web stack.** It passed every acceptance criterion of the ticket, driven in a real headless browser against real PortfolioOptimisers types. `Oxygen + htmx` remains the documented fallback and was **not** spiked — Bonito cleared the bar, so the challenger was not worth a session.

**ShoelaceWidgets is NOT required.** The spike used stock Bonito widgets throughout (`Dropdown`, `Checkbox`, `NumberInput`, `Button`, `TextField`). Keep Shoelace as an optional polish dependency, not a load-bearing one.

## What was proven

A recursive, reflection-generated form over `MeanRisk`, verified with Playwright/Chromium:

| Requirement (from the ticket) | Result |
| --- | --- |
| Dynamically-generated nested form | ✅ 39 pickers, nested 3 levels (`MeanRisk` → `JuMPOptimiser` → `Solver`) |
| Concrete-subtype dropdown on an abstract slot | ✅ `obj` → 4 `ObjectiveFunction`s; `pe` → 13 prior estimators — **generically enumerated** |
| …that re-renders children on change | ✅ picking `FactorPrior` grew its `rsd` control live; picking `MaximumRatio` grew `rf` |
| Add/remove of nested components | ✅ `r` (37 risk measures) — add ×2, remove ×1, list state tracked |
| Values captured back out | ✅ "Build" materialises a real `MeanRisk{JuMPOptimiser{FactorPrior{…}}}`; code export emits a paste-ready constructor call |

**Why Bonito fits.** The UI is *Julia functions returning DOM*, so a recursive `form_for(::Node)` mirrors the recursive type tree directly. Re-rendering a subtree on a subtype change is a plain function call writing into that slot's `Observable{DOM}` container. There is **no framework impedance** — which is precisely what killed Stipple (composite objects not recursively reactive) in T1.

## Load-bearing gotchas

### 1. `@concrete` erases the slot types — `fieldtypes` is useless

```julia
fieldtypes(MeanRisk)   # (Any, Any, Any, Any, Any)   ← ConcreteStructs
```

PortfolioOptimisers declares its structs with `@concrete`, so every field becomes a type parameter and the declared types vanish. **The slot types survive only in the positional validating constructor's method signature:**

```julia
MeanRisk(opt::JuMPOptimiser,
         r::Union{RiskMeasure, AbstractVector{<:RiskMeasure}},
         obj::ObjectiveFunction, …)
```

So introspection must read **`methods(T)`**, picking the positional method with `fieldcount(T)` params that isn't the all-`TypeVar` ConcreteStructs fallback (`slot_types(T)` in the spike). Any strategy starting from `fieldtypes` is dead on arrival. **This is the most probable root cause of "reflection felt wrong" on `dev`. Feeds T3/T4 directly.**

### 2. Reflection needs an escape hatch — generic reflection + a small override table

Some slots are *unreachable by type*:

- `Solver.solver :: Any` — holds a JuMP optimizer factory. No type surface will ever yield "Clarabel".
- `Solver.check_sol :: NamedTuple`, `settings :: Union{AbstractDict, Pair, …}` — structurally opaque.

The spike answers this with an **override registry** keyed by `(Type, field)`: a hand-written widget takes over a slot the types can't describe. Solver detection then becomes a ~20-line widget that enumerates loaded JuMP-capable modules (`detected_solvers()` — found Clarabel and offered it). Unhandled opaque slots render *visibly* as `opaque slot (T) — needs an override` rather than crashing.

**The architecture is therefore: generic reflection + an explicit, small table of overrides.** Not pure reflection. This is the same shape as StructEditor's hand-written abstract controls, but inverted: generic is the default, hand-written is the exception. **Feeds T4 and T5.**

### 3. Library defaults are invisible unless you go and get them

A slot left unset gets the library's default, but the user cannot *see* what that is. The spike default-constructs the parent (`default_for(T)`, filling required kwargs recursively) purely to read back what each slot defaults to, and labels the picker's null option `— default: MinimumRisk —` while leaving the slot **unset**.

Consequence: **the Spec IR should store overrides, not a fully-populated tree.** The code export then contains only what the user actually chose. **Feeds T6.**

### 4. Required vs defaulted kwargs is discoverable, but only by probing

`MeanRisk` requires `opt`; `JuMPOptimiser` requires `slv`; `Solver` requires `solver`. There is no reflective list of "kwargs without defaults" — the spike recovers it by calling `T(; kw...)` and catching `UndefKeywordError` in a loop (`required_kwargs`). It works, but it's a probe, not an introspection. An alternative (parsing defaults out of the source) is a T4 question.

### 5. Form size is a real UX problem, now measured

`JuMPOptimiser` has **~40 slots**, almost all `Union{Nothing, …}` optionals. Rendering them flat is unusable. The spike splits **required/non-optional → visible** and **optional → collapsed `<details>` ("advanced (30 more)")**, which is legible — but the basic/advanced split is a genuine design question, not a mechanical one. **Feeds T5.**

## Process finding: the browser-level verification loop works, and is mandatory

The headless driver **immediately caught a crash the Julia-side test passed straight through** — `nameof(::Union)` blowing up inside `concretes()`, reached only when rendering a slot the spec-tree path never touched. HTTP 200 would have reported "fine".

- **Playwright + `chromium-headless-shell` drives Bonito with no trouble** (install with `npx playwright install chromium`, *without* `--with-deps` — that needs sudo). It connects over the WebSocket, sees Julia-rendered DOM, fires real change events, and reads the re-rendered result.
- **Gotcha:** `selectOption` on a value that is *already* selected fires no change event, and reads as a false failure. Target slots by their label, not by scanning for option text.

This substantially de-risks **T9**. The loop is proven; T9 is now about making it a durable harness rather than about whether it can be done.

## Sources / artifacts

- `spike/t2-nested-form/spike.jl` — the spike (reflection layer, Spec-IR `Node`, recursive Bonito form, override registry).
- Driver scripts used for verification (scratchpad, not committed): label-targeted Playwright scripts.
