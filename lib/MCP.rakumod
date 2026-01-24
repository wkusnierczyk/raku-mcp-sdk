use v6.d;

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

# Re-export commonly used symbols
our constant PROTOCOL_VERSION is export = MCP::Types::LATEST_PROTOCOL_VERSION;

# Re-export types
constant Implementation is export = MCP::Types::Implementation;
constant TextContent is export = MCP::Types::TextContent;
constant ImageContent is export = MCP::Types::ImageContent;
constant Tool is export = MCP::Types::Tool;
constant Resource is export = MCP::Types::Resource;
constant Prompt is export = MCP::Types::Prompt;

# Re-export log levels
constant Debug is export = MCP::Types::Debug;
constant Info is export = MCP::Types::Info;
constant Warning is export = MCP::Types::Warning;
constant Error is export = MCP::Types::Error;

# Re-export server components
constant Server is export = MCP::Server::Server;
constant Transport is export = MCP::Transport::Base::Transport;
constant StdioTransport is export = MCP::Transport::Stdio::StdioTransport;

# Re-export client
constant Client is export = MCP::Client::Client;

# Re-export builders
sub tool is export { MCP::Server::Tool::tool() }
sub resource is export { MCP::Server::Resource::resource() }
sub file-resource(|c) is export { MCP::Server::Resource::file-resource(|c) }
sub prompt is export { MCP::Server::Prompt::prompt() }
