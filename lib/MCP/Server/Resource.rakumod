use v6.d;

#| Resource registration helpers and builder DSL
unit module MCP::Server::Resource;

=begin pod
=head1 NAME

MCP::Server::Resource - Resource registration helpers

=head1 DESCRIPTION

Provides a builder-style DSL and wrapper class for registering MCP resources,
including file-backed helpers.

=head1 FUNCTIONS

=head2 sub resource(--> ResourceBuilder)

Create a new resource builder.

    my $r = resource()
        .uri('config://app')
        .name('App Config')
        .mime-type('application/json')
        .reader({ to-json(%config) })
        .build;

=head2 sub file-resource(IO::Path $path, :$uri, :$name, :$mime-type --> RegisteredResource)

Convenience constructor for a file-backed resource.

    $server.add-resource(file-resource('data.txt'.IO));

=head2 sub resource-template(--> ResourceTemplateBuilder)

Create a new resource template builder.

    my $rt = resource-template()
        .name('files')
        .uri-template('file:///{path}')
        .reader(-> :$path { $path.IO.slurp })
        .build;

=head1 CLASSES

=head2 ResourceBuilder

Fluent builder with chain methods: C<.uri>, C<.name>, C<.description>,
C<.mime-type>, C<.annotations>, C<.reader>, C<.build>.

=head2 RegisteredResource

=item C<.to-resource(--> Resource)> — Get the resource definition.
=item C<.read(--> Array)> — Read the resource contents.

=head2 ResourceTemplateBuilder

Fluent builder with chain methods: C<.name>, C<.uri-template>,
C<.description>, C<.mime-type>, C<.reader>, C<.build>.

=head2 RegisteredResourceTemplate

=item C<.to-template(--> ResourceTemplate)> — Get the template definition.
=item C<.matches(Str $uri --> Bool)> — Test if a URI matches this template.
=item C<.read(Str $uri --> Array)> — Read by extracting template variables from the URI.

=end pod

use MCP::Types;

#| Wrapper class for a registered resource with its reader
class RegisteredResource is export {
    has Str $.uri is required;
    has Str $.name is required;
    has Str $.description;
    has Str $.title;
    has @.icons;
    has Str $.mimeType;
    has MCP::Types::Annotations $.annotations;
    has &.reader is required;

