use v6.d;

#| OAuth 2.1 server-side handler for MCP transport
unit module MCP::OAuth::Server;

=begin pod
=head1 NAME

MCP::OAuth::Server - OAuth 2.1 server-side token validation

=head1 DESCRIPTION

Validates OAuth 2.1 bearer tokens on the server side for MCP transports.
Supports token introspection, scope checking, and enterprise IdP policy
controls.

=head1 CLASS

=head2 OAuthServerHandler

    my $oauth = OAuthServerHandler.new(
        resource-identifier => 'https://mcp.example.com',
        authorization-servers => ['https://auth.example.com'],
    );

Key methods:

=item C<.validate-token(Str $token --> Promise)> — Validate a bearer token and return claims.
=item C<.check-scope(Str $token, Str $scope --> Bool)> — Verify a token has the required scope.

=end pod

use MCP::OAuth;

class OAuthServerHandler is export {
    has Str $.resource-identifier is required;
    has @.authorization-servers;
    has @.scopes-supported;
    has &.token-validator is required; # Str $token --> Hash with 'valid' key

    method resource-metadata(--> Hash) {
        ProtectedResourceMetadata.new(
            resource => $!resource-identifier,
            authorization-servers => @!authorization-servers,
            scopes-supported => @!scopes-supported,
        ).Hash
    }

    method validate-request($req --> Hash) {
        my $auth = $req.header('Authorization') // '';
        unless $auth.starts-with('Bearer ') {
            die X::MCP::OAuth::Unauthorized.new(
                message => 'Missing or invalid Authorization header',
            );
        }
        my $token = $auth.substr(7);
        my %result = &!token-validator($token);
        unless %result<valid> {
            if %result<scopes>:exists {
                die X::MCP::OAuth::Forbidden.new(
                    message => %result<message> // 'Insufficient scope',
                    scopes => %result<scopes>.list,
                );
            }
            die X::MCP::OAuth::Unauthorized.new(
                message => %result<message> // 'Invalid token',
            );
        }
        %result
    }

    method www-authenticate-header(--> Str) {
        my $value = 'Bearer';
        $value ~= " resource_metadata=\"{$!resource-identifier}/.well-known/oauth-protected-resource\"";
        $value
    }

    method www-authenticate-scope-header(@scopes --> Str) {
        my $value = 'Bearer';
        $value ~= " resource_metadata=\"{$!resource-identifier}/.well-known/oauth-protected-resource\"";
        $value ~= ", error=\"insufficient_scope\"";
        $value ~= ", scope=\"{@scopes.join(' ')}\"" if @scopes;
        $value
    }
}
