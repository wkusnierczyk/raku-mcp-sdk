#!/usr/bin/env raku
use v6.d;

use MCP;
use MCP::Transport::Stdio;

=begin pod
=head1 NAME

sampling-client - Example MCP client with sampling handler

=head1 DESCRIPTION

Connects over stdio and responds to sampling/createMessage with a simple
assistant message. Useful for servers that request LLM completions from
the client side.

=end pod

my $client = Client.new(
    info => Implementation.new(name => 'sampling-client', version => '0.1'),
    capabilities => MCP::Types::ClientCapabilities.new(
        sampling => MCP::Types::SamplingCapability.new(tools => True)
    ),
    transport => StdioTransport.new,
    sampling-handler => -> %params {
        my $text = "Received {(%params<messages> // []).elems} messages";
        CreateMessageResult.new(
            role => 'assistant',
            model => 'example-model',
            content => [ TextContent.new(text => $text) ]
        )
    }
);

await $client.connect;
say "Sampling client connected. Waiting for requests...";
react { whenever $client.notifications { } }
