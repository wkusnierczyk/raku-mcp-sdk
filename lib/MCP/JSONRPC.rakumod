use v6.d;

#| JSON-RPC 2.0 message types and parsing helpers
unit module MCP::JSONRPC;

=begin pod
=head1 NAME

MCP::JSONRPC - JSON-RPC 2.0 message types and parsing helpers

=head1 SYNOPSIS

    use MCP::JSONRPC;

    my $req = Request.new(id => 1, method => 'ping');
    my $json = $req.to-json;
    my $msg = parse-message($json);

=head1 DESCRIPTION

Provides lightweight JSON-RPC message types (Request/Response/Notification),
standard error codes, and a parser that maps JSON strings to message objects.

=end pod

use JSON::Fast;

#| Standard JSON-RPC 2.0 error codes
enum ErrorCode is export (
    ParseError              => -32700,
    InvalidRequest          => -32600,
    MethodNotFound          => -32601,
    InvalidParams           => -32602,
    InternalError           => -32603,
    URLElicitationRequired  => -32042,
);

#| Base role for all JSON-RPC messages
role Message is export {
    has Str $.jsonrpc = '2.0';

    #| Convert the message into a Hash suitable for JSON encoding
    method Hash(--> Hash) { ... }
    #| Serialize the message to a JSON string
    method to-json(--> Str) { to-json(self.Hash) }
}

#| JSON-RPC Error object
class Error is export {
    has Int $.code is required;
    has Str $.message is required;
    has $.data;

    #| Serialize the error into a Hash
    method Hash(--> Hash) {
        my %h = code => $!code, message => $!message;
        %h<data> = $_ with $!data;
        %h
    }

    #| Build an Error from a Hash representation
    method from-hash(%h --> Error) {
        self.new(
            code => %h<code>,
            message => %h<message>,
            data => %h<data>
        )
    }

    #| Create an Error from a standard JSON-RPC error code
    method from-code(ErrorCode $code, Str $message?, :$data --> Error) {
        my $msg = $message // do given $code {
            when ParseError              { 'Parse error' }
            when InvalidRequest          { 'Invalid request' }
            when MethodNotFound          { 'Method not found' }
            when InvalidParams           { 'Invalid params' }
            when InternalError           { 'Internal error' }
            when URLElicitationRequired  { 'URL elicitation required' }
            default                      { 'Unknown error' }
        };
        self.new(code => $code.value, message => $msg, :$data)
    }
}

#| JSON-RPC Request message
class Request does Message is export {
    has $.id is required;  # Str or Int, not null
    has Str $.method is required;
    has $.params;  # Hash or Array, optional

    #| Serialize the request into a Hash
    method Hash(--> Hash) {
        my %h = jsonrpc => $!jsonrpc, id => $!id, method => $!method;
        %h<params> = $_ with $!params;
        %h
    }

    #| Build a Request from a Hash representation
    method from-hash(%h --> Request) {
        self.new(
            id => %h<id>,
            method => %h<method>,
            params => %h<params>
        )
    }
}

#| JSON-RPC Response message (success)
class Response does Message is export {
    has $.id is required;  # Str or Int, matches request
    has $.result;          # Any JSON value
    has $.error;  # Error object if failed

    #| Serialize the response into a Hash
    method Hash(--> Hash) {
        my %h = jsonrpc => $!jsonrpc, id => $!id;
        if $!error.defined {
            %h<error> = $!error.Hash;
        } else {
            %h<result> = $!result;
        }
        %h
    }

    #| Build a Response from a Hash representation
    method from-hash(%h --> Response) {
        my $error = %h<error>:exists ?? Error.from-hash(%h<error>) !! Nil;
        self.new(
            id => %h<id>,
            result => %h<result>,
            error => $error
        )
    }

    #| Create a success response
    method success($id, $result --> Response) {
        self.new(:$id, :$result)
    }

    #| Create an error response or access the current error
    proto method error(|) {*}
    #| Return the current error (if any)
    multi method error(::?CLASS:D:) { $!error }
    #| Build an error response with the supplied Error
    multi method error(::?CLASS:U: $id, Error $error --> Response) {
        self.new(:$id, :$error)
    }
}

#| JSON-RPC Notification message (no response expected)
class Notification does Message is export {
    has Str $.method is required;
    has $.params;

    #| Serialize the notification into a Hash
    method Hash(--> Hash) {
        my %h = jsonrpc => $!jsonrpc, method => $!method;
        %h<params> = $_ with $!params;
        %h
    }

    #| Build a Notification from a Hash representation
    method from-hash(%h --> Notification) {
        self.new(
            method => %h<method>,
            params => %h<params>
        )
    }
}

#| Parse a JSON string into the appropriate message type
sub parse-message(Str $json --> Message) is export {
    my %h = from-json($json);

    # Validate JSON-RPC version
    die "Invalid JSON-RPC version" unless %h<jsonrpc> eq '2.0';

    # Determine message type
    if %h<method>:exists {
        if %h<id>:exists {
            return Request.from-hash(%h);
        } else {
            return Notification.from-hash(%h);
        }
    } elsif (%h<result>:exists) || (%h<error>:exists) {
        return Response.from-hash(%h);
    } else {
        die "Invalid JSON-RPC message structure";
    }
}

#| Exception for JSON-RPC errors
class X::JSONRPC is Exception is export {
    has Error $.error is required;

    #| Render a human-readable exception message
    method message(--> Str) {
        "JSON-RPC Error {$!error.code}: {$!error.message}"
    }
}

#| Message ID generator
class IdGenerator is export {
    has Int $!counter = 0;
    has Lock $!lock = Lock.new;

    #| Return a monotonically increasing integer ID
    method next(--> Int) {
        $!lock.protect: { ++$!counter }
    }
}
