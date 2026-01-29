use v6.d;

unit module TestTransport;

use MCP::Transport::Base;
use MCP::JSONRPC;

class TestTransport does MCP::Transport::Base::Transport is export {
    has Supplier $!supplier = Supplier.new;
    has Supply $!supply = $!supplier.Supply;
    has @!sent;
    has Bool $!running = False;

    method start(--> Supply) {
        $!running = True;
        $!supply
    }

    method send(MCP::JSONRPC::Message $msg --> Promise) {
        @!sent.push($msg);
        start { True }
    }

    method close(--> Promise) {
        $!running = False;
        $!supplier.done;
        start { True }
    }

    method is-connected(--> Bool) {
        $!running
    }

    method emit(MCP::JSONRPC::Message $msg) {
        $!supplier.emit($msg);
    }

    method sent(--> Array) {
        @!sent.Array
    }

    method clear-sent() {
        @!sent = ();
    }

    #| Wait until at least $n messages have been sent (default 1).
    #| Returns True if condition met, False on timeout.
    method await-sent(Int $n = 1, Num :$timeout = 5e0 --> Bool) {
        my $deadline = now + $timeout;
        while now < $deadline {
            return True if @!sent.elems >= $n;
            sleep 0.05;
        }
        @!sent.elems >= $n
    }
}
