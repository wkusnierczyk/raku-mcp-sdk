use v6.d;

#| Streamable HTTP transport implementation
unit module MCP::Transport::StreamableHTTP;

=begin pod
=head1 NAME

MCP::Transport::StreamableHTTP - Streamable HTTP transport implementation

=head1 DESCRIPTION

Implements the MCP Streamable HTTP transport using Cro::HTTP. Supports
client-side POST/GET with SSE, and server-side handling of POST requests
plus optional server-initiated SSE streams.

=end pod

use MCP::JSONRPC;
use MCP::Transport::Base;
need MCP::Types;
use JSON::Fast;
# Cro::HTTP is loaded dynamically to keep this transport optional.

my constant DEFAULT_PROTOCOL_FALLBACK = '2025-11-25';
my constant DEFAULT_ACCEPT_POST = 'application/json, text/event-stream';
my constant DEFAULT_ACCEPT_SSE = 'text/event-stream';

class X::MCP::Transport::StreamableHTTP is Exception {
    has Str $.message is required;
    method message(--> Str) { $!message }
}

class X::MCP::Transport::StreamableHTTP::Protocol is X::MCP::Transport::StreamableHTTP {
    method message(--> Str) { "Protocol error: {callsame}" }
}

class X::MCP::Transport::StreamableHTTP::HTTP is X::MCP::Transport::StreamableHTTP {
    method message(--> Str) { "HTTP error: {callsame}" }
}

class MCP::Transport::StreamableHTTP::Stream {
    has Str $.id is required;
    has Supplier $.supplier is required;
    has Int $!seq = 0;
    has Int $.history-size = 200;
    has @!history; # [{ id => Str, data => Str }]

    method emit-priming() {
        $!seq++;
        my $id = "{$!id}:{$!seq}";
        my $payload = "id: $id\ndata:\n\n";
        self!store($id, $payload);
        $!supplier.emit($payload);
        $id
    }

    method emit-message(Str $json) {
        $!seq++;
        my $id = "{$!id}:{$!seq}";
        my $payload = self!sse-payload($id, $json);
        self!store($id, $payload);
        $!supplier.emit($payload);
        $id
    }

    method replay-from(Int $seq) {
        for @!history -> %event {
            my ($sid, $sseq) = %event<id>.split(':', 2);
            next unless $sid eq $!id;
            next unless $sseq.Int > $seq;
            $!supplier.emit(%event<data>);
        }
    }

    method !sse-payload(Str $id, Str $json --> Str) {
        my @lines = $json.split("\n");
        my $data = @lines.map({ "data: $_" }).join("\n");
        "id: $id\n$data\n\n"
    }

    method !store(Str $id, Str $payload) {
        @!history.push({ id => $id, data => $payload });
        if @!history.elems > $!history-size {
            @!history.shift;
        }
    }
}

class StreamableHTTPServerTransport does MCP::Transport::Base::Transport is export {
    has Str $.host = '127.0.0.1';
    has Int $.port = 8080;
    has Str $.path = '/mcp';
    has @.allowed-origins = [];
    has @.protocol-versions = [MCP::Types::LATEST_PROTOCOL_VERSION, '2025-11-25'];
    has Bool $.require-session = False;
    has Bool $.allow-session-delete = True;
    has Int $.stream-history-size = 200;
    has Supplier $!incoming;
    has Supply $!incoming-supply;
    has Bool $!running = False;
    has $!server;
    has %!pending-responses; # id -> { vow => Promise::Vow, init => Bool }
    has %!streams; # id -> Stream
    has @!stream-order;
    has Int $!stream-rr = 0;
    has Str $!session-id;
    has Lock $!send-lock = Lock.new;

