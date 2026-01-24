# Raku MCP SDK Design Document

## Overview

This document outlines the design for a Raku (formerly Perl 6) implementation of the Model Context Protocol (MCP) SDK. The SDK will enable Raku developers to build MCP servers and clients that can integrate with LLM applications like Claude Desktop, IDEs, and other AI tools.

## Protocol Summary

MCP (Model Context Protocol) is an open protocol that standardizes how LLM applications communicate with external data sources and tools. Key characteristics:

- **Transport-agnostic**: Uses JSON-RPC 2.0 over stdio or HTTP (Streamable HTTP)
- **Bidirectional**: Both client and server can initiate requests
- **Capability-based**: Features are negotiated during initialization
- **Stateful**: Connections maintain state throughout their lifecycle

### Protocol Lifecycle

1. **Initialization**: Client sends `initialize` request, server responds with capabilities
2. **Operation**: Normal message exchange based on negotiated capabilities
3. **Shutdown**: Connection closes via transport mechanism

### Core Features

**Server-provided:**
- **Resources**: Read-only data (files, database records, API responses)
- **Prompts**: Templated message workflows
- **Tools**: Functions the LLM can execute

**Client-provided:**
- **Sampling**: Server can request LLM completions
- **Roots**: Server can query filesystem boundaries
- **Elicitation**: Server can request user input

## Architecture

### Module Structure

```
MCP/
├── MCP.rakumod                    # Main entry point, re-exports
├── MCP/
│   ├── Types.rakumod              # Core protocol types
│   ├── Schema.rakumod             # JSON Schema validation
│   ├── JSONRPC.rakumod            # JSON-RPC 2.0 implementation
│   │
│   ├── Transport/
│   │   ├── Base.rakumod           # Transport role/interface
│   │   ├── Stdio.rakumod          # stdio transport
│   │   └── HTTP.rakumod           # Streamable HTTP transport
│   │
│   ├── Server.rakumod             # High-level server API
│   ├── Server/
│   │   ├── Session.rakumod        # Session management
│   │   ├── Tool.rakumod           # Tool definition helpers
│   │   ├── Resource.rakumod       # Resource definition helpers
│   │   └── Prompt.rakumod         # Prompt definition helpers
│   │
│   ├── Client.rakumod             # High-level client API
│   └── Client/
│       └── Session.rakumod        # Client session management
│
└── META6.json
```

### Design Principles

1. **Leverage Raku's strengths**:
   - Use roles for composition
   - Leverage multi-dispatch for message handling
   - Use Supplies for async streaming
   - Exploit gradual typing

2. **Idiomatic Raku API**:
   - Method signatures using Raku's parameter syntax
   - Native async with `Promise` and `Supply`
   - Traits for declarative tool/resource/prompt registration

3. **Compatible with existing ecosystem**:
   - Optional Cro integration for HTTP transport
   - Can use standalone JSON-RPC or build on existing modules

## Core Types

### Protocol Version

```raku
constant LATEST_PROTOCOL_VERSION = "2025-03-26";
constant SUPPORTED_PROTOCOL_VERSIONS = <2025-03-26 2024-11-05>;
```

### Implementation Info

```raku
class MCP::Implementation {
    has Str $.name is required;
    has Str $.version is required;
}
```

### Capabilities

```raku
class MCP::ServerCapabilities {
    has Bool $.experimental;
    has MCP::LoggingCapability $.logging;
    has MCP::PromptsCapability $.prompts;
    has MCP::ResourcesCapability $.resources;
    has MCP::ToolsCapability $.tools;
}

class MCP::ClientCapabilities {
    has Bool $.experimental;
    has MCP::RootsCapability $.roots;
    has MCP::SamplingCapability $.sampling;
    has MCP::ElicitationCapability $.elicitation;
}
```

### Tools

```raku
class MCP::Tool {
    has Str $.name is required;
    has Str $.description;
    has Hash $.inputSchema;  # JSON Schema
    has MCP::ToolAnnotations $.annotations;
}

class MCP::ToolAnnotations {
    has Str $.title;
    has Bool $.readOnlyHint;
    has Bool $.destructiveHint;
    has Bool $.idempotentHint;
    has Bool $.openWorldHint;
}

class MCP::CallToolResult {
    has @.content;  # Array of TextContent, ImageContent, etc.
    has Bool $.isError;
}
```

### Resources

```raku
class MCP::Resource {
    has Str $.uri is required;
    has Str $.name is required;
    has Str $.description;
    has Str $.mimeType;
    has MCP::ResourceAnnotations $.annotations;
}

class MCP::ResourceContents {
    has Str $.uri is required;
    has Str $.mimeType;
    # Either text or blob
    has Str $.text;
    has Blob $.blob;
}
```

