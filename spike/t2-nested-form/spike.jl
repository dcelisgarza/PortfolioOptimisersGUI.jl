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
    out = Pair{String,Any}[]
    for m in names(Main; imported = true)
        mod = try
            getfield(Main, m)
        catch
            ; continue
        end
        mod isa Module || continue
        isdefined(mod, :Optimizer) || continue
        O = getfield(mod, :Optimizer)
        try
            MOI.get(
                MOI.instantiate(O; with_cache_type = Float64, with_bridge_type = Float64),
                MOI.SolverName(),
            )
            push!(out, string(m) => O)
        catch
        end
    end
    return out
end

# slot overrides: (Type, field) => widget builder / default-value supplier
const OVERRIDES = Dict{Tuple{Any,Symbol},Function}()
const SLOT_DEFAULT = Dict{Tuple{Any,Symbol},Function}()

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
        if u isa DataType &&
           u.name.name in (:AbstractVector, :AbstractArray, :AbstractMatrix)
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
    u = try
        Base.unwrap_unionall(T)
    catch
        ; return string(T)
    end
    (u isa DataType) ? string(u.name.name) : string(T)
end

"Is T something we can actually offer as a constructible choice?"
function offerable(T)
    u = try
        Base.unwrap_unionall(T)
    catch
        ; return false
    end
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
        subs = try
            InteractiveUtils.subtypes(T)
        catch
            ; Type[]
        end
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
        u = try
            Base.unwrap_unionall(b)
        catch
            ; continue
        end
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

_scalarish(b) =
    b === Nothing ||
    b === Bool ||
    b === Symbol ||
    (b isa DataType && (b <: Number || b <: AbstractString))
is_scalar(core) =
    core === Any ? false :
    core isa Union ? all(_scalarish, Base.uniontypes(core)) : _scalarish(core)

"""
The scalar branch of a union, if it has one alongside composite branches.

`bgt :: Union{Nothing, Number, BudgetConstraintEstimator, TimeDependent}` is the
motivating case: the slot takes EITHER a plain number OR an estimator object. A
subtype picker alone strands the number; a number box alone hides the estimators.
"""
function scalar_branch_of(core)
    core isa Union || return nothing
    branches = Base.uniontypes(core)
    sc = filter(b -> b !== Nothing && _scalarish(b), branches)
    comp = filter(b -> b !== Nothing && !_scalarish(b), branches)
    (isempty(sc) || isempty(comp)) && return nothing   # not mixed => not hybrid
    return first(sc)
end

"Slots reflection cannot describe: no concrete options, not a scalar."
const OPAQUE = (Any, NamedTuple, Pair, AbstractDict, Function)
_opaque1(b) =
    b === Any ||
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
        kw = Dict{Symbol,Any}()
        names = fieldnames(T)
        types = slot_types(T)
        for _ = 1:length(names)
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
                kw[e2.var] =
                    cand === nothing ? nothing : default_for(cand; depth = depth + 1)
            end
        end
        return nothing
    end
end

"Kwargs of T that have NO default (must be supplied)."
function required_kwargs(T::Type)
    req = Symbol[]
    kw = Dict{Symbol,Any}()
    for _ = 1:fieldcount(T)
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

"""
Explicit `nothing`, as distinct from "unset".

For `bgt :: Union{Nothing, Number, …}` whose library default is `1.0`, these are
THREE different intents:

  * unset            -> omit the kwarg  -> library default applies (bgt = 1.0)
  * Explicit()       -> pass `nothing`  -> bgt = nothing (constraint disabled)
  * 0.85 / BudgetRange -> pass the value

`nothing` in the spec means "unset", so explicit nothing needs its own sentinel.
"""
struct Explicit end

mutable struct Node
    T::Type
    kw::Dict{Symbol,Any}      # Symbol => Node | Vector{Node} | scalar | Explicit | nothing
    libdefault::Dict{Symbol,String}   # what the LIBRARY defaults this slot to, if unset
end

function Node(T::Type)
    n = Node(T, Dict{Symbol,Any}(), Dict{Symbol,String}())
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
            scalarv = v isa Number || v isa Bool || v isa AbstractString
            if v === nothing
                n.kw[f] = nothing
            elseif is_scalar(c.core) && scalarv
                n.kw[f] = v                      # a plain scalar slot: hold the value
            else
                # Either a composite, or a HYBRID slot whose default happens to be a
                # number (bgt = 1.0). Leave it UNSET so the code export stays minimal,
                # but remember the default so the picker can show it.
                n.libdefault[f] = scalarv ? repr(v) : shortname(typeof(v))
                n.kw[f] = nothing
            end
        else
            n.kw[f] = nothing
        end
    end
    return n
end

