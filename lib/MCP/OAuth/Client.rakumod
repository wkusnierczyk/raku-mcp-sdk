use v6.d;

#| OAuth 2.1 client-side handler for MCP transport
unit module MCP::OAuth::Client;

use MCP::OAuth;
use JSON::Fast;

class OAuthClientHandler is export {
    has Str $.resource-url is required;
    has Str $.client-id is required;
    has Str $.client-secret;
    has @.scopes;
    has &.authorization-callback is required; # Str $url --> Str $code
    has Str $.redirect-uri = 'http://localhost:8080/callback';

    has TokenResponse $.token is rw;
    has AuthServerMetadata $.auth-metadata is rw;
    has ProtectedResourceMetadata $.resource-metadata is rw;
    has Str $.pkce-verifier is rw;

    method discover(--> Promise) {
        start {
            my $client = self!cro-client;

            # Fetch protected resource metadata
            my $resource-url = $!resource-url.subst(/ '/' $ /, '');
            my $rm-url = "$resource-url/.well-known/oauth-protected-resource";
            my $rm-resp = await $client.get($rm-url);
            my $rm-body = await $rm-resp.body;
            $!resource-metadata = ProtectedResourceMetadata.from-hash(
                $rm-body ~~ Hash ?? $rm-body !! from-json($rm-body)
            );

            # Fetch auth server metadata
            my $issuer = $!resource-metadata.authorization-servers[0]
                // die X::MCP::OAuth::Discovery.new(message => 'No authorization server found');

            my $issuer-base = $issuer.subst(/ '/' $ /, '');
            my $as-body;
            try {
                my $as-resp = await $client.get("$issuer-base/.well-known/oauth-authorization-server");
                $as-body = await $as-resp.body;
                CATCH {
                    default {
                        # OIDC fallback
                        my $oidc-resp = await $client.get("$issuer-base/.well-known/openid-configuration");
                        $as-body = await $oidc-resp.body;
                    }
                }
            }
            $!auth-metadata = AuthServerMetadata.from-hash(
                $as-body ~~ Hash ?? $as-body !! from-json($as-body)
            );
            True
        }
    }

    method authorization-url(--> Str) {
        die X::MCP::OAuth::Discovery.new(message => 'Must call discover() first')
            unless $!auth-metadata.defined;

        my $pkce = PKCE.new;
        $!pkce-verifier = $pkce.generate-verifier;
        my $challenge = $pkce.generate-challenge($!pkce-verifier);

        my $state = (^32).map({ <a b c d e f 0 1 2 3 4 5 6 7 8 9>.pick }).join;

        my $endpoint = $!auth-metadata.authorization-endpoint;
        my @params;
        @params.push("response_type=code");
        @params.push("client_id={uri-encode($!client-id)}");
        @params.push("redirect_uri={uri-encode($!redirect-uri)}");
        @params.push("code_challenge={uri-encode($challenge)}");
        @params.push("code_challenge_method=S256");
        @params.push("resource={uri-encode($!resource-url)}");
        @params.push("state={uri-encode($state)}");
        @params.push("scope={uri-encode(@!scopes.join(' '))}") if @!scopes;

        "$endpoint?{@params.join('&')}"
    }

    method authenticate(--> Promise) {
        start {
            await self.discover unless $!auth-metadata.defined;
            my $url = self.authorization-url;
            my $code = &!authorization-callback($url);
            await self.exchange-code($code);
            True
        }
    }

    method exchange-code(Str $code --> Promise) {
        start {
            my $client = self!cro-client;
            my %body =
                grant_type => 'authorization_code',
                code => $code,
                redirect_uri => $!redirect-uri,
                client_id => $!client-id,
                code_verifier => $!pkce-verifier,
                resource => $!resource-url;
            %body<client_secret> = $!client-secret if $!client-secret.defined;

            my $resp = await $client.post(
                $!auth-metadata.token-endpoint,
                content-type => 'application/x-www-form-urlencoded',
                body => self!form-encode(%body),
            );
            my $body = await $resp.body;
            my %token-data = $body ~~ Hash ?? $body !! from-json($body);
            $!token = TokenResponse.from-hash(%token-data);
            $!token
        }
    }

    method refresh(--> Promise) {
        start {
            die X::MCP::OAuth::Unauthorized.new(message => 'No refresh token available')
                unless $!token.defined && $!token.refresh-token.defined;

            my $client = self!cro-client;
            my %body =
                grant_type => 'refresh_token',
                refresh_token => $!token.refresh-token,
                client_id => $!client-id,
                resource => $!resource-url;
            %body<client_secret> = $!client-secret if $!client-secret.defined;

            my $resp = await $client.post(
                $!auth-metadata.token-endpoint,
                content-type => 'application/x-www-form-urlencoded',
                body => self!form-encode(%body),
            );
            my $body = await $resp.body;
            my %token-data = $body ~~ Hash ?? $body !! from-json($body);
            $!token = TokenResponse.from-hash(%token-data);
            $!token
        }
    }

    method get-token(--> Promise) {
        start {
            if $!token.defined && !$!token.is-expired {
                $!token
            } elsif $!token.defined && $!token.refresh-token.defined {
                await self.refresh
            } else {
                await self.authenticate;
                $!token
            }
        }
    }

    method authorization-header(--> Promise) {
        start {
            my $token = await self.get-token;
            "Bearer {$token.access-token}"
        }
    }

    method handle-unauthorized(--> Promise) {
        start {
            $!token = Nil;
            $!pkce-verifier = Nil;
            await self.authenticate;
            True
        }
    }

    method !form-encode(%data --> Str) {
        %data.kv.map(-> $k, $v { "{uri-encode($k)}={uri-encode($v)}" }).join('&')
    }

    method !cro-client() {
        try {
            require ::('Cro::HTTP::Client');
            return ::('Cro::HTTP::Client').new;
        }
        CATCH {
            default {
                die X::MCP::OAuth::Discovery.new(
                    message => 'Cro::HTTP is required for OAuth client'
                );
            }
        }
    }

    sub uri-encode(Str $s --> Str) {
        $s.subst(/<-[A..Za..z0..9\-._~]>/, { .Str.encode('utf-8').list.map({ '%' ~ .fmt('%02X') }).join }, :g)
    }
}
