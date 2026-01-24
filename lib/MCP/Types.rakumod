use v6.d;

unit module MCP::Types;

#| Protocol versions
our constant LATEST_PROTOCOL_VERSION is export = "2025-03-26";
our constant SUPPORTED_PROTOCOL_VERSIONS is export = <2025-03-26 2024-11-05>;

#| Implementation information for client/server identification
class Implementation is export {
    has Str $.name is required;
    has Str $.version is required;

    method Hash(--> Hash) {
        { name => $!name, version => $!version }
    }

    method from-hash(%h --> Implementation) {
        self.new(name => %h<name>, version => %h<version>)
    }
}

#| Annotations for content
class Annotations is export {
    has @.audience;      # Intended audience (user, assistant)
    has Num $.priority;  # Importance hint 0.0-1.0

    method Hash(--> Hash) {
        my %h;
        %h<audience> = @!audience if @!audience;
        %h<priority> = $!priority if $!priority.defined;
        %h
    }
}

#| Tool annotations with behavior hints
class ToolAnnotations is export {
    has Str $.title;
    has Bool $.readOnlyHint;
    has Bool $.destructiveHint;
    has Bool $.idempotentHint;
    has Bool $.openWorldHint;

    method Hash(--> Hash) {
        my %h;
        %h<title> = $_ with $!title;
        %h<readOnlyHint> = $_ with $!readOnlyHint;
        %h<destructiveHint> = $_ with $!destructiveHint;
        %h<idempotentHint> = $_ with $!idempotentHint;
        %h<openWorldHint> = $_ with $!openWorldHint;
        %h
    }
}

#| Base role for content types
role Content is export {
    method type(--> Str) { ... }
    method Hash(--> Hash) { ... }
}

#| Text content
class TextContent does Content is export {
    has Str $.text is required;
    has Annotations $.annotations;

    method type(--> Str) { 'text' }

    method Hash(--> Hash) {
        my %h = type => 'text', text => $!text;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h
    }

    method from-hash(%h --> TextContent) {
        self.new(
            text => %h<text>,
            annotations => %h<annotations> ?? Annotations.new(|%h<annotations>) !! Annotations
        )
    }
}

#| Image content (base64 encoded)
class ImageContent does Content is export {
    has Str $.data is required;      # base64 encoded
    has Str $.mimeType is required;
    has Annotations $.annotations;

    method type(--> Str) { 'image' }

    method Hash(--> Hash) {
        my %h = type => 'image', data => $!data, mimeType => $!mimeType;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h
    }
}

#| Embedded resource content
class EmbeddedResource does Content is export {
    has $.resource is required;  # ResourceContents
    has Annotations $.annotations;

    method type(--> Str) { 'resource' }

    method Hash(--> Hash) {
        my %h = type => 'resource', resource => $!resource.Hash;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h
    }
}

#| Tool definition
class Tool is export {
    has Str $.name is required;
    has Str $.description;
    has Hash $.inputSchema;
    has ToolAnnotations $.annotations;

    method Hash(--> Hash) {
        my %h = name => $!name;
        %h<description> = $_ with $!description;
        %h<inputSchema> = $_ with $!inputSchema;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h
    }

    method from-hash(%h --> Tool) {
        self.new(
            name => %h<name>,
            description => %h<description>,
            inputSchema => %h<inputSchema>,
            annotations => %h<annotations> ?? ToolAnnotations.new(|%h<annotations>) !! ToolAnnotations
        )
    }
}

#| Result of calling a tool
class CallToolResult is export {
    has @.content;   # Array of Content objects
    has Bool $.isError = False;

    method Hash(--> Hash) {
        {
            content => @!content.map(*.Hash).Array,
            isError => $!isError
        }
    }
}

#| Resource definition
class Resource is export {
    has Str $.uri is required;
    has Str $.name is required;
    has Str $.description;
    has Str $.mimeType;
    has Annotations $.annotations;

    method Hash(--> Hash) {
        my %h = uri => $!uri, name => $!name;
        %h<description> = $_ with $!description;
        %h<mimeType> = $_ with $!mimeType;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h
    }

    method from-hash(%h --> Resource) {
        self.new(
            uri => %h<uri>,
            name => %h<name>,
            description => %h<description>,
            mimeType => %h<mimeType>,
        )
    }
}

#| Resource contents
class ResourceContents is export {
    has Str $.uri is required;
    has Str $.mimeType;
    has Str $.text;
    has Blob $.blob;

    method Hash(--> Hash) {
        my %h = uri => $!uri;
        %h<mimeType> = $_ with $!mimeType;
        %h<text> = $_ with $!text;
        %h<blob> = $!blob.decode('latin-1') if $!blob;  # base64 in real impl
        %h
    }
}

#| Prompt argument definition
class PromptArgument is export {
    has Str $.name is required;
    has Str $.description;
    has Bool $.required = False;

