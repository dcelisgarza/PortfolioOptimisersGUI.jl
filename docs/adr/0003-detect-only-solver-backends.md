# Solver backends are detected, never bundled

PortfolioOptimisersGUI has no solver-package dependencies. The Solver editor (backend, settings dict, `check_sol`, fallback chains) offers exactly the JuMP backends the user has loaded in their session, discovered by Backend Detection. A fresh install therefore shows an empty backend list with an actionable empty-state ("no solver backends loaded — run `using Clarabel` and refresh") rather than working out of the box.

This was chosen over bundling Clarabel + HiGHS (or bundling + detecting) to keep the GUI's dependency surface clean and impose no solver choices; the target audience is Julia-literate and already installs solvers to use the library at all. The quick-start is `using PortfolioOptimisersGUI, Clarabel, HiGHS; serve()`.
