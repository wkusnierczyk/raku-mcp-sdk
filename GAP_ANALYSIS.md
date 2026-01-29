# MCP Specification Gap Analysis

## Raku MCP SDK vs MCP Specification 2025-11-25

This document compares the current implementation of the Raku MCP SDK against the [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25) and identifies missing features.

---

## Summary

| Category | Status | Notes |
|----------|--------|-------|
| **Base Protocol** | ✅ Complete | JSON-RPC 2.0, lifecycle, version negotiation |
| **Transports** | ✅ Complete | Stdio, Streamable HTTP, Legacy SSE |
| **Server Features** | ✅ Complete | Tools/Resources/Prompts + pagination, templates, subscriptions, annotations |
| **Client Features** | ✅ Complete | Sampling with tools, completion, roots, elicitation |
| **Utilities** | ✅ Complete | Logging, progress, cancellation, ping |
| **Authorization** | ✅ Complete | OAuth 2.1 with PKCE, dynamic registration, M2M, enterprise IdP |
| **New 2025-11-25 Features** | ✅ Complete | Elicitation, Tasks, Sampling-with-tools, Extensions |

---

## Table of Contents

- [Detailed Analysis](#detailed-analysis)
  - [Base Protocol](#base-protocol)
  - [Transports](#transports)
  - [Server Features](#server-features)
  - [Client Features](#client-features)
  - [Utilities](#utilities)
  - [Authorization (2025-03-26+)](#authorization-2025-03-26)
  - [New Features in 2025-11-25](#new-features-in-2025-11-25)
  - [Comparison with Python SDK](#comparison-with-python-sdk)
- [Priority Recommendations](#priority-recommendations)
  - [High Priority (Core Functionality)](#high-priority-core-functionality)
  - [Medium Priority (Enhanced Functionality)](#medium-priority-enhanced-functionality)
  - [Lower Priority (Advanced Features)](#lower-priority-advanced-features)
- [Protocol Version](#protocol-version)
- [Test Coverage Gaps](#test-coverage-gaps)
- [Conclusion](#conclusion)

## Detailed Analysis

### Base Protocol

#### ✅ Implemented
- JSON-RPC 2.0 message format (`MCP::JSONRPC`)
- Request/Response/Notification handling
- ID generation
- Error codes (ParseError, InvalidRequest, MethodNotFound, InvalidParams, InternalError)

#### Notes
- **Lifecycle**: Initialize/initialized handshake with version negotiation (server falls back to latest supported version if client's isn't recognized)
- **JSON-RPC batching**: Not supported (removed from spec in 2025-06-18)

---

### Transports

#### ✅ Stdio Transport (`MCP::Transport::Stdio`)
- Complete implementation
- Proper newline-delimited JSON messages

#### ✅ Streamable HTTP Transport (`MCP::Transport::StreamableHTTP`)
- Full server-side implementation (POST/GET/DELETE)
- Full client-side implementation
- Session management (`MCP-Session-Id` header)
- `Last-Event-ID` replay for SSE resumption
- CORS handling via `allowed-origins`
- Protocol version validation (`MCP-Protocol-Version` header)
- Proper error responses per spec (400, 403, 404, 405, 406, 415)

#### ✅ Legacy SSE Transport (`MCP::Transport::SSE`)
- Server-side: GET `/sse` for SSE stream, POST `/message` for client messages
- Client-side: connects to SSE endpoint, receives POST URL via `endpoint` event
- Origin validation
- Single-client model (one SSE connection at a time)

---

### Server Features

#### ✅ Tools (`MCP::Server::Tool`)
- Tool registration with name, description, schema
- Tool calling with arguments
- Builder pattern API
- Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`)
- `outputSchema` for structured tool outputs (2025-06-18)
- Tool name validation (SEP-986: `^[a-zA-Z0-9_-]{1,64}$`)
- `tools/list` pagination support

#### ✅ Resources (`MCP::Server::Resource`)
- Resource registration with URI, name, description, mimeType
- Resource reading
- Resource templates (URI templates with placeholders)
- Resource subscriptions (`resources/subscribe`, `resources/unsubscribe`)
- `notifications/resources/list_changed` and `notifications/resources/updated`
- `resources/list` pagination support
- Resource annotations (`audience`, `priority`)

#### ✅ Prompts (`MCP::Server::Prompt`)
- Prompt registration with arguments
- Prompt retrieval with argument substitution
- `prompts/list` pagination support
- `notifications/prompts/list_changed`

---

### Client Features

#### ✅ Sampling (`MCP::Client` sampling-handler) - **Implemented**
- `sampling/createMessage` handling with full parameter support
- Tool definitions in sampling requests (SEP-1577)
- `toolChoice` parameter support
- `includeContext` parameter with capability validation
- `stopReason` in responses
- Tool validation in sampling messages
- Server-side `create-message()` convenience method with tools/toolChoice/includeContext

#### ✅ Roots - **Implemented**
- `Root` type with `uri` and optional `name`
- Client-side:
  - `roots` configuration option
  - Handles `roots/list` requests from server
  - `set-roots()` method sends `notifications/roots/list_changed`
  - Advertises `roots` capability (with `listChanged`)
- Server-side:
  - `list-roots()` method to request roots from client

#### ✅ Elicitation (2025-06-18 feature)
- `ElicitationCapability` with form/url mode support
- `ElicitationAction` enum (accept/decline/cancel)
- `ElicitationResponse` type with content
- Server-side:
  - `elicit(message, schema)` for form mode requests
  - `elicit-url(message, url, elicitation-id)` for URL mode
  - `notify-elicitation-complete(elicitation-id)` for completion
- Client-side:
  - `elicitation-handler` callback for handling requests
  - Capability negotiation with form/url modes
  - `URLElicitationRequired` error code (-32042)

---

### Utilities

#### ✅ Progress Tracking - **Implemented**
- `progress()` method on Server with automatic `_meta.progressToken` extraction
- `proto dispatch-request` sets `$*MCP-PROGRESS-TOKEN` dynamic variable for all handlers
- Explicit token parameter overrides implicit `_meta` token
- No notification emitted when no token is available
- Client `progress()` Supply emits typed `Progress` objects from `notifications/progress`
- Types defined (`Progress`)

#### ✅ Logging - **Implemented**
- `log()` method on Server with level filtering
- `LogLevel` enum, `LogEntry` type, `parse-log-level`, `log-level-at-or-above` helpers
- `logging/setLevel` request handler on Server stores and applies log level
- Log notifications below configured level are suppressed
- Client `set-log-level()` method sends `logging/setLevel` request

#### ✅ Cancellation - **Implemented**
- Server tracks in-flight requests and handles `notifications/cancelled`
- Client sends cancellation notification on timeout
- Both sides have `cancel-request` method for explicit cancellation
- `is-cancelled` method for handlers to check cancellation status

#### ✅ Ping
- Server responds to `ping` requests
- Client has `ping()` helper

#### ✅ Completion (autocomplete)
- `completion/complete` request handling
- Server: `add-prompt-completer()`, `add-resource-completer()` for registering completers
- Client: `complete-prompt()`, `complete-resource()` convenience methods
- `CompletionResult` type with values, total, hasMore
- Auto-truncation to 100 values per spec
- `completions` capability advertised when completers registered

---

### Authorization (2025-03-26+)

#### ✅ Implemented
OAuth 2.1 authorization framework:

- ✅ OAuth 2.1 with PKCE (S256)
- ✅ Token refresh
- ✅ Resource indicators (RFC 8707)
- ✅ Authorization server metadata discovery (RFC 8414 + OIDC fallback)
- ✅ Protected resource metadata (RFC 9728)
- ✅ Server-side token validation with WWW-Authenticate headers
- ✅ Client-side automatic token management and 401 retry
- ✅ Dynamic client registration (RFC 7591)

---

### New Features in 2025-11-25

#### ✅ Tasks (Experimental)
Long-running operation support:
- Task creation with `task` hint in `tools/call`
- Task states: `working`, `input_required`, `completed`, `failed`, `cancelled`
- `tasks/get` for status polling
- `tasks/cancel` for cancellation
- `tasks/result` for blocking result retrieval
- `tasks/list` for listing all tasks
- `notifications/tasks/status` on state changes
- Tool-level `execution.taskSupport` via builder

#### ✅ Extensions Framework
- Extension capability negotiation via `experimental` hash
- Extension settings and versioning
- Namespaced extension methods and notification dispatch
- Server: `register-extension()`, `unregister-extension()`
- Client: `register-extension()`, `server-extensions()`, `supports-extension()`

#### ✅ Authorization Extensions
- ✅ SEP-1046: OAuth client credentials (M2M) — `OAuthM2MClient` with `client_credentials` grant
- ✅ SEP-990: Enterprise IdP policy controls — `OAuthEnterpriseClient` with token exchange (RFC 8693) and JWT bearer grant (RFC 7523)

#### ✅ URL Mode Elicitation (SEP-1036)
- `elicit-url()` method for URL mode requests
- `notify-elicitation-complete()` for completion notifications
- `URLElicitationRequired` error code (-32042)

#### ✅ Sampling with Tools (SEP-1577)
- Tool definitions in sampling requests
- Server-side agentic loops

---

## Comparison with Python SDK

The [official Python SDK](https://github.com/modelcontextprotocol/python-sdk) implements:

| Feature | Python SDK | Raku SDK |
|---------|-----------|----------|
| Tools | ✅ Full | ✅ Full + annotations |
| Resources | ✅ Full + templates + subscriptions | ✅ Full + templates + subscriptions |
| Prompts | ✅ Full | ✅ Full |
| Sampling | ✅ Full + tools | ✅ Full + tools |
| Roots | ✅ Full | ✅ Full |
| Elicitation | ✅ Full + URL mode | ✅ Full |
| OAuth 2.1 | ✅ Full | ✅ Full |
| Streamable HTTP | ✅ Full client + server | ✅ Full |
| SSE Transport | ✅ Full | ✅ Full |
| Tasks | ✅ Experimental | ✅ Done (experimental) |
| Completion | ✅ Full | ✅ Full |
| Pagination | ✅ Full | ✅ Full |
| Extensions | ✅ Experimental | ✅ Done (experimental) |

---

## Remaining Work

All priority items from the original roadmap have been completed. Remaining items:

1. **Test coverage** — Missing tests for progress tracking, error edge cases, concurrent operations

---

## Protocol Version

Current implementation targets: **2025-11-25** ✅

All key features for 2025-11-25 compliance are implemented.

---

## Test Coverage Gaps

Current tests cover:
- ✅ Types serialization (`01-types`)
- ✅ JSON-RPC encoding/decoding (`02-jsonrpc`)
- ✅ Builder patterns (`03-builders`)
- ✅ Transport interface (`04-transport`)
- ✅ Server dispatch and lifecycle (`05-server`)
- ✅ Client initialization (`06-client`)
- ✅ Top-level MCP exports (`07-mcp`)
- ✅ Sampling validation (`08-sampling`)
- ✅ HTTP transport (`09-http-transport`)
- ✅ OAuth 2.1 types, PKCE, server/client handlers (`10-oauth`)
- ✅ Tasks framework (`11-tasks`)
- ✅ Extensions framework (`12-extensions`)
- ✅ Resource templates (`13-resource-templates`)
- ✅ SSE transport (`14-sse-transport`)

Areas with limited test coverage:
- Progress tracking (server notifications, client Supply)
- Error edge cases (malformed messages, transport failures)
- Concurrent operations (parallel requests, race conditions)

---

## Conclusion

The Raku MCP SDK provides comprehensive MCP specification 2025-11-25 coverage. All transport types (Stdio, Streamable HTTP, Legacy SSE), all server features (Tools, Resources, Prompts), all client features (Sampling, Roots, Elicitation, Completion), and full OAuth 2.1 authorization are implemented. Remaining work is limited to expanded test coverage.
