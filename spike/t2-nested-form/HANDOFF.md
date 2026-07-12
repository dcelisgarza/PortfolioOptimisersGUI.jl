# T2 spike — handoff

**Status: T2 is resolved and closed.** The v1 web stack is **Bonito** ([#8](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/8), map [#6](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/6)). This folder is a **throwaway spike** kept only as evidence for T4/T5/T6 — do not grow it into the product. Delete it once T5/T8 supersede it.

Findings write-up: [`docs/research/0002-t2-stack-spike.md`](../../docs/research/0002-t2-stack-spike.md).

## Run it

```julia
julia --project=spike/t2-nested-form
julia> include("spike/t2-nested-form/spike.jl")
julia> using Clarabel                     # so a solver is detectable
julia> server = Bonito.Server(spike_app(), "127.0.0.1", 8422)
```

Then open <http://127.0.0.1:8422>. First render takes ~20s (compilation); after that it is snappy.

**Verify in a browser, not with `curl`.** Playwright drives it fine:

```bash
npx playwright install chromium     # NOT --with-deps (needs sudo)
npm i playwright
node drive.mjs                      # scripts live in the session scratchpad, not committed
```

Gotchas that cost time:

- `page.goto(..., {waitUntil: 'networkidle'})` **never settles** — Bonito holds a websocket open. Use `domcontentloaded` plus a wait, and a generous `timeout` for the cold first render.
- `selectOption` on a value that is **already selected** fires no change event and reads as a false failure. Target slots by their `<label>`, not by scanning option text.
- After any re-render, **re-query locators** — stale ones silently point at the wrong row.

## What the spike proves (all verified in headless Chromium)

- Recursive, reflection-generated form over real `MeanRisk`.
- **Generic** abstract-slot pickers (`obj` → 4 objectives, `pe` → 13 priors), not hand-written per type.
- Subtype change re-renders that subtree only.
- List slots: add / remove / per-row type picker.
- Values captured back out: builds a genuine `MeanRisk{…}` and emits a paste-ready constructor call.

## The five things that actually matter (they bind T4/T5/T6)

1. **`@concrete` erases the slot types.** `fieldtypes(MeanRisk) == (Any, Any, Any, Any, Any)`. The real types survive **only** in the positional constructor's method signature → read `methods(T)` (`slot_types`). Anything starting from `fieldtypes` is dead on arrival.
2. **Never enumerate an open universe.** `TimeDependent.val :: Union{AbstractVector, Base.Callable, …}` and `Base.Callable == Union{Function, Type}`. "Abstract slot → list its concrete subtypes" tries to enumerate *every function in the session*, and `Type` never bottoms out — it hung the server at 100% CPU and made `+ add` look like a dead button. `TimeDependent` is in ~20 of `JuMPOptimiser`'s slots. Enumeration is refused for `Any`/`Function`/`Type`/`DataType`/`Module`; such a slot is **opaque** and needs an override widget.
3. **Reflection needs an escape hatch.** `Solver.solver :: Any` holds a JuMP optimizer factory — no type surface yields "Clarabel". Architecture = **generic reflection + a small explicit `(Type, field)` override table** (`OVERRIDES`/`SLOT_DEFAULT`). Unhandled opaque slots render *visibly* rather than crashing.
4. **A slot has four states**, not two: **unset** (→ library default) / **explicit `nothing`** (→ *disable*) / **scalar** / **composite**. Omitting `bgt` gives `1.0`; passing `nothing` disables the budget constraint. An IR that encodes "unset" *as* `nothing` cannot tell them apart (hence the `Explicit` sentinel).
5. **Build the tree lazily, one level deep.** Eagerly filling required slots walks the near-cyclic type graph to build subtrees nobody asked for. Untouched slots stay unset; `materialise` fills required-but-unset kwargs from the library's own default instance. No recursion ⇒ no depth cap, no cycle guard.

Also: scalar widgets are chosen from the **declared type**, not the current value (else `WeightsTracking.fixed::Bool` renders as a number box); reflection is **memoised** (it probes by constructing objects); and **Bonito widgets fire their observable on construction**, so a handler that rebuilds its own subtree re-enters itself — `rebuild!` is non-reentrant and construction echoes are ignored.

## Known warts (deliberately left — they are T5's to decide)

- **One control, two meanings.** A list slot's picker is *the value* in single mode but *what `+ add` appends* in list mode. It no longer destroys the list, and a hint says which mode you are in, but T5 should consider splitting it (a dedicated `add [type] ▾`).
- **The form opens shallow.** `opt` shows as `— default: JuMPOptimiser —` and must be picked to expand. A consequence of laziness — probably right (a 40-slot tree should not unfurl in your face), but it is a real UX decision, not an accident.
- `JuMPOptimiser` has ~40 slots, nearly all optional → required-visible / optional-in-`<details>`. Legible, but the basic/advanced split is a design question.
- No error handling to speak of. Not production code.

## Where the map goes next

Frontier: **T3** (type-surface survey), **T7** (data-loading & session model), **T9** (browser verification loop — now largely de-risked, see above), **T10** (run execution & solver detection). Findings 1, 2, 3 feed **T4**; 3, 4 and both warts feed **T5**; 4 and 5 feed **T6**.
