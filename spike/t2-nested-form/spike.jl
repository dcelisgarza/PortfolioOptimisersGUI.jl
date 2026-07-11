# T2 spike — throwaway. Bonito + a recursive, reflection-generated nested form
# over REAL PortfolioOptimisers types. Answers: can Bonito drive a dynamically
# generated nested form with generic abstract-slot pickers, add/remove lists,
# and values captured back out?
#
# NOT production code. No error handling to speak of. Delete after T2 resolves.

using Bonito, ShoelaceWidgets, PortfolioOptimisers, InteractiveUtils, JuMP
const PO = PortfolioOptimisers

# ---------------------------------------------------------------------------
# 0. The ESCAPE HATCH.
#
# Solver.solver :: Any — it holds a JuMP optimizer factory. Reflection can
# never enumerate that; no amount of type surface will tell you "Clarabel".
# So the generic reflection layer needs a per-slot override registry: a hook
# where a hand-written widget takes over a slot the types can't describe.
# This is the single most important architectural finding of the spike.
# ---------------------------------------------------------------------------

"Optimizer factories from any JuMP-capable package currently loaded."
function detected_solvers()
    out = Pair{String, Any}[]
    for m in names(Main; imported = true)
        mod = try getfield(Main, m) catch; continue end
        mod isa Module || continue
        isdefined(mod, :Optimizer) || continue
        O = getfield(mod, :Optimizer)
        try
            MOI.get(MOI.instantiate(O; with_cache_type = Float64,
                                    with_bridge_type = Float64), MOI.SolverName())
            push!(out, string(m) => O)
        catch
        end
    end
    return out
end

# slot overrides: (Type, field) => widget builder / default-value supplier
const OVERRIDES = Dict{Tuple{Any, Symbol}, Function}()
const SLOT_DEFAULT = Dict{Tuple{Any, Symbol}, Function}()

wrapper(T) = Base.unwrap_unionall(T).name.wrapper

# ---------------------------------------------------------------------------
# 1. Reflection layer
#
# The load-bearing discovery: PortfolioOptimisers uses @concrete structs, so
# fieldtypes(MeanRisk) == (Any, Any, Any, Any, Any). The slot types survive only
# in the POSITIONAL validating constructor's method signature. That is the
# source of truth for introspection.
# ---------------------------------------------------------------------------

function slot_types(T::Type)
    n = fieldcount(T)
    best = nothing
    for m in methods(T)
        sig = Base.unwrap_unionall(m.sig)
        params = sig.parameters[2:end]
        length(params) == n || continue
        all(p -> p isa TypeVar, params) && continue   # ConcreteStructs fallback
        best = params
    end
    best === nothing ? fieldtypes(T) : Tuple(best)
end

basetype(T) = Base.unwrap_unionall(T isa UnionAll ? T : T)

"Split a slot type into (core_type, optional?, list_capable?)."
function classify(ty)
    optional = false
    list = false
    branches = ty isa Union ? collect(Base.uniontypes(ty)) : Any[ty]

    keep = []
    for b in branches
        if b === Nothing
            optional = true
            continue
        end
        u = Base.unwrap_unionall(b)
        if u isa DataType && u.name.name in (:AbstractVector, :AbstractArray, :AbstractMatrix)
            list = true          # a vector branch => this slot accepts a list
            continue             # element type is (near enough) the scalar branch
        end
        push!(keep, b)
    end
    core = isempty(keep) ? Any : (length(keep) == 1 ? keep[1] : Union{keep...})
    return (core = core, optional = optional, list = list)
end

"Name of a type, safe for Unions and other exotica."
function shortname(T)
    u = try Base.unwrap_unionall(T) catch; return string(T) end
    (u isa DataType) ? string(u.name.name) : string(T)
end

"Is T something we can actually offer as a constructible choice?"
function offerable(T)
    u = try Base.unwrap_unionall(T) catch; return false end
    u isa DataType || return false           # rejects Unions
    isabstracttype(u) && return false
    fieldcount(u) >= 0 || return false
    return true
end

"All CONCRETE subtypes of an abstract type, recursively."
function concretes(A::Type)
    out = Type[]
    A === Any && return out
    stack = Type[A]
    seen = Set{Any}()
    while !isempty(stack)
        T = pop!(stack)
        T in seen && continue
        push!(seen, T)
        subs = try InteractiveUtils.subtypes(T) catch; Type[] end
        for S in subs
            u = Base.unwrap_unionall(S)
            if u isa DataType && isabstracttype(u)
                push!(stack, S)
            elseif offerable(S)
                push!(out, S)
            end
        end
    end
    offerable(A) && push!(out, A)
    unique!(out)
    sort!(out; by = shortname)
    return out