    method start(--> Supply) {
        return $!incoming-supply if $!running;

        $!incoming = Supplier.new;
        $!incoming-supply = $!incoming.Supply;
        $!running = True;

        my $application = self!build-router;
        my $server-class = self!cro-class('Cro::HTTP::Server');
        $!server = $server-class.new(
            host => $!host,
            port => $!port,
            application => $application,
        );
        $!server.start;
        $!incoming-supply;
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        start {
            $!send-lock.protect: {
                given $msg {
                    when MCP::JSONRPC::Response {
                        self!respond-to-pending($msg);
                    }
                    default {
                        self!emit-to-stream($msg);
                    }
                }
            }
        }
    }

    method close(--> Promise) {
        start {
            $!running = False;
            $!server.stop if $!server;
            for %!streams.values -> $stream {
                $stream.supplier.done;
            }
            $!incoming.done if $!incoming;
        }
    }

    method is-connected(--> Bool) {
        $!running
    }

    method !build-router() {
        my &route = self!cro-sub('Cro::HTTP::Router', 'route');
        my &get = self!cro-sub('Cro::HTTP::Router', 'get');
        my &post = self!cro-sub('Cro::HTTP::Router', 'post');
        my &delete = self!cro-sub('Cro::HTTP::Router', 'delete');
        my &content = self!cro-sub('Cro::HTTP::Router', 'content');
        my &request = self!cro-sub('Cro::HTTP::Router', 'request');
        my &response = self!cro-sub('Cro::HTTP::Router', 'response');

        my $self = self;
        my $path = $!path;
        &route({
            my sub path-ok($req --> Bool) {
                my $target = $req.target.split('?', 2)[0] // '';
                $target eq $path
            }

            sub validate-request($req, $resp, &content --> Bool) {
                return False unless path-ok($req);
                return False unless $self!validate-origin($req, $resp, &content);
                return False unless $self!validate-protocol($req, $resp, &content);
                return False unless $self!validate-session($req, $resp, &content);
                return True;
            }

            &get(-> *@ {
                my $req = &request();
                my $resp = &response();
                unless validate-request($req, $resp, &content) {
                    return;
                }
                unless $self!accepts-sse($req) {
                    $resp.status = 406;
                    return;
                }
                my $last-event-id = $req.header('Last-Event-ID');
                my $stream;
                if $last-event-id.defined && $last-event-id.chars {
                    # Attempt to resume an existing stream
                    $stream = $self!resume-stream($last-event-id);
                    unless $stream.defined {
                        # Stream not found or cannot be resumed
                        $resp.status = 204;
                        return;
                    }
                } else {
                    $stream = $self!open-stream;
                }
                $resp.append-header('Content-Type', 'text/event-stream');
                $resp.append-header('Cache-Control', 'no-cache');
                $resp.append-header('Connection', 'keep-alive');
                $resp.append-header('MCP-Session-Id', $self!session-id) if $self!session-id;
                &content('text/event-stream', $stream.supplier.Supply);
            });

            &post(-> *@ {
                my $req = &request();
                my $resp = &response();
                unless validate-request($req, $resp, &content) {
                    return;
                }
                unless $self!accepts-post($req) {
                    $resp.status = 406;
                    return;
                }
                unless $self!valid-content-type($req) {
                    $resp.status = 415;
                    &content('application/json', $self!jsonrpc-error("Unsupported Content-Type"));
                    return;
                }

                my $body = await $req.body;
                my Str $json = $self!coerce-body-json($body);
                my $msg;
                try {
                    $msg = parse-message($json);
                    CATCH {
                        default {
                            $resp.status = 400;
                            &content('application/json', $self!jsonrpc-error("Invalid JSON-RPC message"));
                            return;
                        }
                    }
                }

                given $msg {
                    when MCP::JSONRPC::Request {
                        my $p = Promise.new;
                        %!pending-responses{$msg.id} = {
                            vow => $p.vow,
                            init => ($msg.method eq 'initialize')
                        };
                        $!incoming.emit($msg);
                        my %payload = await $p;
                        for %payload<headers>.kv -> $k, $v {
                            $resp.append-header($k, $v);
                        }
                        $resp.status = 200;
                        &content('application/json', %payload<body>);
                    }
                    default {
                        $!incoming.emit($msg);
                        $resp.status = 202;
                        return;
                    }
                }
            });

            &delete(-> *@ {
                my $req = &request();
                my $resp = &response();
                unless validate-request($req, $resp, &content) {
                    return;
                }
                unless $self!allow-session-delete {
                    $resp.status = 405;
                    return;
                }
                if $self!require-session {
                    my $sid = $req.header('MCP-Session-Id');
                    unless $sid && $sid eq $self!session-id {
                        $resp.status = 404;
                        return;
                    }
                }
                $self!terminate-session();
                $resp.status = 204;
                return;
            });
        })
    }

