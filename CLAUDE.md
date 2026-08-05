# Working principles

Guidance for coding agents working in this repository.

- Before designing a solution, look at how established products and libraries solve
  the same problem. Adopt proven patterns and conventions instead of inventing an
  approach from scratch.
- Do not add backward-compatibility shims, fallbacks, or migration layers. Delete
  code paths that are no longer used. The CLI surface is the one exception; see
  "Project rules" below.
- Choose the simplest implementation that fully satisfies the current requirement.
  Do not build abstractions, configuration knobs, or indirection on speculation.
- Grow the system in layers. Start from a minimal version that works end to end,
  then add one feature at a time on top of something that already works. Never
  trade working code for unfinished complexity.
- Split components into modules with clear separation of concerns.
- Use a proven, maintained library when it lowers overall complexity or improves
  reliability. Do not reimplement common functionality without a clear reason.
- Check the dependencies already present before writing your own version or adding
  a package. Do not claim "this library cannot do that" without reading its
  documentation and types first.
- Make architectural decisions for the long term. Do not accept stopgaps that only
  get you through today and will have to be replaced later.

**Do not record here** what an agent can find by reading the files: directory
layout, installed packages, code style. It only dilutes the principles above.

# Project rules

- **This is a public MIT project** (github.com/renovys/codex-run). The second
  principle above (delete instead of keeping compatibility layers) **does not apply
  to the CLI interface.** Flag names, default values, and exit codes are a contract
  that users wrap in their own scripts. When something has to change, add a new flag
  and keep the old one for a while; removal is a separate change and belongs in the
  changelog. Internal implementation and helper functions follow the principle as
  written.
- Verify before finishing: `bash -n codex-run` (shell syntax), `--help` exits 0, an
  unknown option exits 2.
- Never put development absolute paths, internal IP addresses, or account names into
  code or examples. This repository is public.
