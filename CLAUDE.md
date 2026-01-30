# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Raku implementation of the Model Context Protocol (MCP) SDK. MCP is an open standard that allows AI models to interact with external data and tools. This SDK enables building MCP servers and clients in Raku to integrate with LLM applications like Claude Desktop.

## Build Commands

```bash
make all              # Full pipeline: dependencies + build + test
make build            # Validate metadata and precompile modules
make test             # Run complete test suite
make test-verbose     # Run tests with verbose output
make test-file FILE=t/03-builders.rakutest  # Run specific test
make lint             # Run syntax and META6.json validation
make check            # Run lint and tests together
make coverage         # Generate test coverage report
make benchmark        # Run performance benchmarks
make run-example EXAMPLE=simple-server      # Run example server
make repl             # Start REPL with project loaded
make benchmark        # Run performance benchmarks
make stress           # Run stress tests
```

Environment: `V=1` for verbose output, `NO_COLOR=1` to disable colors.

## Architecture

```
MCP.rakumod (main entry point, re-exports all public API)
├── MCP::Types        # Protocol types: Content, Tool, Resource, Prompt, Capabilities
├── MCP::JSONRPC      # JSON-RPC 2.0 message types and parsing
├── MCP::Server       # Server initialization, request dispatch, lifecycle
├── MCP::Client       # Client initialization, sampling support
├── MCP::Server::Tool/Resource/Prompt  # Fluent builders for primitives
├── MCP::Transport::Base/Stdio/StreamableHTTP/SSE  # Transport layer
└── MCP::OAuth / OAuth::Client / OAuth::Server  # OAuth 2.1 authorization
```

**Protocol**: JSON-RPC 2.0 over Stdio, Streamable HTTP, or Legacy SSE. Targets MCP spec 2025-11-25.

## Key Patterns

**Builder Pattern** for tools, resources, and prompts:
```raku
my $tool = tool()
    .name('add')
    .description('Add two numbers')
    .input-schema(%schema)
    .handler(-> :%params { $params<a> + $params<b> })
    .build;
```

**Multi-dispatch handlers** - SDK calls handlers with multiple signature styles:
```raku
&handler(:params(%args))  # Named pair
&handler(|%args)          # Slip
&handler(%args)           # Hash
&handler()                # No args fallback
```

**Result normalization** - Handlers can return various types; SDK auto-wraps:
- `Str` → `TextContent`
- `Blob` → Binary content
- Direct MCP types pass through unchanged

**Async model** - Uses Raku's Promises and Supplies for concurrent messaging.

## Test Structure

Tests in `t/` numbered by layer:
- `01-types.rakutest` - Type constructors, serialization
- `02-jsonrpc.rakutest` - JSON-RPC message handling
- `03-builders.rakutest` - Tool/Resource/Prompt builders
- `04-transport.rakutest` - Transport interface
- `05-server.rakutest` - Server initialization, dispatch
- `06-client.rakutest` - Client initialization
- `07-mcp.rakutest` - Top-level exports
- `08-sampling.rakutest` - Sampling/createMessage
- `09-http-transport.rakutest` - HTTP transport
- `10-oauth.rakutest` - OAuth 2.1 types, PKCE, server/client handlers
- `11-tasks.rakutest` - Tasks framework (async tools, polling, cancellation)
- `12-extensions.rakutest` - Extensions framework (registration, dispatch, capabilities)
- `13-resource-templates.rakutest` - Resource templates (URI templates, matching, builder)
- `14-sse-transport.rakutest` - Legacy SSE transport

## Dependencies

Runtime: `JSON::Fast`, `Cro::HTTP`, `MIME::Base64`
Optional (loaded at runtime): `Digest::SHA256::Native` (for OAuth PKCE)
Dev: `Test`, `Test::META`, `App::Prove6`, `Test::Coverage`

## Implementation Status

See `GAP_ANALYSIS.md` for detailed feature comparison with MCP spec. No significant gaps remain.
