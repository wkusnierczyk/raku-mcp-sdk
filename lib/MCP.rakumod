use v6.d;

#| Top-level convenience exports for the MCP SDK
unit module MCP;

=begin pod
=head1 NAME

MCP - Top-level convenience exports for the MCP SDK

=head1 SYNOPSIS

    use MCP;

    my $server = Server.new(...);
    my $client = Client.new(...);

=head1 DESCRIPTION

Re-exports core MCP types, builders, and transport classes to reduce the number
of explicit module imports required in typical usage.

=head1 RE-EXPORTS

Using C<use MCP;> imports the following into scope:

=head2 Classes

=item C<Server> — C<MCP::Server::Server>
=item C<Client> — C<MCP::Client::Client>
=item C<StdioTransport> — C<MCP::Transport::Stdio::StdioTransport>
=item C<StreamableHTTPServerTransport> — C<MCP::Transport::StreamableHTTP::StreamableHTTPServerTransport>
=item C<StreamableHTTPClientTransport> — C<MCP::Transport::StreamableHTTP::StreamableHTTPClientTransport>

=head2 Builder functions

=item C<tool()> — Create a C<ToolBuilder>
=item C<resource()> — Create a C<ResourceBuilder>
=item C<file-resource($path)> — Create a file-backed resource
=item C<resource-template()> — Create a C<ResourceTemplateBuilder>
=item C<prompt()> — Create a C<PromptBuilder>

=head2 Types and constants

All types from C<MCP::Types> (Content classes, Tool, Resource, Prompt,
capabilities, enums, etc.) and the current protocol version constant.

=head1 SEE ALSO

For detailed API documentation, see the individual modules:
C<MCP::Server>, C<MCP::Client>, C<MCP::Types>, C<MCP::JSONRPC>,
C<MCP::Transport::Base>, C<MCP::Transport::Stdio>,
C<MCP::Transport::StreamableHTTP>, C<MCP::Transport::SSE>,
C<MCP::OAuth>, C<MCP::OAuth::Client>, C<MCP::OAuth::Server>.

=end pod

# Re-export all MCP modules
need MCP::Types;
need MCP::JSONRPC;
need MCP::Transport::Base;
need MCP::Transport::Stdio;
need MCP::Transport::StreamableHTTP;
need MCP::Server;
need MCP::Server::Tool;
need MCP::Server::Resource;
need MCP::Server::Prompt;
need MCP::Client;

#| Latest supported protocol version string
our constant PROTOCOL_VERSION is export = MCP::Types::LATEST_PROTOCOL_VERSION;

#| Re-exported core type constructors
constant Implementation is export = MCP::Types::Implementation;
constant TextContent is export = MCP::Types::TextContent;
constant ImageContent is export = MCP::Types::ImageContent;
constant AudioContent is export = MCP::Types::AudioContent;
constant ResourceLink is export = MCP::Types::ResourceLink;
constant ToolUseContent is export = MCP::Types::ToolUseContent;
constant ToolResultContent is export = MCP::Types::ToolResultContent;
constant Tool is export = MCP::Types::Tool;
constant Resource is export = MCP::Types::Resource;
constant Prompt is export = MCP::Types::Prompt;
constant SamplingMessage is export = MCP::Types::SamplingMessage;
constant ModelHint is export = MCP::Types::ModelHint;
constant ModelPreferences is export = MCP::Types::ModelPreferences;
constant ToolChoice is export = MCP::Types::ToolChoice;
constant CreateMessageResult is export = MCP::Types::CreateMessageResult;
constant Task is export = MCP::Types::Task;
constant TaskStatus is export = MCP::Types::TaskStatus;
constant CreateTaskResult is export = MCP::Types::CreateTaskResult;
constant ResourceTemplate is export = MCP::Types::ResourceTemplate;
constant Extension is export = MCP::Types::Extension;

#| Re-exported log level constants
constant Debug is export = MCP::Types::Debug;
constant Info is export = MCP::Types::Info;
constant Warning is export = MCP::Types::Warning;
constant Error is export = MCP::Types::Error;

#| Re-exported server and transport classes
constant Server is export = MCP::Server::Server;
constant Transport is export = MCP::Transport::Base::Transport;
constant StdioTransport is export = MCP::Transport::Stdio::StdioTransport;
constant StreamableHTTPServerTransport is export = MCP::Transport::StreamableHTTP::StreamableHTTPServerTransport;
constant StreamableHTTPClientTransport is export = MCP::Transport::StreamableHTTP::StreamableHTTPClientTransport;

#| Re-exported client class
constant Client is export = MCP::Client::Client;

#| Builder for tool definitions
sub tool is export {
    require ::MCP::Server::Tool;
    ::('MCP::Server::Tool').WHO<&tool>()
}
#| Builder for resource definitions
sub resource is export {
    require ::MCP::Server::Resource;
    ::('MCP::Server::Resource').WHO<&resource>()
}
#| Convenience builder for file-backed resources
sub file-resource(|c) is export {
    require ::MCP::Server::Resource;
    ::('MCP::Server::Resource').WHO<&file-resource>(|c)
}
#| Builder for resource template definitions
sub resource-template is export {
    require ::MCP::Server::Resource;
    ::('MCP::Server::Resource').WHO<&resource-template>()
}
#| Builder for prompt definitions
sub prompt is export {
    require ::MCP::Server::Prompt;
    ::('MCP::Server::Prompt').WHO<&prompt>()
}
