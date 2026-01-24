#!/usr/bin/env raku
use v6.d;

=begin pod
=head1 NAME

simple-server - Minimal MCP server example using stdio transport

=head1 DESCRIPTION

Demonstrates a small MCP server that exposes a handful of tools, resources,
and prompts. The server communicates over stdio using JSON-RPC messages.

=head1 USAGE

    make run-example EXAMPLE=simple-server

=end pod

# Simple MCP Server Example
# This server provides basic tools and resources

use lib 'lib';
use MCP::Types;
use MCP::Server;
use MCP::Transport::Stdio;

# Create the server
my $server = MCP::Server::Server.new(
    info => MCP::Types::Implementation.new(
        name => 'raku-example-server',
        version => '1.0.0'
    ),
    transport => MCP::Transport::Stdio::StdioTransport.new,
    instructions => 'A simple Raku MCP server with calculator tools and greeting resources.',
);

# ============ TOOLS ============

# Add a simple calculator tool
$server.add-tool(
    name => 'add',
    description => 'Add two numbers together',
    schema => {
        type => 'object',
        properties => {
            a => { type => 'number', description => 'First number' },
            b => { type => 'number', description => 'Second number' },
        },
        required => ['a', 'b'],
    },
    handler => -> :%params {
        my $result = %params<a> + %params<b>;
        MCP::Types::TextContent.new(text => "Result: $result")
    }
);

# Subtract tool
$server.add-tool(
    name => 'subtract',
    description => 'Subtract second number from first',
    schema => {
        type => 'object',
        properties => {
            a => { type => 'number', description => 'Number to subtract from' },
            b => { type => 'number', description => 'Number to subtract' },
        },
        required => ['a', 'b'],
    },
    handler => -> :%params {
        my $result = %params<a> - %params<b>;
        "Result: $result"  # Can also return plain string
    }
);

# Multiply tool
$server.add-tool(
    name => 'multiply',
    description => 'Multiply two numbers',
    schema => {
        type => 'object',
        properties => {
            a => { type => 'number', description => 'First number' },
            b => { type => 'number', description => 'Second number' },
        },
        required => ['a', 'b'],
    },
    handler => -> :%params {
        my $result = %params<a> * %params<b>;
        "Result: $result"
    }
);

# Echo tool - returns what you send it
$server.add-tool(
    name => 'echo',
    description => 'Echo back the provided message',
    schema => {
        type => 'object',
        properties => {
            message => { type => 'string', description => 'Message to echo' },
        },
        required => ['message'],
    },
    handler => -> :%params {
        %params<message>
    }
);

# Current time tool
$server.add-tool(
    name => 'current_time',
    description => 'Get the current date and time',
    schema => {
        type => 'object',
        properties => {
            format => { 
                type => 'string', 
                description => 'Time format (iso, human, unix)',
                enum => ['iso', 'human', 'unix'],
            },
        },
    },
    handler => -> :%params {
        my $now = DateTime.now;
        given %params<format> // 'iso' {
            when 'iso'   { $now.Str }
            when 'human' { $now.Date.Str ~ ' ' ~ $now.hh-mm-ss }
            when 'unix'  { $now.posix.Str }
            default      { $now.Str }
        }
    }
);

# ============ RESOURCES ============

# Static greeting resource
$server.add-resource(
    uri => 'greeting://hello',
    name => 'Hello World',
    description => 'A friendly greeting message',
    mimeType => 'text/plain',
    reader => { 'Hello from Raku MCP Server! 🦋' }
);

# Dynamic resource - server info
$server.add-resource(
    uri => 'info://server',
    name => 'Server Info',
    description => 'Information about this server',
    mimeType => 'application/json',
    reader => {
        use JSON::Fast;
        to-json({
            name => 'raku-example-server',
            version => '1.0.0',
            raku-version => $*RAKU.version.Str,
            compiler => $*RAKU.compiler.name,
            os => $*KERNEL.name,
            tools => $server.capabilities.tools.defined ?? 'enabled' !! 'disabled',
        })
    }
);

# ============ PROMPTS ============

# Code review prompt
$server.add-prompt(
    name => 'code_review',
    description => 'Generate a code review prompt',
    arguments => [
        { name => 'language', description => 'Programming language', required => True },
        { name => 'focus', description => 'What to focus on (security, performance, style)', required => False },
    ],
    generator => -> :%params {
        my $lang = %params<language>;
        my $focus = %params<focus> // 'general quality';
        
        [
            MCP::Types::PromptMessage.new(
                role => 'user',
                content => MCP::Types::TextContent.new(
                    text => qq:to/END/
                    Please review the following $lang code with a focus on $focus.
                    
                    Provide feedback on:
                    - Code quality and readability
                    - Potential bugs or issues
                    - Suggestions for improvement
                    
                    [Paste your code here]
                    END
                )
            )
        ]
    }
);

# Explain concept prompt
$server.add-prompt(
    name => 'explain',
    description => 'Get an explanation of a concept',
    arguments => [
        { name => 'topic', description => 'Topic to explain', required => True },
        { name => 'level', description => 'Explanation level (beginner, intermediate, expert)', required => False },
    ],
    generator => -> :%params {
        my $topic = %params<topic>;
        my $level = %params<level> // 'intermediate';
        
        [
            MCP::Types::PromptMessage.new(
                role => 'user',
                content => MCP::Types::TextContent.new(
                    text => "Please explain $topic at a $level level. Include examples where helpful."
                )
            )
        ]
    }
);

# ============ START SERVER ============

say "Starting Raku MCP Server...";
say "Tools: add, subtract, multiply, echo, current_time";
say "Resources: greeting://hello, info://server";
say "Prompts: code_review, explain";
say "Listening on stdio...";

await $server.serve;
