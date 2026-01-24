use v6.d;

#| Top-level convenience exports for the MCP SDK
unit module MCP;

# Re-export all MCP modules
need MCP::Types;
need MCP::JSONRPC;
need MCP::Transport::Base;
need MCP::Transport::Stdio;
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
constant Tool is export = MCP::Types::Tool;
constant Resource is export = MCP::Types::Resource;
constant Prompt is export = MCP::Types::Prompt;

#| Re-exported log level constants
constant Debug is export = MCP::Types::Debug;
constant Info is export = MCP::Types::Info;
constant Warning is export = MCP::Types::Warning;
constant Error is export = MCP::Types::Error;

#| Re-exported server and transport classes
constant Server is export = MCP::Server::Server;
constant Transport is export = MCP::Transport::Base::Transport;
constant StdioTransport is export = MCP::Transport::Stdio::StdioTransport;

#| Re-exported client class
constant Client is export = MCP::Client::Client;

#| Builder for tool definitions
sub tool is export { MCP::Server::Tool::tool() }
#| Builder for resource definitions
sub resource is export { MCP::Server::Resource::resource() }
#| Convenience builder for file-backed resources
sub file-resource(|c) is export { MCP::Server::Resource::file-resource(|c) }
#| Builder for prompt definitions
sub prompt is export { MCP::Server::Prompt::prompt() }
