use v6.d;

#| Core MCP data types and capability structures
unit module MCP::Types;

=begin pod
=head1 NAME

MCP::Types - Core MCP data types

=head1 DESCRIPTION

Defines MCP protocol data structures (content types, tools, resources, prompts,
capabilities, and logging). These types are used by both clients and servers
for serialization and validation.

=end pod

#| Protocol versions
our constant LATEST_PROTOCOL_VERSION is export = "2025-11-25";
our constant SUPPORTED_PROTOCOL_VERSIONS is export = <2025-11-25 2025-03-26 2024-11-05>;

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

#| Audio content (base64 encoded)
class AudioContent does Content is export {
    has Str $.data is required;      # base64 encoded
    has Str $.mimeType is required;
    has Annotations $.annotations;

    method type(--> Str) { 'audio' }

    method Hash(--> Hash) {
        my %h = type => 'audio', data => $!data, mimeType => $!mimeType;
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

#| Resource link content
class ResourceLink does Content is export {
    has Str $.name is required;
    has Str $.title;
    has Str $.uri is required;
    has Str $.description;
    has Str $.mimeType;
    has Annotations $.annotations;
    has Int $.size;

    method type(--> Str) { 'resource_link' }

    method Hash(--> Hash) {
        my %h = type => 'resource_link', name => $!name, uri => $!uri;
        %h<title> = $_ with $!title;
        %h<description> = $_ with $!description;
        %h<mimeType> = $_ with $!mimeType;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h<size> = $_ with $!size;
        %h
    }
}

#| Tool use content
class ToolUseContent does Content is export {
    has Str $.id is required;
    has Str $.name is required;
    has $.input is required; # Hash or Array

    method type(--> Str) { 'tool_use' }

    method Hash(--> Hash) {
        {
            type => 'tool_use',
            id => $!id,
            name => $!name,
            input => $!input
        }
    }
}

#| Tool result content
class ToolResultContent does Content is export {
    has @.content;     # Array of Content objects
    has Str $.toolUseId is required;
    has Bool $.isError = False;
    has $.structuredContent;
    has $.meta;

    method type(--> Str) { 'tool_result' }

    method Hash(--> Hash) {
        my %h = type => 'tool_result', toolUseId => $!toolUseId;
        %h<content> = @!content.map(*.Hash).Array;
        %h<isError> = $!isError if $!isError.defined;
        %h<structuredContent> = $_ with $!structuredContent;
        %h<_meta> = $_ with $!meta;
        %h
    }
}

#| Task status values
enum TaskStatus is export (
    TaskWorking       => 'working',
    TaskInputRequired => 'input_required',
    TaskCompleted     => 'completed',
    TaskFailed        => 'failed',
    TaskCancelled     => 'cancelled',
);

#| Task support level for tool execution
enum TaskSupport is export (
    TaskForbidden => 'forbidden',
    TaskOptional  => 'optional',
    TaskRequired  => 'required',
);

#| Task execution configuration for tools
class TaskExecution is export {
    has TaskSupport $.taskSupport is required;

    method Hash(--> Hash) {
        { taskSupport => $!taskSupport.value }
    }

    method from-hash(%h --> TaskExecution) {
        my $ts = do given %h<taskSupport> {
            when 'forbidden' { TaskForbidden }
            when 'optional'  { TaskOptional }
            when 'required'  { TaskRequired }
            default          { TaskOptional }
        };
        self.new(taskSupport => $ts)
    }
}

#| A task representing an async operation
class Task is export {
    has Str $.taskId is required;
    has TaskStatus $.status is required;
    has Str $.statusMessage;
    has Str $.createdAt;
    has Str $.lastUpdatedAt;
    has Int $.ttl;
    has Int $.pollInterval;

    method Hash(--> Hash) {
        my %h = taskId => $!taskId, status => $!status.value;
        %h<statusMessage> = $_ with $!statusMessage;
        %h<createdAt> = $_ with $!createdAt;
        %h<lastUpdatedAt> = $_ with $!lastUpdatedAt;
        %h<ttl> = $_ with $!ttl;
        %h<pollInterval> = $_ with $!pollInterval;
        %h
    }

    method from-hash(%h --> Task) {
        my $status = do given %h<status> {
            when 'working'        { TaskWorking }
            when 'input_required' { TaskInputRequired }
            when 'completed'      { TaskCompleted }
            when 'failed'         { TaskFailed }
            when 'cancelled'      { TaskCancelled }
            default               { TaskWorking }
        };
        my %args = taskId => %h<taskId>, status => $status;
        %args<statusMessage> = %h<statusMessage> if %h<statusMessage>.defined;
        %args<createdAt> = %h<createdAt> if %h<createdAt>.defined;
        %args<lastUpdatedAt> = %h<lastUpdatedAt> if %h<lastUpdatedAt>.defined;
        %args<ttl> = %h<ttl> if %h<ttl>.defined;
        %args<pollInterval> = %h<pollInterval> if %h<pollInterval>.defined;
        self.new(|%args)
    }

    method is-terminal(--> Bool) {
        $!status === TaskCompleted || $!status === TaskFailed || $!status === TaskCancelled
    }
}

#| Result wrapping a created task
class CreateTaskResult is export {
    has Task $.task is required;

    method Hash(--> Hash) {
        { task => $!task.Hash }
    }
}

#| Tool definition
class Tool is export {
    has Str $.name is required;
    has Str $.description;
    has Hash $.inputSchema;
    has Hash $.outputSchema;
    has ToolAnnotations $.annotations;
    has TaskExecution $.execution;

    method Hash(--> Hash) {
        my %h = name => $!name;
        %h<description> = $_ with $!description;
        %h<inputSchema> = $_ with $!inputSchema;
        %h<outputSchema> = $_ with $!outputSchema;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h<execution> = $!execution.Hash if $!execution;
        %h
    }

    method from-hash(%h --> Tool) {
        my %args = name => %h<name>;
        %args<description> = %h<description> if %h<description>.defined;
        %args<inputSchema> = %h<inputSchema> if %h<inputSchema>.defined;
        %args<outputSchema> = %h<outputSchema> if %h<outputSchema>.defined;
        %args<annotations> = %h<annotations> ?? ToolAnnotations.new(|%h<annotations>) !! ToolAnnotations;
        %args<execution> = TaskExecution.from-hash(%h<execution>) if %h<execution>.defined;
        self.new(|%args)
    }
}

#| Result of calling a tool
class CallToolResult is export {
    has @.content;   # Array of Content objects
    has Bool $.isError = False;
    has $.structuredContent;  # Optional structured output matching outputSchema

    method Hash(--> Hash) {
        my %h = content => @!content.map(*.Hash).Array, isError => $!isError;
        %h<structuredContent> = $_ with $!structuredContent;
        %h
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
        my %args = uri => %h<uri>, name => %h<name>;
        %args<description> = %h<description> if %h<description>.defined;
        %args<mimeType> = %h<mimeType> if %h<mimeType>.defined;
        self.new(|%args)
    }
}

#| Resource template definition (URI templates with placeholders)
class ResourceTemplate is export {
    has Str $.uriTemplate is required;
    has Str $.name is required;
    has Str $.description;
    has Str $.mimeType;
    has Annotations $.annotations;

    method Hash(--> Hash) {
        my %h = uriTemplate => $!uriTemplate, name => $!name;
        %h<description> = $_ with $!description;
        %h<mimeType> = $_ with $!mimeType;
        %h<annotations> = $!annotations.Hash if $!annotations;
        %h
    }

    method from-hash(%h --> ResourceTemplate) {
        my %args = uriTemplate => %h<uriTemplate>, name => %h<name>;
        %args<description> = %h<description> if %h<description>.defined;
        %args<mimeType> = %h<mimeType> if %h<mimeType>.defined;
        self.new(|%args)
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
        my %args = name => %h<name>;
        %args<description> = %h<description> if %h<description>.defined;
        %args<arguments> = (%h<arguments> // []).map({ PromptArgument.new(|$_) }).Array;
        self.new(|%args)
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

#| Sampling message
class SamplingMessage is export {
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

#| Model selection hint
class ModelHint is export {
    has Str $.name is required;

    method Hash(--> Hash) { { name => $!name } }
}

#| Model preferences for sampling
class ModelPreferences is export {
    has @.hints; # Array of ModelHint
    has Num $.costPriority;
    has Num $.speedPriority;
    has Num $.intelligencePriority;

    method Hash(--> Hash) {
        my %h;
        %h<hints> = @!hints.map(*.Hash).Array if @!hints;
        %h<costPriority> = $_ with $!costPriority;
        %h<speedPriority> = $_ with $!speedPriority;
        %h<intelligencePriority> = $_ with $!intelligencePriority;
        %h
    }
}

#| Tool choice for sampling
class ToolChoice is export {
    has Str $.mode is required; # auto | none | required | tool
    has Str $.name;

    method Hash(--> Hash) {
        my %h = mode => $!mode;
        %h<name> = $_ with $!name;
        %h
    }
}

#| Sampling result
class CreateMessageResult is export {
    has $.content is required;  # Content or array of Content
    has Str $.model is required;
    has Str $.role is required;
    has Str $.stopReason;
    has $.meta;

    method Hash(--> Hash) {
        my %h = model => $!model, role => $!role,
            content => $!content ~~ Positional
                ?? $!content.map(*.Hash).Array
                !! $!content.Hash;
        %h<stopReason> = $_ with $!stopReason;
        %h<_meta> = $_ with $!meta;
        %h
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

class CompletionsCapability is export {
    method Hash(--> Hash) { {} }
}

#| Completion result from server
class CompletionResult is export {
    has @.values;  # Array of Str, max 100
    has Int $.total;
    has Bool $.hasMore;

    method Hash(--> Hash) {
        my %h = values => @!values.Array;
        %h<total> = $_ with $!total;
        %h<hasMore> = $_ with $!hasMore;
        %h
    }

    method from-hash(%h --> CompletionResult) {
        my @vals = |(%h<values> // []);
        my %args;
        %args<total> = %h<total> if %h<total>.defined;
        %args<hasMore> = %h<hasMore> if %h<hasMore>.defined;
        self.new(values => @vals, |%args)
    }
}

#| Extension definition for experimental capabilities
class Extension is export {
    has Str $.name is required;
    has Str $.version;
    has Hash $.settings;

    method Hash(--> Hash) {
        my %h = name => $!name;
        %h<version> = $_ with $!version;
        %h<settings> = $_ with $!settings;
        %h
    }

    method from-hash(%h --> Extension) {
        my %args = name => %h<name>;
        %args<version> = %h<version> if %h<version>.defined;
        %args<settings> = %h<settings> if %h<settings>.defined;
        self.new(|%args)
    }
}

#| Full server capabilities
class ServerCapabilities is export {
    has Hash $.experimental;
    has LoggingCapability $.logging;
    has PromptsCapability $.prompts;
    has ResourcesCapability $.resources;
    has ToolsCapability $.tools;
    has CompletionsCapability $.completions;
    has Hash $.tasks;

    method Hash(--> Hash) {
        my %h;
        %h<experimental> = $!experimental if $!experimental;
        %h<logging> = $!logging.Hash if $!logging;
        %h<prompts> = $!prompts.Hash if $!prompts;
        %h<resources> = $!resources.Hash if $!resources;
        %h<tools> = $!tools.Hash if $!tools;
        %h<completions> = $!completions.Hash if $!completions;
        %h<tasks> = $!tasks if $!tasks;
        %h
    }

    method from-hash(%h --> ServerCapabilities) {
        my %args;
        %args<experimental> = %h<experimental> if %h<experimental>.defined && %h<experimental> ~~ Hash;
        %args<logging> = %h<logging> ?? LoggingCapability.new !! LoggingCapability;
        %args<prompts> = %h<prompts> ?? PromptsCapability.new(|%h<prompts>) !! PromptsCapability;
        %args<resources> = %h<resources> ?? ResourcesCapability.new(|%h<resources>) !! ResourcesCapability;
        %args<tools> = %h<tools> ?? ToolsCapability.new(|%h<tools>) !! ToolsCapability;
        %args<completions> = %h<completions> ?? CompletionsCapability.new !! CompletionsCapability;
        %args<tasks> = %h<tasks> if %h<tasks>.defined;
        self.new(|%args)
    }
}

#| Root definition (filesystem boundary)
class Root is export {
    has Str $.uri is required;
    has Str $.name;

    method Hash(--> Hash) {
        my %h = uri => $!uri;
        %h<name> = $_ with $!name;
        %h
    }

    method from-hash(%h --> Root) {
        my %args = uri => %h<uri>;
        %args<name> = %h<name> if %h<name>.defined;
        self.new(|%args)
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
    has Bool $.tools;
    has Bool $.context;

    method Hash(--> Hash) {
        my %h;
        %h<tools> = {} if $!tools;
        %h<context> = {} if $!context;
        %h
    }
}

#| Elicitation action responses
enum ElicitationAction is export (
    ElicitAccept  => 'accept',
    ElicitDecline => 'decline',
    ElicitCancel  => 'cancel',
);

#| Elicitation capability with mode support
class ElicitationCapability is export {
    has Bool $.form = True;  # Form mode enabled by default
    has Bool $.url = False;  # URL mode disabled by default

    method Hash(--> Hash) {
        my %h;
        %h<form> = {} if $!form;
        %h<url> = {} if $!url;
        %h
    }

    method from-hash(%h --> ElicitationCapability) {
        self.new(
            form => %h<form>:exists || !%h.keys,  # Empty = form only
            url => %h<url>:exists
        )
    }

    method supports-form(--> Bool) { $!form }
    method supports-url(--> Bool) { $!url }
}

#| Elicitation response from client
class ElicitationResponse is export {
    has ElicitationAction $.action is required;
    has %.content;  # Present only for form mode accept

    method Hash(--> Hash) {
        my %h = action => $!action.value;
        %h<content> = %!content if %!content && $!action === ElicitAccept;
        %h
    }

    method from-hash(%h --> ElicitationResponse) {
        my $action = do given %h<action> {
            when 'accept'  { ElicitAccept }
            when 'decline' { ElicitDecline }
            when 'cancel'  { ElicitCancel }
            default        { ElicitCancel }
        };
        self.new(
            action => $action,
            content => %h<content> // {}
        )
    }
}

#| Full client capabilities
class ClientCapabilities is export {
    has Hash $.experimental;
    has RootsCapability $.roots;
    has SamplingCapability $.sampling;
    has ElicitationCapability $.elicitation;
    has Hash $.tasks;

    method Hash(--> Hash) {
        my %h;
        %h<experimental> = $!experimental if $!experimental;
        %h<roots> = $!roots.Hash if $!roots;
        %h<sampling> = $!sampling.Hash if $!sampling;
        %h<elicitation> = $!elicitation.Hash if $!elicitation;
        %h<tasks> = $!tasks if $!tasks;
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
