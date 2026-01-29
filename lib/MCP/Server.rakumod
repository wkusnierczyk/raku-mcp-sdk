use v6.d;

#| MCP server implementation and request dispatch
unit module MCP::Server;

=begin pod
=head1 NAME

MCP::Server - MCP server implementation

=head1 SYNOPSIS

    use MCP::Server;
    use MCP::Transport::Stdio;
    use MCP::Types;

    my $server = Server.new(
        info => MCP::Types::Implementation.new(name => 'srv', version => '0.1'),
        transport => MCP::Transport::Stdio::StdioTransport.new
    );
    await $server.serve;

=head1 DESCRIPTION

Implements the MCP server-side protocol: initialization, request dispatch,
tool/resource/prompt registration, and JSON-RPC message handling.

=head1 CONSTRUCTOR

=head2 Server.new(:$info!, :$transport!, :$instructions, :$page-size)

Creates a new MCP server.

=item C<info> — C<MCP::Types::Implementation> with server name and version.
=item C<transport> — A transport object (e.g., C<StdioTransport>, C<StreamableHTTPServerTransport>).
=item C<instructions> — Optional instructions string sent to clients during initialization.
=item C<page-size> — Page size for paginated list responses (default: 50).

=head1 REGISTRATION METHODS

=head2 method add-tool

    $server.add-tool($registered-tool);
    $server.add-tool(name => 'add', description => 'Add numbers',
        schema => %schema, handler => -> :%params { ... });

Register a tool by passing a C<RegisteredTool> object or named parameters.
The handler receives C<:%params> and returns a string, content object, or
C<CallToolResult>.

=head2 method add-resource

    $server.add-resource($registered-resource);
    $server.add-resource(uri => 'data://x', name => 'X',
        mimeType => 'text/plain', reader => { 'content' });

Register a resource by object or named parameters. The reader block returns
the resource content.

=head2 method add-resource-template

    $server.add-resource-template($registered-template);
    $server.add-resource-template(name => 'files', uriTemplate => 'file:///{path}',
        reader => -> :$path { $path.IO.slurp });

Register a URI template that matches resource reads dynamically.

=head2 method add-prompt

    $server.add-prompt($registered-prompt);
    $server.add-prompt(name => 'summarize', description => 'Summarize text',
        arguments => [{ name => 'text', required => True }],
        generator => -> :%params { user-message(%params<text>) });

Register a prompt template. The generator returns prompt messages.

=head2 method add-prompt-completer(Str $prompt-name, &completer)

Register an autocomplete handler for a prompt argument. The completer
receives the argument name and partial value, returns a list of suggestions.

=head2 method add-resource-completer(Str $uri, &completer)

Register an autocomplete handler for a resource URI.

=head2 method register-extension(:$name!, :$version, :%settings, :%methods, :%notifications)

Register a server-side extension with custom method and notification handlers.

=head1 LIFECYCLE

=head2 method serve(--> Promise)

Start the server event loop. Listens on the transport, dispatches incoming
messages, and returns a Promise that resolves when the transport closes.

    await $server.serve;

=head2 method capabilities(--> ServerCapabilities)

Returns the server's capability object based on registered handlers.

=head1 OUTBOUND COMMUNICATION

=head2 method request(Str $method, $params? --> Promise)

Send a JSON-RPC request to the client (e.g., for sampling or roots).

=head2 method notify(Str $method, $params?)

Send a JSON-RPC notification to the client.

=head2 method log(LogLevel $level, $data, :$logger)

Send a log notification to the client if the level meets the configured threshold.

=head2 method progress(Num $progress, :$total, :$message, :$token)

Send a progress notification for the current request.

=head2 method create-message(...)

Request the client to sample an LLM response (createMessage). Accepts
messages, model preferences, system prompt, and other sampling parameters.

=head2 method elicit(:$message!, :%schema! --> Promise)

Request structured input from the user via form elicitation.

=head2 method list-roots(--> Promise)

Request the client's root URIs.

=head1 RESOURCE NOTIFICATIONS

=head2 method notify-resource-updated(Str $uri)

Notify subscribed clients that a resource has changed.

=head2 method notify-resources-list-changed()

Notify clients that the list of available resources has changed.

=head2 method notify-prompts-list-changed()

Notify clients that the list of available prompts has changed.

=head1 CANCELLATION

=head2 method is-cancelled($request-id --> Bool)

Check whether a request has been cancelled by the client.

=head2 method cancel-request($request-id, :$reason)

