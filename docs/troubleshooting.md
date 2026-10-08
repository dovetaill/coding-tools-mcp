# Troubleshooting

## Protocol Version Errors

Send `MCP-Protocol-Version` on every HTTP request. A `2026-07-28` client sends
`MCP-Protocol-Version: 2026-07-28`, repeating the version in its
`params._meta`; a header that disagrees with the body, or is missing from such
a request, returns `400` with `-32020`. A handshake client sends the version it
negotiated at initialization, normally `MCP-Protocol-Version: 2025-11-25`, or
`2025-06-18` for compatibility. A header naming a version this server does not
know returns `400` with `-32600` and lists the ones it does; a request with no
header at all is read as `2025-11-25`.

Asking to handshake with a version this server does not speak is no longer an
error: `initialize` answers with the newest version it does speak. If a client
seems to be on an older protocol than expected, read the `protocolVersion` in
the `InitializeResult` rather than assuming the one that was requested.

## SANDBOX_UNAVAILABLE

If `exec_command` returns a warning about Linux Landlock being unavailable, the command still ran under server-side policy checks, but without kernel filesystem confinement. This is expected on Windows, macOS, and Linux hosts without Landlock support. Put the server inside an external sandbox before running untrusted commands or untrusted project code.

If an older client or server reports `SANDBOX_UNAVAILABLE` as an error, upgrade to the current behavior or run on a Landlock-capable Linux kernel.

## Command Hangs Or Times Out

If the result returns `status: "running"`, poll with `write_stdin` using empty `chars`, or terminate with `kill_command`. Command deadlines still apply when the client stops polling.

## Permission Elicitation Is Unsupported

If `request_permissions` returns `ELICITATION_UNSUPPORTED`, the MCP client cannot show approval prompts. For dependency downloads and local development, prefer `--permission-mode trusted`; it allows network-looking commands, shell expansion, and inline scripts while keeping secret filtering and destructive-command checks. For isolated containers or VMs, use `--permission-mode dangerous` to disable `exec_command` permission gates.

## Missing Toolchain Environment

`exec_command` defaults to a core shell environment. If tools such as MSVC, CUDA, oneAPI, or Nix depend on variables from the parent terminal, start the server with:

```bash
CODING_TOOLS_MCP_SHELL_ENV_INHERIT=all coding-tools-mcp --workspace /path/to/repo
```

This still filters secret-looking and loader/startup variables unless `--permission-mode dangerous` is also enabled.

## Exec Diagnostics

`exec_command` may include `diagnostics` with codes such as `DEV_NULL_DENIED`, `DNS_RESOLUTION_FAILED`, `NETWORK_PERMISSION_REQUIRED`, `TMPDIR_NOT_WRITABLE`, `HOME_NOT_WRITABLE`, `COMMAND_TIMED_OUT`, and `OUTPUT_TRUNCATED`. See [troubleshooting-exec.md](troubleshooting-exec.md).

## Trace Tool Calls

For local debugging:

```bash
CODING_TOOLS_MCP_TRACE=1 coding-tools-mcp --workspace /path/to/repo
```

Trace events are JSON lines on stderr. Arguments are redacted for secret-looking keys and values; stdout remains reserved for stdio JSON-RPC frames.

### Durable local tool events

To retain content-free tool diagnostics across server restarts, opt in with a
dedicated absolute directory outside your repository:

```bash
CODING_TOOLS_MCP_EVENT_LOG_DIR=/private/state/coding-tools-events \
  coding-tools-mcp --workspace /path/to/repo
```

The same setting works with `--stdio`. It is read when a Runtime is created;
unset or empty means disabled, with no journal files created. It is independent
of both `CODING_TOOLS_MCP_TRACE` and anonymous telemetry. Existing TRACE behavior
is unchanged; the new journal never stores its argument previews.

The directory contains `events.jsonl` and up to three rotated files
(`events.jsonl.1` is newest), each at most 1 MiB, plus `journal.lock`. Restart
appends to this same bounded ring instead of accumulating per-process files.
Read rotated files oldest first, followed by `events.jsonl`. Rotation discards
old records and may split a call's start/end pair; this is not a lossless audit.
Individual records are limited to 4 KiB. Writes reach the OS before returning,
but are not fsynced: power loss can lose records. An interrupted final line is
separated from the next record on restart; readers must skip malformed lines.

Use a local filesystem and a directory with trusted parent directories. On
POSIX, the new journal directory uses 0700 and new files use 0600; existing storage must
already be owned by the process user with no group/other permissions. Leaf
directory symlinks, nonregular files, and hard-linked files are rejected.
Windows deployments must protect the directory with account-specific ACLs;
POSIX mode bits do not establish those ACLs. The OS lock permits only one
Runtime to write a directory. Give concurrent server instances separate
directories. Do not delete or replace `journal.lock` while a server is running.

Each call reaching `Runtime.call_tool` produces `tool_call_started` and, if it
returns or raises an ordinary exception, `tool_call_finished`. Both carry a
schema version, UTC timestamp, random runtime ID, unique call ID, and a known
tool name (`unknown` for unrecognized names). Completion adds monotonic elapsed
milliseconds and `success`, `tool_error`, `rpc_error`, or `internal_error`.
Known error categories/protocol codes, operation outcomes, truncation/replay
flags and runtime-owned command IDs are included when available. Arbitrary
error codes, messages, status strings, arguments, paths, output text, client
metadata, authentication material, and chat messages are excluded.

Coverage includes unknown tools and tool-argument validation, shared by HTTP,
stdio and direct Runtime calls. It does **not** include earlier authentication,
HTTP framing, JSON-RPC envelope/method rejection, or client/network failures.
A finished call does not prove the client received the reply. For asynchronous
exec, `operation_outcome: running` means the process is still running;
`success` describes the tool call, not the command's exit status. Use later
poll records and their operation outcomes. An unmatched start means unknown,
not automatic failure or permission to replay a mutation. Call IDs pair events;
they do not identify a ChatGPT conversation or an authenticated user.

Storage/locking failures disable recording for that Runtime and emit one
content-free stderr warning. Tools continue with their normal results; logging
never retries them. Repair the directory/disk/ownership issue and restart at a
safe point to re-enable recording. This diagnostic log is not tamper-resistant
and does not grant MCP file tools access outside their workspace.

For task handoff, save a short workspace file with the goal, branch/HEAD and
dirty state, verified results and persistent output paths, unknown operations,
and the next action. A new client should verify those facts before continuing.
Import client-provided chat exports separately as historical data: MCP does
not automatically receive all human/assistant messages. Neither a journal nor
a handoff file restores a process handle after server restart or changes a
provider's usage limits.

## SWE-bench

If Docker or the `swebench` package is missing, the default scaffold should report `PREFLIGHT_ONLY`; an explicit evaluation attempt should report `BLOCKED`, not pass. See [swe-bench.md](swe-bench.md).