### Prompts

```raku
class MCP::Prompt {
    has Str $.name is required;
    has Str $.description;
    has @.arguments;  # Array of PromptArgument
}

class MCP::PromptArgument {
    has Str $.name is required;
    has Str $.description;
    has Bool $.required;
}

class MCP::PromptMessage {
    has Str $.role is required where * ~~ <user assistant>;
    has $.content;  # TextContent, ImageContent, or EmbeddedResource
}
```

### Content Types

```raku
role MCP::Content { }

class MCP::TextContent does MCP::Content {
    has Str $.type = 'text';
    has Str $.text is required;
    has MCP::Annotations $.annotations;
}

class MCP::ImageContent does MCP::Content {
    has Str $.type = 'image';
    has Str $.data is required;     # base64
    has Str $.mimeType is required;
    has MCP::Annotations $.annotations;
}

class MCP::ResourceContent does MCP::Content {
    has Str $.type = 'resource';
    has MCP::Resource $.resource is required;
}
```

## JSON-RPC Layer

### Message Types

```raku
role MCP::JSONRPC::Message { }

class MCP::JSONRPC::Request does MCP::JSONRPC::Message {
    has Str $.jsonrpc = '2.0';
    has $.id is required;  # Str | Int
    has Str $.method is required;
    has $.params;
}

class MCP::JSONRPC::Response does MCP::JSONRPC::Message {
    has Str $.jsonrpc = '2.0';
    has $.id is required;
    has $.result;
    has MCP::JSONRPC::Error $.error;
}

class MCP::JSONRPC::Notification does MCP::JSONRPC::Message {
    has Str $.jsonrpc = '2.0';
    has Str $.method is required;
    has $.params;
}

class MCP::JSONRPC::Error {
    has Int $.code is required;
    has Str $.message is required;
    has $.data;
}
```

### Standard Error Codes

```raku
enum MCP::JSONRPC::ErrorCode (
    ParseError      => -32700,
    InvalidRequest  => -32600,
    MethodNotFound  => -32601,
    InvalidParams   => -32602,
    InternalError   => -32603,
);
```

## Transport Layer

### Transport Role

```raku
role MCP::Transport {
    # Start the transport, returns Supply of incoming messages
    method start(--> Supply) { ... }
    
    # Send a message
    method send(MCP::JSONRPC::Message $msg --> Promise) { ... }
    
    # Close the transport
    method close(--> Promise) { ... }
    
    # Check if connected
    method is-connected(--> Bool) { ... }
}
```

### Stdio Transport

```raku
class MCP::Transport::Stdio does MCP::Transport {
    has IO::Handle $.input = $*IN;
    has IO::Handle $.output = $*OUT;
    has Supply $!incoming;
    has Bool $!running = False;
    
    method start(--> Supply) {
        $!running = True;
        $!incoming = supply {
            whenever self!read-messages() -> $msg {
                emit $msg;
            }
        }
    }
    
    method !read-messages(--> Supply) {
        supply {
            my $buffer = '';
            whenever $!input.Supply(:bin) -> $chunk {
                $buffer ~= $chunk.decode('utf-8');
                # Parse Content-Length header and extract messages
                while self!parse-message($buffer) -> ($msg, $rest) {
                    emit $msg;
                    $buffer = $rest;
                }
            }
        }
    }
    
    method send(MCP::JSONRPC::Message $msg --> Promise) {
        start {
            my $json = to-json($msg.Hash);
            my $bytes = $json.encode('utf-8');
            $!output.print("Content-Length: {$bytes.elems}\r\n\r\n");
            $!output.print($json);
            $!output.flush;
        }
    }
    
    method close(--> Promise) {
        start {
            $!running = False;
            $!input.close;
        }
    }
}
```

### HTTP Transport (Streamable HTTP)

```raku
class MCP::Transport::HTTP does MCP::Transport {
    has Str $.endpoint is required;
    has Int $.port = 3000;
    has Str $.host = 'localhost';
    
    # For server mode
    has Cro::HTTP::Server $!server;
    has Supplier $!incoming-supplier;
    
    # For client mode  
    has Cro::HTTP::Client $!client;
    has Str $!session-id;
    
    method start-server(--> Supply) {
        $!incoming-supplier = Supplier.new;
        
        my $routes = route {
            post -> 'mcp' {
                request-body -> $body {
                    my $msg = self!parse-json($body);
                    $!incoming-supplier.emit($msg);
                    # Handle response...
                }
            }
            
            get -> 'mcp' {
                # SSE endpoint for server-initiated messages
                content 'text/event-stream', supply {
                    whenever $!outgoing -> $msg {
                        emit "data: {to-json($msg)}\n\n";
                    }
                };
            }
        };
        
        $!server = Cro::HTTP::Server.new(
            :host($!host), :port($!port), application => $routes
        );
        $!server.start;
        
        $!incoming-supplier.Supply;
    }
}
```

