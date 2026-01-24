use v6.d;

#| JSON-RPC 2.0 message types and parsing helpers
unit module MCP::JSONRPC;

use JSON::Fast;

#| Standard JSON-RPC 2.0 error codes
enum ErrorCode is export (
    ParseError      => -32700,
    InvalidRequest  => -32600,
    MethodNotFound  => -32601,
    InvalidParams   => -32602,
    InternalError   => -32603,
);

#| Base role for all JSON-RPC messages
role Message is export {
    has Str $.jsonrpc = '2.0';

    method Hash(--> Hash) { ... }
    method to-json(--> Str) { to-json(self.Hash) }
}

#| JSON-RPC Error object
class Error is export {
    has Int $.code is required;
    has Str $.message is required;
    has $.data;

    method Hash(--> Hash) {
        my %h = code => $!code, message => $!message;
        %h<data> = $_ with $!data;
        %h
    }

    method from-hash(%h --> Error) {
        self.new(
            code => %h<code>,
            message => %h<message>,
            data => %h<data>
        )
    }

    #| Create error from standard error code
    method from-code(ErrorCode $code, Str $message?, :$data --> Error) {
        my $msg = $message // do given $code {
            when ParseError     { 'Parse error' }
            when InvalidRequest { 'Invalid request' }
            when MethodNotFound { 'Method not found' }
            when InvalidParams  { 'Invalid params' }
            when InternalError  { 'Internal error' }
            default             { 'Unknown error' }
        };
        self.new(code => $code.value, message => $msg, :$data)
    }
}

#| JSON-RPC Request message
class Request does Message is export {
    has $.id is required;  # Str or Int, not null
    has Str $.method is required;
    has $.params;  # Hash or Array, optional

    method Hash(--> Hash) {
        my %h = jsonrpc => $!jsonrpc, id => $!id, method => $!method;
        %h<params> = $_ with $!params;
        %h
    }

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

    method Hash(--> Hash) {
        my %h = jsonrpc => $!jsonrpc, id => $!id;
        if $!error.defined {
            %h<error> = $!error.Hash;
        } else {
            %h<result> = $!result;
        }
        %h
    }

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

    #| Create an error response
    proto method error(|) {*}
    multi method error(::?CLASS:D:) { $!error }
    multi method error(::?CLASS:U: $id, Error $error --> Response) {
        self.new(:$id, :$error)
    }
}

#| JSON-RPC Notification message (no response expected)
class Notification does Message is export {
    has Str $.method is required;
    has $.params;

    method Hash(--> Hash) {
        my %h = jsonrpc => $!jsonrpc, method => $!method;
        %h<params> = $_ with $!params;
        %h
    }

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

    method message(--> Str) {
        "JSON-RPC Error {$!error.code}: {$!error.message}"
    }
}

#| Message ID generator
class IdGenerator is export {
    has Int $!counter = 0;
    has Lock $!lock = Lock.new;

    method next(--> Int) {
        $!lock.protect: { ++$!counter }
    }
}
