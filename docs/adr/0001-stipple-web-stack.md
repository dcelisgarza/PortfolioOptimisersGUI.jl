# Stipple owns the app; Plotly and Makie both render inside it

The workbench is a locally-served web app running in the user's own Julia session (so their environment, data, and solvers are available). We chose Genie/Stipple as the app framework: StippleUI supplies the large widget set the estimator-composition forms need, StipplePlotly renders the library's existing ~35 `plot_*` Plots.jl recipes via the `plotlyjs()` backend with no rewriting, and StippleMakie embeds WGLMakie (riding on Bonito) for the planned Makie plotting extension.

## Considered Options

- **Bonito-first**: WGLMakie first-class, but most form widgets would be hand-rolled — and a workbench is mostly forms.
- **Dash.jl**: Plotly-native but second-class Julia support; callback model scales poorly to deeply nested dynamic forms.
- **Oxygen.jl + custom frontend**: maximum control, slowest path to a usable workbench.
- **Native desktop (GLMakie/QML)** and **separate TS/React frontend**: rejected for tooling weakness and double-codebase maintenance respectively.

## Consequences

- StippleMakie is the least battle-tested piece; milestone M1 is a spike proving Plotly + WGLMakie + a nested reactive form on one page. Fallback if it fails: render Makie figures as static SVG/PNG.
