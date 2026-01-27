#!/usr/bin/env raku
use v6.d;

use MCP;
use MCP::Transport::StreamableHTTP;
use MCP::OAuth::Server;

=begin pod
=head1 NAME

oauth-server - Example MCP server with OAuth 2.1 token validation

=head1 DESCRIPTION

Starts an HTTP server that requires Bearer token authentication.
The token validator is a simple callback; in production, this would
verify JWTs or introspect tokens against an authorization server.

Demonstrates:
  - OAuthServerHandler setup with token validation
  - Protected resource metadata endpoint
  - WWW-Authenticate headers on 401/403

=end pod

# Simple in-memory token validator for demonstration
my %valid-tokens = (
    'demo-token-abc' => { sub => 'user1', scopes => ['read', 'write'] },
    'read-only-token' => { sub => 'user2', scopes => ['read'] },
);

my $oauth = OAuthServerHandler.new(
    resource-identifier => 'http://127.0.0.1:8080',
    authorization-servers => ['https://auth.example.com'],
    scopes-supported => ['read', 'write'],
    token-validator => -> Str $token {
        if %valid-tokens{$token}:exists {
            my %info = %valid-tokens{$token};
            { valid => True, sub => %info<sub>, scopes => %info<scopes> }
        } else {
            { valid => False, message => 'Unknown token' }
        }
    },
);

my $transport = StreamableHTTPServerTransport.new(
    host => '127.0.0.1',
    port => 8080,
    path => '/mcp',
    oauth-handler => $oauth,
);

my $server = Server.new(
    info => Implementation.new(name => 'oauth-server', version => '0.1'),
    transport => $transport,
);

$server.add-tool(
    name => 'secret-data',
    description => 'Return protected data (requires valid token)',
    schema => { type => 'object', properties => {} },
    handler => -> %args {
        'This is protected data accessible only with a valid Bearer token.'
    }
);

await $server.serve;
say "OAuth-protected MCP server listening on http://127.0.0.1:8080/mcp";
say "Protected resource metadata: http://127.0.0.1:8080/.well-known/oauth-protected-resource";
say "";
say "Test with valid token:";
say "  curl -H 'Authorization: Bearer demo-token-abc' ...";
say "Test without token (expect 401):";
say "  curl http://127.0.0.1:8080/mcp ...";
react { whenever Supply.interval(3600) { } }
