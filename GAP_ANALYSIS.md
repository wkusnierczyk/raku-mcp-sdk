# MCP Specification Gap Analysis

## Raku MCP SDK vs MCP Specification 2025-11-25

This document compares the current implementation of the Raku MCP SDK against the [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25) and identifies missing features.

---

## Summary

| Category | Status | Notes |
|----------|--------|-------|
| **Base Protocol** | ✅ Mostly Complete | JSON-RPC 2.0, lifecycle, basic message handling |
| **Transports** | ✅ Mostly Complete | Stdio complete, Streamable HTTP complete |
| **Server Features** | ⚠️ Partial | Tools/Resources/Prompts basic support |
| **Client Features** | ⚠️ Partial | Sampling basic support |
| **Utilities** | ⚠️ Partial | Logging, progress, cancellation implemented |
| **Authorization** | ❌ Missing | OAuth 2.1 not implemented |
| **New 2025-11-25 Features** | ⚠️ Partial | Elicitation done, Tasks done (experimental), Extensions missing |

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

#### ⚠️ Partial
- **Lifecycle**: Initialize/initialized handshake works, but:
  - Missing proper version negotiation (server should respond with supported version if client's isn't supported)
  - Missing `instructions` parsing from server in client
  
#### ❌ Missing
- **JSON-RPC batching**: Not supported (though removed in 2025-06-18, re-evaluate if needed)

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

#### ❌ Missing
- **SSE Transport** (legacy, but some clients still use it)

---

### Server Features

#### ✅ Tools (`MCP::Server::Tool`)
- Tool registration with name, description, schema
- Tool calling with arguments
- Builder pattern API

**Missing**:
- ✅ Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) - **Implemented** via builder API
- ✅ `outputSchema` for structured tool outputs (2025-06-18 feature)
- ❌ Tool name validation (SEP-986: must match `^[a-zA-Z0-9_-]{1,64}$`)
- ✅ `tools/list` pagination support - **Implemented**

#### ✅ Resources (`MCP::Server::Resource`)
- Resource registration with URI, name, description, mimeType
- Resource reading

**Missing**:
- ❌ Resource templates (URI templates with placeholders)
- ✅ Resource subscriptions (`resources/subscribe`, `resources/unsubscribe`) - **Implemented**
- ✅ `notifications/resources/list_changed` - **Implemented** via `notify-resources-list-changed()`
- ✅ `notifications/resources/updated` for subscribed resources - **Implemented** via `notify-resource-updated(uri)`
- ✅ `resources/list` pagination support - **Implemented**
- ✅ Resource annotations (`audience`, `priority`) - **Implemented** via builder API

#### ✅ Prompts (`MCP::Server::Prompt`)
- Prompt registration with arguments
- Prompt retrieval with argument substitution

**Missing**:
- ✅ `prompts/list` pagination support - **Implemented**
- ❌ `notifications/prompts/list_changed`

---

### Client Features

#### ⚠️ Sampling (`MCP::Client` sampling-handler)
- Basic `sampling/createMessage` handling
- Tool validation in sampling messages

**Missing**:
- ❌ Sampling with tools (SEP-1577) - allowing tool definitions in sampling requests
- ❌ `includeContext` parameter support
- ❌ Proper `stopReason` handling

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

#### ⚠️ Progress Tracking
- `progress()` method exists on Server
- Types defined (`Progress`)

**Missing**:
- ❌ `_meta.progressToken` in request params
- ❌ Client-side progress handling

#### ⚠️ Logging
- `log()` method exists on Server
- `LogLevel` enum and `LogEntry` type defined

**Missing**:
- ❌ `logging/setLevel` request
- ❌ Client-side log level configuration

#### ✅ Cancellation - **Implemented**
- Server tracks in-flight requests and handles `notifications/cancelled`
- Client sends cancellation notification on timeout
- Both sides have `cancel-request` method for explicit cancellation
- `is-cancelled` method for handlers to check cancellation status

#### ❌ Ping
- Server responds to `ping` requests
- Missing:
  - Client-side `ping` for keepalive
  - Timeout handling

#### ✅ Completion (autocomplete)
- `completion/complete` request handling
- Server: `add-prompt-completer()`, `add-resource-completer()` for registering completers
- Client: `complete-prompt()`, `complete-resource()` convenience methods
- `CompletionResult` type with values, total, hasMore
- Auto-truncation to 100 values per spec
- `completions` capability advertised when completers registered