end

"Concrete options a slot can hold (walks Union branches)."
function options_for(core)
    core === Any && return Type[]
    branches = core isa Union ? collect(Base.uniontypes(core)) : Any[core]
    out = Type[]
    for b in branches
        b === Nothing && continue
        _scalarish(b) && continue            # leaf scalars get widgets, not pickers
        u = try Base.unwrap_unionall(b) catch; continue end
        u isa DataType || continue
        if isabstracttype(u)
            append!(out, concretes(b))
        elseif offerable(b)
            push!(out, b)
        end
    end
    unique!(out)
    sort!(out; by = shortname)
    return out
end

_scalarish(b) = b === Nothing || b === Bool || b === Symbol ||
                (b isa DataType && (b <: Number || b <: AbstractString))
is_scalar(core) = core === Any ? false :
                  core isa Union ? all(_scalarish, Base.uniontypes(core)) : _scalarish(core)

"Slots reflection cannot describe: no concrete options, not a scalar."
const OPAQUE = (Any, NamedTuple, Pair, AbstractDict, Function)
_opaque1(b) = b === Any ||
              any(O -> b === O || Base.unwrap_unionall(b) === Base.unwrap_unionall(O), OPAQUE)
is_opaque(core) = core isa Union ? any(_opaque1, Base.uniontypes(core)) : _opaque1(core)

"Best-effort default instance of T, filling required kwargs recursively."
function default_for(T::Type; depth = 0)
    depth > 6 && return nothing
    try
        return T()
    catch e
        e isa UndefKeywordError || return nothing
        # required kwargs: fill them from their slot types, recursively
        kw = Dict{Symbol, Any}()
        names = fieldnames(T)
        types = slot_types(T)
        for _ in 1:length(names)
            try
                return T(; kw...)
            catch e2
                e2 isa UndefKeywordError || return nothing
                i = findfirst(==(e2.var), names)
                i === nothing && return nothing
                key = (wrapper(T), e2.var)
                if haskey(SLOT_DEFAULT, key)
                    kw[e2.var] = SLOT_DEFAULT[key]()
                    continue
                end
                c = classify(types[i])
                opts = options_for(c.core)
                cand = isempty(opts) ? nothing : first(opts)
                kw[e2.var] = cand === nothing ? nothing : default_for(cand; depth = depth + 1)
            end
        end
        return nothing
    end
end

"Kwargs of T that have NO default (must be supplied)."
function required_kwargs(T::Type)
    req = Symbol[]
    kw = Dict{Symbol, Any}()
    for _ in 1:fieldcount(T)
        try
            T(; kw...)
            break
        catch e
            e isa UndefKeywordError || break
            push!(req, e.var)
            kw[e.var] = nothing   # placeholder to advance to the next missing one
        end
    end
    return req
end

# ---------------------------------------------------------------------------
# 2. Spec IR — what the form edits. A tree of (type, kwargs), materialised on demand.
# ---------------------------------------------------------------------------

mutable struct Node
    T::Type
    kw::Dict{Symbol, Any}      # Symbol => Node | Vector{Node} | scalar | nothing
    libdefault::Dict{Symbol, String}   # what the LIBRARY defaults this slot to, if unset
end

function Node(T::Type)
    n = Node(T, Dict{Symbol, Any}(), Dict{Symbol, String}())
    inst = default_for(T)
    names, types = fieldnames(T), slot_types(T)
    req = required_kwargs(T)
    for (f, ty) in zip(names, types)
        c = classify(ty)
        key = (wrapper(T), f)
        if haskey(SLOT_DEFAULT, key)
            n.kw[f] = SLOT_DEFAULT[key]()
        elseif f in req
            opts = options_for(c.core)
            n.kw[f] = isempty(opts) ? nothing : Node(first(opts))
        elseif inst !== nothing
            v = getfield(inst, f)
            if v !== nothing && !(is_scalar(c.core) || v isa Number || v isa Bool || v isa AbstractString)
                # a composite the library defaults for us: leave it UNSET (so code
                # export stays minimal) but remember what the default actually is.
                n.libdefault[f] = shortname(typeof(v))
            end
            n.kw[f] = v === nothing ? nothing :
                      (is_scalar(c.core) || v isa Number || v isa Bool || v isa AbstractString) ? v :
                      nothing   # non-required composites start collapsed/nothing (= library default)
        else
            n.kw[f] = nothing
        end
    end
    return n