## Server API

### High-Level Server

```raku
class MCP::Server {
    has MCP::Implementation $.info is required;
    has MCP::ServerCapabilities $.capabilities;
    has MCP::Transport $.transport;
    
    # Registered handlers
    has %!tools;
    has %!resources;
    has %!prompts;
    
    # Tool registration with trait
    method add-tool(
        Str :$name!,
        Str :$description,
        :$schema,
        :&handler!
    ) {
        %!tools{$name} = MCP::Server::Tool.new(
            :$name, :$description, :$schema, :&handler
        );
    }
    
    # Resource registration
    method add-resource(
        Str :$uri!,
        Str :$name!,
        Str :$description,
        Str :$mimeType,
        :&reader!
    ) {
        %!resources{$uri} = MCP::Server::Resource.new(
            :$uri, :$name, :$description, :$mimeType, :&reader
        );
    }
    
    # Prompt registration
    method add-prompt(
        Str :$name!,
        Str :$description,
        :@arguments,
        :&generator!
    ) {
        %!prompts{$name} = MCP::Server::Prompt.new(
            :$name, :$description, :@arguments, :&generator
        );
    }
    
    # Start serving
    method serve(--> Promise) {
        start {
            react {
                whenever $!transport.start() -> $msg {
                    self!handle-message($msg);
                }
            }
        }
    }
    
    # Message dispatch
    method !handle-message($msg) {
        given $msg {
            when MCP::JSONRPC::Request {
                my $result = self!dispatch-request($msg);
                self!send-response($msg.id, $result);
            }
            when MCP::JSONRPC::Notification {
                self!handle-notification($msg);
            }
        }
    }
    
    # Request dispatch via multi-dispatch
    multi method !dispatch-request($req where *.method eq 'initialize') {
        self!handle-initialize($req.params);
    }
    
    multi method !dispatch-request($req where *.method eq 'tools/list') {
        self!list-tools();
    }
    
    multi method !dispatch-request($req where *.method eq 'tools/call') {
        self!call-tool($req.params);
    }
    
    # ... etc for other methods
}
```

### Declarative Tool Definition (using traits)

```raku
# Define a custom trait for MCP tools
multi trait_mod:<is>(Method $m, :$mcp-tool!) {
    # Register the method as an MCP tool
    # This can be used with a server instance later
}

# Example usage:
class MyMCPServer is MCP::Server {
    method greet(Str :$name!) is mcp-tool(
        description => 'Greets a person by name',
        schema => {
            type => 'object',
            properties => {
                name => { type => 'string', description => 'Name to greet' }
            },
            required => ['name']
        }
    ) {
        return MCP::TextContent.new(text => "Hello, $name!");
    }
}
```

### Simple Server Example

```raku
use MCP;
use MCP::Transport::Stdio;

my $server = MCP::Server.new(
    info => MCP::Implementation.new(
        name => 'my-raku-server',
        version => '1.0.0'
    ),
    transport => MCP::Transport::Stdio.new
);

# Add a simple tool
$server.add-tool(
    name => 'add',
    description => 'Add two numbers',
    schema => {
        type => 'object',
        properties => {
            a => { type => 'number' },
            b => { type => 'number' }
        },
        required => <a b>
    },
    handler => -> :%params {
        MCP::CallToolResult.new(
            content => [
                MCP::TextContent.new(
                    text => (~(%params<a> + %params<b>))
                )
            ]
        )
    }
);

# Add a resource
$server.add-resource(
    uri => 'file:///greeting.txt',
    name => 'Greeting',
    description => 'A friendly greeting',
    mimeType => 'text/plain',
    reader => -> {
        MCP::ResourceContents.new(
            uri => 'file:///greeting.txt',
            mimeType => 'text/plain',
            text => 'Hello from Raku MCP!'
        )
    }
);

# Start serving
await $server.serve;
```

## Client API

### High-Level Client

