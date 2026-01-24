use v6.d;

#| Base transport role and transport error types
unit module MCP::Transport::Base;

=begin pod
=head1 NAME

MCP::Transport::Base - Transport role and error types

=head1 DESCRIPTION

Defines the transport interface used by MCP client/server implementations
and the associated exception hierarchy.

=end pod

use MCP::JSONRPC;

#| Base role for all MCP transports
role Transport is export {
    #| Start the transport and return a Supply of incoming messages
    method start(--> Supply) { ... }

    #| Send a message through the transport
    method send(MCP::JSONRPC::Message $msg --> Promise) { ... }

    #| Close the transport
    method close(--> Promise) { ... }

    #| Check if the transport is currently connected
    method is-connected(--> Bool) { ... }
}

#| Exception for transport errors
class MCP::Transport::Base::X::Transport is Exception {
    has Str $.message is required;
    has $.cause;

    method message(--> Str) { $!message }
}

#| Exception for connection errors
class MCP::Transport::Base::X::Transport::Connection is MCP::Transport::Base::X::Transport {
    method message(--> Str) { "Connection error: {callsame}" }
}

#| Exception for send errors
class MCP::Transport::Base::X::Transport::Send is MCP::Transport::Base::X::Transport {
    method message(--> Str) { "Send error: {callsame}" }
}
