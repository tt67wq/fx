# fx

fx is a terminal coding agent. It reads your workspace, plans, edits files, runs commands, and verifies its own work, with permission checks on every sensitive action.

This is a fork of [vercel-labs/fx](https://github.com/vercel-labs/fx). It adds a JavaScript sandbox for multi-step tool work and an optional shell output-compression hook, and drops the embedding surfaces the upstream carries for external hosts. fx here runs as a terminal application only.

## Codemode (experimental)

One tool that runs JavaScript in a QuickJS sandbox, so several steps land in a single model call instead of one tool call per turn:

* `await tools.read_file({...})` calls a whitelisted built-in tool with a JSON object argument: `glob_files`, `grep_files`, `read_file`, and `run_command`. The older `await tools.call("tool_name", "{json args}")` form still works. Everything else is invisible to the sandbox.
* `tools.list()` returns each whitelisted tool's name, description, and full parameter schema, injected from the built-in tool specs at startup, so scripts can introspect argument shapes before calling.
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
