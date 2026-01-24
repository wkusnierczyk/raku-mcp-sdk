# Raku MCP SDK

<table>
  <tr>
    <td>
      <img src="graphics/raku-mcp-sdk.png" alt="logo" width="300" />
    </td>
    <td>
      <p><strong>Raku MCP SDK</strong>: 
      A Raku (Perl 6) implementation of the <a href="https://modelcontextprotocol.io/">Model Context Protocol (MCP)</a> SDK.</p>
      <p>Build MCP servers and clients in Raku to integrate with LLM applications like Claude Desktop, IDEs, and other AI tools.</p>
    </td>
  </tr>
</table>

## Status

**Work in Progress**

- [x] Core types
- [x] JSON-RPC 2.0 layer
- [x] Stdio transport
- [x] Server API with tools, resources, prompts
- [x] Client API
- [ ] HTTP/Streamable HTTP transport
- [ ] Full test coverage
- [x] Documentation

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Features](#features)
- [Protocol support](#protocol-support)
- [Development](#development)
- [Architecture](#architecture)
- [Project structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)
- [References](#references)
- [About](#about)

## Installation

```bash
# From zef (once published)
zef install MCP

# From source
git clone https://github.com/your-username/raku-mcp-sdk
cd raku-mcp-sdk
zef install .
```

## Quick start

### Creating a server

```raku
use MCP;
use MCP::Server;
use MCP::Transport::Stdio;
use MCP::Types;

# Create server
my $server = MCP::Server::Server.new(
    info => MCP::Types::Implementation.new(
        name => 'my-server',
        version => '1.0.0'
    ),
    transport => MCP::Transport::Stdio::StdioTransport.new,
);

# Add a tool
$server.add-tool(
    name => 'greet',
    description => 'Greet someone by name',
    schema => {
        type => 'object',
        properties => {
            name => { type => 'string', description => 'Name to greet' }
        },
        required => ['name'],
    },
    handler => -> :%params {
        "Hello, %params<name>!"
    }
);

# Add a resource
$server.add-resource(
    uri => 'info://about',
    name => 'About',
    description => 'About this server',
    mimeType => 'text/plain',
    reader => { 'This is my MCP server!' }
);

# Start serving
await $server.serve;
```

### Using the fluent builder API

```raku
use MCP::Server::Tool;

# Build tools with fluent API
my $calculator = tool()
    .name('add')
    .description('Add two numbers')
    .number-param('a', description => 'First number', :required)
    .number-param('b', description => 'Second number', :required)
    .annotations(title => 'Calculator', :readOnly, :idempotent)
    .handler(-> :%params { %params<a> + %params<b> })
    .build;

$server.add-tool($calculator);
```

### Creating a client

```raku
use MCP;
use MCP::Client;
use MCP::Transport::Stdio;
use MCP::Types;

# Connect to an MCP server process
my $proc = Proc::Async.new('path/to/mcp-server');
my $client = MCP::Client::Client.new(
    info => MCP::Types::Implementation.new(
        name => 'my-client',
        version => '1.0.0'
    ),
    transport => MCP::Transport::Stdio::StdioTransport.new(
        input => $proc.stdout,
        output => $proc.stdin,
    ),
);

await $client.connect;

# List and call tools
my @tools = await $client.list-tools;
for @tools -> $tool {
    say "Tool: $tool.name() - $tool.description()";
}

my $result = await $client.call-tool('greet', arguments => { name => 'World' });
say $result.content[0].text;  # "Hello, World!"

# Read resources
my @contents = await $client.read-resource('info://about');
say @contents[0].text;
```

## Features

### Tools

Tools are functions that the LLM can call.

```raku
$server.add-tool(
    name => 'search',
    description => 'Search for something',
    schema => {
        type => 'object',
        properties => {
            query => { type => 'string' },
            limit => { type => 'integer', default => 10 },
        },
        required => ['query'],
    },
    handler => -> :%params {
        # Return string, Content object, or CallToolResult
        my @results = do-search(%params<query>, %params<limit>);
        @results.join("\n")
    }
);
```

### Resources

Resources provide read-only data.

```raku
# Static resource
$server.add-resource(
    uri => 'config://app',
    name => 'App Config',
    mimeType => 'application/json',
    reader => { to-json(%config) }
);

# File-based resource
use MCP::Server::Resource;
$server.add-resource(file-resource('data.txt'.IO));
```

### Prompts

Prompts are templated message workflows.

```raku
use MCP::Server::Prompt;

$server.add-prompt(
    name => 'summarize',
    description => 'Summarize content',
    arguments => [
        { name => 'content', required => True },
        { name => 'length', required => False },
    ],
    generator => -> :%params {
        my $length = %params<length> // 'medium';
        user-message("Please provide a $length summary of: %params<content>")
    }
);
```

## Protocol support

This SDK implements the [MCP specification version 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26).

- ✅ JSON-RPC 2.0 messaging
- ✅ Capability negotiation
- ✅ Tools (list, call)
- ✅ Resources (list, read)
- ✅ Prompts (list, get)
- ✅ Logging
- ✅ Progress notifications
- 🔄 Sampling (server requesting LLM completions)
- 🔄 Roots (filesystem boundaries)
- 🔄 HTTP transport

## Development

The project uses a comprehensive Makefile for development tasks:

```bash
make about       # Show project information
make all         # Full build: dependencies → build → test
make test        # Run test suite
```

### Makefile Targets

Primary targets

| Target | Description | Notes |
|--------|-------------|-------|
| `all` | Install deps, build, and test | Runs `dependencies → build → test` |
| `build` | Validate and precompile modules | Runs `validate` then `build-precompile` |
| `build-precompile` | Precompile the main module | Uses `raku -Ilib -c lib/MCP.rakumod` fallback |
| `test` | Build and run tests | Depends on `build` |
| `install` | Install module globally | Uses `zef install . --/test` |

Validation and metadata

| Target | Description | Notes |
|--------|-------------|-------|
| `validate` | Validate META6.json and provides entries | Runs `validate-meta` and `validate-provides` |
| `validate-meta` | Check required META6.json fields | Ensures `name`, `version`, `description`, `provides` |
| `validate-provides` | Verify `provides` paths exist | Prints each resolved entry |

Dependencies

| Target | Description | Notes |
|--------|-------------|-------|
| `dependencies` | Install runtime dependencies | `zef install --deps-only .` |
| `dependencies-dev` | Install dev dependencies | Includes Prove6, Test::META, Mi6, Racoco |
| `dependencies-update` | Update dependencies | Runs `zef update` and `zef upgrade` |

Lint and formatting

| Target | Description | Notes |
|--------|-------------|-------|
| `lint` | Run syntax + META checks | Runs `lint-syntax` and `lint-meta` |
| `lint-syntax` | Compile-check source files | Uses `raku -Ilib -c` |
| `lint-meta` | Validate META6.json | Requires JSON::Fast |
| `format` | Format guidance and whitespace scan | Non-destructive |
| `format-fix` | Remove trailing whitespace | Applies to source + tests |
| `check` | Run lint + tests | Equivalent to `lint test` |

Testing and coverage

| Target | Description | Notes |
|--------|-------------|-------|
| `test-verbose` | Run tests with verbose output | Uses `prove6` with `--verbose` |
| `test-file` | Run a specific test file | `FILE=t/01-types.rakutest` |
| `test-quick` | Run tests without build | Skips `build` |
| `coverage` | Generate coverage report | HTML in `coverage-report/report.html`, raw data in `.racoco/` |

Documentation

| Target | Description | Notes |
|--------|-------------|-------|
| `docs` | Generate text docs into `docs/` | Uses `raku --doc=Text` per module |
| `docs-serve` | Serve docs (placeholder) | Not implemented |
| `architecture-diagram` | Build architecture PNG | Renders `architecture/architecture.mmd` to `architecture/architecture.png` |

Distribution and release

| Target | Description | Notes |
|--------|-------------|-------|
| `dist` | Create source tarball | Writes to `dist/` |
| `release` | Interactive release helper | Prompts for `fez upload` |

Utilities and examples

| Target | Description | Notes |
|--------|-------------|-------|
| `about` | Show project info | Prints metadata from Makefile |
| `repl` | Start REPL with project loaded | `raku -Ilib -MMCP` |
| `run-example` | Run example by name | `EXAMPLE=simple-server` |
| `info` | Show toolchain + stats | Raku/Zef/Prove versions |
| `list-modules` | List module files | From `lib/` |
| `list-tests` | List test files | From `t/` |

Install/uninstall

| Target | Description | Notes |
|--------|-------------|-------|
| `install-local` | Install to home | Uses `zef install . --to=home` |
| `install-force` | Force install | Uses `zef install . --force-install` |
| `uninstall` | Uninstall module | `zef uninstall MCP` |

CI helpers

| Target | Description | Notes |
|--------|-------------|-------|
| `ci` | CI pipeline | `dependencies → lint → test` |
| `ci-full` | Full CI pipeline | `dependencies-dev → lint → test → coverage` |

Version management

| Target | Description | Notes |
|--------|-------------|-------|
| `version` | Show or update project version | `make version 1.2.3 "Release description"` updates Makefile + META6.json and creates a local annotated tag |
| `bump-patch` | Patch bump placeholder | Not implemented |
| `bump-minor` | Minor bump placeholder | Not implemented |
| `bump-major` | Major bump placeholder | Not implemented |

Cleaning

| Target | Description | Notes |
|--------|-------------|-------|
| `clean` | Remove build/coverage/dist | Runs clean-build/clean-coverage/clean-dist |
| `clean-build` | Remove precomp/build dirs | Removes `.precomp` and `.build` |
| `clean-coverage` | Remove coverage output | Removes `.racoco` and `coverage-report` |
| `clean-dist` | Remove tarballs/dist dir | Removes `dist/` and `*.tar.gz` |
| `clean-all` | Deep clean | Also removes docs build output |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `V=1` | Enable verbose output |
| `NO_COLOR=1` | Disable colored output |
| `FILE=<path>` | Specify file for `test-file` target |
| `EXAMPLE=<name>` | Specify example for `run-example` target |

### Coverage Prerequisites

The coverage report uses RaCoCo. If `racoco` is not on your PATH, add the
Raku site bin directory:

```bash
export PATH="$(brew --prefix rakudo-star)/share/perl6/site/bin:$PATH"
```

Then run:

```bash
make coverage
# report: coverage-report/report.html
```

## Architecture

The diagram below shows how the core components interact. 
The Mermaid source is in `architecture/architecture.mmd` and the rendered image is in
`architecture/architecture.png`.
Regenerate the PNG with `make architecture-diagram`.

![Architecture diagram](architecture/architecture.png)

## Project structure

```
MCP/
├── MCP.rakumod              # Main module, re-exports
├── MCP/
│   ├── Types.rakumod        # Protocol types
│   ├── JSONRPC.rakumod      # JSON-RPC 2.0
│   ├── Transport/
│   │   ├── Base.rakumod     # Transport role
│   │   └── Stdio.rakumod    # stdio transport
│   ├── Server.rakumod       # Server implementation
│   ├── Server/
│   │   ├── Tool.rakumod     # Tool helpers
│   │   ├── Resource.rakumod # Resource helpers
│   │   └── Prompt.rakumod   # Prompt helpers
│   └── Client.rakumod       # Client implementation
```

## Contributing

Contributions are welcome! Please see the [DESIGN.md](DESIGN.md) document for architecture details.

## License

MIT License - see LICENSE file.

## References

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [Official TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [Official Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Raku Documentation](https://docs.raku.org/)

## About

```bash
$ make about

Raku MCP SDK: Raku Implementation of the Model Context Protocol
├─ version:    0.1.0
├─ developer:  mailto:waclaw.kusnierczyk@gmail.com
├─ source:     https://github.com/wkusnierczyk/raku-mcp-sdk
└─ licence:    MIT https://opensource.org/licenses/MIT
```
