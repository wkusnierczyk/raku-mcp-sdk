use v6.d;

#| MCP client implementation and convenience APIs
unit module MCP::Client;

=begin pod
=head1 NAME

MCP::Client - MCP client implementation

=head1 SYNOPSIS

    use MCP::Client;
    use MCP::Transport::Stdio;
    use MCP::Types;

    my $client = Client.new(
        info => MCP::Types::Implementation.new(name => 'my-client', version => '0.1'),
        transport => MCP::Transport::Stdio::StdioTransport.new
    );
    await $client.connect;

=head1 DESCRIPTION

Provides a high-level MCP client that performs initialization, sends requests,
and parses typed responses for tools, resources, and prompts.

=end pod

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
    has &.sampling-handler;

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
        given $req.method {
            when 'sampling/createMessage' {
                self!handle-sampling-request($req);
            }
            default {
                my $error = MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::MethodNotFound,
                    "Client does not support method: {$req.method}"
                );
                my $response = MCP::JSONRPC::Response.error($req.id, $error);
                $!transport.send($response);
            }
        }
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
    method list-tools(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('tools/list', %params || Nil).then(-> $p {
            {
                tools => $p.result<tools>.map({ MCP::Types::Tool.from-hash($_) }).Array,
                ($p.result<nextCursor> ?? (nextCursor => $p.result<nextCursor>) !! Empty),
            }
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
    method list-resources(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('resources/list', %params || Nil).then(-> $p {
            {
                resources => $p.result<resources>.map({ MCP::Types::Resource.from-hash($_) }).Array,
                ($p.result<nextCursor> ?? (nextCursor => $p.result<nextCursor>) !! Empty),
            }
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
    method list-prompts(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('prompts/list', %params || Nil).then(-> $p {
            {
                prompts => $p.result<prompts>.map({ MCP::Types::Prompt.from-hash($_) }).Array,
                ($p.result<nextCursor> ?? (nextCursor => $p.result<nextCursor>) !! Empty),
            }
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
        return $content if $content ~~ MCP::Types::Content;
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
            when 'audio' {
                MCP::Types::AudioContent.new(
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
            when 'resource_link' {
                MCP::Types::ResourceLink.new(
                    name => $content<name>,
                    uri => $content<uri>,
                    title => $content<title>,
                    description => $content<description>,
                    mimeType => $content<mimeType>,
                    size => $content<size>,
                )
            }
            when 'tool_use' {
                MCP::Types::ToolUseContent.new(
                    id => $content<id>,
                    name => $content<name>,
                    input => $content<input>,
                )
            }
            when 'tool_result' {
                my @items = ($content<content> // []).map({
                    self!parse-content($_)
                }).Array;
                MCP::Types::ToolResultContent.new(
                    toolUseId => $content<toolUseId>,
                    content => @items,
                    isError => $content<isError> // False,
                    structuredContent => $content<structuredContent>,
                    meta => $content<_meta>,
                )
            }
            default {
                MCP::Types::TextContent.new(text => $content.Str)
            }
        }
    }

    method !handle-sampling-request(MCP::JSONRPC::Request $req) {
        unless &!sampling-handler.defined {
            my $error = MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::MethodNotFound,
                "Client does not support method: {$req.method}"
            );
            my $response = MCP::JSONRPC::Response.error($req.id, $error);
            $!transport.send($response);
            return;
        }

        my $params = $req.params // {};
        my %params;
        if $params ~~ Associative {
            %params = $params;
        } elsif $params ~~ Pair {
            %params = Hash.new($params);
        } elsif $params ~~ Positional && $params.all ~~ Pair {
            %params = Hash.new(|$params);
        } else {
            die X::MCP::Client::Error.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InvalidParams,
                    "Invalid sampling params"
                )
            );
        }
        $! = Nil;
        my $result = try {
            self!validate-sampling-params(%params);
            my $out = &!sampling-handler(%params);
            if $out ~~ Promise {
                $out = $out.result;
            }
            $out
        };

        my $failure = $!;
        my $response;
        if $failure.defined {
            my $ex = $failure ~~ Failure ?? $failure.exception !! $failure;
            if $ex ~~ X::MCP::Client::Error {
                $response = MCP::JSONRPC::Response.error($req.id, $ex.error);
            } else {
                my $err = MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InternalError,
                    ($ex ?? $ex.message !! 'Sampling request failed')
                );
                $response = MCP::JSONRPC::Response.error($req.id, $err);
            }
        } else {
            my $payload = self!coerce-sampling-result($result);
            $response = MCP::JSONRPC::Response.success($req.id, $payload);
        }

        $!transport.send($response);
    }

    method !validate-sampling-params(%params) {
        my $tools = %params<tools>;
        my $tool-choice = %params<toolChoice>;
        if ($tools.defined || $tool-choice.defined) && !self!sampling-supports-tools {
            die X::MCP::Client::Error.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InvalidParams,
                    "Client does not support sampling tools"
                )
            );
        }
        if %params<messages>:exists && %params<messages>.defined {
            my $msgs = %params<messages>;
            my @messages = $msgs ~~ Positional ?? $msgs !! [$msgs];
            self!validate-sampling-messages(@messages);
        }
    }

    method !validate-sampling-messages(@messages) {
        my %pending;
        for @messages -> $msg {
            my $entry = $msg;
            if $entry ~~ Pair {
                $entry = Hash.new($entry);
            } elsif $entry ~~ Positional && $entry.all ~~ Pair {
                $entry = Hash.new(|$entry);
            } elsif $entry !~~ Associative {
                self!invalid-sampling("Invalid message format");
            }

            my $content = $entry<content>;
            next unless $content.defined;
            my @blocks = $content ~~ Positional ?? $content !! [$content];
            # Normalize blocks: convert Array of Pairs to Hash
            @blocks = @blocks.map({
                when Associative { $_ }
                when Positional { $_.all ~~ Pair ?? Hash.new(|$_) !! $_ }
                default { $_ }
            }).Array;
            my @tool-use = @blocks.grep({ $_ ~~ Associative && $_<type> eq 'tool_use' });
            my @tool-result = @blocks.grep({ $_ ~~ Associative && $_<type> eq 'tool_result' });

            if @tool-result {
                self!invalid-sampling("Tool result messages must contain only tool_result blocks")
                    if @tool-result.elems != @blocks.elems;
                self!invalid-sampling("Tool results must be in user messages")
                    unless $entry<role> eq 'user';
                if %pending.elems {
                    my @ids = @tool-result.map(*<toolUseId>);
                    for %pending.keys -> $id {
                        self!invalid-sampling("Tool result missing in request") unless $id eq any(@ids);
                    }
                    %pending = ();
                }
            }

            if @tool-use {
                for @tool-use -> $block {
                    %pending{$block<id>} = True if $block<id>.defined;
                }
            }

            if %pending.elems && $entry<role> eq 'assistant' {
                self!invalid-sampling("Tool result missing in request");
            }
        }
        if %pending.elems {
            self!invalid-sampling("Tool result missing in request");
        }
    }

    method !coerce-sampling-result($result --> Hash) {
        return $result.Hash if $result ~~ MCP::Types::CreateMessageResult;
        return $result if $result ~~ Hash;
        return {
            role => 'assistant',
            content => [ MCP::Types::TextContent.new(text => $result.Str).Hash ],
            model => 'unknown',
        }
    }

    method !sampling-supports-tools(--> Bool) {
        my $sampling = $!capabilities.sampling;
        $sampling.defined && $sampling.tools
    }

    method !invalid-sampling(Str $message) {
        die X::MCP::Client::Error.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                $message
            )
        );
    }
}