"Turn the spec back into a real PortfolioOptimisers object."
function materialise(n::Node)
    kw = Dict{Symbol,Any}()
    for (k, v) in n.kw
        v === nothing && continue          # unset => omit => library default applies
        kw[k] =
            v isa Explicit ? nothing : # explicit nothing => pass it
            v isa Node ? materialise(v) :
            v isa Vector{Node} ? [materialise(x) for x in v] : v
    end
    return n.T(; kw...)
end

"Code export — the constructor call the user could paste into the REPL."
function to_code(n::Node; indent = 0)
    pad, pad2 = "  "^indent, "  "^(indent + 1)
    parts = String[]
    for (k, v) in sort(collect(n.kw); by = first)
        v === nothing && continue
        s =
            v isa Explicit ? "nothing" :
            v isa Node ? to_code(v; indent = indent + 1) :
            v isa Vector{Node} ?
            "[" * join([to_code(x; indent = indent + 1) for x in v], ", ") * "]" : repr(v)
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
        on(cb.value) do x
            ;
            node.kw[f] = x;
        end
        return cb
    elseif v isa Number
        ni = NumberInput(Float64(v))
        on(ni.value) do x
            ;
            node.kw[f] = x;
        end
        return ni
    else
        tf = TextField(v === nothing ? "" : string(v))
        on(tf.value) do x
            ;
            node.kw[f] = isempty(x) ? nothing : x;
        end
        return tf
    end
end