    method !validate-origin($req, $resp, &content --> Bool) {
        my $origin = $req.header('Origin');
        return True unless $origin.defined;
        if @!allowed-origins.elems == 0 {
            $resp.status = 403;
            &content('application/json', self!jsonrpc-error("Invalid Origin"));
            return False;
        }
        if $origin eq any(@!allowed-origins) {
            return True;
        }
        $resp.status = 403;
        &content('application/json', self!jsonrpc-error("Invalid Origin"));
        False
    }

    method !validate-protocol($req, $resp, &content --> Bool) {
        my $ver = $req.header('MCP-Protocol-Version') // DEFAULT_PROTOCOL_FALLBACK;
        if $ver eq any(@!protocol-versions) {
            return True;
        }
        $resp.status = 400;
        &content('application/json', self!jsonrpc-error("Unsupported MCP-Protocol-Version"));
        False
    }

    method !validate-session($req, $resp, &content --> Bool) {
        return True unless $!require-session;
        # When no session exists yet, allow the request (initialization phase)
        return True unless $!session-id.defined;
        # Once a session is established, require matching session ID
        my $sid = $req.header('MCP-Session-Id');
        if $sid && $sid eq $!session-id {
            return True;
        }
        # Per MCP spec: 400 for missing session ID, 404 for unknown session
        if !$sid.defined || $sid eq '' {
            $resp.status = 400;
            &content('application/json', self!jsonrpc-error("Missing MCP-Session-Id header"));
        } else {
            $resp.status = 404;
            &content('application/json', self!jsonrpc-error("Unknown MCP session"));
        }
        False
    }

    method !accepts-post($req --> Bool) {
        my $accept = $req.header('Accept') // '';
        $accept.contains('application/json') && $accept.contains('text/event-stream')
    }

    method !accepts-sse($req --> Bool) {
        my $accept = $req.header('Accept') // '';
        $accept.contains('text/event-stream')
    }

    method !valid-content-type($req --> Bool) {
        my $ct = $req.header('Content-Type') // '';
        $ct.contains('application/json')
    }

    method !coerce-body-json($body --> Str) {
        given $body {
            when Blob|Buf { $body.decode('utf-8') }
            when Str { $body }
            when Hash|Array { to-json($body) }
            default { $body.Str }
        }
    }

    method !respond-to-pending(MCP::JSONRPC::Response $resp) {
        return unless %!pending-responses{$resp.id}:exists;
        my %entry = %!pending-responses{$resp.id}:delete;
        my %headers;
        if %entry<init> {
            $!session-id //= self!new-session-id;
            %headers<MCP-Session-Id> = $!session-id if $!session-id;
        }
        %entry<vow>.keep({
            body => $resp.Hash,
            headers => %headers,
        });
    }

    method !emit-to-stream(MCP::JSONRPC::Message $msg) {
        return unless @!stream-order;
        my $json = $msg.to-json;
        my $stream-id = @!stream-order[$!stream-rr % @!stream-order.elems];
        $!stream-rr++;
        my $stream = %!streams{$stream-id} or return;
        $stream.emit-message($json);
    }

    method !open-stream() {
        my $id = self!new-stream-id;
        my $supplier = Supplier.new;
        my $stream = MCP::Transport::StreamableHTTP::Stream.new(
            id => $id,
            supplier => $supplier,
            history-size => $!stream-history-size
        );
        %!streams{$id} = $stream;
        @!stream-order.push($id);
        $stream.emit-priming;
        $stream
    }