    method Hash(--> Hash) {
        my %h = name => $!name;
        %h<description> = $_ with $!description;
        %h<required> = $!required;
        %h
    }
}

#| Prompt definition
class Prompt is export {
    has Str $.name is required;
    has Str $.description;
    has @.arguments;  # Array of PromptArgument

    method Hash(--> Hash) {
        my %h = name => $!name;
        %h<description> = $_ with $!description;
        %h<arguments> = @!arguments.map(*.Hash).Array if @!arguments;
        %h
    }

    method from-hash(%h --> Prompt) {
        self.new(
            name => %h<name>,
            description => %h<description>,
            arguments => (%h<arguments> // []).map({ PromptArgument.new(|$_) }).Array
        )
    }
}

#| Prompt message
class PromptMessage is export {
    has Str $.role is required where * ~~ any(<user assistant>);
    has $.content is required;  # Content or array of Content

    method Hash(--> Hash) {
        {
            role => $!role,
            content => $!content ~~ Positional
                ?? $!content.map(*.Hash).Array
                !! $!content.Hash
        }
    }
}

#| Server capabilities sub-types
class LoggingCapability is export {
    method Hash(--> Hash) { {} }
}

class PromptsCapability is export {
    has Bool $.listChanged;

    method Hash(--> Hash) {
        my %h;
        %h<listChanged> = $_ with $!listChanged;
        %h
    }
}

class ResourcesCapability is export {
    has Bool $.subscribe;
    has Bool $.listChanged;

    method Hash(--> Hash) {
        my %h;
        %h<subscribe> = $_ with $!subscribe;
        %h<listChanged> = $_ with $!listChanged;
        %h
    }
}

class ToolsCapability is export {
    has Bool $.listChanged;

    method Hash(--> Hash) {
        my %h;
        %h<listChanged> = $_ with $!listChanged;
        %h
    }
}

#| Full server capabilities
class ServerCapabilities is export {
    has Bool $.experimental;
    has LoggingCapability $.logging;
    has PromptsCapability $.prompts;
    has ResourcesCapability $.resources;
    has ToolsCapability $.tools;

    method Hash(--> Hash) {
        my %h;
        %h<experimental> = {} if $!experimental;
        %h<logging> = $!logging.Hash if $!logging;
        %h<prompts> = $!prompts.Hash if $!prompts;
        %h<resources> = $!resources.Hash if $!resources;
        %h<tools> = $!tools.Hash if $!tools;
        %h
    }

    method from-hash(%h --> ServerCapabilities) {
        self.new(
            experimental => %h<experimental>.defined,
            logging => %h<logging> ?? LoggingCapability.new !! LoggingCapability,
            prompts => %h<prompts> ?? PromptsCapability.new(|%h<prompts>) !! PromptsCapability,
            resources => %h<resources> ?? ResourcesCapability.new(|%h<resources>) !! ResourcesCapability,
            tools => %h<tools> ?? ToolsCapability.new(|%h<tools>) !! ToolsCapability,
        )
    }
}

#| Client capabilities sub-types
class RootsCapability is export {
    has Bool $.listChanged;

    method Hash(--> Hash) {
        my %h;
        %h<listChanged> = $_ with $!listChanged;
        %h
    }
}

class SamplingCapability is export {
    method Hash(--> Hash) { {} }
}

class ElicitationCapability is export {
    method Hash(--> Hash) { {} }
}

#| Full client capabilities
class ClientCapabilities is export {
    has Bool $.experimental;
    has RootsCapability $.roots;
    has SamplingCapability $.sampling;
    has ElicitationCapability $.elicitation;

    method Hash(--> Hash) {
        my %h;
        %h<experimental> = {} if $!experimental;
        %h<roots> = $!roots.Hash if $!roots;
        %h<sampling> = $!sampling.Hash if $!sampling;
        %h<elicitation> = $!elicitation.Hash if $!elicitation;
        %h
    }
}

#| Progress information for long-running operations
class Progress is export {
    has $.progressToken is required;
    has Num $.progress is required;
    has Num $.total;
    has Str $.message;

    method Hash(--> Hash) {
        my %h = progressToken => $!progressToken, progress => $!progress;
        %h<total> = $_ with $!total;
        %h<message> = $_ with $!message;
        %h
    }
}

#| Log levels
enum LogLevel is export (
    Debug     => 'debug',
    Info      => 'info',
    Notice    => 'notice',
    Warning   => 'warning',
    Error     => 'error',
    Critical  => 'critical',
    Alert     => 'alert',
    Emergency => 'emergency',
);

#| Log entry
class LogEntry is export {
    has LogLevel $.level is required;
    has Str $.logger;
    has $.data is required;  # Any JSON-serializable data

    method Hash(--> Hash) {
        my %h = level => $!level.value, data => $!data;
        %h<logger> = $_ with $!logger;
        %h
    }
}