"Render one slot (field f of node). Returns a DOM row."
labelled(f, w...) = DOM.div(
    DOM.label(string(f); style = "font-weight:600;width:9em;display:inline-block"),
    w...;
    style = "margin:4px 0",
)

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
        return DOM.div(
            DOM.label(string(f); style = "width:9em;display:inline-block"),
            DOM.em("opaque slot ($(ty)) — needs an override");
            style = "margin:4px 0;color:#bf616a",
        )
    end

    # --- plain scalar leaf: mandatory AND purely scalar (sc::Number, brt::Bool).
    # Nothing to choose between, so no mode selector — just the box.
    if is_scalar(c.core) && !c.optional && !(cur isa Node)
        w = scalar_widget(node, f, cur === nothing ? 0.0 : cur)
        on(x -> on_dirty(), w.value)
        return DOM.div(
            DOM.label(string(f); style = "font-weight:600;width:9em;display:inline-block"),
            w;
            style = "margin:4px 0",
        )
    end

    opts = options_for(c.core)
    # a slot is scalar-capable if it IS a scalar, or has a scalar branch among composites
    has_scalar = is_scalar(c.core) || scalar_branch_of(c.core) !== nothing
    if isempty(opts) && !has_scalar
        return DOM.div(
            DOM.label(string(f)),
            DOM.em(" (unsupported slot: $(ty))");
            style = "margin:4px 0;color:#999",
        )
    end

    # --- HYBRID slot: the union mixes a scalar branch with composite branches,
    # e.g. bgt :: Union{Nothing, Number, BudgetConstraintEstimator, TimeDependent}.
    # A picker alone would strand the number (uneditable); a number box alone
    # would hide the estimators. The mode selector offers BOTH — plus `nothing`.
    labels = shortname.(opts)
    SCALAR = has_scalar ? "number…" : nothing
    subtree = Observable{Any}(DOM.div())

    function rebuild!()
        v = node.kw[f]
        if v isa Number || v isa AbstractString || v isa Bool
            # scalar mode: an editable box, live-bound back into the spec
            w = scalar_widget(node, f, v)
            on(x -> on_dirty(), w.value)
            subtree[] = DOM.div(w; style = "margin-left:1.2em")
        elseif v isa Node
            subtree[] = DOM.div(
                form_for(v, on_dirty);
                style = "margin-left:1.2em;padding-left:.8em;border-left:2px solid #d8dee9",
            )
        elseif v isa Vector{Node}
            rows = map(enumerate(v)) do (i, child)
                del = Button("remove")
                on(del) do _
                    deleteat!(node.kw[f], i)
                    rebuild!()
                    on_dirty()
                end
                # each entry owns its type: a list of risk measures is a list of
                # DIFFERENT risk measures, so every row needs its own picker.
                rowsel = Dropdown(
                    labels;
                    index = something(findfirst(==(shortname(child.T)), labels), 1),
                )
                on(rowsel.value) do choice
                    node.kw[f][i] = Node(opts[findfirst(==(choice), labels)])
                    rebuild!()
                    on_dirty()
                end
                DOM.div(
                    DOM.div(DOM.strong("[$i] "), rowsel, del),
                    form_for(child, on_dirty);
                    style = "margin-left:1.2em;padding-left:.8em;border-left:2px solid #a3be8c;margin-top:6px",
                )
            end
            subtree[] = DOM.div(rows...)
        else
            subtree[] = DOM.div()
        end
    end

    # Mode selector. First entry = "leave unset", naming the library's own default
    # so the user can SEE what doing nothing gets them. On a hybrid slot the scalar
    # branch appears as its own mode ("number…").
    has_default = haskey(node.libdefault, f)
    unset = has_default ? "— default: $(node.libdefault[f]) —" : "— unset —"

    # `nothing` is a LEGAL VALUE for an optional slot, and it differs from omitting
    # whenever the library's default is something else (bgt defaults to 1.0, so
    # `nothing` means "disable the budget constraint" — not the same as omitting).
    # Where the default IS nothing, the two coincide and one entry suffices.
    NOTHING = (c.optional && has_default) ? "nothing (disable)" : nothing

    choices = String[unset]
    NOTHING === nothing || push!(choices, NOTHING)
    SCALAR === nothing || push!(choices, SCALAR)
    append!(choices, labels)

    idx = if cur isa Node
        something(findfirst(==(shortname(cur.T)), choices), 1)
    elseif cur isa Explicit
        something(findfirst(==(NOTHING), choices), 1)
    elseif cur isa Number || cur isa AbstractString || cur isa Bool
        something(findfirst(==(SCALAR), choices), 1)
    else
        1
    end

    sel = Dropdown(choices; index = idx)

    # Which concrete type does "+ add" append? The one the picker names; and if the
    # picker is on a non-type entry (unset/nothing/number), the LIBRARY DEFAULT —
    # never merely the alphabetically-first subtype.
    function default_type()
        i = has_default ? findfirst(==(node.libdefault[f]), labels) : nothing
        return i === nothing ? opts[1] : opts[i]
    end
    function add_type()
        i = findfirst(==(sel.value[]), labels)
        return i === nothing ? default_type() : opts[i]
    end

    on(sel.value) do choice
        if choice == unset
            node.kw[f] = nothing
        elseif choice == NOTHING
            node.kw[f] = Explicit()
        elseif choice == SCALAR
            # entering scalar mode: seed with the library default if it was a
            # number, else zero. rebuild! then renders the editable box.
            prev = node.kw[f]
            node.kw[f] = prev isa Number ? prev : 0.0
        else
            T = opts[findfirst(==(choice), labels)]
            node.kw[f] = Node(T)
        end
        rebuild!();
        on_dirty()
    end

    controls = Any[sel]
    if c.list
        addb = Button("+ add")
        on(addb) do _
            v = node.kw[f]
            if v isa Vector{Node}
                # already a list: append one of whatever the picker currently names
                push!(v, Node(add_type()))
            elseif v isa Node
                # FIRST add on a slot holding a single value: promote scalar -> vector,
                # carrying the existing value in. Do NOT also append a new element.
                node.kw[f] = Node[v]
            else
                # unset / nothing: the list starts as the value it would have had
                node.kw[f] = Node[Node(default_type())]
            end
            rebuild!()
            on_dirty()
        end
        push!(controls, addb)
    end

    rebuild!()
    return DOM.div(
        DOM.div(
            DOM.label(string(f); style = "font-weight:600;width:9em;display:inline-block"),
            controls...;
            style = "margin:6px 0",
        ),
        subtree,
    )
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
        push!(
            children,
            DOM.details(
                DOM.summary("advanced ($(length(advanced)) more)"),
                DOM.div(advanced...);
                style = "margin-top:6px;color:#4c566a",
            ),
        )
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
        return DOM.em(
            "no JuMP solver loaded — `using Clarabel` and reload";
            style = "color:#bf616a",
        )
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
    return DOM.div(
        sel,
        DOM.small(" (detected from loaded packages)"; style = "color:#7b8794"),
    )
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

        formdiv = DOM.div(
            form_for(root, on_dirty);
            style = "font-family:ui-monospace,monospace;font-size:13px",
        )

        left = DOM.div(
            DOM.h2("MeanRisk — reflection-generated form"),
            formdiv;
            style = "flex:1;min-width:0;overflow:auto;max-height:90vh",
        )
        right = DOM.div(
            DOM.h2("Captured back out"),
            buildb,
            DOM.pre(built; style = "background:#eceff4;padding:8px;white-space:pre-wrap"),
            DOM.h3("Code export"),
            DOM.pre(
                code;
                style = "background:#2e3440;color:#d8dee9;padding:10px;overflow:auto",
            ),
            style = "flex:1;min-width:0",
        )

        return DOM.div(
            DOM.div(left, right; style = "display:flex;gap:24px;align-items:flex-start"),
            style = "font-family:system-ui;padding:16px",
        )
    end
end
