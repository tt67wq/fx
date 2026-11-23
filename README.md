# fx

fx is a terminal coding agent. It reads your workspace, plans, edits files, runs commands, and verifies its own work, with permission checks on every sensitive action.

This is a fork of [vercel-labs/fx](https://github.com/vercel-labs/fx). It adds a JavaScript sandbox for multi-step tool work and an optional shell output-compression hook, and drops the embedding surfaces the upstream carries for external hosts. fx here runs as a terminal application only.

## Codemode (experimental)

One tool that runs JavaScript in a QuickJS sandbox, so several steps land in a single model call instead of one tool call per turn:

* `await tools.read_file({...})` calls a built-in tool with a JSON object argument. With the derived surface off (the default), the sandbox sees four tools: `glob_files`, `grep_files`, `read_file`, and `run_command`; everything else is invisible. With `experimental.codemode_derived_surface` on (profile-only, default off), it also sees `write_file`, `edit_file`, `web_fetch`, `ask_user_question`, and `vision`, plus the `run_script` primitive below; `run_command` maps to the registered `shell` tool. The older `await tools.call("tool_name", "{json args}")` form still works. Every nested call still passes the same permission checks as a direct call.
* `run_script` runs shell or python through an fx-picked interpreter: python code lands in an fx temp file run via the fixed `python3 <path>` argv shape, shell code runs as the command line. An optional workspace `file` is exposed to the script as `CTX_FILE`. Model text never becomes an interpreter option token; unknown fields are rejected before admission.
* `tools.list()` returns each tool's name, description, and full parameter schema, injected from the built-in tool specs at startup. On the derived surface the listing is budgeted by `context_limits.codemode_catalog_bytes` (16KiB default): the four core tools always stay listed, then mutation tools, then the rest, and a triggered budget drops later entries with an omitted list and a hint. `searchTools(query)` searches the full surface by name, parameter, and description (optional `{limit: N}`, default 8); `describeTool(name)` returns one full schema and suggests close names when the name is unknown.
* Script output has a 1MiB capture cap; past it, text and console keep the head and tail with an omitted byte count, and the full captured output is stored and readable with `read_tool_result`. A failure body carries the same capture markers. `// @options: {"timeout_ms": N, "max_output_tokens": N}` as the first non-empty line declares a bigger budget (timeout 1000..300000 ms; output cap of 4 bytes per token, clamped to the 1MiB capture cap).
* A script runs on a default 30 second wall-clock budget; a nested `run_command` gets min(requested, remaining script budget), counted from its own start. On timeout the failure names the elapsed wall, the effective budget and its source (default or @options), and the @options fix.
* Finish with `text(your short summary)`. Top-level `return` is not valid script syntax. A script that only wraps one tool call is slower than calling the tool directly.

Codemode is off by default and is enabled per profile in `~/.fx/settings.json`:

```json
{
  "experimental": {
    "codemode": true
  }
}
```

## rtk (experimental)

When enabled, shell commands are rewritten through [rtk](https://www.rtk-ai.app/), a CLI proxy that filters and summarizes command output before it reaches the model. Treat compressed output as the command result; run a command with an explicit `rtk` prefix, such as `rtk git status`, when you need the full uncompressed output. Unknown commands, failures, timeouts, and empty rewrites fall back to the original command.

Like codemode, rtk is off by default:

```json
{
  "experimental": {
    "rtk": true
  }
}
```

## Differences from upstream

Removed in this fork:

* The ACP embedding layer (`src/acp/`) and all JS host surfaces (`src/core/hosts/`): no editor or application embedding, no `fx acp` runner.
* WebAssembly and Node N-API entry points (`wasm_core_main`, `wasm_term_main`, `napi_*`).
* ChatGPT and Grok subscription sign-in. API-key providers still work.
* Checkpoint and journal session recovery.

Everything else carries over: the agent loop, sessions, permission modes, MCP support, skills, the workspace indexer, subagents, and compaction.

## Build

You need [Zig 0.17.0](https://ziglang.org/download/) or newer:

```bash
git clone https://github.com/tt67wq/fx.git
cd fx
zig build
./zig-out/bin/fx
```

Always run the freshly built `./zig-out/bin/fx` from this checkout. A bare `fx` may be an older copy on your `PATH`.

`zig build test` runs the unit tests, which sit next to the code they cover. The end-to-end tests in [`tests/e2e/`](tests/e2e) drive the built binary through tmux and need [Bun](https://bun.sh); on macOS, set `FX_SOUND=0` when running them.

## Usage

Run `fx` for the interactive terminal, or `fx ask "topic"` for a one-shot answer that prints its result to stdout and exits nonzero on failure. `fx status --json` reports configuration and runtime information, `fx doctor --json` runs local health checks, and `fx --help` lists every command and flag.

`fx ask` uses the saved permission mode, which is `auto` unless changed. Pass `--full-access` only when you intend to turn off fx's permission checks.

## Source layout

```text
fx/
├── src/
│   ├── main.zig     entry point that wires everything together
│   ├── core/        agent loop, sessions, config, permissions, MCP, skills
│   ├── builtins/    built-in tool specs, providers, system prompt, hooks
│   ├── tools/       built-in tools, including the codemode sandbox
│   ├── ui/          terminal rendering and input
│   ├── gateway/     model provider transport
│   └── mcp/         MCP engine
├── tests/           end-to-end tests, evals, fuzz targets, and TLA+ models
└── benchmarks/      startup, memory, and latency benchmarks
```

## Contributing

Read [AGENTS.md](AGENTS.md) for repository rules and [CONTRIBUTING.md](CONTRIBUTING.md) for verification, CI, and pull request expectations before opening a pull request.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Based on [vercel-labs/fx](https://github.com/vercel-labs/fx) by Vercel. Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