---

### Authorization (2025-03-26+)

#### ❌ Not Implemented
The entire authorization framework is missing:

- OAuth 2.1 with PKCE
- Dynamic client registration
- Token refresh
- Resource indicators (RFC 8707)
- Authorization server metadata discovery
- Protected resource metadata

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

#### ❌ Extensions Framework
- Extension capability negotiation
- Extension settings
- Namespaced extension methods

#### ❌ Authorization Extensions
- SEP-1046: OAuth client credentials (M2M)
- SEP-990: Enterprise IdP policy controls

#### ✅ URL Mode Elicitation (SEP-1036)
- `elicit-url()` method for URL mode requests
- `notify-elicitation-complete()` for completion notifications
- `URLElicitationRequired` error code (-32042)

#### ❌ Sampling with Tools (SEP-1577)
- Tool definitions in sampling requests
- Server-side agentic loops

---

## Comparison with Python SDK

The [official Python SDK](https://github.com/modelcontextprotocol/python-sdk) implements:

| Feature | Python SDK | Raku SDK |
|---------|-----------|----------|
| Tools | ✅ Full | ⚠️ Basic + annotations |
| Resources | ✅ Full + templates + subscriptions | ✅ Full + subscriptions (no templates) |
| Prompts | ✅ Full | ⚠️ Basic |
| Sampling | ✅ Full + tools | ⚠️ Basic |
| Roots | ✅ Full | ✅ Full |
| Elicitation | ✅ Full + URL mode | ✅ Full |
| OAuth 2.1 | ✅ Full | ❌ No |
| Streamable HTTP | ✅ Full client + server | ✅ Full |
| SSE Transport | ✅ Full | ❌ No |
| Tasks | ✅ Experimental | ✅ Done (experimental) |
| Completion | ✅ Full | ❌ No |
| Pagination | ✅ Full | ✅ Full |

---

## Priority Recommendations

### High Priority (Core Functionality)
1. ~~**Complete Streamable HTTP transport**~~ ✅ **Done** - Full client/server with session management, SSE, and resumption
2. ~~**Add resource subscriptions**~~ ✅ **Done** - Subscribe/unsubscribe and update notifications
3. ~~**Add pagination**~~ ✅ **Done** - Cursor-based pagination for all list endpoints
4. ~~**Implement roots**~~ ✅ **Done** - Client roots support and server list-roots
5. ~~**Implement proper cancellation**~~ ✅ **Done** - Request cancellation with notifications

### Medium Priority (Enhanced Functionality)
6. ~~**Add tool output schemas**~~ ✅ **Done** - outputSchema and structuredContent support
7. ~~**Implement elicitation**~~ ✅ **Done** - Form and URL mode with handler callbacks
8. ~~**Add completion/autocomplete**~~ ✅ **Done** - Prompt and resource completion with handler registration
9. **Implement OAuth 2.1** - Required for authenticated servers

### Lower Priority (Advanced Features)
10. **Tasks framework** - Long-running operations (experimental)
11. **Extensions framework** - Plugin architecture
12. **Sampling with tools** - Advanced agentic capabilities

---

## Protocol Version

Current implementation targets: **2025-11-25** ✅

Key features still needed for full 2025-11-25 compliance:
- Add Extensions framework
- Update capability negotiation for new features

---

## Test Coverage Gaps

Current tests cover:
- ✅ Types serialization
- ✅ JSON-RPC encoding/decoding
- ✅ Builder patterns
- ✅ Basic server/client lifecycle
- ✅ Sampling validation

Missing tests for:
- ✅ Resource subscriptions - **Implemented**
- ✅ Pagination - **Implemented**
- ✅ Cancellation - **Implemented**
- ❌ Progress tracking
- ❌ HTTP transport (partial)
- ❌ Error edge cases
- ❌ Concurrent operations

---

## Conclusion

The Raku MCP SDK provides a solid foundation with core protocol support, but significant work remains to achieve full specification compliance. The highest impact improvements would be:

1. Completing HTTP transport for production deployment
2. ~~Adding resource subscriptions for real-time updates~~ ✅ **Done**
3. ~~Implementing pagination for scalability~~ ✅ **Done**
4. ~~Adding roots support for filesystem servers~~ ✅ **Done**
5. Implementing the authorization framework for secure connections

The SDK's architecture is well-designed and should accommodate these additions without major refactoring.
