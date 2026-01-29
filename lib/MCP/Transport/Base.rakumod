use v6.d;

#| Base transport role and transport error types
unit module MCP::Transport::Base;

=begin pod
=head1 NAME

MCP::Transport::Base - Transport role and error types

=head1 DESCRIPTION

Defines the transport interface used by MCP client/server implementations
and the associated exception hierarchy.

=head1 TRANSPORT ROLE

=head2 role Transport

All transports must implement this role. Required methods:

=item C<method start(--> Supply)> — Start the transport and return a Supply of incoming C<Message> objects.
=item C<method send(Message $msg --> Promise)> — Send a message through the transport.
=item C<method close(--> Promise)> — Close the transport and release resources.
=item C<method is-connected(--> Bool)> — Check whether the transport is currently connected.

=head1 EXCEPTIONS

=head2 X::Transport

Base exception for transport errors: C<.message>.

=head2 X::Transport::Connection

Connection failure: C<.message>.

=head2 X::Transport::Send

Send failure: C<.message>.

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
