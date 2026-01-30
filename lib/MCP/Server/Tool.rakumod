use v6.d;

#| Tool registration helpers and builder DSL
unit module MCP::Server::Tool;

=begin pod
=head1 NAME

MCP::Server::Tool - Tool registration helpers

=head1 DESCRIPTION

Provides a builder-style DSL and wrapper class for registering MCP tools.

=head1 FUNCTIONS

=head2 sub tool(--> ToolBuilder)

Create a new tool builder. Chain methods to define the tool, then call
C<.build> to produce a C<RegisteredTool>.

    my $t = tool()
        .name('add')
        .description('Add two numbers')
        .number-param('a', description => 'First', :required)
        .number-param('b', description => 'Second', :required)
        .handler(-> :%params { %params<a> + %params<b> })
        .build;

=head2 sub validate-tool-name(Str $name)

Validate that a tool name matches the MCP spec pattern:
C<^[a-zA-Z0-9_-]{1,64}$>. Dies on invalid names.

=head1 CLASSES

=head2 ToolBuilder

Fluent builder for tool definitions. Available chain methods:

=item C<.name(Str)> — Tool name (required).
=item C<.description(Str)> — Human-readable description.
=item C<.input-schema(%schema)> — Raw JSON Schema for input.
=item C<.output-schema(%schema)> — JSON Schema for structured output.
=item C<.string-param(Str, :$description, :$required, :$enum)> — Add a string parameter.
=item C<.number-param(Str, :$description, :$required)> — Add a number parameter.
=item C<.integer-param(Str, :$description, :$required)> — Add an integer parameter.
=item C<.boolean-param(Str, :$description, :$required)> — Add a boolean parameter.
=item C<.array-param(Str, :$description, :$required, :%items)> — Add an array parameter.
=item C<.object-param(Str, :$description, :$required, :%properties)> — Add an object parameter.
=item C<.annotations(...)> — Set tool annotations (C<title>, C<readOnly>, C<destructive>, etc.).
=item C<.handler(&callable)> — The handler block (required).
=item C<.build(--> RegisteredTool)> — Finalize the tool.

=head2 RegisteredTool

Wrapper holding a C<Tool> definition and its handler.

=item C<.to-tool(--> Tool)> — Get the tool definition for listing.
=item C<.call(%arguments --> CallToolResult)> — Call the handler with arguments.

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
    has Str $.title;
    has @.icons;
    has Hash $.inputSchema;
    has Hash $.outputSchema;
    has MCP::Types::ToolAnnotations $.annotations;
    has MCP::Types::TaskExecution $.execution;
    has &.handler is required;

    #| Get the Tool definition for listing
    method to-tool(--> MCP::Types::Tool) {
        MCP::Types::Tool.new(
            :$!name,
            :$!description,
            :$!title,
            :@!icons,
            :$!inputSchema,
            :$!outputSchema,
            :$!annotations,
            :$!execution,
        )
    }

    #| Call the tool with given arguments
    method call(%arguments --> MCP::Types::CallToolResult) {
        my $result =
            (try &!handler(:params(%arguments)))
            // (try &!handler(|%arguments))
            // (try &!handler(%arguments))
            // &!handler();

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
    has Str $.name;
    has Str $.description;
    has Str $.title;
    has @.icons;
    has Hash $.inputSchema = { type => 'object', properties => {}, required => [] };
    has Hash $.outputSchema;
    has MCP::Types::ToolAnnotations $.annotations;
    has MCP::Types::TaskExecution $.execution;
    has &.handler;

    method name(Str $!name --> ToolBuilder) { self }

    method description(Str $!description --> ToolBuilder) { self }

    method title(Str $!title --> ToolBuilder) { self }

    method icon(Str $src, Str :$mimeType, :@sizes --> ToolBuilder) {
        @!icons.push(MCP::Types::IconDefinition.new(:$src, :$mimeType, :@sizes));
        self
    }

    method schema(Hash $!inputSchema --> ToolBuilder) { self }

    method input-schema(Hash $!inputSchema --> ToolBuilder) { self }

    method output-schema(Hash $!outputSchema --> ToolBuilder) { self }

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

    method handler(&!handler --> ToolBuilder) { self }

    method build(--> RegisteredTool) {
        die "Tool name is required" unless $!name;
        validate-tool-name($!name);
        die "Tool handler is required" unless &!handler;

        RegisteredTool.new(
            :$!name,
            :$!description,
            :$!title,
            :@!icons,
            :$!inputSchema,
            :$!outputSchema,
            :$!annotations,
            :$!execution,
            :&!handler,
        )
    }
}

#| Convenience function to create a tool builder
our sub tool(--> ToolBuilder) is export {
    ToolBuilder.new
}