Cancel an outbound pending request.

=end pod

use MCP::Types;
need MCP::JSONRPC;
use MCP::Transport::Base;
use MCP::Server::Tool;
use MCP::Server::Resource;
use MCP::Server::Prompt;
use JSON::Fast;
use MIME::Base64;

#| Exception for MCP JSON-RPC errors
class X::MCP::JSONRPC is Exception is export {
    has MCP::JSONRPC::Error $.error is required;
    method message(--> Str) { $!error.message }
}

#| MCP Server implementation
class Server is export {
    has MCP::Types::Implementation $.info is required;
    has MCP::Transport::Base::Transport $.transport is required;
    has Str $.instructions;
    has Int $.page-size = 50;

    # Registered handlers
    has %!tools;      # name => RegisteredTool
    has %!resources;  # uri => RegisteredResource
    has %!prompts;    # name => RegisteredPrompt
    has %!resource-templates; # name => RegisteredResourceTemplate
    has %!completers; # "prompt:name" or "resource:uri" => &completer

    # State
    has Bool $!initialized = False;
    has MCP::Types::ClientCapabilities $!client-capabilities;
    has Str $!protocol-version;
    has MCP::JSONRPC::IdGenerator $!id-gen = MCP::JSONRPC::IdGenerator.new;

    # Pending request handlers for bidirectional communication
    has %!pending-requests;  # id => Promise vow

    # In-flight request tracking for cancellation support
    has %!in-flight-requests;  # id => { cancelled => Bool }
    has Lock $!flight-lock = Lock.new;

    # Resource subscriptions tracking
    has %!subscriptions;  # uri => True (SetHash-like)

    # Task registry
    has %!tasks;  # taskId => { task => Task, promise => Promise, result => Any }
    has Lock $!task-lock = Lock.new;
    has Int $!default-poll-interval = 1000;

    # Extension registry
    has %!extensions;  # name => { version => Str, settings => Hash, methods => Hash of &handler, notifications => Hash of &handler }

    # Logging level (default: Debug - emit all log messages)
    has MCP::Types::LogLevel $!log-level = MCP::Types::Debug;

    #| Encode an offset into a cursor string
    method !encode-cursor(Int $offset --> Str) {
        MIME::Base64.encode(to-json({ offset => $offset }).encode, :str)
    }

    #| Decode a cursor string into an offset
    method !decode-cursor(Str $cursor --> Int) {
        my $json = MIME::Base64.decode($cursor, :bin).decode;
        from-json($json)<offset>
    }

    #| Paginate a list of items
    method !paginate(@items, $params, Str :$key! --> Hash) {
        my Int $offset = 0;

        if $params && $params<cursor> {
            try {
                $offset = self!decode-cursor($params<cursor>);
                CATCH {
                    default {
                        die X::MCP::JSONRPC.new(
                            error => MCP::JSONRPC::Error.from-code(
                                MCP::JSONRPC::InvalidParams,
                                "Invalid cursor"
                            )
                        );
                    }
                }
            }
        }

        my @page = @items[$offset ..^ min($offset + $!page-size, +@items)];
        my %result = $key => @page;

        my $next-offset = $offset + $!page-size;
        if $next-offset < +@items {
            %result<nextCursor> = self!encode-cursor($next-offset);
        }

        %result
    }

    #| Add a tool to the server
    multi method add-tool(MCP::Server::Tool::RegisteredTool $tool) {
        %!tools{$tool.name} = $tool;
    }

