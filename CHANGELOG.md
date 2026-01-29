# Changelog

All notable changes to the Raku MCP SDK are documented in this file.

## [0.29.0] - 2026-01-29

### Added
- Performance benchmarks: JSON-RPC parsing/serialization throughput, dispatch latency, concurrent scaling (`make benchmark`)
- Stress tests: concurrent tool calls, resource reads, mixed operations, slow handler saturation, high concurrency bursts (`make stress`)
- SECURITY.md with responsible disclosure policy
- CODE_OF_CONDUCT.md (Contributor Covenant v2.1)
- GitHub issue and PR templates
- README badges (CI status, zef, license)
- Configurable scheme on SSE transport (no longer hardcoded to HTTP)

### Fixed
- Race conditions in Client `%!pending-requests` (added `$!request-lock`)
- Race conditions in Server `%!in-flight-requests` and `%!tasks` (added `$!flight-lock`, `$!task-lock`)
- Flaky SSE endpoint test replaced `start { react { whenever } }` with synchronous `.tap()`
- Handler exceptions sanitized before sending to clients (no longer leaks internal details)
- PKCE verifier cleared from memory immediately after token exchange (single-use per RFC 7636)
- Bumped Rakudo from 2024.01 to 2024.12 in CI and release workflows
- Fixed release workflow fez publish (install Cro::HTTP before fez)

### Changed
- CI now includes coverage job with 70% threshold
- README rewritten quality section as implemented features rather than task list

## [0.28.0] - 2026-01-29

### Added
- Icons and title metadata on Tool, Resource, Prompt, ResourceTemplate, and Implementation (SEP-973)
- Expanded test coverage for progress tracking, error edge cases, and concurrent operations
- `IconDefinition` type with `src`, `mimeType`, and `sizes` fields
- `.title()` and `.icon()` builder methods on all primitive builders

### Changed
- Gap analysis and status docs updated to reflect full specification coverage

## [0.27.0] - 2026-01-28

### Added
- Legacy SSE transport for backwards compatibility with MCP spec 2024-11-05
- Enterprise IdP policy controls (SEP-990)
- OAuth client credentials for machine-to-machine authentication (SEP-1046)
- Dynamic client registration for OAuth

### Changed
- Documentation cleanup: corrected completeness claims, added SSE references

## [0.26.0] - 2025-12-15

### Added
- Progress token support with `$*MCP-PROGRESS-TOKEN` dynamic variable
- Client-side progress Supply for typed Progress objects
- Logging level setting via `logging/setLevel` and client `set-log-level`
- Protocol version negotiation across 2024-11-05, 2025-03-26, and 2025-11-25

## [0.25.0] - 2025-12-01

### Added
- Tool name validation per SEP-986 (1-64 chars, `[a-zA-Z0-9_-]`)
- Resource templates with URI template pattern matching and builder API
- Prompt and resource list-changed notifications

## [0.24.0] - 2025-11-15

### Added
- Extensions framework with capability negotiation and method dispatch
- Extension registration, `experimental` capabilities advertising

## [0.23.0] - 2025-11-01

### Added
- Sampling with tools (SEP-1577): `tools`, `toolChoice`, `includeContext` in createMessage
- Tasks framework for long-running async tool execution with status polling and cancellation

## [0.22.0] - 2025-10-15

### Added
- OAuth 2.1 authorization: PKCE, token management, server validation, metadata discovery

## [0.21.0] - 2025-10-01

### Added
- Tool output schemas with `outputSchema` and `structuredContent` for structured results
- Completion/autocomplete support with prompt and resource completers
- Elicitation support (form and URL modes) with handler callbacks

## [0.20.0] - 2025-09-15

### Added
- Streamable HTTP transport with session management, SSE streaming, and resumption
- Roots support: client roots configuration, server `list-roots`, `set-roots`
- Resource subscriptions: subscribe, unsubscribe, update notifications

## [0.19.0] - 2025-09-01

### Added
- Request cancellation with `notifications/cancelled`
- Pagination support for all list endpoints (tools, resources, prompts)
- Tool and resource annotations with builder API

### Changed
- Updated to MCP protocol version 2025-11-25

## [0.1.0] - 2025-07-01

### Added
- Initial implementation
- JSON-RPC 2.0 message handling
- Stdio transport
- Tools, Resources, Prompts with builder API
- Server and Client initialization
- MCP protocol types and capabilities
