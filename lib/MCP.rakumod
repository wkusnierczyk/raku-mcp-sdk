use v6.d;

unit module MCP;

# Re-export all MCP modules
use MCP::Types;
use MCP::JSONRPC;
use MCP::Transport::Base;
use MCP::Transport::Stdio;
use MCP::Server;
use MCP::Server::Tool;
use MCP::Server::Resource;
use MCP::Server::Prompt;
use MCP::Client;

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

# Re-export builders
sub tool is export { MCP::Server::Tool::tool() }
sub resource is export { MCP::Server::Resource::resource() }
sub prompt is export { MCP::Server::Prompt::prompt() }

# Re-export log levels
constant Debug is export = MCP::Types::Debug;
constant Info is export = MCP::Types::Info;
constant Warning is export = MCP::Types::Warning;
constant Error is export = MCP::Types::Error;