    #| Add a tool using named parameters
    multi method add-tool(
        Str :$name!,
        Str :$description,
        Hash :$schema,
        Hash :$output-schema,
        :&handler!
    ) {
        MCP::Server::Tool::validate-tool-name($name);
        my $builder = MCP::Server::Tool::tool()
            .name($name)
            .description($description // '')
            .schema($schema // { type => 'object', properties => {} })
            .handler(&handler);
        $builder.output-schema($output-schema) if $output-schema;
        self.add-tool($builder.build);
    }

    #| Add a resource to the server
    multi method add-resource(MCP::Server::Resource::RegisteredResource $resource) {
        %!resources{$resource.uri} = $resource;
    }

    #| Add a resource using named parameters
    multi method add-resource(
        Str :$uri!,
        Str :$name!,
        Str :$description,
        Str :$mimeType,
        :&reader!
    ) {
        my $resource = MCP::Server::Resource::resource()
            .uri($uri)
            .name($name)
            .description($description // '')
            .mimeType($mimeType // 'text/plain')
            .reader(&reader)
            .build;
        self.add-resource($resource);
    }

    #| Add a resource template to the server
    multi method add-resource-template(MCP::Server::Resource::RegisteredResourceTemplate $template) {
        %!resource-templates{$template.name} = $template;
    }

    #| Add a resource template using named parameters
    multi method add-resource-template(
        Str :$uri-template!,
        Str :$name!,
        Str :$description,
        Str :$mimeType,
        :&reader!
    ) {
        my $template = MCP::Server::Resource::resource-template()
            .uri-template($uri-template)
            .name($name)
            .description($description // '')
            .mimeType($mimeType // 'text/plain')
            .reader(&reader)
            .build;
        self.add-resource-template($template);
    }

    #| Remove a resource template by name
    method remove-resource-template(Str $name) {
        %!resource-templates{$name}:delete;
    }

    #| Add a prompt to the server
    multi method add-prompt(MCP::Server::Prompt::RegisteredPrompt $prompt) {
        %!prompts{$prompt.name} = $prompt;
    }

    #| Add a prompt using named parameters
    multi method add-prompt(
        Str :$name!,
        Str :$description,
        :@arguments,
        :&generator!
    ) {
        my $builder = MCP::Server::Prompt::prompt()
            .name($name)
            .description($description // '')
            .generator(&generator);

        my @args = @arguments;
        if @args && @args.all ~~ Pair {
            @args = [ Hash.new(@args) ];
        }

        for @args -> $arg {
            my %a = $arg ~~ Pair ?? { $arg.key => $arg.value } !! $arg;
            my $arg-name = %a<name>;
            die "Prompt argument name is required" unless $arg-name.defined;
            my $req = %a<required> // False;
            my $desc = %a<description>;
            if $desc.defined {
                $builder.argument($arg-name, description => $desc, required => $req);
            } else {
                $builder.argument($arg-name, required => $req);
            }
        }

        self.add-prompt($builder.build);
    }

    #| Register a completion handler for a prompt argument
    method add-prompt-completer(Str $prompt-name, &completer) {
        %!completers{"prompt:$prompt-name"} = &completer;
    }

    #| Register a completion handler for a resource URI
    method add-resource-completer(Str $uri, &completer) {
        %!completers{"resource:$uri"} = &completer;
    }

    #| Register an extension with method/notification handlers
    method register-extension(Str :$name!, Str :$version, Hash :$settings, Hash :$methods, Hash :$notifications) {
        die "Extension name must contain '/': $name" unless $name.contains('/');
        %!extensions{$name} = {
            version       => $version // '',
            settings      => $settings // {},
            methods       => $methods // {},
            notifications => $notifications // {},
        };
    }

    #| Remove a registered extension
    method unregister-extension(Str $name) {
        %!extensions{$name}:delete;
    }

    #| Get server capabilities based on registered handlers
    method capabilities(--> MCP::Types::ServerCapabilities) {
        my %args;
        %args<tools> = %!tools ?? MCP::Types::ToolsCapability.new(listChanged => True) !! MCP::Types::ToolsCapability;
        %args<resources> = (%!resources || %!resource-templates) ?? MCP::Types::ResourcesCapability.new(listChanged => True, subscribe => True) !! MCP::Types::ResourcesCapability;
        %args<prompts> = %!prompts ?? MCP::Types::PromptsCapability.new(listChanged => True) !! MCP::Types::PromptsCapability;
        %args<logging> = MCP::Types::LoggingCapability.new;
        %args<completions> = %!completers ?? MCP::Types::CompletionsCapability.new !! MCP::Types::CompletionsCapability;
        if %!tools {
            %args<tasks> = {
                list => {},
                cancel => {},
                requests => { tools => { call => {} } },
            };
        }
        if %!extensions {
            my %experimental;
            for %!extensions.kv -> $ext-name, %ext {
                %experimental{$ext-name} = {
                    version  => %ext<version>,
                    settings => %ext<settings>,
                };
            }
            %args<experimental> = %experimental;
        }
        MCP::Types::ServerCapabilities.new(|%args)
    }

    #| Start serving requests
    method serve(--> Promise) {
        start {
            react {
                whenever $!transport.start() -> $msg {
                    self!handle-message($msg);
                }
            }
        }
    }

    #| Handle incoming message
    method !handle-message($msg) {
        given $msg {
            when MCP::JSONRPC::Request {
                self!handle-request($msg);
            }
            when MCP::JSONRPC::Notification {
                self!handle-notification($msg);
            }
            when MCP::JSONRPC::Response {
                self!handle-response($msg);
            }
        }
    }

    #| Handle incoming request
    method !handle-request(MCP::JSONRPC::Request $req) {
        # Track this request as in-flight (for cancellation support)
        $!flight-lock.protect: { %!in-flight-requests{$req.id} = { cancelled => False } };

        my $result;
        my $error;

        try {
            $result = self.dispatch-request($req);

            CATCH {
                when X::MCP::JSONRPC {
                    $error = $_.error;
                }
                default {
                    $error = MCP::JSONRPC::Error.from-code(
                        MCP::JSONRPC::InternalError,
                        "Internal error"
                    );
                }
            }
        }

        # Check if request was cancelled - don't send response if so
        my $cancelled = $!flight-lock.protect: {
            my $c = %!in-flight-requests{$req.id}<cancelled>;
            %!in-flight-requests{$req.id}:delete;
            $c
        };
        return if $cancelled;

        # Send response
        my $response = $error
            ?? MCP::JSONRPC::Response.error($req.id, $error)
            !! MCP::JSONRPC::Response.success($req.id, $result);

        $!transport.send($response);
    }

    #| Dispatch request to appropriate handler using multi-dispatch
    proto method dispatch-request($req) {
        # Set progress token from _meta for all dispatched requests
        my $*MCP-PROGRESS-TOKEN = ($req.params<_meta><progressToken> if $req.params ~~ Associative) // Nil;
        {*}
    }

    multi method dispatch-request($req where *.method eq 'initialize') {
        self!handle-initialize($req.params);
    }

    multi method dispatch-request($req where *.method eq 'ping') {
        {}  # Empty response for ping
    }

    multi method dispatch-request($req where *.method eq 'tools/list') {
        self!list-tools($req.params);
    }

    multi method dispatch-request($req where *.method eq 'tools/call') {
        self!call-tool($req.params);
    }

    multi method dispatch-request($req where *.method eq 'resources/list') {
        self!list-resources($req.params);
    }

    multi method dispatch-request($req where *.method eq 'resources/templates/list') {
        self!list-resource-templates($req.params);
    }

    multi method dispatch-request($req where *.method eq 'resources/read') {
        self!read-resource($req.params);
    }

    multi method dispatch-request($req where *.method eq 'resources/subscribe') {
        self!subscribe-resource($req.params);
    }

    multi method dispatch-request($req where *.method eq 'resources/unsubscribe') {
        self!unsubscribe-resource($req.params);
    }

    multi method dispatch-request($req where *.method eq 'prompts/list') {
        self!list-prompts($req.params);
    }

    multi method dispatch-request($req where *.method eq 'prompts/get') {
        self!get-prompt($req.params);
    }

    multi method dispatch-request($req where *.method eq 'completion/complete') {
        self!handle-completion($req.params);
    }

    multi method dispatch-request($req where *.method eq 'tasks/get') {
        self!get-task($req.params);
    }

    multi method dispatch-request($req where *.method eq 'tasks/result') {
        self!get-task-result($req.params);
    }

    multi method dispatch-request($req where *.method eq 'tasks/cancel') {
        self!cancel-task($req.params);
    }

    multi method dispatch-request($req where *.method eq 'tasks/list') {
        self!list-tasks($req.params);
    }

    multi method dispatch-request($req where *.method eq 'logging/setLevel') {
        self!handle-set-log-level($req.params);
    }

    multi method dispatch-request($req) {
        # Check if this is an extension method
        for %!extensions.kv -> $ext-name, %ext {
            if %ext<methods>{$req.method}:exists {
                my &handler = %ext<methods>{$req.method};
                return handler($req.params // {});
            }
        }

        die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::MethodNotFound,
                "Unknown method: {$req.method}"
            )
        );
    }

    #| Get extensions negotiated with the client (supported by both sides)
    method negotiated-extensions(--> Hash) {
        return {} unless $!client-capabilities.defined && $!client-capabilities.experimental.defined;
        my %negotiated;
        for $!client-capabilities.experimental.kv -> $name, $config {
            %negotiated{$name} = $config if %!extensions{$name}:exists;
        }
        %negotiated
    }

    #| Handle initialize request
    method !handle-initialize(%params) {
        my $client-version = %params<protocolVersion>;

        # Negotiate protocol version: use client's version if supported,
        # otherwise fall back to the server's latest supported version
        my $negotiated = $client-version ~~ any(MCP::Types::SUPPORTED_PROTOCOL_VERSIONS.list)
            ?? $client-version
            !! MCP::Types::LATEST_PROTOCOL_VERSION;

        $!protocol-version = $negotiated;
        my %cap-args;
        if %params<capabilities> && %params<capabilities> ~~ Hash {
            my %caps = %params<capabilities>;
            %cap-args<experimental> = %caps<experimental> if %caps<experimental>.defined && %caps<experimental> ~~ Hash;
            %cap-args<roots> = MCP::Types::RootsCapability.new(|%caps<roots>) if %caps<roots>.defined && %caps<roots> ~~ Hash;
            %cap-args<sampling> = MCP::Types::SamplingCapability.new(|%caps<sampling>) if %caps<sampling>.defined && %caps<sampling> ~~ Hash;
            %cap-args<tasks> = %caps<tasks> if %caps<tasks>.defined;
        }
        $!client-capabilities = MCP::Types::ClientCapabilities.new(|%cap-args);
        $!initialized = True;

        {
            protocolVersion => $negotiated,
            capabilities => self.capabilities.Hash,
            serverInfo => $!info.Hash,
            ($!instructions ?? (instructions => $!instructions) !! Empty),
        }
    }

    #| Handle logging/setLevel request
    method !handle-set-log-level(%params) {
        my $level-str = %params<level> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: level"
            )
        );
        $!log-level = parse-log-level($level-str);
        CATCH {
            when X::AdHoc {
                die X::MCP::JSONRPC.new(
                    error => MCP::JSONRPC::Error.from-code(
                        MCP::JSONRPC::InvalidParams,
                        "Invalid log level: $level-str"
                    )
                );
            }
        }
        {}
    }

    #| Handle notifications
    method !handle-notification(MCP::JSONRPC::Notification $notif) {
        given $notif.method {
            when 'initialized' {
                # Client is ready
            }
            when 'notifications/cancelled' | 'cancelled' {
                # Request was cancelled - mark it so we don't send a response
                my $id = $notif.params<requestId>;
                if $id.defined {
                    $!flight-lock.protect: {
                        if %!in-flight-requests{$id}:exists {
                            %!in-flight-requests{$id}<cancelled> = True;
                        }
                    }
                }
                # Silently ignore unknown/completed requests per spec
            }
            default {
                # Check extension notification handlers
                for %!extensions.kv -> $ext-name, %ext {
                    if %ext<notifications>{$notif.method}:exists {
                        my &handler = %ext<notifications>{$notif.method};
                        handler($notif.params // {});
                        return;
                    }
                }
                # Unknown notification - ignore per spec
            }
        }
    }

    #| Handle response to our requests
    method !handle-response(MCP::JSONRPC::Response $resp) {
        $!flight-lock.protect: {
            if %!pending-requests{$resp.id}:exists {
                my $vow = %!pending-requests{$resp.id}:delete;
                if $resp.error {
                    $vow.break(X::MCP::JSONRPC.new(error => $resp.error));
                } else {
                    $vow.keep($resp.result);
                }
            }
        }
    }

    #| List tools
    method !list-tools($params?) {
        my @tools = %!tools.values.map(*.to-tool.Hash).Array;
        self!paginate(@tools, $params, key => 'tools')
    }

    #| Call a tool
    method !call-tool(%params) {
        my $name = %params<name> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: name"
            )
        );

        my $tool = %!tools{$name} // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Unknown tool: $name"
            )
        );

        # If task hint is present, run as async task
        if %params<task> && %params<task><ttl> {
            return self!call-tool-as-task($tool, %params);
        }

        my %arguments = %params<arguments> // {};
        my $result = $tool.call(%arguments);
        $result.Hash;
    }

    #| Generate a unique task ID
    method !generate-task-id(--> Str) {
        "task-" ~ (^2**64).pick.base(16).lc
    }

    #| ISO 8601 timestamp
    method !iso-now(--> Str) {
        DateTime.now(formatter => { sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ", .year, .month, .day, .hour, .minute, .second.Int }).Str
    }

    #| Run a tool call as an async task
    method !call-tool-as-task($tool, %params --> Hash) {
        my $task-id = self!generate-task-id;
        my $now = self!iso-now;
        my $ttl = %params<task><ttl>;

        my $task = MCP::Types::Task.new(
            taskId => $task-id,
            status => MCP::Types::TaskWorking,
            createdAt => $now,
            lastUpdatedAt => $now,
            ttl => $ttl.Int,
            pollInterval => $!default-poll-interval,
        );

        my %arguments = %params<arguments> // {};
        my $promise = start {
            $tool.call(%arguments)
        };

        my $completion = $promise.then(-> $p {
            $!task-lock.protect: {
                my $now2 = self!iso-now;
                if $p.status ~~ Kept {
                    my $result = $p.result;
                    %!tasks{$task-id}<result> = $result.Hash;
                    %!tasks{$task-id}<task> = MCP::Types::Task.new(
                        taskId => $task-id,
                        status => MCP::Types::TaskCompleted,
                        createdAt => %!tasks{$task-id}<task>.createdAt,
                        lastUpdatedAt => $now2,
                        ttl => $ttl.Int,
                        pollInterval => $!default-poll-interval,
                    );
                } else {
                    %!tasks{$task-id}<task> = MCP::Types::Task.new(
                        taskId => $task-id,
                        status => MCP::Types::TaskFailed,
                        statusMessage => $p.cause.message,
                        createdAt => %!tasks{$task-id}<task>.createdAt,
                        lastUpdatedAt => $now2,
                        ttl => $ttl.Int,
                        pollInterval => $!default-poll-interval,
                    );
                }
                try self.notify('notifications/tasks/status', %!tasks{$task-id}<task>.Hash);
            }
        });

        $!task-lock.protect: { %!tasks{$task-id} = { task => $task, promise => $promise, completion => $completion, result => Any } };

        MCP::Types::CreateTaskResult.new(task => $task).Hash;
    }

    #| Get a task by ID
    method !get-task(%params --> Hash) {
        my $task-id = %params<taskId> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: taskId"
            )
        );

        $!task-lock.protect: {
            my $entry = %!tasks{$task-id} // die X::MCP::JSONRPC.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InvalidParams,
                    "Unknown task: $task-id"
                )
            );

            $entry<task>.Hash
        }
    }

    #| Get task result (blocks until terminal)
    method !get-task-result(%params --> Hash) {
        my $task-id = %params<taskId> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: taskId"
            )
        );

        my ($entry, $completion);
        $!task-lock.protect: {
            $entry = %!tasks{$task-id} // die X::MCP::JSONRPC.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InvalidParams,
                    "Unknown task: $task-id"
                )
            );
            $completion = $entry<completion>;
        };

        # If not terminal, block until the .then callback has updated state
        unless $entry<task>.is-terminal {
            try { await $completion }
        }

        # Return stored result or task status
        $!task-lock.protect: {
            my %result;
            %result<task> = %!tasks{$task-id}<task>.Hash;
            %result<result> = $_ with %!tasks{$task-id}<result>;
            %result
        }
    }

    #| Cancel a task
    method !cancel-task(%params --> Hash) {
        my $task-id = %params<taskId> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: taskId"
            )
        );

        $!task-lock.protect: {
            my $entry = %!tasks{$task-id} // die X::MCP::JSONRPC.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InvalidParams,
                    "Unknown task: $task-id"
                )
            );

            unless $entry<task>.is-terminal {
                my $now = self!iso-now;
                %!tasks{$task-id}<task> = MCP::Types::Task.new(
                    taskId => $task-id,
                    status => MCP::Types::TaskCancelled,
                    createdAt => $entry<task>.createdAt,
                    lastUpdatedAt => $now,
                    ttl => $entry<task>.ttl,
                    pollInterval => $entry<task>.pollInterval,
                );
                try self.notify('notifications/tasks/status', %!tasks{$task-id}<task>.Hash);
            }

            %!tasks{$task-id}<task>.Hash
        }
    }

    #| List tasks with pagination
    method !list-tasks($params?) {
        my @tasks = $!task-lock.protect: { %!tasks.values.map(*<task>.Hash).Array };
        self!paginate(@tasks, $params, key => 'tasks')
    }

    #| List resources
    method !list-resources($params?) {
        my @resources = %!resources.values.map(*.to-resource.Hash).Array;
        self!paginate(@resources, $params, key => 'resources')
    }

    #| List resource templates
    method !list-resource-templates($params?) {
        my @templates = %!resource-templates.values.map(*.to-resource-template.Hash).Array;
        self!paginate(@templates, $params, key => 'resourceTemplates')
    }

    #| Read a resource
    method !read-resource(%params) {
        my $uri = %params<uri> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: uri"
            )
        );

        # Try exact match first
        if %!resources{$uri}:exists {
            return {
                contents => %!resources{$uri}.read.map(*.Hash).Array
            };
        }

        # Try matching against resource templates
        for %!resource-templates.values -> $template {
            my $match = $template.match-uri($uri);
            if $match.defined {
                return {
                    contents => $template.read($match, uri => $uri).map(*.Hash).Array
                };
            }
        }

        die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Unknown resource: $uri"
            )
        );
    }

    #| Subscribe to a resource
    method !subscribe-resource(%params) {
        my $uri = %params<uri> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: uri"
            )
        );

        # Verify resource exists
        unless %!resources{$uri}:exists {
            die X::MCP::JSONRPC.new(
                error => MCP::JSONRPC::Error.from-code(
                    MCP::JSONRPC::InvalidParams,
                    "Unknown resource: $uri"
                )
            );
        }

        %!subscriptions{$uri} = True;
        {}  # Empty response on success
    }

    #| Unsubscribe from a resource
    method !unsubscribe-resource(%params) {
        my $uri = %params<uri> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: uri"
            )
        );

        %!subscriptions{$uri}:delete;
        {}  # Empty response on success
    }

    #| List prompts
    method !list-prompts($params?) {
        my @prompts = %!prompts.values.map(*.to-prompt.Hash).Array;
        self!paginate(@prompts, $params, key => 'prompts')
    }

    #| Get a prompt
    method !get-prompt(%params) {
        my $name = %params<name> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: name"
            )
        );

        my $prompt = %!prompts{$name} // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Unknown prompt: $name"
            )
        );

        my %arguments = %params<arguments> // {};

        {
            description => $prompt.description,
            messages => $prompt.get(%arguments).map(*.Hash).Array
        }
    }

    #| Send a request to the client (for sampling, etc.)
    method request(Str $method, $params? --> Promise) {
        my $id = $!id-gen.next;
        my $p = Promise.new;
        $!flight-lock.protect: { %!pending-requests{$id} = $p.vow };

        my $request = MCP::JSONRPC::Request.new(:$id, :$method, :$params);
        $!transport.send($request);

        $p
    }

    #| Send a notification to the client
    method notify(Str $method, $params?) {
        my $notification = MCP::JSONRPC::Notification.new(:$method, :$params);
        $!transport.send($notification);
    }

    #| Send a log message (suppressed if below current log level)
    method log(MCP::Types::LogLevel $level, $data, Str :$logger) {
        return unless log-level-at-or-above($level, $!log-level);
        self.notify('notifications/message', {
            level => $level.value,
            data => $data,
            ($logger ?? (logger => $logger) !! Empty),
        });
    }

    #| Send a progress notification
    #| If no token is provided, uses the progress token from the current request's _meta
    method progress(Num $progress, Num :$total, Str :$message, :$token is copy) {
        $token //= $*MCP-PROGRESS-TOKEN // Nil;
        return unless $token.defined;
        self.notify('notifications/progress', {
            progressToken => $token,
            progress => $progress,
            ($total.defined ?? (total => $total) !! Empty),
            ($message ?? (message => $message) !! Empty),
        });
    }

    #| Check if a request has been cancelled
    #| Useful for long-running tool handlers to check periodically
    method is-cancelled($request-id --> Bool) {
        $!flight-lock.protect: {
            return False unless %!in-flight-requests{$request-id}:exists;
            %!in-flight-requests{$request-id}<cancelled>
        }
    }

    #| Cancel a request (for server-initiated cancellation)
    method cancel-request($request-id, Str :$reason) {
        self.notify('notifications/cancelled', {
            requestId => $request-id,
            ($reason ?? (reason => $reason) !! Empty),
        });
    }

    #| Check if a resource is subscribed
    method is-subscribed(Str $uri --> Bool) {
        %!subscriptions{$uri}:exists && %!subscriptions{$uri}
    }

    #| Notify clients that a subscribed resource has been updated
    #| Only sends notification if the resource is subscribed
    method notify-resource-updated(Str $uri) {
        return unless self.is-subscribed($uri);
        self.notify('notifications/resources/updated', { uri => $uri });
    }

    #| Handle completion/complete request
    method !handle-completion(%params) {
        my $ref = %params<ref> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: ref"
            )
        );

        my $argument = %params<argument> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: argument"
            )
        );

        my $ref-type = $ref<type> // '';
        my $key = do given $ref-type {
            when 'ref/prompt'   { "prompt:{$ref<name> // ''}" }
            when 'ref/resource' { "resource:{$ref<uri> // ''}" }
            default {
                die X::MCP::JSONRPC.new(
                    error => MCP::JSONRPC::Error.from-code(
                        MCP::JSONRPC::InvalidParams,
                        "Unknown ref type: $ref-type"
                    )
                );
            }
        };

        unless %!completers{$key}:exists {
            return { completion => { values => [] } };
        }
        my &completer = %!completers{$key};

        my $arg-name = $argument<name> // '';
        my $arg-value = $argument<value> // '';

        my $result = &completer($arg-name, $arg-value, |(%params<context> // {}));

        # Normalize result
        if $result ~~ MCP::Types::CompletionResult {
            return { completion => $result.Hash };
        } elsif $result ~~ Hash && ($result<values>:exists) {
            # Truncate to 100 values per spec
            my @vals = $result<values>.head(100).Array;
            my %completion = values => @vals;
            %completion<total> = $_ with $result<total>;
            %completion<hasMore> = $_ with $result<hasMore>;
            return { completion => %completion };
        } elsif $result ~~ Positional {
            return { completion => { values => $result.head(100).Array } };
        } else {
            return { completion => { values => [] } };
        }
    }

    #| Notify clients that the resource list has changed
    method notify-resources-list-changed() {
        self.notify('notifications/resources/list_changed');
    }

    #| Notify clients that the prompt list has changed
    method notify-prompts-list-changed() {
        self.notify('notifications/prompts/list_changed');
    }

    #| Request roots from client
    #| Returns a Promise that resolves to an array of Root objects
    method list-roots(--> Promise) {
        self.request('roots/list').then(-> $p {
            my $result = $p.result;
            ($result<roots> // []).map({
                MCP::Types::Root.from-hash($_)
            }).Array
        })
    }

    #| Request a sampling/createMessage from the client
    #| Returns a Promise that resolves to a CreateMessageResult
    method create-message(
        :@messages!,
        Int :$maxTokens,
        :$modelPreferences,
        Str :$systemPrompt,
        Str :$includeContext,
        :@tools,
        :$toolChoice,
        :$meta,
    --> Promise) {
        my %params = messages => @messages.map({
            $_ ~~ MCP::Types::SamplingMessage ?? $_.Hash !! $_
        }).Array;
        %params<maxTokens> = $_ with $maxTokens;
        %params<modelPreferences> = $_ ~~ MCP::Types::ModelPreferences ?? $_.Hash !! $_ with $modelPreferences;
        %params<systemPrompt> = $_ with $systemPrompt;
        %params<includeContext> = $_ with $includeContext;
        if @tools {
            %params<tools> = @tools.map({
                $_ ~~ MCP::Types::Tool ?? $_.Hash !! $_
            }).Array;
        }
        %params<toolChoice> = $_ ~~ MCP::Types::ToolChoice ?? $_.Hash !! $_ with $toolChoice;
        %params<_meta> = $_ with $meta;

        self.request('sampling/createMessage', %params).then(-> $p {
            my $result = $p.result;
            MCP::Types::CreateMessageResult.new(
                role => $result<role>,
                model => $result<model>,
                content => $result<content>,
                stopReason => $result<stopReason>,
                meta => $result<_meta>,
            )
        })
    }

    #| Request user input via form mode elicitation
    #| Returns a Promise that resolves to an ElicitationResponse
    method elicit(Str :$message!, :%schema! --> Promise) {
        self.request('elicitation/create', {
            mode => 'form',
            message => $message,
            requestedSchema => %schema,
        }).then(-> $p {
            my $result = $p.result;
            MCP::Types::ElicitationResponse.from-hash($result)
        })
    }

    #| Request user interaction via URL mode elicitation
    #| Returns a Promise that resolves to an ElicitationResponse
    method elicit-url(Str :$message!, Str :$url!, Str :$elicitation-id! --> Promise) {
        self.request('elicitation/create', {
            mode => 'url',
            message => $message,
            url => $url,
            elicitationId => $elicitation-id,
        }).then(-> $p {
            my $result = $p.result;
            MCP::Types::ElicitationResponse.from-hash($result)
        })
    }

    #| Notify client that a URL mode elicitation has completed
    method notify-elicitation-complete(Str $elicitation-id) {
        self.notify('notifications/elicitation/complete', {
            elicitationId => $elicitation-id,
        });
    }
}
