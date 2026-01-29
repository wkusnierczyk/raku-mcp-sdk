use v6.d;

#| Stdio transport implementation with LSP-style framing
unit module MCP::Transport::Stdio;

=begin pod
=head1 NAME

MCP::Transport::Stdio - Stdio transport implementation

=head1 DESCRIPTION

Implements MCP transport over stdin/stdout using Content-Length framing
(LSP-style). Useful for CLI tools and embedding in subprocess pipelines.

=head1 CLASS

=head2 StdioTransport

    my $transport = StdioTransport.new;
    my $transport = StdioTransport.new(input => $proc.stdout, output => $proc.stdin);

Attributes:

=item C<input> — Input stream (default: C<$*IN>).
=item C<output> — Output stream (default: C<$*OUT>).

=head1 FUNCTIONS

=head2 sub stdio-server-transport(--> StdioTransport)

Create a transport using standard I/O (for servers).

=head2 sub subprocess-transport(Proc::Async $proc --> StdioTransport)

Create a transport connected to a subprocess (for clients).

=end pod

use MCP::JSONRPC;
use MCP::Transport::Base;
use JSON::Fast;

#| Stdio transport for MCP communication
#| Messages are framed with Content-Length headers (like LSP)
class StdioTransport does MCP::Transport::Base::Transport is export {
    has IO::Handle $.input = $*IN;
    has IO::Handle $.output = $*OUT;
    has Supply $!incoming;
    has Supplier $!supplier;
    has Bool $!running = False;
    has Lock $!write-lock = Lock.new;

    #| Start the transport and return a Supply of incoming messages
    method start(--> Supply) {
        return $!incoming if $!running;

        $!running = True;
        $!supplier = Supplier.new;
        $!incoming = $!supplier.Supply;

        # Start reading in background
        start {
            self!read-loop();
        }

        $!incoming;
    }

    method !read-loop() {
        my $buffer = '';

        loop {
            last unless $!running;

            # Read available data
            my $chunk = self!read-chunk();
            last unless $chunk.defined;

            $buffer ~= $chunk;

            # Try to parse complete messages
            while $!running {
                my ($msg, $rest) = self!parse-message($buffer);
                last unless $msg.defined;

                $!supplier.emit($msg);
                $buffer = $rest;
            }
        }

        $!supplier.done unless $!supplier.done;
    }

    method !read-chunk(--> Str) {
        try {
            # Read line by line for header parsing
            my $line = $!input.get;
            return Str unless $line.defined;
            return $line ~ "\n";

            CATCH {
                default {
                    return Str;
                }
            }
        }
    }

    #| Parse a message from the buffer
    #| Returns (message, remaining-buffer) or (Nil, buffer)
    method !parse-message(Str $buffer --> List) {
        my ($header, $body) = $buffer.split(/\r?\n\r?\n/, 2);
        return (Nil, $buffer) unless $body.defined;

        my $m = $header ~~ /'Content-Length:' \s* (\d+)/;
        return (Nil, $buffer) unless $m;
        my $length = $0.Int;

        return (Nil, $buffer) if $body.encode('utf-8').elems < $length;

        my $json = $body.substr(0, $length);
        my $rest = $body.substr($length);

        try {
            my $msg = parse-message($json);
            return ($msg, $rest);

            CATCH {
                default {
                    return (Nil, $rest);
                }
            }
        }
    }

    #| Send a message using Content-Length framing
    method send(MCP::JSONRPC::Message $msg --> Promise) {
        start {
            $!write-lock.protect: {
                my $json = $msg.to-json;
                my $bytes = $json.encode('utf-8');
                my $length = $bytes.elems;

                # Write header
                $!output.print("Content-Length: $length\r\n\r\n");
                # Write body
                $!output.print($json);
                $!output.flush;
            }
        }
    }

    #| Stop the transport and complete the supply
    method close(--> Promise) {
        start {
            $!running = False;
            $!supplier.done if $!supplier;
        }
    }

    #| Report whether the transport is running
    method is-connected(--> Bool) {
        $!running
    }
}

#| Create a stdio transport for server mode (reads from stdin, writes to stdout)
sub stdio-server-transport(--> StdioTransport) is export {
    StdioTransport.new(input => $*IN, output => $*OUT)
}

#| Create a stdio transport connected to a subprocess
sub subprocess-transport(Proc::Async $proc --> StdioTransport) is export {
    StdioTransport.new(
        input => $proc.stdout,
        output => $proc.stdin
    )
}