    #| Get the Resource definition for listing
    method to-resource(--> MCP::Types::Resource) {
        MCP::Types::Resource.new(
            uri => $!uri,
            name => $!name,
            description => $!description,
            title => $!title,
            icons => @!icons,
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
            when Str {
                return [MCP::Types::ResourceContents.new(
                    uri => $!uri,
                    mimeType => $!mimeType // 'text/plain',
                    text => $result
                )];
            }
            when Blob | Buf {
                return [MCP::Types::ResourceContents.new(
                    uri => $!uri,
                    mimeType => $!mimeType // 'application/octet-stream',
                    blob => $result
                )];
            }
            when Positional {
                return $result.Array;
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
    has Str $!title;
    has @!icons;
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

    method title(Str $t --> ResourceBuilder) {
        $!title = $t;
        self
    }

    method icon(Str $src, Str :$mimeType, :@sizes --> ResourceBuilder) {
        @!icons.push(MCP::Types::IconDefinition.new(:$src, :$mimeType, :@sizes));
        self
    }

    method mimeType(Str $mime --> ResourceBuilder) {
        $!mimeType = $mime;
        self
    }

    method annotations(@audience, Real :$priority --> ResourceBuilder) {
        $!annotations = MCP::Types::Annotations.new(:@audience, priority => $priority.Num);
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
            title => $!title,
            icons => @!icons,
            mimeType => $!mimeType,
            annotations => $!annotations,
            reader => &!reader,
        )
    }
}

#| Convenience function to create a resource builder
our sub resource(--> ResourceBuilder) is export {
    ResourceBuilder.new
}

#| Create a resource from a file
our sub file-resource(IO::Path $path, Str :$uri, Str :$name --> RegisteredResource) is export {
    my $builder = resource().from-file($path);
    $builder.uri($_) with $uri;
    $builder.name($_) with $name;
    $builder.build
}

#| Wrapper class for a registered resource template with its reader
class RegisteredResourceTemplate is export {
    has Str $.uri-template is required;
    has Str $.name is required;
    has Str $.description;
    has Str $.title;
    has @.icons;
    has Str $.mimeType;
    has MCP::Types::Annotations $.annotations;
    has &.reader is required;

    #| Get the ResourceTemplate definition for listing
    method to-resource-template(--> MCP::Types::ResourceTemplate) {
        MCP::Types::ResourceTemplate.new(
            uriTemplate => $!uri-template,
            name => $!name,
            description => $!description,
            title => $!title,
            icons => @!icons,
            mimeType => $!mimeType,
            annotations => $!annotations,
        )
    }

    #| Try to match a URI against this template; returns params hash or Nil
    method match-uri(Str $uri --> Hash) {
        # Parse template into literal parts and variable names
        my @names;
        my @literal-parts;
        my $rest = $!uri-template;
        while $rest ~~ / ^ (.*?) '{' (<-[}]>+) '}' (.*)/ {
            @literal-parts.push: ~$0;
            @names.push: ~$1;
            $rest = ~$2;
        }
        @literal-parts.push: $rest;

        # Build match attempt: split URI by literal parts
        my $remaining = $uri;
        my @values;

        for @literal-parts.kv -> $i, $literal {
            if $i == 0 {
                # First literal must be a prefix
                return Nil unless $remaining.starts-with($literal);
                $remaining = $remaining.substr($literal.chars);
            } else {
                # Find the next literal to know where this variable ends
                if $literal.chars {
                    my $pos = $remaining.index($literal);
                    return Nil unless $pos.defined;
                    my $val = $remaining.substr(0, $pos);
                    return Nil unless $val.chars;  # empty variable
                    @values.push: $val;
                    $remaining = $remaining.substr($pos + $literal.chars);
                } else {
                    # Last variable, consume rest
                    return Nil unless $remaining.chars;
                    @values.push: $remaining;
                    $remaining = '';
                }
            }
        }

        return Nil if $remaining.chars;  # leftover means no match
        return Nil unless @values.elems == @names.elems;

        my %params;
        for @names.kv -> $i, $name {
            %params{$name} = @values[$i];
        }
        %params
    }

    #| Read the resource via template reader with extracted params
    method read(%params, Str :$uri --> Array) {
        my $result = &!reader(%params);

        my $resolved-uri = $uri // $!uri-template;

        given $result {
            when MCP::Types::ResourceContents {
                return [$result];
            }
            when Str {
                return [MCP::Types::ResourceContents.new(
                    uri => $resolved-uri,
                    mimeType => $!mimeType // 'text/plain',
                    text => $result
                )];
            }
            when Blob | Buf {
                return [MCP::Types::ResourceContents.new(
                    uri => $resolved-uri,
                    mimeType => $!mimeType // 'application/octet-stream',
                    blob => $result
                )];
            }
            when Positional {
                return $result.Array;
            }
            default {
                return [MCP::Types::ResourceContents.new(
                    uri => $resolved-uri,
                    mimeType => 'text/plain',
                    text => $result.Str
                )];
            }
        }
    }
}

#| Builder for creating resource template definitions
class ResourceTemplateBuilder is export {
    has Str $!uri-template;
    has Str $!name;
    has Str $!description;
    has Str $!title;
    has @!icons;
    has Str $!mimeType;
    has MCP::Types::Annotations $!annotations;
    has &!reader;

    method uri-template(Str $t --> ResourceTemplateBuilder) {
        $!uri-template = $t;
        self
    }

    method name(Str $name --> ResourceTemplateBuilder) {
        $!name = $name;
        self
    }

    method description(Str $desc --> ResourceTemplateBuilder) {
        $!description = $desc;
        self
    }

    method title(Str $t --> ResourceTemplateBuilder) {
        $!title = $t;
        self
    }

    method icon(Str $src, Str :$mimeType, :@sizes --> ResourceTemplateBuilder) {
        @!icons.push(MCP::Types::IconDefinition.new(:$src, :$mimeType, :@sizes));
        self
    }

    method mimeType(Str $mime --> ResourceTemplateBuilder) {
        $!mimeType = $mime;
        self
    }

    method annotations(@audience, Real :$priority --> ResourceTemplateBuilder) {
        $!annotations = MCP::Types::Annotations.new(:@audience, priority => $priority.Num);
        self
    }

    method reader(&reader --> ResourceTemplateBuilder) {
        &!reader = &reader;
        self
    }

    method build(--> RegisteredResourceTemplate) {
        die "Resource template URI template is required" unless $!uri-template;
        die "Resource template name is required" unless $!name;
        die "Resource template reader is required" unless &!reader;

        RegisteredResourceTemplate.new(
            uri-template => $!uri-template,
            name => $!name,
            description => $!description,
            title => $!title,
            icons => @!icons,
            mimeType => $!mimeType,
            annotations => $!annotations,
            reader => &!reader,
        )
    }
}

#| Convenience function to create a resource template builder
our sub resource-template(--> ResourceTemplateBuilder) is export {
    ResourceTemplateBuilder.new
}
