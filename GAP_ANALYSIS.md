# MCP Specification Gap Analysis

## Raku MCP SDK vs MCP Specification 2025-11-25

This document compares the current implementation of the Raku MCP SDK against the [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25) and identifies missing features.

---

## Summary

| Category | Status | Notes |
|----------|--------|-------|
| **Base Protocol** | ✅ Mostly Complete | JSON-RPC 2.0, lifecycle, basic message handling |
| **Transports** | ⚠️ Partial | Stdio complete, Streamable HTTP started |
| **Server Features** | ⚠️ Partial | Tools/Resources/Prompts basic support |
| **Client Features** | ⚠️ Partial | Sampling basic support |
| **Utilities** | ⚠️ Partial | Logging, progress basic; missing cancellation |
| **Authorization** | ❌ Missing | OAuth 2.1 not implemented |
| **New 2025-11-25 Features** | ❌ Missing | Tasks, Extensions, URL Elicitation |

---

## Detailed Analysis

### 1. Base Protocol

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

### 2. Transports

#### ✅ Stdio Transport (`MCP::Transport::Stdio`)
- Complete implementation
- Proper newline-delimited JSON messages

#### ⚠️ Streamable HTTP Transport (`MCP::Transport::StreamableHTTP`)
- Server-side implementation started
- **Missing**:
  - Full client-side implementation
  - Session management (Mcp-Session-Id header)
  - Last-Event-ID replay for SSE resumption
  - CORS handling (started but incomplete)
  - Proper error responses per spec

#### ❌ Missing
- **SSE Transport** (legacy, but some clients still use it)

---

### 3. Server Features

#### ✅ Tools (`MCP::Server::Tool`)
- Tool registration with name, description, schema
- Tool calling with arguments
- Builder pattern API

**Missing**:
- ❌ Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) - types exist but not used in registration
- ❌ `outputSchema` for structured tool outputs (2025-06-18 feature)
- ❌ Tool name validation (SEP-986: must match `^[a-zA-Z0-9_-]{1,64}$`)
- ✅ `tools/list` pagination support - **Implemented**

#### ✅ Resources (`MCP::Server::Resource`)
- Resource registration with URI, name, description, mimeType
- Resource reading

**Missing**:
- ❌ Resource templates (URI templates with placeholders)
- ❌ Resource subscriptions (`resources/subscribe`, `resources/unsubscribe`)
- ❌ `notifications/resources/list_changed`
- ❌ `notifications/resources/updated` for subscribed resources
- ✅ `resources/list` pagination support - **Implemented**
- ❌ Resource annotations

#### ✅ Prompts (`MCP::Server::Prompt`)
- Prompt registration with arguments
- Prompt retrieval with argument substitution

**Missing**:
- ✅ `prompts/list` pagination support - **Implemented**
- ❌ `notifications/prompts/list_changed`

---

### 4. Client Features

#### ⚠️ Sampling (`MCP::Client` sampling-handler)
- Basic `sampling/createMessage` handling
- Tool validation in sampling messages

**Missing**:
- ❌ Sampling with tools (SEP-1577) - allowing tool definitions in sampling requests
- ❌ `includeContext` parameter support
- ❌ Proper `stopReason` handling

#### ❌ Roots
- `RootsCapability` type exists but not implemented
- Missing:
  - `roots/list` request handler (server → client)
  - `notifications/roots/list_changed` handling
  - Root URI validation

#### ❌ Elicitation (2025-06-18 feature)
- `ElicitationCapability` type exists but not implemented
- Missing:
  - `elicitation/create` request (server → client)
  - Schema-based user input collection
  - URL mode elicitation (SEP-1036) for OAuth flows

---

### 5. Utilities

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

#### ❌ Cancellation
- `cancelled` notification is received but not acted upon
- Missing:
  - Proper request cancellation mechanism
  - `notifications/cancelled` sending from client
  - Timeout-based auto-cancellation

#### ❌ Ping
- Server responds to `ping` requests
- Missing:
  - Client-side `ping` for keepalive
  - Timeout handling

#### ❌ Completion (autocomplete)
- Not implemented
- Missing:
  - `completion/complete` request
  - Argument completion for prompts
  - Resource URI completion

---

### 6. Authorization (2025-03-26+)

#### ❌ Not Implemented
The entire authorization framework is missing:

