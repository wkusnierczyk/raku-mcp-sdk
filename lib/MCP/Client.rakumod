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
    has &.elicitation-handler;  # Handler for elicitation requests
    has @.roots;  # Array of Root objects or Hashes with uri/name

    # Client-side extension declarations
    has %!extensions;  # name => { version => Str, settings => Hash }

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

    #| Register a client-side extension (included in capabilities during init)
    method register-extension(Str :$name!, Str :$version, Hash :$settings) {
        die "Extension name must contain '/': $name" unless $name.contains('/');
        %!extensions{$name} = {
            version  => $version // '',
            settings => $settings // {},
        };
    }

    #| Get extensions reported by the server
    method server-extensions(--> Hash) {
        return {} unless $!server-capabilities.defined && $!server-capabilities.experimental.defined;
        $!server-capabilities.experimental
    }

    #| Check if the server supports a specific extension
    method supports-extension(Str $name --> Bool) {
        self.server-extensions{$name}:exists
    }

    #| Get extensions negotiated with the server (supported by both sides)
    method negotiated-extensions(--> Hash) {
        my %server = self.server-extensions;
        my %negotiated;
        for %!extensions.kv -> $name, $config {
            %negotiated{$name} = %server{$name} if %server{$name}:exists;
        }
        %negotiated
    }

    #| Initialize the connection
    method !initialize(--> Promise) {
        # Build capabilities, adding roots if configured
        my %capabilities = $!capabilities.Hash;
        if @!roots {
            %capabilities<roots> = { listChanged => True };
        }
        # Add elicitation capability if handler is configured
        if &!elicitation-handler.defined {
            %capabilities<elicitation> //= {};
            %capabilities<elicitation><form> = {};
        }
        # Add extension declarations to experimental capability
        if %!extensions {
            my %experimental;
            for %!extensions.kv -> $ext-name, %ext {
                %experimental{$ext-name} = {
                    version  => %ext<version>,
                    settings => %ext<settings>,
                };
            }
            %capabilities<experimental> = %experimental;
        }

        self.request('initialize', {
            protocolVersion => MCP::Types::LATEST_PROTOCOL_VERSION,
            capabilities => %capabilities,
            clientInfo => $!info.Hash,
        }).then(-> $promise {
            my $result = $promise.result;
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
            when 'elicitation/create' {
                self!handle-elicitation-request($req);
            }
            when 'roots/list' {
                self!handle-roots-list-request($req);
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

    #| Handle roots/list request from server
    method !handle-roots-list-request(MCP::JSONRPC::Request $req) {
        my @root-hashes = @!roots.map({
            $_ ~~ MCP::Types::Root ?? $_.Hash !! $_
        }).Array;

        my $response = MCP::JSONRPC::Response.success($req.id, {
            roots => @root-hashes
        });
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
    method list-tools(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('tools/list', %params || Nil).then(-> $promise {
            {
                tools => $promise.result<tools>.map({ MCP::Types::Tool.from-hash($_) }).Array,
                ($promise.result<nextCursor> ?? (nextCursor => $promise.result<nextCursor>) !! Empty),
            }
        })
    }

    #| Call a tool
    method call-tool(Str $name, :%arguments --> Promise) {
        self.request('tools/call', {
            name => $name,
            arguments => %arguments,
        }).then(-> $promise {
            MCP::Types::CallToolResult.new(
                content => $promise.result<content>.map({
                    self!parse-content($_)
                }).Array,
                isError => $promise.result<isError> // False,
                structuredContent => $promise.result<structuredContent>,
            )
        })
    }

    #| List available resources
    method list-resources(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('resources/list', %params || Nil).then(-> $promise {
            {
                resources => $promise.result<resources>.map({ MCP::Types::Resource.from-hash($_) }).Array,
                ($promise.result<nextCursor> ?? (nextCursor => $promise.result<nextCursor>) !! Empty),
            }
        })
    }

    #| List available resource templates
    method list-resource-templates(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('resources/templates/list', %params || Nil).then(-> $promise {
            {
                resourceTemplates => $promise.result<resourceTemplates>.map({ MCP::Types::ResourceTemplate.from-hash($_) }).Array,
                ($promise.result<nextCursor> ?? (nextCursor => $promise.result<nextCursor>) !! Empty),
            }
        })
    }

    #| Read a resource
    method read-resource(Str $uri --> Promise) {
        self.request('resources/read', { uri => $uri }).then(-> $promise {
            $promise.result<contents>.map({
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
        self.request('prompts/list', %params || Nil).then(-> $promise {
            {
                prompts => $promise.result<prompts>.map({ MCP::Types::Prompt.from-hash($_) }).Array,
                ($promise.result<nextCursor> ?? (nextCursor => $promise.result<nextCursor>) !! Empty),
            }
        })
    }

    #| Get a prompt with arguments
    method get-prompt(Str $name, :%arguments --> Promise) {
        self.request('prompts/get', {
            name => $name,
            arguments => %arguments,
        }).then(-> $promise {
            {
                description => $promise.result<description>,
                messages => $promise.result<messages>.map({
                    MCP::Types::PromptMessage.new(
                        role => $_<role>,
                        content => self!parse-content($_<content>),
                    )
                }).Array,
            }
        })
    }

    #| Request completion for a prompt argument
    method complete-prompt(Str $prompt-name, Str :$argument-name!, Str :$value! --> Promise) {
        self.request('completion/complete', {
            ref => { type => 'ref/prompt', name => $prompt-name },
            argument => { name => $argument-name, value => $value },
        }).then(-> $promise {
            MCP::Types::CompletionResult.from-hash($promise.result<completion> // {})
        })
    }

    #| Request completion for a resource URI
    method complete-resource(Str $uri, Str :$argument-name!, Str :$value! --> Promise) {
        self.request('completion/complete', {
            ref => { type => 'ref/resource', uri => $uri },
            argument => { name => $argument-name, value => $value },
        }).then(-> $promise {
            MCP::Types::CompletionResult.from-hash($promise.result<completion> // {})
        })
    }

    #| Call a tool as an async task
    method call-tool-as-task(Str $name, :%arguments, Int :$ttl = 30000 --> Promise) {
        self.request('tools/call', {
            name => $name,
            arguments => %arguments,
            task => { ttl => $ttl },
        }).then(-> $promise {
            MCP::Types::Task.from-hash($promise.result<task>)
        })
    }

    #| Get task status
    method get-task(Str $task-id --> Promise) {
        self.request('tasks/get', { taskId => $task-id }).then(-> $promise {
            MCP::Types::Task.from-hash($promise.result)
        })
    }

    #| Get task result (blocks until terminal on server side)
    method get-task-result(Str $task-id --> Promise) {
        self.request('tasks/result', { taskId => $task-id }).then(-> $promise {
            $promise.result
        })
    }

    #| Cancel a task
    method cancel-task(Str $task-id --> Promise) {
        self.request('tasks/cancel', { taskId => $task-id }).then(-> $promise {
            MCP::Types::Task.from-hash($promise.result)
        })
    }

    #| List tasks
    method list-tasks(Str :$cursor --> Promise) {
        my %params = $cursor ?? (cursor => $cursor) !! ();
        self.request('tasks/list', %params || Nil).then(-> $promise {
            {
                tasks => ($promise.result<tasks> // []).map({ MCP::Types::Task.from-hash($_) }).Array,
                ($promise.result<nextCursor> ?? (nextCursor => $promise.result<nextCursor>) !! Empty),
            }
        })
    }

    #| Poll until task completes, then fetch result
    method await-task(Str $task-id, Int :$poll-ms = 1000 --> Promise) {
        start {
            loop {
                my $task = await self.get-task($task-id);
                if $task.is-terminal {
                    my $res = await self.get-task-result($task-id);
                    last $res;
                }
                await Promise.in($poll-ms / 1000);
            }
        }
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

        # Add timeout with cancellation notification
        my $timeout = Promise.in(30).then({
            if %!pending-requests{$id}:exists {
                # Send cancellation notification before breaking the promise
                self.notify('notifications/cancelled', {
                    requestId => $id,
                    reason => "Request timed out",
                });
                my $vow = %!pending-requests{$id}:delete;
                $vow.break(X::MCP::Client::Timeout.new(method => $method));
            }
        });

        $p
    }

    #| Cancel a pending request
    method cancel-request($request-id, Str :$reason) {
        self.notify('notifications/cancelled', {
            requestId => $request-id,
            ($reason ?? (reason => $reason) !! Empty),
        });
        # Also break the local promise if it exists
        if %!pending-requests{$request-id}:exists {
            my $vow = %!pending-requests{$request-id}:delete;
            $vow.break(X::MCP::Client::Error.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InternalError,
                    $reason // "Request cancelled"
                )
            ));
        }
    }

    #| Send a notification
    method notify(Str $method, $params?) {
        my $notification = MCP::JSONRPC::Notification.new(:$method, :$params);
        $!transport.send($notification);
    }

    #| Get current roots
    method get-roots(--> Array) {
        @!roots.map({
            $_ ~~ MCP::Types::Root ?? $_ !! MCP::Types::Root.from-hash($_)
        }).Array
    }

    #| Update roots and notify server
    method set-roots(@new-roots) {
        @!roots = @new-roots;
        self.notify('notifications/roots/list_changed');
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
            self!invalid-sampling("Client does not support sampling tools");
        }
        # Validate tool definitions if present
        if $tools.defined && $tools ~~ Positional {
            for $tools.list -> $t {
                my $entry = $t ~~ Associative ?? $t !! {};
                unless $entry<name>.defined {
                    self!invalid-sampling("Tool definition missing required 'name' field");
                }
                unless $entry<inputSchema>.defined {
                    self!invalid-sampling("Tool definition missing required 'inputSchema' field");
                }
            }
        }
        # Validate includeContext against capability
        if %params<includeContext>.defined && !self!sampling-supports-context {
            self!invalid-sampling("Client does not support sampling includeContext");
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
        if $result ~~ Hash {
            # Ensure stopReason is preserved
            my %h = $result;
            %h<role> //= 'assistant';
            %h<model> //= 'unknown';
            return %h;
        }
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

    method !sampling-supports-context(--> Bool) {
        my $sampling = $!capabilities.sampling;
        $sampling.defined && $sampling.context
    }

    method !invalid-sampling(Str $message) {
        die X::MCP::Client::Error.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                $message
            )
        );
    }

    #| Handle elicitation/create request from server
    method !handle-elicitation-request(MCP::JSONRPC::Request $req) {
        unless &!elicitation-handler.defined {
            my $error = MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::MethodNotFound,
                "Client does not support elicitation"
            );
            my $response = MCP::JSONRPC::Response.error($req.id, $error);
            $!transport.send($response);
            return;
        }

        my $params = $req.params // {};
        my %params = $params ~~ Hash ?? $params !! {};

        # Validate mode is supported
        my $mode = %params<mode> // 'form';
        if $mode eq 'url' && !self!elicitation-supports-url {
            my $error = MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Client does not support URL mode elicitation"
            );
            my $response = MCP::JSONRPC::Response.error($req.id, $error);
            $!transport.send($response);
            return;
        }

        $! = Nil;
        my $result = try {
            my $out = &!elicitation-handler(%params);
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
                    ($ex ?? $ex.message !! 'Elicitation request failed')
                );
                $response = MCP::JSONRPC::Response.error($req.id, $err);
            }
        } else {
            my $payload = self!coerce-elicitation-result($result);
            $response = MCP::JSONRPC::Response.success($req.id, $payload);
        }

        $!transport.send($response);
    }

    #| Convert elicitation handler result to response payload
    method !coerce-elicitation-result($result --> Hash) {
        return $result.Hash if $result ~~ MCP::Types::ElicitationResponse;
        return $result if $result ~~ Hash && ($result<action>:exists);
        # Default to cancel if result is not in expected format
        return { action => 'cancel' }
    }

    #| Check if URL mode elicitation is supported
    method !elicitation-supports-url(--> Bool) {
        my $elicitation = $!capabilities.elicitation;
        $elicitation.defined && $elicitation.supports-url
    }
}
