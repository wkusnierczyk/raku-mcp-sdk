use v6.d;

#| Legacy SSE transport implementation (MCP spec 2024-11-05)
unit module MCP::Transport::SSE;

=begin pod
=head1 NAME

MCP::Transport::SSE - Legacy HTTP+SSE transport implementation

=head1 DESCRIPTION

Implements the legacy MCP SSE transport (spec 2024-11-05) for backwards
compatibility with older clients. The server provides two endpoints:

=item GET C</sse> — Client connects to receive SSE stream. First event is C<endpoint> with the POST URL.
=item POST C</message> — Client sends JSON-RPC messages here.

All server-to-client messages are sent as SSE C<message> events.

=head1 CLASS

=head2 SSEServerTransport

    my $transport = SSEServerTransport.new(
        host => 'localhost', port => 3001, scheme => 'https');

Attributes:

=item C<host> — Bind address (default: C<localhost>).
=item C<port> — Bind port (default: C<3001>).
=item C<scheme> — URL scheme for the endpoint URL sent to clients (default: C<http>).

=end pod

use MCP::JSONRPC;
use MCP::Transport::Base;
use JSON::Fast;
use MCP::OAuth;

class X::MCP::Transport::SSE is Exception {
    has Str $.message is required;
    method message(--> Str) { $!message }
}

class X::MCP::Transport::SSE::HTTP is X::MCP::Transport::SSE {
    method message(--> Str) { "HTTP error: {callsame}" }
}