- OAuth 2.1 with PKCE
- Dynamic client registration
- Token refresh
- Resource indicators (RFC 8707)
- Authorization server metadata discovery
- Protected resource metadata

---

### 7. New Features in 2025-11-25

#### ❌ Tasks (Experimental)
Long-running operation support:
- Task creation with `_meta.task` hint
- Task states: `working`, `input_required`, `completed`, `failed`, `cancelled`
- `tasks/get` for status polling
- `tasks/cancel` for cancellation
- Task result retrieval

#### ❌ Extensions Framework
- Extension capability negotiation
- Extension settings
- Namespaced extension methods

#### ❌ Authorization Extensions
- SEP-1046: OAuth client credentials (M2M)
- SEP-990: Enterprise IdP policy controls

#### ❌ URL Mode Elicitation (SEP-1036)
- Browser-based credential collection
- Out-of-band OAuth flows

#### ❌ Sampling with Tools (SEP-1577)
- Tool definitions in sampling requests
- Server-side agentic loops

---

## Comparison with Python SDK

The [official Python SDK](https://github.com/modelcontextprotocol/python-sdk) implements:

| Feature | Python SDK | Raku SDK |
|---------|-----------|----------|
| Tools | ✅ Full | ⚠️ Basic |
| Resources | ✅ Full + templates + subscriptions | ⚠️ Basic |
| Prompts | ✅ Full | ⚠️ Basic |
| Sampling | ✅ Full + tools | ⚠️ Basic |
| Roots | ✅ Full | ❌ No |
| Elicitation | ✅ Full + URL mode | ❌ No |
| OAuth 2.1 | ✅ Full | ❌ No |
| Streamable HTTP | ✅ Full client + server | ⚠️ Server partial |
| SSE Transport | ✅ Full | ❌ No |
| Tasks | ✅ Experimental | ❌ No |
| Completion | ✅ Full | ❌ No |
| Pagination | ✅ Full | ✅ Full |

---

## Priority Recommendations

### High Priority (Core Functionality)
1. **Complete Streamable HTTP transport** - Required for remote deployments
2. **Add resource subscriptions** - Common use case for file watching
3. ~~**Add pagination**~~ ✅ **Done** - Cursor-based pagination for all list endpoints
4. **Implement roots** - Required for filesystem-based servers
5. **Implement proper cancellation** - Important for long-running operations

### Medium Priority (Enhanced Functionality)
6. **Add tool output schemas** - Better structured responses
7. **Implement elicitation** - Server-initiated user input
8. **Add completion/autocomplete** - Better UX for prompt arguments
9. **Implement OAuth 2.1** - Required for authenticated servers

### Lower Priority (Advanced Features)
10. **Tasks framework** - Long-running operations (experimental)
11. **Extensions framework** - Plugin architecture
12. **URL mode elicitation** - Advanced OAuth flows
13. **Sampling with tools** - Advanced agentic capabilities

---

## Type System Gaps

The following types are defined but not fully utilized:

```raku
# Defined but unused/incomplete:
- ToolAnnotations (readOnlyHint, etc.) - not exposed in registration
- Annotations (audience, priority) - not exposed in builders
- RootsCapability - defined, not implemented
- ElicitationCapability - defined, not implemented
```

---

## Protocol Version

Current implementation targets: **2025-03-26**

Should update to: **2025-11-25**

Key changes needed:
- Update `LATEST_PROTOCOL_VERSION` constant
- Add Tasks support
- Add Extensions framework
- Update capability negotiation

---

## Test Coverage Gaps

Current tests cover:
- ✅ Types serialization
- ✅ JSON-RPC encoding/decoding
- ✅ Builder patterns
- ✅ Basic server/client lifecycle
- ✅ Sampling validation

Missing tests for:
- ❌ Resource subscriptions
- ✅ Pagination - **Implemented**
- ❌ Cancellation
- ❌ Progress tracking
- ❌ HTTP transport (partial)
- ❌ Error edge cases
- ❌ Concurrent operations

---

## Conclusion

The Raku MCP SDK provides a solid foundation with core protocol support, but significant work remains to achieve full specification compliance. The highest impact improvements would be:

1. Completing HTTP transport for production deployment
2. Adding resource subscriptions for real-time updates
3. Implementing pagination for scalability
4. Adding roots support for filesystem servers
5. Implementing the authorization framework for secure connections

The SDK's architecture is well-designed and should accommodate these additions without major refactoring.
