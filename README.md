# Raku MCP SDK

A Raku (Perl 6) implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) SDK.

Build MCP servers and clients in Raku to integrate with LLM applications like Claude Desktop, IDEs, and other AI tools.

## Status

🚧 **Work in Progress** - Core functionality is being implemented.

- [x] Core types
- [x] JSON-RPC 2.0 layer
- [x] Stdio transport
- [x] Server API with tools, resources, prompts
- [x] Client API
- [ ] HTTP/Streamable HTTP transport
- [ ] Full test coverage
- [ ] Documentation

## Installation

```bash
# From zef (once published)
zef install MCP

# From source
git clone https://github.com/your-username/raku-mcp-sdk
cd raku-mcp-sdk
zef install .
```

## Quick Start

### Creating a Server

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

### Using the Fluent Builder API

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

### Creating a Client

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

Tools are functions that the LLM can call:

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

Resources provide read-only data:

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

Prompts are templated message workflows:

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

## Protocol Support

This SDK implements the MCP specification version 2025-03-26:

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

| Target | Description |
|--------|-------------|
| **Primary** | |
| `all` | Build the complete project (dependencies → build → test) |
| `build` | Build/compile the project |
| `test` | Run the test suite |
| `install` | Install the module globally |
| `clean` | Remove all build artifacts |
| **Development** | |
| `dependencies` | Install project dependencies |
| `dependencies-dev` | Install development dependencies |
| `lint` | Run linter/static analysis |
| `format` | Format source code |
| `check` | Run all checks (lint + test) |
| **Testing** | |
| `test` | Run all tests |
| `test-verbose` | Run tests with verbose output |
| `test-file` | Run a specific test (`FILE=t/01-types.rakutest`) |
| `coverage` | Generate test coverage report |
| **Distribution** | |
| `dist` | Create distribution tarball |
| `release` | Release to Zef ecosystem |
| `docs` | Generate documentation |
| **Utility** | |
| `about` | Show project information |
| `validate` | Validate META6.json |
| `repl` | Start REPL with project loaded |
| `run-example` | Run an example (`EXAMPLE=simple-server`) |
| `info` | Show toolchain information |

### Environment Variables

- `V=1` - Enable verbose output
- `NO_COLOR=1` - Disable colored output
- `FILE=<path>` - Specify file for `test-file` target
- `EXAMPLE=<name>` - Specify example for `run-example` target

## Architecture

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
