use v6.d;

unit module MCP::Client;

use MCP::Types;
need MCP::JSONRPC;
use MCP::Transport::Base;
use JSON::Fast;

#| Exception for client errors
class X::MCP::Client::Error is Exception {
    has MCP::JSONRPC::Error $.error is required;
    method message(--> Str) { $!error.message }
}

#| Exception for timeout
class X::MCP::Client::Timeout is Exception {
    has Str $.method is required;
    method message(--> Str) { "Request timed out: $!method" }
}

#| MCP Client implementation
class Client is export {
    has MCP::Types::Implementation $.info is required;
    has MCP::Types::ClientCapabilities $.capabilities = MCP::Types::ClientCapabilities.new;
    has MCP::Transport::Base::Transport $.transport is required;

    # State
    has Bool $!initialized = False;
    has MCP::Types::ServerCapabilities $!server-capabilities;
    has Str $!protocol-version;
    has Str $!server-instructions;
    has MCP::JSONRPC::IdGenerator $!id-gen = MCP::JSONRPC::IdGenerator.new;

    # Pending requests
    has %!pending-requests;  # id => Promise vow

    # Incoming message supply
    has Supply $!incoming;
    has Supplier $!notifications;

    #| Connect and initialize the client
    method connect(--> Promise) {
        start {
            $!notifications = Supplier.new;

            # Start transport and message handling
            $!incoming = $!transport.start;

            # Start message handler in background
            start {
                react {
                    whenever $!incoming -> $msg {
                        self!handle-message($msg);
                    }
                }
            }

            # Perform initialization handshake
            await self!initialize;

            True
        }
    }

    #| Initialize the connection
    method !initialize(--> Promise) {
        self.request('initialize', {
            protocolVersion => MCP::Types::LATEST_PROTOCOL_VERSION,
            capabilities => $!capabilities.Hash,
            clientInfo => $!info.Hash,
        }).then(-> $p {
            my $result = $p.result;
            $!protocol-version = $result<protocolVersion>;
            $!server-capabilities = MCP::Types::ServerCapabilities.from-hash($result<capabilities>);
            $!server-instructions = $result<instructions>;
            $!initialized = True;

            # Send initialized notification
            self.notify('initialized');

            $result
        })
    }

    #| Handle incoming messages
    method !handle-message($msg) {
        given $msg {
            when MCP::JSONRPC::Response {
                self!handle-response($msg);
            }
            when MCP::JSONRPC::Request {
                self!handle-request($msg);
            }
            when MCP::JSONRPC::Notification {
                $!notifications.emit($msg);
            }
        }
    }

    #| Handle response to our requests
    method !handle-response(MCP::JSONRPC::Response $resp) {
        if %!pending-requests{$resp.id}:exists {
            my $vow = %!pending-requests{$resp.id}:delete;
            if $resp.error {
                $vow.break(X::MCP::Client::Error.new(error => $resp.error));
            } else {
                $vow.keep($resp.result);
            }
        }
    }

    #| Handle incoming requests from server (sampling, etc.)
    method !handle-request(MCP::JSONRPC::Request $req) {
        # Handle server-initiated requests
        # For now, return method not found
        my $error = MCP::JSONRPC::Error.from-code(
            MCP::JSONRPC::MethodNotFound,
            "Client does not support method: {$req.method}"
        );
        my $response = MCP::JSONRPC::Response.error($req.id, $error);
        $!transport.send($response);
    }

    #| Get server capabilities
    method server-capabilities(--> MCP::Types::ServerCapabilities) {
        $!server-capabilities
    }

    #| Get server instructions
    method server-instructions(--> Str) {
        $!server-instructions
    }

    #| Get notifications supply
    method notifications(--> Supply) {
        $!notifications.Supply
    }

    #| List available tools
    method list-tools(--> Promise) {
        self.request('tools/list').then(-> $p {
            $p.result<tools>.map({ MCP::Types::Tool.from-hash($_) }).Array
        })
    }

    #| Call a tool
    method call-tool(Str $name, :%arguments --> Promise) {
        self.request('tools/call', {
            name => $name,
            arguments => %arguments,
        }).then(-> $p {
            MCP::Types::CallToolResult.new(
                content => $p.result<content>.map({
                    self!parse-content($_)
                }).Array,
                isError => $p.result<isError> // False,
            )
        })
    }

    #| List available resources
    method list-resources(--> Promise) {
        self.request('resources/list').then(-> $p {
            $p.result<resources>.map({ MCP::Types::Resource.from-hash($_) }).Array
        })
    }

    #| Read a resource
    method read-resource(Str $uri --> Promise) {
        self.request('resources/read', { uri => $uri }).then(-> $p {
            $p.result<contents>.map({
                MCP::Types::ResourceContents.new(
                    uri => $_<uri>,
                    mimeType => $_<mimeType>,
                    text => $_<text>,
                )
            }).Array
        })
    }

    #| Subscribe to resource updates
    method subscribe-resource(Str $uri --> Promise) {
        self.request('resources/subscribe', { uri => $uri })
    }

    #| Unsubscribe from resource updates
    method unsubscribe-resource(Str $uri --> Promise) {
        self.request('resources/unsubscribe', { uri => $uri })
    }

    #| List available prompts
    method list-prompts(--> Promise) {
        self.request('prompts/list').then(-> $p {
            $p.result<prompts>.map({ MCP::Types::Prompt.from-hash($_) }).Array
        })
    }

    #| Get a prompt with arguments
    method get-prompt(Str $name, :%arguments --> Promise) {
        self.request('prompts/get', {
            name => $name,
            arguments => %arguments,
        }).then(-> $p {
            {
                description => $p.result<description>,
                messages => $p.result<messages>.map({
                    MCP::Types::PromptMessage.new(
                        role => $_<role>,
                        content => self!parse-content($_<content>),
                    )
                }).Array,
            }
        })
    }

    #| Ping the server
    method ping(--> Promise) {
        self.request('ping').then({ True })
    }

    #| Send a request
    method request(Str $method, $params? --> Promise) {
        my $id = $!id-gen.next;
        my $p = Promise.new;
        %!pending-requests{$id} = $p.vow;

        my $request = MCP::JSONRPC::Request.new(:$id, :$method, :$params);
        $!transport.send($request);

        # Add timeout
        my $timeout = Promise.in(30).then({
            if %!pending-requests{$id}:exists {
                my $vow = %!pending-requests{$id}:delete;
                $vow.break(X::MCP::Client::Timeout.new(method => $method));
            }
        });

        $p
    }

    #| Send a notification
    method notify(Str $method, $params?) {
        my $notification = MCP::JSONRPC::Notification.new(:$method, :$params);
        $!transport.send($notification);
    }

    #| Close the connection
    method close(--> Promise) {
        $!transport.close
    }

    #| Parse content from response
    method !parse-content($content) {
        given $content<type> {
            when 'text' {
                MCP::Types::TextContent.new(text => $content<text>)
            }
            when 'image' {
                MCP::Types::ImageContent.new(
                    data => $content<data>,
                    mimeType => $content<mimeType>,
                )
            }
            when 'resource' {
                MCP::Types::EmbeddedResource.new(
                    resource => MCP::Types::ResourceContents.new(
                        uri => $content<resource><uri>,
                        mimeType => $content<resource><mimeType>,
                        text => $content<resource><text>,
                    )
                )
            }
            default {
                MCP::Types::TextContent.new(text => $content.Str)
            }
        }
    }
}
