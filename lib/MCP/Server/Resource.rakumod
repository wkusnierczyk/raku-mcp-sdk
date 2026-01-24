use v6.d;

#| Resource registration helpers and builder DSL
unit module MCP::Server::Resource;

use MCP::Types;

#| Wrapper class for a registered resource with its reader
class RegisteredResource is export {
    has Str $.uri is required;
    has Str $.name is required;
    has Str $.description;
    has Str $.mimeType;
    has MCP::Types::Annotations $.annotations;
    has &.reader is required;

    #| Get the Resource definition for listing
    method to-resource(--> MCP::Types::Resource) {
        MCP::Types::Resource.new(
            uri => $!uri,
            name => $!name,
            description => $!description,
            mimeType => $!mimeType,
            annotations => $!annotations,
        )
    }

    #| Read the resource contents
    method read(--> Array) {
        my $result = &!reader();

        # Normalize result to array of ResourceContents
        given $result {
            when MCP::Types::ResourceContents {
                return [$result];
            }
            when Positional {
                return $result.Array;
            }
            when Str {
                return [MCP::Types::ResourceContents.new(
                    uri => $!uri,
                    mimeType => $!mimeType // 'text/plain',
                    text => $result
                )];
            }
            when Blob {
                return [MCP::Types::ResourceContents.new(
                    uri => $!uri,
                    mimeType => $!mimeType // 'application/octet-stream',
                    blob => $result
                )];
            }
            default {
                return [MCP::Types::ResourceContents.new(
                    uri => $!uri,
                    mimeType => 'text/plain',
                    text => $result.Str
                )];
            }
        }
    }
}

#| Builder for creating resource definitions
class ResourceBuilder is export {
    has Str $!uri;
    has Str $!name;
    has Str $!description;
    has Str $!mimeType;
    has MCP::Types::Annotations $!annotations;
    has &!reader;

    method uri(Str $uri --> ResourceBuilder) {
        $!uri = $uri;
        self
    }

    method name(Str $name --> ResourceBuilder) {
        $!name = $name;
        self
    }

    method description(Str $desc --> ResourceBuilder) {
        $!description = $desc;
        self
    }

    method mimeType(Str $mime --> ResourceBuilder) {
        $!mimeType = $mime;
        self
    }

    method annotations(@audience, Num :$priority --> ResourceBuilder) {
        $!annotations = MCP::Types::Annotations.new(:@audience, :$priority);
        self
    }

    method reader(&reader --> ResourceBuilder) {
        &!reader = &reader;
        self
    }

    #| Helper for file-based resources
    method from-file(IO::Path $path --> ResourceBuilder) {
        $!uri //= "file://{$path.absolute}";
        $!name //= $path.basename;
        $!mimeType //= self!guess-mime-type($path);
        &!reader = { $path.slurp };
        self
    }

    method !guess-mime-type(IO::Path $path --> Str) {
        given $path.extension.lc {
            when 'txt'  { 'text/plain' }
            when 'html' { 'text/html' }
            when 'css'  { 'text/css' }
            when 'js'   { 'text/javascript' }
            when 'json' { 'application/json' }
            when 'xml'  { 'application/xml' }
            when 'png'  { 'image/png' }
            when 'jpg' | 'jpeg' { 'image/jpeg' }
            when 'gif'  { 'image/gif' }
            when 'svg'  { 'image/svg+xml' }
            when 'pdf'  { 'application/pdf' }
            when 'md'   { 'text/markdown' }
            default     { 'application/octet-stream' }
        }
    }

    method build(--> RegisteredResource) {
        die "Resource URI is required" unless $!uri;
        die "Resource name is required" unless $!name;
        die "Resource reader is required" unless &!reader;

        RegisteredResource.new(
            uri => $!uri,
            name => $!name,
            description => $!description,
            mimeType => $!mimeType,
            annotations => $!annotations,
            reader => &!reader,
        )
    }
}

#| Convenience function to create a resource builder
sub resource(--> ResourceBuilder) is export {
    ResourceBuilder.new
}

#| Create a resource from a file
sub file-resource(IO::Path $path, Str :$uri, Str :$name --> RegisteredResource) is export {
    my $builder = resource().from-file($path);
    $builder.uri($_) with $uri;
    $builder.name($_) with $name;
    $builder.build
}