    method !resume-stream(Str $last-event-id) {
        # Event ID format: "streamId:seq"
        my ($stream-id, $seq-str) = $last-event-id.split(':', 2);
        return Nil unless $stream-id.defined && $seq-str.defined;
        my $stream = %!streams{$stream-id};
        return Nil unless $stream.defined;
        my $seq = $seq-str.Int // return Nil;
        # Replay events after the given sequence number
        $stream.replay-from($seq);
        $stream
    }

    method !new-stream-id(--> Str) {
        my $rand = (0..^16).map({ <a b c d e f 0 1 2 3 4 5 6 7 8 9>.pick }).join;
        "s{$rand}"
    }

    method !new-session-id(--> Str) {
        my $rand = (0..^31).map({ <a b c d e f 0 1 2 3 4 5 6 7 8 9>.pick }).join;
        "session-$rand"
    }

    method !session-id(--> Str) { $!session-id }
    method !require-session(--> Bool) { $!require-session }
    method !allow-session-delete(--> Bool) { $!allow-session-delete }

    method !terminate-session() {
        $!session-id = Nil;
    }

    method !jsonrpc-error(Str $message --> Hash) {
        {
            jsonrpc => '2.0',
            error => { code => -32600, message => $message }
        }
    }

    method !cro-class(Str $name) {
        try {
            require ::($name);
            return ::($name);
        }
        CATCH {
            default {
                die X::MCP::Transport::StreamableHTTP::HTTP.new(
                    message => "Cro::HTTP is required for StreamableHTTP transport"
                );
            }
        }
    }

    method !cro-sub(Str $module, Str $name) {
        my $pkg = self!cro-class($module);
        my &sub = $pkg.WHO{$name};
        die X::MCP::Transport::StreamableHTTP::HTTP.new(
            message => "Missing $name in $module"
        ) unless &sub.defined;
        &sub
    }
}

class StreamableHTTPClientTransport does MCP::Transport::Base::Transport is export {
    has Str $.endpoint is required;
    has Str $.protocol-version = MCP::Types::LATEST_PROTOCOL_VERSION;
    has $.client;
    has Supplier $!incoming;
    has Supply $!incoming-supply;
    has Bool $!running = False;
    has Bool $!closing = False;
    has Str $!session-id;
    has Str $!last-event-id;
    has Int $!retry-ms = 1000;
    has Lock $!emit-lock = Lock.new;

    method start(--> Supply) {
        return $!incoming-supply if $!running;
        $!incoming = Supplier.new;
        $!incoming-supply = $!incoming.Supply;
        $!running = True;
        $!client //= self!cro-client;
        start {
            self!sse-loop;
        }
        $!incoming-supply;
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        start {
            my $headers = [
                Accept => DEFAULT_ACCEPT_POST,
                'MCP-Protocol-Version' => $!protocol-version,
            ];
            if $!session-id.defined {
                $headers.push('MCP-Session-Id' => $!session-id);
            }
            $!client //= self!cro-client;
            my $resp = await $!client.post(
                $!endpoint,
                headers => $headers,
                content-type => 'application/json',
                body => $msg.to-json
            );

            self!capture-session-id($resp);
            return if $resp.status == 202;

            # Per MCP spec: 404 means session expired, must reinitialize
            if $resp.status == 404 && $!session-id.defined {
                $!session-id = Nil;
                die X::MCP::Transport::StreamableHTTP::Protocol.new(
                    message => "Session expired, reinitialization required"
                );
            }

            my $ctype = $resp.header('Content-Type') // '';
            if $ctype.contains('text/event-stream') {
                await self!consume-sse($resp.body-byte-stream);
            } else {
                my $body = await $resp.body;
                if $body.defined {
                    my $json =
                        $body ~~ Str ?? $body
                        !! $body ~~ Hash|Array ?? to-json($body)
                        !! $body ~~ Blob|Buf ?? $body.decode('utf-8')
                        !! $body.Str;
                    self!emit-json($json);
                }
            }
        }
    }

