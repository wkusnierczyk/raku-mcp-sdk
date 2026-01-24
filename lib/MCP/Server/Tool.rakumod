use v6.d;

#| Tool registration helpers and builder DSL
unit module MCP::Server::Tool;

use MCP::Types;

#| Wrapper class for a registered tool with its handler
class RegisteredTool is export {
    has Str $.name is required;
    has Str $.description;
    has Hash $.inputSchema;
    has MCP::Types::ToolAnnotations $.annotations;
    has &.handler is required;

    #| Get the Tool definition for listing
    method to-tool(--> MCP::Types::Tool) {
        MCP::Types::Tool.new(
            name => $!name,
            description => $!description,
            inputSchema => $!inputSchema,
            annotations => $!annotations,
        )
    }

    #| Call the tool with given arguments
    method call(%arguments --> MCP::Types::CallToolResult) {
        my $result = &!handler(%arguments);

        # Normalize result to CallToolResult
        given $result {
            when MCP::Types::CallToolResult {
                return $result;
            }
            when MCP::Types::Content {
                return MCP::Types::CallToolResult.new(content => [$result]);
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
    has MCP::Types::ToolAnnotations $!annotations;
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

    #| Set annotations
    method annotations(
        Str :$title,
        Bool :$readOnly,
        Bool :$destructive,
        Bool :$idempotent,
        Bool :$openWorld
    --> ToolBuilder) {
        $!annotations = MCP::Types::ToolAnnotations.new(
            title => $title,
            readOnlyHint => $readOnly,
            destructiveHint => $destructive,
            idempotentHint => $idempotent,
            openWorldHint => $openWorld,
        );
        self
    }

    method handler(&handler --> ToolBuilder) {
        &!handler = &handler;
        self
    }

    method build(--> RegisteredTool) {
        die "Tool name is required" unless $!name;
        die "Tool handler is required" unless &!handler;

        RegisteredTool.new(
            name => $!name,
            description => $!description,
            inputSchema => $!inputSchema,
            annotations => $!annotations,
            handler => &!handler,
        )
    }
}

#| Convenience function to create a tool builder
sub tool(--> ToolBuilder) is export {
    ToolBuilder.new
}