end

"Turn the spec back into a real PortfolioOptimisers object."
function materialise(n::Node)
    kw = Dict{Symbol, Any}()
    for (k, v) in n.kw
        v === nothing && continue          # omit => library default applies
        kw[k] = v isa Node ? materialise(v) :
                v isa Vector{Node} ? [materialise(x) for x in v] : v
    end
    return n.T(; kw...)
end

"Code export — the constructor call the user could paste into the REPL."
function to_code(n::Node; indent = 0)
    pad, pad2 = "    "^indent, "    "^(indent + 1)
    parts = String[]
    for (k, v) in sort(collect(n.kw); by = first)
        v === nothing && continue
        s = v isa Node ? to_code(v; indent = indent + 1) :
            v isa Vector{Node} ? "[" * join([to_code(x; indent = indent + 1) for x in v], ", ") * "]" :
            repr(v)
        push!(parts, "$pad2$k = $s")
    end
    nm = shortname(n.T)
    isempty(parts) && return "$nm()"
    return "$nm(;\n" * join(parts, ",\n") * "\n$pad)"
end

# ---------------------------------------------------------------------------
# 3. Recursive Bonito form
#
# The reactivity test: each composite slot owns an Observable{DOM} container.
# Changing its subtype picker rebuilds ONLY that subtree — a plain Julia
# function call, no framework impedance.
# ---------------------------------------------------------------------------

function scalar_widget(node::Node, f::Symbol, v)
    if v isa Bool
        cb = Checkbox(v)
        on(cb.value) do x; node.kw[f] = x; end
        return cb
    elseif v isa Number
        ni = NumberInput(Float64(v))
        on(ni.value) do x; node.kw[f] = x; end
        return ni
    else
        tf = TextField(v === nothing ? "" : string(v))
        on(tf.value) do x; node.kw[f] = isempty(x) ? nothing : x; end
        return tf
    end
end

"Render one slot (field f of node). Returns a DOM row."
labelled(f, w...) = DOM.div(DOM.label(string(f);
                                      style = "font-weight:600;width:9em;display:inline-block"),
                            w...; style = "margin:4px 0")

function slot_row(node::Node, f::Symbol, ty, on_dirty)
    c = classify(ty)
    cur = node.kw[f]

    # --- ESCAPE HATCH: a hand-written widget owns this slot
    key = (Base.unwrap_unionall(node.T).name.wrapper, f)
    if haskey(OVERRIDES, key)
        return labelled(f, OVERRIDES[key](node, f, on_dirty))
    end

    # --- reflection dead end, and nobody overrode it
    if is_opaque(c.core)
        return DOM.div(DOM.label(string(f); style = "width:9em;display:inline-block"),
                       DOM.em("opaque slot ($(ty)) — needs an override");
                       style = "margin:4px 0;color:#bf616a")
    end

    # --- scalar leaf
    if is_scalar(c.core) && !(cur isa Node)
        w = scalar_widget(node, f, cur === nothing ? (c.optional ? "" : 0.0) : cur)
        on(x -> on_dirty(), w.value)
        return DOM.div(DOM.label(string(f); style = "font-weight:600;width:9em;display:inline-block"),
                       w; style = "margin:4px 0")
    end

    opts = options_for(c.core)
    if isempty(opts)
        return DOM.div(DOM.label(string(f)), DOM.em(" (unsupported slot: $(ty))");
                       style = "margin:4px 0;color:#999")
    end

    # --- composite slot: subtype picker + re-rendered subtree
    labels = shortname.(opts)
    subtree = Observable{Any}(DOM.div())

    function rebuild!()
        v = node.kw[f]
        if v isa Node
            subtree[] = DOM.div(form_for(v, on_dirty);
                                style = "margin-left:1.2em;padding-left:.8em;border-left:2px solid #d8dee9")
        elseif v isa Vector{Node}
            rows = map(enumerate(v)) do (i, child)
                del = Button("remove")
                on(del) do _
                    deleteat!(node.kw[f], i); rebuild!(); on_dirty()
                end
                DOM.div(DOM.div(DOM.strong("[$i] $(shortname(child.T))"), del),
                        form_for(child, on_dirty);
                        style = "margin-left:1.2em;padding-left:.8em;border-left:2px solid #a3be8c;margin-top:6px")
            end
            subtree[] = DOM.div(rows...)
        else
            subtree[] = DOM.div()
        end
    end

    # picker. The first entry means "leave unset" — and it names the library's
    # own default so the user can SEE what they get by doing nothing.
    unset = haskey(node.libdefault, f) ? "— default: $(node.libdefault[f]) —" : "— unset —"
    sel = Dropdown([unset; labels];
                   index = cur isa Node ? findfirst(==(shortname(cur.T)), labels) + 1 : 1)
    on(sel.value) do choice
        if choice == unset
            node.kw[f] = nothing
        else
            T = opts[findfirst(==(choice), labels)]
            node.kw[f] = Node(T)
        end
        rebuild!(); on_dirty()
    end

    controls = Any[sel]
    if c.list
        addb = Button("+ add")
        on(addb) do _
            T = opts[1]
            if !(node.kw[f] isa Vector{Node})
                node.kw[f] = node.kw[f] isa Node ? Node[node.kw[f]] : Node[]
            end
            push!(node.kw[f], Node(T)); rebuild!(); on_dirty()
        end
        push!(controls, addb)
    end

    rebuild!()
    return DOM.div(DOM.div(DOM.label(string(f); style = "font-weight:600;width:9em;display:inline-block"),
                           controls...; style = "margin:6px 0"),
                   subtree)
