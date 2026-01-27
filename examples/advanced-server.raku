#!/usr/bin/env raku
use v6.d;

use MCP::Server;
use MCP::Types;
use MCP::Transport::Base;
use MONKEY-TYPING;
need MCP::JSONRPC;

=begin pod
=head1 NAME

advanced-server - Server-side pagination, subscriptions, and cancellation

=head1 DESCRIPTION

Runs entirely in-process using a tiny recording transport. It demonstrates
three implemented features that are easy to miss when only looking at the
basic examples:

- Cursor-based pagination
- Resource subscriptions and update notifications
- Request cancellation that suppresses a response

=head1 USAGE

    make run-example EXAMPLE=advanced-server

=end pod

class RecordingTransport does MCP::Transport::Base::Transport {
    has Supplier $!incoming = Supplier.new;
    has Bool $!connected = False;
    has @!sent;

    method start(--> Supply) {
        $!connected = True;
        $!incoming.Supply;
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        @!sent.push($msg);
        Promise.kept(True);
    }

    method close(--> Promise) {
        $!connected = False;
        $!incoming.done;
        Promise.kept(True);
    }

    method is-connected(--> Bool) { $!connected }

    method sent(--> Array) { @!sent }
    method clear-sent() { @!sent = () }
}

augment class MCP::Server::Server {
    method handle-message-public($msg) { self!handle-message($msg) }
}

sub demo-pagination(Server $server) {
    say "\n== Pagination ==";

    my %page1 = $server.dispatch-request(MCP::JSONRPC::Request.new(
        id => 'page-1',
        method => 'tools/list',
    ));
    say "Page 1 tools: " ~ %page1<tools>.map(*<name>).sort.join(', ');
    say "Page 1 nextCursor present: " ~ (%page1<nextCursor>.defined ?? 'yes' !! 'no');

    my %page2 = $server.dispatch-request(MCP::JSONRPC::Request.new(
        id => 'page-2',
        method => 'tools/list',
        params => { cursor => %page1<nextCursor> },
    ));
    say "Page 2 tools: " ~ %page2<tools>.map(*<name>).sort.join(', ');
    say "Page 2 nextCursor present: " ~ (%page2<nextCursor>.defined ?? 'yes' !! 'no');
}

sub demo-subscriptions(Server $server, RecordingTransport $transport) {
    say "\n== Resource Subscriptions ==";
    $transport.clear-sent;

    my %sub = $server.dispatch-request(MCP::JSONRPC::Request.new(
        id => 'sub-1',
        method => 'resources/subscribe',
        params => { uri => 'info://clock' },
    ));
    say "Subscribe result keys: " ~ %sub.keys.join(', ');

    $server.notify-resource-updated('info://clock');

    my @notifications = $transport.sent.grep(MCP::JSONRPC::Notification);
    say "Update notifications sent: {@notifications.elems}";
    if @notifications {
        say "Last notification method: " ~ @notifications[*-1].method;
    }
}

sub demo-cancellation(Server $server, RecordingTransport $transport) {
    say "\n== Cancellation ==";
    $transport.clear-sent;

    my $gate = Promise.new;
    my $vow = $gate.vow;

    $server.add-tool(
        name => 'slow-tool',
        description => 'Waits until released, useful for cancellation demos',
        handler => -> {
            await $gate;
            'completed'
        }
    );

    my $task = start {
        $server.handle-message-public(MCP::JSONRPC::Request.new(
            id => 'cancel-demo-1',
            method => 'tools/call',
            params => { name => 'slow-tool', arguments => {} },
        ));
    };

    sleep 0.05;

    $server.handle-message-public(MCP::JSONRPC::Notification.new(
        method => 'notifications/cancelled',
        params => { requestId => 'cancel-demo-1', reason => 'demo cancel' },
    ));

    say "Marked cancelled: " ~ ($server.is-cancelled('cancel-demo-1') ?? 'yes' !! 'no');

    $vow.keep(True);
    await $task;

    my @responses = $transport.sent.grep(MCP::JSONRPC::Response);
    say "Responses sent after cancellation: {@responses.elems}";
}

my $transport = RecordingTransport.new;
my $server = Server.new(
    info => Implementation.new(name => 'advanced-server', version => '0.1.0'),
    transport => $transport,
    page-size => 2,
);

# Seed tools for pagination
for <alpha beta gamma delta epsilon> -> $name {
    $server.add-tool(
        name => "tool-$name",
        description => "Demo tool $name",
        handler => -> { "result-$name" },
    );
}

# Resource used by the subscription demo
$server.add-resource(
    uri => 'info://clock',
    name => 'Clock',
    description => 'A ticking clock resource',
    mimeType => 'text/plain',
    reader => { DateTime.now.Str },
);

demo-pagination($server);
demo-subscriptions($server, $transport);
demo-cancellation($server, $transport);

await $transport.close;

say "\nDone.";
