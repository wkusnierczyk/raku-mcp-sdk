use v6.d;

#| Prompt registration helpers and builder DSL
unit module MCP::Server::Prompt;

=begin pod
=head1 NAME

MCP::Server::Prompt - Prompt registration helpers

=head1 DESCRIPTION

Provides a builder-style DSL and wrapper class for registering MCP prompts.

=end pod

use MCP::Types;

#| Wrapper class for a registered prompt with its generator
class RegisteredPrompt is export {
    has Str $.name is required;
    has Str $.description;
    has @.arguments;  # Array of PromptArgument
    has &.generator is required;

    #| Get the Prompt definition for listing
    method to-prompt(--> MCP::Types::Prompt) {
        MCP::Types::Prompt.new(
            name => $!name,
            description => $!description,
            arguments => @!arguments,
        )
    }

    #| Generate the prompt messages
    method get(%arguments --> Array) {
        my $result;
        my $called = False;
        try {
            $result = &!generator(:params(%arguments));
            $called = True;
            CATCH {
                when X::AdHoc | X::Multi::NoMatch { }
                default { .rethrow }
            }
        }
        if !$called {
            try {
                $result = &!generator(|%arguments);
                $called = True;
                CATCH {
                    when X::AdHoc | X::Multi::NoMatch { }
                    default { .rethrow }
                }
            }
        }
        if !$called {
            try {
                $result = &!generator(%arguments);
                $called = True;
                CATCH {
                    when X::AdHoc | X::Multi::NoMatch { }
                    default { .rethrow }
                }
            }
        }
        if !$called {
            $result = &!generator();
        }

        # Normalize to array of PromptMessage
        given $result {
            when MCP::Types::PromptMessage {
                return [$result];
            }
            when Positional {
                return $result.Array;
            }
            when Str {
                return [MCP::Types::PromptMessage.new(
                    role => 'user',
                    content => MCP::Types::TextContent.new(text => $result)
                )];
            }
            default {
                return [MCP::Types::PromptMessage.new(
                    role => 'user',
                    content => MCP::Types::TextContent.new(text => $result.Str)
                )];
            }
        }
    }
}

#| Builder for creating prompt definitions
class PromptBuilder is export {
    has Str $!name;
    has Str $!description;
    has @!arguments;
    has &!generator;

    method name(Str $name --> PromptBuilder) {
        $!name = $name;
        self
    }

    method description(Str $desc --> PromptBuilder) {
        $!description = $desc;
        self
    }

    #| Add an argument
    method argument(Str $name, :$description?, Bool :$required --> PromptBuilder) {
        my %args = :$name, :$required;
        %args<description> = $description if $description.defined;
        @!arguments.push(MCP::Types::PromptArgument.new(|%args));
        self
    }

    #| Add a required argument
    method required-argument(Str $name, :$description --> PromptBuilder) {
        self.argument($name, :$description, :required)
    }

    #| Add an optional argument
    method optional-argument(Str $name, :$description --> PromptBuilder) {
        self.argument($name, :$description, :!required)
    }

    method generator(&generator --> PromptBuilder) {
        &!generator = &generator;
        self
    }

    method build(--> RegisteredPrompt) {
        die "Prompt name is required" unless $!name;
        die "Prompt generator is required" unless &!generator;

        RegisteredPrompt.new(
            name => $!name,
            description => $!description,
            arguments => @!arguments,
            generator => &!generator,
        )
    }
}

#| Convenience function to create a prompt builder
our sub prompt(--> PromptBuilder) is export {
    PromptBuilder.new
}

#| Helper to create a simple user message
our sub user-message(Str $text --> MCP::Types::PromptMessage) is export {
    MCP::Types::PromptMessage.new(
        role => 'user',
        content => MCP::Types::TextContent.new(:$text)
    )
}

#| Helper to create a simple assistant message
our sub assistant-message(Str $text --> MCP::Types::PromptMessage) is export {
    MCP::Types::PromptMessage.new(
        role => 'assistant',
        content => MCP::Types::TextContent.new(:$text)
    )
}
