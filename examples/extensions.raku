#!/usr/bin/env raku
use v6.d;

use MCP::Server;
use MCP::Client;
use MCP::Types;
use MCP::Transport::Base;
use MONKEY-TYPING;
need MCP::JSONRPC;

=begin pod
=head1 NAME

extensions - Extension registration, negotiation, and method dispatch

=head1 DESCRIPTION

Runs entirely in-process using a tiny recording transport. Demonstrates
the extensions framework:

- Registering extensions with settings on server and client
- Capability negotiation during initialize
- Extension method dispatch
- Extension notification handling
- Querying negotiated extensions

=head1 USAGE

    make run-example EXAMPLE=extensions

=end pod

class RecordingTransport does MCP::Transport::Base::Transport {
    has Supplier $!incoming = Supplier.new;
    has Bool $!connected = False;
    has @!sent;

    method start(--> Supply) {
        $!connected = True;
        $!incoming.Supply;
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        @!sent.push($msg);
        Promise.kept(True);
    }

    method close(--> Promise) {
        $!connected = False;
        $!incoming.done;
        Promise.kept(True);
    }

    method is-connected(--> Bool) { $!connected }
    method sent(--> Array) { @!sent }
    method clear-sent() { @!sent = () }
}

augment class MCP::Server::Server {
    method handle-message-public($msg) { self!handle-message($msg) }
}

# --- Server setup ---

my $transport = RecordingTransport.new;
my $server = Server.new(
    info => Implementation.new(name => 'ext-server', version => '0.1.0'),
    transport => $transport,
);

# Register extensions with settings and handlers
$server.register-extension(
    name     => 'acme/logging',
    version  => '1.0',
    settings => { level => 'debug', format => 'json' },
    methods  => {
        'acme/logging.query' => -> %params {
            { entries => ["[debug] request from {%params<source> // 'unknown'}"] }
        },
    },
    notifications => {
        'acme/logging.flush' => -> %params {
            say "  (flush notification received)";
        },
    },
);

$server.register-extension(
    name     => 'acme/metrics',
    version  => '2.0',
    settings => { interval => 60 },
    methods  => {
        'acme/metrics.snapshot' => -> %params {
            { cpu => 42, memory => 1024 }
        },
    },
);

# --- Demo: Capabilities ---

say "== Extension Capabilities ==";
my $caps = $server.capabilities;
say "Extensions in server capabilities:";
for $caps.experimental.sort -> (:$key, :$value) {
    say "  $key: version={$value<version>}, settings={$value<settings>.raku}";
}

# --- Demo: Initialize with client extensions ---

say "\n== Initialization & Negotiation ==";
my $init-result = $server.dispatch-request(MCP::JSONRPC::Request.new(
    id => 1,
    method => 'initialize',
    params => {
        protocolVersion => '2025-11-25',
        capabilities => {
            experimental => {
                'acme/logging' => { version => '1.0', settings => {} },
                'acme/unknown' => { version => '1.0', settings => {} },
            },
        },
        clientInfo => { name => 'ext-client', version => '0.1.0' },
    },
));

my %negotiated = $server.negotiated-extensions;
say "Client advertised: acme/logging, acme/unknown";
say "Server registered: acme/logging, acme/metrics";
say "Negotiated (intersection): {%negotiated.keys.sort.join(', ')}";

# --- Demo: Method dispatch ---

say "\n== Extension Method Dispatch ==";
my $result = $server.dispatch-request(MCP::JSONRPC::Request.new(
    id => 2,
    method => 'acme/logging.query',
    params => { source => 'demo-client' },
));
say "acme/logging.query result: {$result.raku}";

$result = $server.dispatch-request(MCP::JSONRPC::Request.new(
    id => 3,
    method => 'acme/metrics.snapshot',
    params => {},
));
say "acme/metrics.snapshot result: {$result.raku}";

# --- Demo: Notification dispatch ---

say "\n== Extension Notification Dispatch ==";
$server.handle-message-public(MCP::JSONRPC::Notification.new(
    method => 'acme/logging.flush',
    params => {},
));

# --- Demo: Unregister ---

say "\n== Unregister Extension ==";
say "Before: {$server.capabilities.experimental.keys.sort.join(', ')}";
$server.unregister-extension('acme/metrics');
say "After:  {$server.capabilities.experimental.keys.sort.join(', ')}";

# --- Demo: Namespace validation ---

say "\n== Namespace Validation ==";
try {
    $server.register-extension(name => 'invalid-no-slash');
    CATCH { default { say "Rejected 'invalid-no-slash': {.message}" } }
}

await $transport.close;

say "\nDone.";
