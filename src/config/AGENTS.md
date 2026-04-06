<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# config

## Purpose
Configuration system. Parses tmux-style configuration files, defines typed options with scoped inheritance (server u2192 session u2192 window u2192 pane), and provides the option definition table.

## Key Files

| File | Description |
|------|-------------|
| `parser.zig` | `Command` struct and config file parser u2014 reads tmux-style config lines into command name + args, handles comments and continuation |
| `options.zig` | `OptionScope` (server/session/window/pane), `OptionType` (string/number/boolean/colour/style), `OptionValue` union, `OptionDef`, `OptionStore` with scoped inheritance |
| `options_table.zig` | Static table of all option definitions with names, scopes, types, and default values |

## For AI Agents

### Working In This Directory
- Config file format matches tmux: one command per line, `#` comments, `\` line continuation
- `parser.zig` produces `Command` structs that are executed through `cmd/cmd.zig`'s `Registry.executeParsed()`
- Options inherit: pane overrides window overrides session overrides server defaults
- Adding a new option: add to `options_table.zig`, use in the relevant scope's code
- `OptionValue` is a tagged union matching `OptionType`

### Testing Requirements
- Parser tests: comments, empty lines, continuation, quoted strings, multi-word args
- Option store tests: set/get with inheritance, scope override, unset fallback

## Dependencies

### Internal
- `../core/colour.zig` u2014 `Colour` type used in option values

<!-- MANUAL: -->
