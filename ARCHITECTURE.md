# Architecture

This document describes the internal structure of the Raku MCP SDK, how data flows through the system, and the key design decisions behind the implementation.

For the visual module dependency diagram, see [`architecture/architecture.mmd`](architecture/architecture.mmd).

## Overview

The SDK implements the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/specification/2025-11-25) in Raku. It provides both a **server** (exposing tools, resources, and prompts to AI clients) and a **client** (connecting to MCP servers and invoking their capabilities).

Communication uses JSON-RPC 2.0 over pluggable transports: stdio (local processes), Streamable HTTP (remote), or legacy SSE (backwards compatibility).

## Module structure

```
MCP.rakumod                          # Entry point, re-exports all public API
├── MCP::Types                       # Protocol data types: Content, Tool, Resource,
│                                    #   Prompt, Capabilities, enums
├── MCP::JSONRPC                     # JSON-RPC 2.0 messages: Request, Response,
│                                    #   Notification, parse-message(), ErrorCode
├── MCP::Server                      # Server: init, dispatch, registration, lifecycle
│   ├── MCP::Server::Tool            # Tool builder DSL and RegisteredTool wrapper
│   ├── MCP::Server::Resource        # Resource/template builder and RegisteredResource
│   └── MCP::Server::Prompt          # Prompt builder and RegisteredPrompt
├── MCP::Client                      # Client: connect, typed request methods, tasks
├── MCP::Transport::Base             # Transport role (start, send, close, is-connected)
│   ├── MCP::Transport::Stdio        # Stdio with Content-Length framing (LSP-style)
│   ├── MCP::Transport::StreamableHTTP  # HTTP POST + SSE, session management
│   └── MCP::Transport::SSE          # Legacy SSE (spec 2024-11-05)
├── MCP::OAuth                       # OAuth 2.1 types, PKCE (RFC 7636), exceptions
│   ├── MCP::OAuth::Client           # Client-side: discovery, auth code, token exchange
│   └── MCP::OAuth::Server           # Server-side: token validation, scope checking
```

## Data flow

### Server side

1. **Transport** receives bytes, frames them, parses JSON into `MCP::JSONRPC::Message` objects.
2. **Server.serve()** starts the event loop: subscribes to the transport's `Supply` of messages.
3. **Dispatch**: `handle-message` routes by message type:
   - **Request** → `dispatch-request` multi-method selects handler by `method` field (e.g., `tools/call`, `resources/read`).
   - **Notification** → `handle-notification` (e.g., `notifications/cancelled`, `notifications/initialized`).
   - **Response** → `handle-response` resolves a pending outbound request's Promise.
4. **Handler execution**: For `tools/call`, the server looks up the registered tool handler, calls it with arguments, and normalizes the return value (string → `TextContent`, etc.) into a `CallToolResult`.
5. **Response** is serialized to JSON-RPC and sent back through the transport.

### Client side

1. **Client.connect()** starts the transport, subscribes to incoming messages, and sends `initialize` + `notifications/initialized`.
2. **Typed methods** (e.g., `list-tools`, `call-tool`, `read-resource`) build a `Request`, send it via `request()`, and return a `Promise` that resolves when the response arrives.
3. **Incoming requests from server** (e.g., `sampling/createMessage`, `roots/list`) are handled by registered callbacks.
4. **Progress and notifications** are emitted on dedicated `Supply` objects for reactive consumption.

## Concurrency model

The SDK uses Raku's concurrency primitives:

- **Promises** for request/response pairs. Each outbound request stores a `Vow` in a pending-requests hash, keyed by request ID. The response handler keeps the vow.
- **Supplies** for event streams: transport messages, server notifications, progress updates.
- **Locks** protect shared mutable state:
  - `$!request-lock` guards `%!pending-requests` in both Client and Server.
  - `$!flight-lock` guards `%!in-flight-requests` and `%!pending-requests` in Server.
  - `$!task-lock` guards `%!tasks` in Server.

All lock acquisitions use `Lock.protect` (non-reentrant, short critical sections). No nested locking — each lock protects a single hash to avoid deadlocks.

## Handler dispatch

Tool, resource, and prompt handlers support multiple calling conventions via multi-dispatch:

```raku
&handler(:params(%args))  # Named pair (preferred)
&handler(|%args)          # Slip
&handler(%args)           # Hash
&handler()                # No-args fallback
```

Return values are automatically normalized:
- `Str` → `TextContent`
- `Blob` → base64-encoded binary content
- `CallToolResult` / `Array[Content]` → pass through

## Transport architecture

All transports implement the `Transport` role from `MCP::Transport::Base`:

| Transport | Wire format | Use case |
|-----------|-------------|----------|
| **Stdio** | Content-Length framed JSON over stdin/stdout | Local subprocess servers |
| **StreamableHTTP** | HTTP POST (request) + SSE (streaming responses) | Remote servers, web deployment |
| **SSE (legacy)** | GET /sse + POST /message | Backwards compatibility (spec 2024-11-05) |

Transports are symmetric: the same role is used by both client and server. The `StreamableHTTP` module provides separate `StreamableHTTPServerTransport` and `StreamableHTTPClientTransport` classes since their HTTP roles differ.

## OAuth integration

OAuth 2.1 authorization is layered on top of the HTTP transports:

- **Client side** (`MCP::OAuth::Client`): metadata discovery, PKCE authorization code flow, token exchange, refresh, dynamic client registration.
- **Server side** (`MCP::OAuth::Server`): bearer token validation, scope checking, enterprise IdP policy controls.
- **Core** (`MCP::OAuth`): shared types, PKCE verifier/challenge generation, exceptions.

The PKCE verifier is cleared from memory immediately after token exchange (single-use per RFC 7636).

## Builder pattern

Tools, resources, and prompts use a fluent builder DSL:

```raku
my $tool = tool()
    .name('search')
    .description('Search documents')
    .string-param('query', :required)
    .integer-param('limit', description => 'Max results')
    .handler(-> :%params { do-search(%params<query>, %params<limit>) })
    .build;
```

Builders validate at `.build` time and produce immutable registered objects.

## Error handling

- JSON-RPC errors use standard error codes (`ErrorCode` enum) and are sent as `Response` with an `Error` object.
- Handler exceptions are caught and returned as internal errors with sanitized messages (no internal details leak to clients).
- Transport errors raise typed exceptions (`X::Transport::Connection`, `X::Transport::Send`).
- OAuth errors have dedicated exception types (`X::MCP::OAuth::Unauthorized`, etc.).

## Testing

Tests are layered bottom-up in `t/`, numbered by dependency order (types → JSONRPC → builders → transport → server → client → integration). Performance benchmarks and stress tests are in `bench/`.
