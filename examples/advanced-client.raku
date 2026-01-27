#!/usr/bin/env raku
use v6.d;

use MCP::Server;
use MCP::Client;
use MCP::Types;
use MCP::Transport::Base;
use MONKEY-TYPING;
need MCP::JSONRPC;

=begin pod
=head1 NAME

advanced-client - In-process client/server loopback for advanced features

=head1 DESCRIPTION

Creates a client and a server connected by an in-process loopback transport.
This keeps the example fully runnable without external services while still
demonstrating:

- Pagination through list endpoints
- Completions for prompts and resources
- Roots (server requesting roots from the client)
- Elicitation (server asking the client for input)

=head1 USAGE

    make run-example EXAMPLE=advanced-client

=end pod

class LoopbackTransport does MCP::Transport::Base::Transport {
    has Supplier $!incoming = Supplier.new;
    has Bool $!connected = False;
    has LoopbackTransport $.peer is rw;
    has @!sent;

    method start(--> Supply) {
        $!connected = True;
        $!incoming.Supply;
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        @!sent.push($msg);
        $.peer!emit($msg) if $.peer.defined;
        Promise.kept(True);
    }

    method close(--> Promise) {
        $!connected = False;
        $!incoming.done;
        Promise.kept(True);
    }

    method is-connected(--> Bool) { $!connected }

    method !emit(MCP::JSONRPC::Message $msg) {
        $!incoming.emit($msg);
    }
}

sub loopback-pair(--> List) {
    my $a = LoopbackTransport.new;
    my $b = LoopbackTransport.new;
    $a.peer = $b;
    $b.peer = $a;
    ($a, $b)
}

augment class MCP::Server::Server {
    method handle-message-public($msg) { self!handle-message($msg) }
}

sub show-pagination(Client $client) {
    say "\n== Pagination ==";

    my %tools-page1 = await $client.list-tools;
    say "Tools page 1: " ~ %tools-page1<tools>.map(*.name).sort.join(', ');
    if %tools-page1<nextCursor>:exists {
        my %tools-page2 = await $client.list-tools(cursor => %tools-page1<nextCursor>);
        say "Tools page 2: " ~ %tools-page2<tools>.map(*.name).sort.join(', ');
    }

    my %prompts-page1 = await $client.list-prompts;
    say "Prompts page 1: " ~ %prompts-page1<prompts>.map(*.name).sort.join(', ');
    if %prompts-page1<nextCursor>:exists {
        my %prompts-page2 = await $client.list-prompts(cursor => %prompts-page1<nextCursor>);
        say "Prompts page 2: " ~ %prompts-page2<prompts>.map(*.name).sort.join(', ');
    }
}

sub show-completions(Client $client) {
    say "\n== Completions ==";

    my $prompt-result = await $client.complete-prompt(
        'code-review',
        argument-name => 'language',
        value => 'ru',
    );
    say "Prompt completion values: " ~ $prompt-result.values.join(', ');

    my $resource-result = await $client.complete-resource(
        'file:///projects',
        argument-name => 'path',
        value => 'pro',
    );
    say "Resource completion values: " ~ $resource-result.values.join(', ');
}

sub show-roots-and-elicitation(Server $server) {
    say "\n== Roots ==";
    my @roots = await $server.list-roots;
    say "Roots from client: " ~ @roots.map(*.uri).join(', ');

    say "\n== Elicitation ==";
    my $form-response = await $server.elicit(
        message => 'Who is approving this request?',
        schema => {
            type => 'object',
            properties => {
                name => { type => 'string' },
                approved => { type => 'boolean' },
            },
            required => ['name', 'approved'],
        },
    );
    say "Form elicitation action: {$form-response.action}";
    say "Form elicitation content keys: " ~ ($form-response.content // {}).keys.join(', ');

    my $url-response = await $server.elicit-url(
        message => 'Open the approval UI',
        url => 'https://example.test/approve',
        elicitation-id => 'approval-1',
    );
    say "URL elicitation action: {$url-response.action}";

    $server.notify-elicitation-complete('approval-1');
}

my ($server-transport, $client-transport) = loopback-pair;

my $server = Server.new(
    info => Implementation.new(name => 'advanced-server', version => '0.1.0'),
    transport => $server-transport,
    page-size => 2,
    instructions => 'Loopback server for advanced client features',
);

# Seed enough data for pagination
for <alpha beta gamma delta epsilon> -> $name {
    $server.add-tool(
        name => "tool-$name",
        description => "Demo tool $name",
        handler => -> { "result-$name" },
    );
}

for <code-review explain summarize> -> $name {
    $server.add-prompt(
        name => $name,
        description => "Prompt $name",
        generator => -> :%params { "prompt-$name for " ~ (%params<topic> // 'general') },
    );
}

$server.add-resource(
    uri => 'file:///projects',
    name => 'Projects root',
    description => 'Root folder for projects',
    mimeType => 'text/plain',
    reader => { 'project listing placeholder' },
);

# Register completion handlers
$server.add-prompt-completer('code-review', -> $arg-name, $value, *%context {
    my @langs = <raku ruby rust python perl>;
    @langs.grep(*.starts-with($value.lc)).Array
});

$server.add-resource-completer('file:///projects', -> $arg-name, $value, *%context {
    my @paths = <project-a project-b prototype docs>;
    my @filtered = @paths.grep(*.starts-with($value.lc));
    CompletionResult.new(values => @filtered, total => @paths.elems, hasMore => False)
});

# Start server loop
$server.serve;

my @roots = [
    Root.new(uri => 'file:///project', name => 'Project'),
    Root.new(uri => 'file:///tmp', name => 'Temp'),
];

my $capabilities = ClientCapabilities.new(
    elicitation => ElicitationCapability.new(form => True, url => True),
);

my $client = Client.new(
    info => Implementation.new(name => 'advanced-client', version => '0.1.0'),
    transport => $client-transport,
    capabilities => $capabilities,
    roots => @roots,
    elicitation-handler => -> %params {
        ElicitationResponse.new(
            action => ElicitAccept,
            content => {
                name => 'Example User',
                approved => True,
                mode => %params<mode>,
            },
        )
    },
);

await $client.connect;

show-pagination($client);
show-completions($client);
show-roots-and-elicitation($server);

await $client.close;
await $client-transport.close;
await $server-transport.close;

say "\nDone.";
