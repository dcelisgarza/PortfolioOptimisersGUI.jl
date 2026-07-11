# T2 spike — throwaway

Proves the v1 stack decision for [#8](https://github.com/dcelisgarza/PortfolioOptimisersGUI.jl/issues/8).
Findings: [`docs/research/0002-t2-stack-spike.md`](../../docs/research/0002-t2-stack-spike.md).

```julia
julia> include("spike/t2-nested-form/spike.jl")
julia> using Clarabel                      # so a solver is detectable
julia> server = Bonito.Server(spike_app(), "127.0.0.1", 8422)
```

**Not production code.** Delete once T5/T8 supersede it.
