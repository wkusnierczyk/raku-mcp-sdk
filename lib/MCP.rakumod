use v6.d;

unit module MCP;

# Re-export all MCP modules
need MCP::Types;
need MCP::JSONRPC;
use MCP::Transport::Base;
need MCP::Transport::Stdio;
need MCP::Server;
need MCP::Server::Tool;
need MCP::Server::Resource;
need MCP::Server::Prompt;
need MCP::Client;

# Re-export commonly used symbols
our constant PROTOCOL_VERSION is export = MCP::Types::LATEST_PROTOCOL_VERSION;

# Re-export types
sub Implementation(|c) is export { MCP::Types::Implementation.new(|c) }
sub TextContent(|c) is export { MCP::Types::TextContent.new(|c) }
sub ImageContent(|c) is export { MCP::Types::ImageContent.new(|c) }
sub Tool(|c) is export { MCP::Types::Tool.new(|c) }
sub Resource(|c) is export { MCP::Types::Resource.new(|c) }
sub Prompt(|c) is export { MCP::Types::Prompt.new(|c) }

# Re-export server components
sub Server(|c) is export { MCP::Server::Server.new(|c) }
sub StdioTransport(|c) is export { MCP::Transport::Stdio::StdioTransport.new(|c) }

# Re-export client
sub Client(|c) is export { MCP::Client::Client.new(|c) }


# Re-export log levels
constant Debug is export = MCP::Types::Debug;
constant Info is export = MCP::Types::Info;
constant Warning is export = MCP::Types::Warning;
constant Error is export = MCP::Types::Error;