```raku
class MCP::Client {
    has MCP::Implementation $.info is required;
    has MCP::ClientCapabilities $.capabilities;
    has MCP::Transport $.transport;
    
    has MCP::ServerCapabilities $!server-capabilities;
    has Bool $!initialized = False;
    
    # Connect and initialize
    method connect(--> Promise) {
        start {
            await $!transport.start;
            $!server-capabilities = await self!initialize;
            $!initialized = True;
        }
    }
    
    # Initialize handshake
    method !initialize(--> Promise) {
        self.request('initialize', {
            protocolVersion => LATEST_PROTOCOL_VERSION,
            capabilities => $!capabilities.Hash,
            clientInfo => $!info.Hash
        }).then(-> $result {
            # Send initialized notification
            self.notify('initialized');
            MCP::ServerCapabilities.from-hash($result);
        })
    }
    
    # List available tools
    method list-tools(--> Promise) {
        self.request('tools/list').then(-> $result {
            $result<tools>.map({ MCP::Tool.from-hash($_) }).list
        })
    }
    
    # Call a tool
    method call-tool(Str $name, :%arguments --> Promise) {
        self.request('tools/call', {
            name => $name,
            arguments => %arguments
        }).then(-> $result {
            MCP::CallToolResult.from-hash($result)
        })
    }
    
    # List resources
    method list-resources(--> Promise) {
        self.request('resources/list').then(-> $result {
            $result<resources>.map({ MCP::Resource.from-hash($_) }).list
        })
    }
    
    # Read a resource
    method read-resource(Str $uri --> Promise) {
        self.request('resources/read', { uri => $uri }).then(-> $result {
            $result<contents>.map({ MCP::ResourceContents.from-hash($_) }).list
        })
    }
    
    # Low-level request
    method request(Str $method, $params? --> Promise) {
        my $id = self!next-id;
        my $request = MCP::JSONRPC::Request.new(:$id, :$method, :$params);
        
        my $response-promise = Promise.new;
        %!pending-requests{$id} = $response-promise;
        
        $!transport.send($request).then({
            # Response handled by incoming message handler
        });
        
        $response-promise;
    }
    
    # Low-level notification
    method notify(Str $method, $params?) {
        my $notification = MCP::JSONRPC::Notification.new(:$method, :$params);
        $!transport.send($notification);
    }
}
```

### Client Example

```raku
use MCP;
use MCP::Transport::Stdio;

my $client = MCP::Client.new(
    info => MCP::Implementation.new(
        name => 'my-raku-client',
        version => '1.0.0'
    ),
    transport => MCP::Transport::Stdio.new(
        # Connect to server process
        input => $server-process.stdout,
        output => $server-process.stdin
    )
);

await $client.connect;

# List and use tools
my @tools = await $client.list-tools;
say "Available tools: ", @tools.map(*.name).join(', ');

my $result = await $client.call-tool('add', arguments => { a => 5, b => 3 });
say "Result: ", $result.content[0].text;

# List and read resources
my @resources = await $client.list-resources;
for @resources -> $res {
    my @contents = await $client.read-resource($res.uri);
    say "$res.name(): ", @contents[0].text;
}
```

## Dependencies

### Required
- `JSON::Fast` - Fast JSON parsing/serialization

### Optional
- `Cro::HTTP::Server` - For HTTP transport (server mode)
- `Cro::HTTP::Client` - For HTTP transport (client mode)

### For Testing
- `Test` - Core testing
- `Test::Mock` - Mocking support

## Implementation Phases

### Phase 1: Core Foundation
- [ ] Basic types (MCP::Types)
- [ ] JSON-RPC implementation (MCP::JSONRPC)
- [ ] Stdio transport (MCP::Transport::Stdio)
- [ ] Basic server with tool support
- [ ] Unit tests for all components

### Phase 2: Full Server Features
- [ ] Resource support
- [ ] Prompt support
- [ ] Logging capability
- [ ] Progress notifications
- [ ] Cancellation support

### Phase 3: Client Implementation
- [ ] Basic client API
- [ ] Sampling support
- [ ] Roots support
- [ ] Elicitation support

### Phase 4: HTTP Transport
- [ ] Streamable HTTP server
- [ ] Streamable HTTP client
- [ ] Session management

### Phase 5: Polish & Ecosystem
- [ ] Comprehensive documentation
- [ ] Example servers
- [ ] Integration tests
- [ ] Publish to Raku ecosystem (zef)

## Testing Strategy

### Unit Tests
- Test each class in isolation
- Mock transports for server/client tests
- Validate JSON Schema compliance

### Integration Tests
- Test full server/client communication
- Test with real stdio transport
- Test protocol compliance

### Compliance Tests
- Validate against MCP specification examples
- Test edge cases from specification

## References

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Raku JSON::RPC](https://github.com/bbkr/JSON-RPC)
- [Cro Documentation](https://cro.raku.org/docs)