end

"Recursive form for a node: required/basic slots visible, the rest in a <details>."
function form_for(node::Node, on_dirty)
    names, types = fieldnames(node.T), slot_types(node.T)
    req = Set(required_kwargs(node.T))

    basic, advanced = Any[], Any[]
    for (f, ty) in zip(names, types)
        row = slot_row(node, f, ty, on_dirty)
        c = classify(ty)
        # "basic" = required, or already set, or a non-optional slot
        if f in req || !c.optional
            push!(basic, row)
        else
            push!(advanced, row)
        end
    end

    children = Any[DOM.div(basic...)]
    if !isempty(advanced)
        push!(children,
              DOM.details(DOM.summary("advanced ($(length(advanced)) more)"),
                          DOM.div(advanced...);
                          style = "margin-top:6px;color:#4c566a"))
    end
    return DOM.div(children...)
end

# ---------------------------------------------------------------------------
# 3.5 Register the overrides. This is what a real app would grow: a small,
# explicit table of slots the type system cannot describe.
# ---------------------------------------------------------------------------

SLOT_DEFAULT[(PO.Solver, :solver)] = function ()
    ds = detected_solvers()
    isempty(ds) ? nothing : first(ds)[2]
end

OVERRIDES[(PO.Solver, :solver)] = function (node, f, on_dirty)
    ds = detected_solvers()
    if isempty(ds)
        return DOM.em("no JuMP solver loaded — `using Clarabel` and reload";
                      style = "color:#bf616a")
    end
    labels = first.(ds)
    cur = node.kw[f]
    idx = something(findfirst(p -> last(p) === cur, ds), 1)
    sel = Dropdown(labels; index = idx)
    node.kw[f] = ds[idx][2]
    on(sel.value) do choice
        node.kw[f] = ds[findfirst(==(choice), labels)][2]
        on_dirty()
    end
    return DOM.div(sel, DOM.small(" (detected from loaded packages)"; style = "color:#7b8794"))
end

# ---------------------------------------------------------------------------
# 4. The app
# ---------------------------------------------------------------------------

function spike_app()
    App() do session
        root = Node(PO.MeanRisk)

        code = Observable(to_code(root))
        built = Observable("(not built)")
        on_dirty() = (code[] = to_code(root))

        buildb = Button("Build the object")
        on(buildb) do _
            built[] = try
                obj = materialise(root)
                "OK  ::  " * string(typeof(obj))
            catch e
                "ERROR: " * sprint(showerror, e)
            end
        end

        formdiv = DOM.div(form_for(root, on_dirty);
                          style = "font-family:ui-monospace,monospace;font-size:13px")

        left = DOM.div(DOM.h2("MeanRisk — reflection-generated form"), formdiv;
                       style = "flex:1;min-width:0;overflow:auto;max-height:90vh")
        right = DOM.div(DOM.h2("Captured back out"), buildb,
                        DOM.pre(built; style = "background:#eceff4;padding:8px;white-space:pre-wrap"),
                        DOM.h3("Code export"),
                        DOM.pre(code; style = "background:#2e3440;color:#d8dee9;padding:10px;overflow:auto"),
                        style = "flex:1;min-width:0")

        return DOM.div(DOM.div(left, right; style = "display:flex;gap:24px;align-items:flex-start"),
                       style = "font-family:system-ui;padding:16px")
    end
end