class SSEServerTransport does MCP::Transport::Base::Transport is export {
    has Str $.host = '127.0.0.1';
    has Int $.port = 8080;
    has Str $.scheme = 'http';
    has Str $.sse-path = '/sse';
    has Str $.message-path = '/message';
    has @.allowed-origins = [];
    has $.oauth-handler;
    has Supplier $!incoming;
    has Supply $!incoming-supply;
    has Bool $!running = False;
    has $!server;
    has %!pending-responses; # id -> Promise::Vow
    has Supplier $!sse-supplier;
    has Bool $!client-connected = False;
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
                        self!emit-to-sse($msg);
                    }
                }
            }
        }
    }

    method close(--> Promise) {
        start {
            $!running = False;
            $!server.stop if $!server;
            $!sse-supplier.done if $!sse-supplier;
            $!client-connected = False;
            $!incoming.done if $!incoming;
        }
    }

    method is-connected(--> Bool) {
        $!running && $!client-connected
    }

    method !build-router() {
        my &route = self!cro-sub('Cro::HTTP::Router', 'route');
        my &get = self!cro-sub('Cro::HTTP::Router', 'get');
        my &post = self!cro-sub('Cro::HTTP::Router', 'post');
        my &content = self!cro-sub('Cro::HTTP::Router', 'content');
        my &request = self!cro-sub('Cro::HTTP::Router', 'request');
        my &response = self!cro-sub('Cro::HTTP::Router', 'response');

        my $self = self;
        my $sse-path = $!sse-path;
        my $message-path = $!message-path;

        # Extract path segments (e.g. '/sse' -> ['sse'], '/foo/bar' -> ['foo','bar'])
        my @sse-segments = $sse-path.split('/').grep(*.chars);
        my @msg-segments = $message-path.split('/').grep(*.chars);

        &route({
            &get(sub (*@) {
                my $req = &request();
                my $resp = &response();
                my $target = $req.target.split('?', 2)[0] // '';
                my @target-segs = $target.split('/').grep(*.chars);
                unless @target-segs eqv @sse-segments {
                    $resp.status = 404;
                    return;
                }
                unless $self!validate-origin($req, $resp, &content) {
                    return;
                }
                unless $self!validate-oauth($req, $resp, &content) {
                    return;
                }

                $self!setup-sse-stream();
                my $post-url = "{$self.scheme}://{$self.host}:{$self.port}{$message-path}";
                my $endpoint-event = "event: endpoint\ndata: $post-url\n\n";

                # Emit endpoint event after Supply is tapped by Cro
                my $supplier = $self!sse-supplier;
                start {
                    sleep 0.1;
                    $supplier.emit($endpoint-event.encode('utf-8'));
                }

                $resp.append-header('Content-Type', 'text/event-stream');
                $resp.append-header('Cache-Control', 'no-cache');
                $resp.append-header('Connection', 'keep-alive');
                &content('text/event-stream', $supplier.Supply);
            });

            &post(sub (*@) {
                my $req = &request();
                my $resp = &response();
                my $target = $req.target.split('?', 2)[0] // '';
                my @target-segs = $target.split('/').grep(*.chars);
                unless @target-segs eqv @msg-segments {
                    $resp.status = 404;
                    return;
                }
                unless $self!validate-origin($req, $resp, &content) {
                    return;
                }
                unless $self!validate-oauth($req, $resp, &content) {
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
                {
                    $msg = parse-message($json);
                    CATCH {
                        default {
                            $resp.status = 400;
                            &content('application/json', $self!jsonrpc-error("Invalid JSON-RPC message"));
                            return;
                        }
                    }
                }

                if $msg ~~ MCP::JSONRPC::Request {
                    my $p = Promise.new;
                    %!pending-responses{$msg.id} = $p.vow;
                    $!incoming.emit($msg);
                    my $response-msg = await $p;
                    $self!emit-to-sse($response-msg);
                } else {
                    $!incoming.emit($msg);
                }
                $resp.status = 202;
                &content('text/plain', '');
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

    method !validate-oauth($req, $resp, &content --> Bool) {
        return True unless $!oauth-handler.defined;
        {
            $!oauth-handler.validate-request($req);
            return True;
            CATCH {
                when X::MCP::OAuth::Unauthorized {
                    $resp.status = 401;
                    $resp.append-header('WWW-Authenticate', $!oauth-handler.www-authenticate-header);
                    &content('application/json', self!jsonrpc-error(.message));
                    return False;
                }
                when X::MCP::OAuth::Forbidden {
                    $resp.status = 403;
                    $resp.append-header('WWW-Authenticate', $!oauth-handler.www-authenticate-scope-header(.scopes));
                    &content('application/json', self!jsonrpc-error(.message));
                    return False;
                }
            }
        }
        False
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

    method !setup-sse-stream() {
        $!sse-supplier.done if $!sse-supplier;
        $!sse-supplier = Supplier.new;
        $!client-connected = True;
    }

    method !sse-supplier() { $!sse-supplier }

    method !respond-to-pending(MCP::JSONRPC::Response $resp) {
        return unless %!pending-responses{$resp.id}:exists;
        my $vow = %!pending-responses{$resp.id}:delete;
        $vow.keep($resp);
    }

    method !emit-to-sse(MCP::JSONRPC::Message $msg) {
        return unless $!sse-supplier;
        my $json = $msg.to-json;
        my @lines = $json.split("\n");
        my $data = @lines.map({ "data: $_" }).join("\n");
        $!sse-supplier.emit("event: message\n$data\n\n".encode('utf-8'));
    }

    method !jsonrpc-error(Str $message --> Hash) {
        {
            jsonrpc => '2.0',
            error => { code => -32600, message => $message }
        }
    }

    method !cro-class(Str $name) {
        require ::($name);
        return ::($name);
        CATCH {
            default {
                die X::MCP::Transport::SSE::HTTP.new(
                    message => "Cro::HTTP is required for SSE transport"
                );
            }
        }
    }

    method !cro-sub(Str $module, Str $name) {
        my $pkg = self!cro-class($module);
        my $exports = $pkg.WHO<EXPORT>.WHO<DEFAULT>.WHO;
        my $sub = $exports{'&' ~ $name} // $exports{'&term:<' ~ $name ~ '>'};
        die X::MCP::Transport::SSE::HTTP.new(
            message => "Missing $name in $module"
        ) unless $sub.defined && $sub ~~ Callable;
        $sub
    }
}

class SSEClientTransport does MCP::Transport::Base::Transport is export {
    has Str $.url is required;
    has Supplier $!incoming;
    has Supply $!incoming-supply;
    has Bool $!running = False;
    has Bool $!closing = False;
    has Str $!post-endpoint;
    has Lock $!emit-lock = Lock.new;
    has $!cro-client-class;

    method start(--> Supply) {
        return $!incoming-supply if $!running;
        $!incoming = Supplier.new;
        $!incoming-supply = $!incoming.Supply;
        $!running = True;
        self!connect-sse();
        $!incoming-supply;
    }

    method !connect-sse() {
        my $self = self;
        my $url = $!url;
        # Use Thread.start to avoid Raku thread pool scheduler issues with Cro
        Thread.start({
            my $client-class = (require ::('Cro::HTTP::Client'));
            my $client = $client-class.new;
            my $resp = $client.get($url, headers => [Accept => 'text/event-stream']).result;
            react {
                whenever $resp.body-byte-stream -> $chunk {
                    $self.handle-sse-chunk($chunk);
                }
            }
            CATCH { default { } }
        });
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        die X::MCP::Transport::SSE.new(
            message => "Not connected - no POST endpoint received"
        ) unless $!post-endpoint.defined;
        $!cro-client-class = self!cro-class('Cro::HTTP::Client') unless $!cro-client-class;
        my $post-client = $!cro-client-class.new;
        $post-client.post(
            $!post-endpoint,
            content-type => 'application/json',
            body => $msg.to-json
        );
    }

    method close(--> Promise) {
        start {
            $!closing = True;
            $!running = False;
            $!incoming.done if $!incoming;
        }
    }

    method is-connected(--> Bool) {
        $!running && $!post-endpoint.defined
    }

    #| Returns the POST endpoint URL once received from server
    method post-endpoint(--> Str) { $!post-endpoint }

    has Str $!sse-buffer = '';
    has Str $!sse-event-type = '';
    has @!sse-data;

    #| Handle an SSE chunk from the body stream
    method handle-sse-chunk(Blob $chunk) {
        $!sse-buffer ~= $chunk.decode('utf-8');
        loop {
            my $idx = $!sse-buffer.index("\n");
            last unless $idx.defined;
            my $line = $!sse-buffer.substr(0, $idx);
            $!sse-buffer = $idx + 1 < $!sse-buffer.chars ?? $!sse-buffer.substr($idx + 1) !! '';
            $line = $line.subst(/\r$/, '');
            if $line eq '' {
                if $!sse-event-type eq 'endpoint' && @!sse-data {
                    $!post-endpoint = @!sse-data.join("\n");
                } elsif ($!sse-event-type eq 'message' || $!sse-event-type eq '') && @!sse-data {
                    my $json = @!sse-data.join("\n");
                    self!emit-json($json);
                }
                $!sse-event-type = '';
                @!sse-data = ();
                next;
            }
            next if $line.substr(0,1) eq ':';
            my ($field, $value) = $line.split(':', 2);
            $value = $value.substr(1) if $value.defined && $value.starts-with(' ');
            if $field eq 'event' { $!sse-event-type = $value // '' }
            elsif $field eq 'data' { @!sse-data.push($value // '') }
        }
    }

    method !emit-json(Str $json) {
        return unless $json.defined && $json.chars;
        my $msg;
        {
            $msg = parse-message($json);
            CATCH { default { return } }
        }
        $!emit-lock.protect: { $!incoming.emit($msg) if $msg.defined }
    }

    method !cro-class(Str $name) {
        require ::($name);
        return ::($name);
        CATCH {
            default {
                die X::MCP::Transport::SSE::HTTP.new(
                    message => "Cro::HTTP is required for SSE transport"
                );
            }
        }
    }
}