    method close(--> Promise) {
        start {
            $!closing = True;
            $!running = False;
            $!incoming.done if $!incoming;
        }
    }

    #| Terminate the session by sending DELETE request
    method terminate-session(--> Promise) {
        start {
            return unless $!session-id.defined;
            my @headers = (
                'MCP-Protocol-Version' => $!protocol-version,
                'MCP-Session-Id' => $!session-id,
            );
            $!client //= self!cro-client;
            try {
                my $resp = await $!client.delete($!endpoint, headers => @headers);
                if $resp.status == 204 || $resp.status == 200 {
                    $!session-id = Nil;
                    True
                } else {
                    False
                }
                CATCH { default { False } }
            }
        }
    }

    method is-connected(--> Bool) {
        $!running
    }

    method !sse-loop() {
        loop {
            last if $!closing;
            try {
                my @headers = (
                    Accept => DEFAULT_ACCEPT_SSE,
                    'MCP-Protocol-Version' => $!protocol-version,
                );
                if $!session-id.defined {
                    @headers.push('MCP-Session-Id' => $!session-id);
                }
                if $!last-event-id.defined {
                    @headers.push('Last-Event-ID' => $!last-event-id);
                }
                $!client //= self!cro-client;
                my $resp = await $!client.get($!endpoint, headers => @headers);
                self!capture-session-id($resp);
                if $resp.status == 405 {
                    last;
                }
                if $resp.status >= 400 {
                    last;
                }
                await self!consume-sse($resp.body-byte-stream);
            }
            CATCH { default { } }
            last if $!closing;
            sleep $!retry-ms / 1000;
        }
    }

    method !consume-sse(Supply $bytes --> Promise) {
        start {
            my $buffer = '';
            my $event-id;
            my @data;
            my $retry;

            react {
                whenever $bytes -> $chunk {
                    $buffer ~= $chunk.decode('utf-8');
                    loop {
                        my $idx = $buffer.index("\n");
                        last unless $idx.defined;
                        my $line = $buffer.substr(0, $idx);
                        $buffer = $buffer.substr($idx + 1);
                        $line = $line.subst(/\r$/, '');
                        if $line eq '' {
                            if @data {
                                my $data = @data.join("\n");
                                self!emit-json($data);
                            }
                            $event-id.defined && ($!last-event-id = $event-id);
                            @data = ();
                            $event-id = Nil;
                            $retry = Nil;
                            next;
                        }
                        next if $line.substr(0,1) eq ':';
                        my ($field, $value) = $line.split(':', 2);
                        $value = $value.subst(/^ /, '') if $value.defined;
                        given $field {
                            when 'id' { $event-id = $value }
                            when 'data' { @data.push($value // '') }
                            when 'retry' {
                                $retry = $value.Int;
                                $!retry-ms = $retry if $retry > 0;
                            }
                            default { }
                        }
                    }
                }
            }
        }
    }

    method !emit-json(Str $json) {
        return unless $json.defined && $json.chars;
        my $msg;
        try {
            $msg = parse-message($json);
            CATCH { default { return } }
        }
        $!emit-lock.protect: { $!incoming.emit($msg) if $msg.defined }
    }

    method !capture-session-id($resp) {
        my $sid = $resp.header('MCP-Session-Id');
        $!session-id = $sid if $sid.defined && $sid.chars;
    }

    method !cro-client() {
        my $client-class = self!cro-class('Cro::HTTP::Client');
        $client-class.new
    }

    method !cro-class(Str $name) {
        try {
            require ::($name);
            return ::($name);
        }
        CATCH {
            default {
                die X::MCP::Transport::StreamableHTTP::HTTP.new(
                    message => "Cro::HTTP is required for StreamableHTTP transport"
                );
            }
        }
    }
}
