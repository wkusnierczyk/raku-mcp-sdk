#!/usr/bin/env raku
use v6.d;

use MCP;
use MCP::Transport::StreamableHTTP;

=begin pod
=head1 NAME

http-server - Example MCP server over Streamable HTTP

=head1 DESCRIPTION

Starts a server on http://127.0.0.1:8080/mcp and exposes a simple tool.

=end pod

my $transport = StreamableHTTPServerTransport.new(
    host => '127.0.0.1',
    port => 8080,
    path => '/mcp'
);

my $server = Server.new(
    info => Implementation.new(name => 'http-server', version => '0.1'),
    transport => $transport
);

$server.add-tool(
    name => 'echo',
    description => 'Echo input text',
    schema => {
        type => 'object',
        properties => {
            text => { type => 'string' }
        },
        required => ['text']
    },
    handler => -> %args {
        MCP::Types::CallToolResult.new(
            content => [ TextContent.new(text => %args<text> // '') ]
        )
    }
);

await $server.serve;
say "Streamable HTTP MCP server listening on http://127.0.0.1:8080/mcp";
react { whenever Supply.interval(3600) { } }
