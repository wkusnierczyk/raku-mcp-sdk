use v6.d;

#| Tool registration helpers and builder DSL
unit module MCP::Server::Tool;

=begin pod
=head1 NAME

MCP::Server::Tool - Tool registration helpers

=head1 DESCRIPTION

Provides a builder-style DSL and wrapper class for registering MCP tools.

=end pod

use MCP::Types;

#| Validate tool name matches MCP spec pattern: ^[a-zA-Z0-9_-]{1,64}$
our sub validate-tool-name(Str $name) is export {
    unless $name ~~ /^ <[a..zA..Z0..9_\-]> ** 1..64 $/ {
        die "Invalid tool name '$name': must match ^[a-zA-Z0-9_-]\{1,64\}\$ (letters, digits, underscores, hyphens; 1-64 characters)";
    }
}

#| Wrapper class for a registered tool with its handler
class RegisteredTool is export {
    has Str $.name is required;
    has Str $.description;
    has Hash $.inputSchema;
    has Hash $.outputSchema;
    has MCP::Types::ToolAnnotations $.annotations;
    has MCP::Types::TaskExecution $.execution;
    has &.handler is required;

    #| Get the Tool definition for listing
    method to-tool(--> MCP::Types::Tool) {
        MCP::Types::Tool.new(
            name => $!name,
            description => $!description,
            inputSchema => $!inputSchema,
            outputSchema => $!outputSchema,
            annotations => $!annotations,
            execution => $!execution,
        )
    }

    #| Call the tool with given arguments
    method call(%arguments --> MCP::Types::CallToolResult) {
        my $result;
        my $called = False;
        try {
            $result = &!handler(:params(%arguments));
            $called = True;
            CATCH {
                when X::AdHoc | X::Multi::NoMatch { }
                default { .rethrow }
            }
        }
        if !$called {
            try {
                $result = &!handler(|%arguments);
                $called = True;
                CATCH {
                    when X::AdHoc | X::Multi::NoMatch { }
                    default { .rethrow }
                }
            }
        }
        if !$called {
            try {
                $result = &!handler(%arguments);
                $called = True;
                CATCH {
                    when X::AdHoc | X::Multi::NoMatch { }
                    default { .rethrow }
                }
            }
        }
        if !$called {
            $result = &!handler();
        }

        # Normalize result to CallToolResult
        given $result {
            when MCP::Types::CallToolResult {
                return $result;
            }
            when MCP::Types::Content {
                return MCP::Types::CallToolResult.new(content => [$result]);
            }
            when Hash {
                # If tool has outputSchema, treat Hash as structuredContent
                if $!outputSchema {
                    return MCP::Types::CallToolResult.new(
                        structuredContent => $result,
                        content => [MCP::Types::TextContent.new(text => $result.raku)],
                    );
                }
                return MCP::Types::CallToolResult.new(
                    content => [MCP::Types::TextContent.new(text => $result.Str)]
                );
            }
            when Str {
                return MCP::Types::CallToolResult.new(
                    content => [MCP::Types::TextContent.new(text => $result)]
                );
            }
            when Positional {
                return MCP::Types::CallToolResult.new(content => $result.Array);
            }
            default {
                return MCP::Types::CallToolResult.new(
                    content => [MCP::Types::TextContent.new(text => $result.Str)]
                );
            }
        }
    }
}

#| Builder for creating tool definitions
class ToolBuilder is export {
    has Str $!name;
    has Str $!description;
    has Hash $!inputSchema = { type => 'object', properties => {}, required => [] };
    has Hash $!outputSchema;
    has MCP::Types::ToolAnnotations $!annotations;
    has MCP::Types::TaskExecution $!execution;
    has &!handler;

    method name(Str $name --> ToolBuilder) {
        $!name = $name;
        self
    }

    method description(Str $desc --> ToolBuilder) {
        $!description = $desc;
        self
    }

    method schema(Hash $schema --> ToolBuilder) {
        $!inputSchema = $schema;
        self
    }

    method input-schema(Hash $schema --> ToolBuilder) {
        $!inputSchema = $schema;
        self
    }

    method output-schema(Hash $schema --> ToolBuilder) {
        $!outputSchema = $schema;
        self
    }

    #| Add a string parameter
    method string-param(Str $name, Str :$description, Bool :$required --> ToolBuilder) {
        $!inputSchema<properties>{$name} = {
            type => 'string',
            ($description ?? (description => $description) !! Empty)
        };
        $!inputSchema<required>.push($name) if $required;
        self
    }

    #| Add a number parameter
    method number-param(Str $name, Str :$description, Bool :$required --> ToolBuilder) {
        $!inputSchema<properties>{$name} = {
            type => 'number',
            ($description ?? (description => $description) !! Empty)
        };
        $!inputSchema<required>.push($name) if $required;
        self
    }

    #| Add an integer parameter
    method integer-param(Str $name, Str :$description, Bool :$required --> ToolBuilder) {
        $!inputSchema<properties>{$name} = {
            type => 'integer',
            ($description ?? (description => $description) !! Empty)
        };
        $!inputSchema<required>.push($name) if $required;
        self
    }

    #| Add a boolean parameter
    method boolean-param(Str $name, Str :$description, Bool :$required --> ToolBuilder) {
        $!inputSchema<properties>{$name} = {
            type => 'boolean',
            ($description ?? (description => $description) !! Empty)
        };
        $!inputSchema<required>.push($name) if $required;
        self
    }

    #| Add an array parameter
    method array-param(Str $name, Str :$description, Hash :$items, Bool :$required --> ToolBuilder) {
        $!inputSchema<properties>{$name} = {
            type => 'array',
            ($description ?? (description => $description) !! Empty),
            ($items ?? (items => $items) !! Empty)
        };
        $!inputSchema<required>.push($name) if $required;
        self
    }

    #| Set annotations (supports both short names and spec names with Hint suffix)
    method annotations(
        Str :$title,
        Bool :$readOnly,
        Bool :$readOnlyHint,
        Bool :$destructive,
        Bool :$destructiveHint,
        Bool :$idempotent,
        Bool :$idempotentHint,
        Bool :$openWorld,
        Bool :$openWorldHint
    --> ToolBuilder) {
        $!annotations = MCP::Types::ToolAnnotations.new(
            title => $title,
            readOnlyHint => $readOnly // $readOnlyHint,
            destructiveHint => $destructive // $destructiveHint,
            idempotentHint => $idempotent // $idempotentHint,
            openWorldHint => $openWorld // $openWorldHint,
        );
        self
    }

    #| Set task support level (forbidden, optional, required)
    method task-support(Str $level --> ToolBuilder) {
        my $ts = do given $level {
            when 'forbidden' { MCP::Types::TaskForbidden }
            when 'optional'  { MCP::Types::TaskOptional }
            when 'required'  { MCP::Types::TaskRequired }
            default          { MCP::Types::TaskOptional }
        };
        $!execution = MCP::Types::TaskExecution.new(taskSupport => $ts);
        self
    }

    method handler(&handler --> ToolBuilder) {
        &!handler = &handler;
        self
    }

    method build(--> RegisteredTool) {
        die "Tool name is required" unless $!name;
        validate-tool-name($!name);
        die "Tool handler is required" unless &!handler;

        RegisteredTool.new(
            name => $!name,
            description => $!description,
            inputSchema => $!inputSchema,
            outputSchema => $!outputSchema,
            annotations => $!annotations,
            execution => $!execution,
            handler => &!handler,
        )
    }
}

#| Convenience function to create a tool builder
our sub tool(--> ToolBuilder) is export {
    ToolBuilder.new
}
