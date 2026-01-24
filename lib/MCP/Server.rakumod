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

=end pod

use MCP::Types;
need MCP::JSONRPC;
use MCP::Transport::Base;
use MCP::Server::Tool;
use MCP::Server::Resource;
use MCP::Server::Prompt;
use JSON::Fast;

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

    # Registered handlers
    has %!tools;      # name => RegisteredTool
    has %!resources;  # uri => RegisteredResource
    has %!prompts;    # name => RegisteredPrompt

    # State
    has Bool $!initialized = False;
    has MCP::Types::ClientCapabilities $!client-capabilities;
    has Str $!protocol-version;
    has MCP::JSONRPC::IdGenerator $!id-gen = MCP::JSONRPC::IdGenerator.new;

    # Pending request handlers for bidirectional communication
    has %!pending-requests;  # id => Promise vow

    #| Add a tool to the server
    multi method add-tool(MCP::Server::Tool::RegisteredTool $tool) {
        %!tools{$tool.name} = $tool;
    }

    #| Add a tool using named parameters
    multi method add-tool(
        Str :$name!,
        Str :$description,
        Hash :$schema,
        :&handler!
    ) {
        my $tool = MCP::Server::Tool::tool()
            .name($name)
            .description($description // '')
            .schema($schema // { type => 'object', properties => {} })
            .handler(&handler)
            .build;
        self.add-tool($tool);
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

    #| Get server capabilities based on registered handlers
    method capabilities(--> MCP::Types::ServerCapabilities) {
        MCP::Types::ServerCapabilities.new(
            tools => %!tools ?? MCP::Types::ToolsCapability.new(listChanged => True) !! MCP::Types::ToolsCapability,
            resources => %!resources ?? MCP::Types::ResourcesCapability.new(listChanged => True) !! MCP::Types::ResourcesCapability,
            prompts => %!prompts ?? MCP::Types::PromptsCapability.new(listChanged => True) !! MCP::Types::PromptsCapability,
            logging => MCP::Types::LoggingCapability.new,
        )
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
                        $_.message
                    );
                }
            }
        }

        # Send response
        my $response = $error
            ?? MCP::JSONRPC::Response.error($req.id, $error)
            !! MCP::JSONRPC::Response.success($req.id, $result);

        $!transport.send($response);
    }

    #| Dispatch request to appropriate handler using multi-dispatch
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

    multi method dispatch-request($req where *.method eq 'resources/read') {
        self!read-resource($req.params);
    }

    multi method dispatch-request($req where *.method eq 'prompts/list') {
        self!list-prompts($req.params);
    }

    multi method dispatch-request($req where *.method eq 'prompts/get') {
        self!get-prompt($req.params);
    }

    multi method dispatch-request($req) {
        die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::MethodNotFound,
                "Unknown method: {$req.method}"
            )
        );
    }

    #| Handle initialize request
    method !handle-initialize(%params) {
        $!protocol-version = %params<protocolVersion>;
        $!client-capabilities = MCP::Types::ClientCapabilities.new; # Parse from params
        $!initialized = True;

        {
            protocolVersion => MCP::Types::LATEST_PROTOCOL_VERSION,
            capabilities => self.capabilities.Hash,
            serverInfo => $!info.Hash,
            ($!instructions ?? (instructions => $!instructions) !! Empty),
        }
    }

    #| Handle initialized notification
    method !handle-notification(MCP::JSONRPC::Notification $notif) {
        given $notif.method {
            when 'initialized' {
                # Client is ready
            }
            when 'cancelled' {
                # Request was cancelled
                my $id = $notif.params<requestId>;
                # Could handle cancellation here
            }
            default {
                # Unknown notification - ignore
            }
        }
    }

    #| Handle response to our requests
    method !handle-response(MCP::JSONRPC::Response $resp) {
        if %!pending-requests{$resp.id}:exists {
            my $vow = %!pending-requests{$resp.id}:delete;
            if $resp.error {
                $vow.break(X::MCP::JSONRPC.new(error => $resp.error));
            } else {
                $vow.keep($resp.result);
            }
        }
    }

    #| List tools
    method !list-tools($params?) {
        {
            tools => %!tools.values.map(*.to-tool.Hash).Array
        }
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

        my %arguments = %params<arguments> // {};
        my $result = $tool.call(%arguments);
        $result.Hash;
    }

    #| List resources
    method !list-resources($params?) {
        {
            resources => %!resources.values.map(*.to-resource.Hash).Array
        }
    }

    #| Read a resource
    method !read-resource(%params) {
        my $uri = %params<uri> // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Missing required parameter: uri"
            )
        );

        my $resource = %!resources{$uri} // die X::MCP::JSONRPC.new(
            error => MCP::JSONRPC::Error.from-code(
                MCP::JSONRPC::InvalidParams,
                "Unknown resource: $uri"
            )
        );

        {
            contents => $resource.read.map(*.Hash).Array
        }
    }

    #| List prompts
    method !list-prompts($params?) {
        {
            prompts => %!prompts.values.map(*.to-prompt.Hash).Array
        }
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
        %!pending-requests{$id} = $p.vow;

        my $request = MCP::JSONRPC::Request.new(:$id, :$method, :$params);
        $!transport.send($request);

        $p
    }

    #| Send a notification to the client
    method notify(Str $method, $params?) {
        my $notification = MCP::JSONRPC::Notification.new(:$method, :$params);
        $!transport.send($notification);
    }

    #| Send a log message
    method log(MCP::Types::LogLevel $level, $data, Str :$logger) {
        self.notify('notifications/message', {
            level => $level.value,
            data => $data,
            ($logger ?? (logger => $logger) !! Empty),
        });
    }

    #| Send a progress notification
    method progress($token, Num $progress, Num :$total, Str :$message) {
        self.notify('notifications/progress', {
            progressToken => $token,
            progress => $progress,
            ($total.defined ?? (total => $total) !! Empty),
            ($message ?? (message => $message) !! Empty),
        });
    }
}
