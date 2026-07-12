# T3 — PortfolioOptimisers.jl type surface: what is reliably introspectable

Asset for [#9](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/9), part of the wayfinder map [#6](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/6). Date: 2026-07-12. Julia 1.12.6, PortfolioOptimisers @ `4c122dad2`, probed live via kaimon.

## Verdict

**The type surface is introspectable enough to generate the form generically.** On the surface that actually matters — the types reachable from `MeanRisk` that a user can configure — keyword construction is **100% uniform**, docstrings are **100% present**, and the declared slot types are recoverable for all but one type.

The hand-maintained overlay is **small and enumerable**: **5 bespoke slot widgets, 15 "custom callable" escapes, 6 kwarg/field mismatches, 1 type with no recoverable slot types.** Everything else — 915 slots across 337 types — comes out of reflection.

**But the map's standing enumeration rule is the wrong shape and must be replaced** (§5). It is a blacklist; it needs to be an allowlist.

## Definitions

Two different sets get conflated, and the numbers only make sense once they are split:

- **Package surface** — every type in `PortfolioOptimisers`: **434 structs** (108 of them singletons with no fields, 326 with fields) and **211 abstract types**.
- **Form surface** — types reachable from `MeanRisk` by walking declared slot types, **excluding `AbstractResult` subtypes**: **337 types, 238 of them with fields, 915 slots, max depth 5** (`MeanRisk` 0 → `JuMPOptimiser` 1 → `Solver` 2).

Almost every ugly exception in the package lives *outside* the form surface. Reporting package-wide numbers makes reflection look far less reliable than it is.

## 1. Are estimators uniformly constructed via keyword constructors?

**On the form surface: yes, without exception.**

| | Form surface | Package-wide |
| --- | --- | --- |
| Fielded structs | 238 | 326 |
| Have a keyword constructor | **238 (100%)** | 312 (96%) |
| kwargs exactly match fieldnames | 232 (97%) | 301 (92%) |
| Docstring present | **238 (100%)** | 434 (100%) |
| Zero-arg constructible (`T()`) | 203 (85%) | — |

The 14 package types with **no** keyword constructor are all off-surface: `*Result` types, kernels (`GerberIQKernel`, `SmythBrobyKernel`), and parser/config internals (`ParsingResult`, `ScopedConfig`, `StringDistanceConfig`, `SubsetMIPSpace`, `ClusterNode`, `EquationLimits`). A form generator never meets them.

**The 6 on-surface kwarg/field mismatches** — the overlay must special-case these, because "kwargs = fieldnames" is otherwise the round-trip rule:

| Type | kwarg with no field | field with no kwarg |
| --- | --- | --- |
| `Frontier` | — | `factor` |
| `DateWalkForward` | — | `test_size`, `train_size` |
| `IndexWalkForward` | — | `test_size`, `train_size` |
| `CombinatorialCrossValidation` | `max_comb` | — |
| `MatrixProcessing` | `N` | — |
| `LogRegimeAdjusted` | — | `kappa` |

These are *derived* fields (computed by the constructor from other kwargs) and *shorthand* kwargs (expanded into several fields). Both directions break a naive `T(; fieldnames...)` round-trip.

## 2. `@concrete` erases the field types — but the constructor signature restores them

**319 of 326** fielded structs (98%) are declared with `@concrete`, so every field becomes a type parameter and `fieldtypes(T)` returns all-`Any`:

```julia
fieldtypes(MeanRisk)                       # (Any, Any, Any, Any, Any)          ← useless
fieldtypes(Base.unwrap_unionall(MeanRisk)) # (__T_opt, __T_r, __T_obj, …)       ← TypeVars, still useless
```

The declared types survive **only** in the positional validating constructor's method signature. `methods(T)` carries *two* positional methods with `fieldcount(T)` arguments: the ConcreteStructs inner constructor (all `TypeVar`s — discard it) and the real one:

```julia
MeanRisk(opt::JuMPOptimiser,
         r::Union{RiskMeasure, AbstractVector{<:RiskMeasure}},
         obj::ObjectiveFunction, …)
```

This confirms T2's finding and extends it with the coverage number: **the signature recovers the slot types for every fielded struct in the package except 12** — of which 11 are `*Result`/`*Cache` types, leaving exactly **one on the form surface: `LogRegimeAdjusted`**, which needs a hand-written slot list.

> Any introspection strategy that starts from `fieldtypes` is dead on arrival. This remains the single most likely root cause of "reflection felt wrong" on `dev`.

## 3. Slot census — what a form generator actually faces

All 915 slots on the form surface, classified by what the declared type permits:

| Kind | Slots | What the GUI must do |
| --- | --- | --- |
| **structural** (`Number`, `Integer`, `AbstractString`, `NamedTuple`, …) | 521 (57%) | scalar widget |
| **abstract, PO-owned** | 268 (29%) | **generic subtype picker** — the reflection sweet spot |
| **concrete composite** | 68 (7%) | nested sub-form, single option |
| **vector-only** | 38 (4%) | list / data widget |
| **open-universe inside a Union** | 15 (1.6%) | drop the `Function` branch; offer a callable escape |
| **open-universe, pure** | 5 (0.5%) | **bespoke override widget** |

370 slots (40%) are optional (`Union{Nothing, …}`) and 205 (22%) accept a vector — corroborating T2's "a slot has four states" and "scalar-or-vector slots promote on first add".

Picker sizes on the 268 PO-abstract slots: **median 2 options, max 56.** Small, humane dropdowns.

### The entire bespoke-widget list (5 slots)

These have no type surface at all and *must* be hand-written — this is the whole of the `(Type, field)` override table T2 predicted:

| Slot | Declared type | Why |
| --- | --- | --- |
| `Solver.solver` | `Any` | a JuMP optimizer factory; solver detection (T2's `detected_solvers()`) |
| `Denoise.kernel` | `Any` | a KernelDensity kernel |
| `Posdef.alg` | `Any` | algorithm handle |
| `PreviousWeightsFunction.f` | `Any` | user callable |
| `RelativisticDrawdownatRisk.settings` | `Any` | opaque settings bag |

### The 15 open-in-Union slots are *not* a problem

Every one has the same shape — `Union{Function, <something perfectly introspectable>}`:

```julia
SubsetResampling.n_subsets :: Union{Function, Integer, NumberSubsetsEstimator}
GerberIQCovariance.sc      :: Union{Nothing, Function, GerberIQScalerEstimator}
TimeDependent.val          :: Union{Function, TimeDependentCallable, Type, PreviousWeightsFunction, AbstractVector}
```

The `Function`/`Type` branch is an **escape hatch for user-supplied callables**; the other branches are ordinary. So the rule is *not* "this slot is opaque" (T2's reading, which is what hung the server) but: **drop the `Function`/`Type` branch, render the rest normally, and offer "custom callable" as an advanced option.** That downgrades 15 killers — including `TimeDependent.val`, the one that pegged the CPU — to 15 ordinary slots.

## 4. `Estimator | Result` is a first-class pattern, not an accident

**66 slots** on the form surface accept a union of an estimator *and* a result:

```julia
JuMPOptimiser.pe  :: Union{AbstractPriorEstimator, AbstractPriorResult}
MeanRisk.fb       :: Union{Nothing, NonFiniteAllocationOptimisationEstimator,
                                    NonFiniteAllocationOptimisationResult}
IntegerPhylogenyEstimator.pl :: Union{AbstractClusteringResult, AbstractClustersEstimator, …}
```

This means **"compute this, or reuse something already computed"**. It is why 44 `AbstractResult` types are reachable from `MeanRisk` at all.

A result cannot be sensibly built field-by-field in a form — it is the output of a previous run. So the Result branch of these unions must **not** render as a nested constructor sub-form; it must render as a **reference picker**: *"use the result from ⟨earlier step / workspace variable⟩"*.

This is a UX and session-model decision, and it is load-bearing: it is the mechanism by which the workbench composes runs. **Feeds T6 (spec IR) and T7 (session model) directly.** `AbstractResult` is a clean common ancestor to detect it on.

## 5. ⚠️ The map's enumeration rule is the wrong shape — replace the blacklist with an allowlist

The map currently carries this standing constraint:

> ⛔ Never enumerate the subtypes of `Function`, `Type`, `DataType`, `Module` or `Any`.

**That is necessary but not sufficient, and the shape is wrong.** Enumerating "any abstract type that isn't on the blacklist" is still catastrophic, because plenty of *closed* abstract types are semantically scalar and enormous:

| Abstract type | Concrete subtypes in session | Slots pointing at it |
| --- | --- | --- |
| `Number` | **53** | 217 |
| `AbstractArray` | **63–91** | 82 |
| `Distributions.Distribution` | **102** | 1 |
| `Integer` | 13 | 62 |
| `Real` | 50 | 1 |

Enumerate by "closedness" and the median picker becomes **19 options and the worst becomes 311** — versus median 2 / max 56 when restricted to PO-owned abstracts. A slot that means *"a number"* would render as a 53-item dropdown of `Float16`, `BigInt`, `Rational`, …

Worse, **these counts depend on which packages happen to be loaded.** `Number` has 53 subtypes *because* JuMP and Distributions are in the session. A dropdown whose contents change because the user typed `using Distributions` is a bug, and it makes the GUI non-deterministic.

**The rule that actually works — and it is two rules, not one:**

1. **Enumerate by ownership, not by closedness.** Offer a subtype picker **only** for abstract types owned by `PortfolioOptimisers`, plus a short explicit allowlist of foreign abstracts that are genuinely choices:

   | Allowed foreign abstract | Options | Slots |
   | --- | --- | --- |
   | `StatsBase.AbstractWeights` | 5 | 49 |
   | `StatsBase.CovarianceEstimator` | 19 | 17 |
   | `Transducers.Executor` | 4 | 10 |
   | `Random.AbstractRNG` | 5 | 5 |
   | `Distances.Metric` | 22 | 2 |
   | `Dates.Period` | 11 | 3 |

   Everything else abstract (`Number`, `Integer`, `AbstractString`, `AbstractArray`, `AbstractDict`, `Distribution`) is **scalar or data**, and gets a widget — never a picker.

2. **Recurse by ownership too — foreign types are leaves.** An unbounded walk of the type graph does not merely enumerate too much: it **leaves the package entirely and crashes.** Walking from `MeanRisk` without a module bound reached Base's `Array` wrapper and died in `fieldcount` ("type does not have a definite number of fields") after 58s. Bounded to PO, the same walk terminates at **337 types, depth 5**.

Note the asymmetry, because it is the crux: `StatsBase.AbstractWeights` is *enumerated* (5 options offered) but its concretes are **not recursed into** — they are leaves, default-constructed. Enumeration and recursion need separate rules.

Two further traps worth recording:

- **`PortfolioOptimisers.DynamicAbstractWeights` has zero concrete subtypes.** An abstract slot can legitimately yield an **empty picker**; the form must not assume ≥1 option.
- **`subtypes()` rescans every loaded module on every call** and is slow enough to make a naive walk look like a hang. Measured on the walk from `MeanRisk`: **~51s** calling `subtypes` per slot, **7.7s** memoised-but-cold, **0.03s** memoised and warm. This is the mechanical reason T2's spike had to memoise — it is not an optimisation, it is the difference between a form that renders and a server that looks hung.

## 6. What this binds

- **T4 (reflection layer).** Read slot types from `methods(T)`, never `fieldtypes`. Enumerate by the ownership allowlist in §5, not by a blacklist. Memoise `subtypes`. Override table = the 5 slots in §3 + `LogRegimeAdjusted`'s slot list + the 6 kwarg mismatches in §1. Foreign abstracts: enumerate, don't recurse.
- **T5 (form UX).** 268 pickers (median 2 options), 521 scalar widgets, 40% optional slots, 22% list-capable. The `Function` branch of the 15 union slots becomes a "custom callable" advanced control, not an opacity error.
- **T6 (spec IR).** Must express the four slot states (T2) *and* the `Estimator | Result` reference (§4) — a slot's value may be a **pointer to a prior result**, not a constructed object.
- **T7 (session model).** §4 is the composition mechanism: results are first-class, referenceable session objects.

## Reproducing

Live probe, no files needed:

```julia
julia --project=spike/t2-nested-form
julia> using PortfolioOptimisers
julia> fieldtypes(MeanRisk)                      # (Any, Any, Any, Any, Any) — the erasure
julia> methods(MeanRisk)                         # the positional signature has the real types
julia> length(subtypes(Number))                  # 53 — why a closedness blacklist fails
```

`slot_types`, `classify`, and the memoised `concretes` in [`spike/t2-nested-form/spike.jl`](../../spike/t2-nested-form/spike.jl) are the working reference implementations of §2 and §5.
