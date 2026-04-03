# Repository Guidelines

## Project Structure & Module Organization
`agentmux` is a Zig terminal multiplexer. The root contains `build.zig`, `build.zig.zon`, and `README.md`. Core code lives under `src/`: `cmd/` for tmux-style commands, `screen/` for grid/redraw, `terminal/` for parsing/output, `layout/` for pane trees, `copy/` for copy/paste state, `mode/` for chooser UIs, and `render/` for Metal/Vulkan backends. Tests live as inline Zig `test` blocks beside the code they cover.

## Build, Test, and Development Commands
- `zig build` — compile and install `agentmux` into `zig-out/bin/`.
- `zig build run -- <args>` — build and run locally with arguments.
- `./zig-out/bin/agentmux <args>` — run the previously built binary directly.
- `zig build test` — run the full unit test suite rooted at `src/main.zig`.
- `zig fmt src/**/*.zig` — format changed Zig files before review.

## Coding Style & Naming Conventions
Use Zig defaults: 4-space indentation, no trailing whitespace, and `zig fmt` as the source of truth. Prefer short names that match existing patterns such as `cmdFooBar`, `PaneState`, `handleX`, and `renderY`. Keep tmux-compatible behavior on the routed command path instead of adding parallel local-only flows. Extend existing modules before creating new top-level directories.

## Architecture Overview
The binary follows a client/server model. `main.zig` decides whether to launch the server or act as a one-shot client, `protocol.zig` frames messages, `server.zig` owns sessions/windows/panes, and `cmd/cmd.zig` is the routed command registry. Interactive features such as copy mode, chooser trees, and prompt state should stay on that path.

## Testing Guidelines
Add or update inline `test` blocks for each behavior change, especially in `src/cmd/`, `src/mode/`, `src/window.zig`, and protocol code. Prefer focused tests that prove state transitions or rendered output. Run `zig build test` before committing; for command-path changes, also run a smoke flow such as `zig build run -- new-session -s demo` followed by a relevant follow-up command.

## Commit & Pull Request Guidelines
Recent history uses concise imperative subjects, e.g. `Enable...`, `Tighten...`, `Make...`. Keep commit subjects short and action-oriented. Group related changes into coherent commits, and mention verification in the commit body when behavior is non-trivial. Pull requests should summarize user-visible changes, list verification commands, and include terminal output or screenshots when chooser/copy/prompt UX changes.

## Security & Configuration Tips
Use repo-supported socket settings (`AGENTMUX_SOCKET_NAME`, `AGENTMUX_SOCKET_PATH`) for isolated local testing. Avoid hard-coding machine-specific paths or shell assumptions beyond `/bin/sh`, which is the current default shell path in command/session flows.

# Commit Messages
- Use the repository's existing `scope: imperative summary` style for commit subjects.
- When a task spans multiple logical slices, commit and push each validated slice incrementally instead of batching unrelated work into one final commit.
- Keep the scope lowercase and map it to the primary area changed, for example `docs`, `web`, `worker`, `orchestrator`, `deploy`, `ci`, `hack`, or `github/workflows`.
- Write the summary as a short imperative phrase, not a sentence with terminal punctuation.
- When writing or editing a commit message, do not rely on shell-escaped newlines with repeated `-m` flags. Write the full message to a temporary file and use `git commit --gpg-sign -F <file>` so paragraph breaks, backticks, and trailers are preserved exactly.
    - Example subjects from the current history: `docs: add local codex skills`, `rendor: align tooling workflow with validated Vite+ behavior`, `orchestrator: keep execution-review approvals on the plan track`.
