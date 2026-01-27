use v6.d;

#| OAuth 2.1 server-side handler for MCP transport
unit module MCP::OAuth::Server;

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
