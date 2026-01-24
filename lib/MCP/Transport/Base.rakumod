use v6.d;

unit module MCP::Transport::Base;

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
class X::Transport is Exception is export {
    has Str $.message is required;
    has $.cause;
    
    method message(--> Str) { $!message }
}

#| Exception for connection errors
class X::Transport::Connection is X::Transport is export {
    method message(--> Str) { "Connection error: {callsame}" }
}

#| Exception for send errors
class X::Transport::Send is X::Transport is export {
    method message(--> Str) { "Send error: {callsame}" }
}
