use v6.d;

#| OAuth 2.1 client-side handler for MCP transport
unit module MCP::OAuth::Client;

=begin pod
=head1 NAME

MCP::OAuth::Client - OAuth 2.1 client-side authorization handler

=head1 DESCRIPTION

Manages the client side of OAuth 2.1 authorization for MCP transports:
metadata discovery, authorization code flow with PKCE, token exchange,
refresh, and dynamic client registration.

=head1 CLASS

=head2 OAuthClientHandler

    my $oauth = OAuthClientHandler.new(
        resource-url => 'https://mcp.example.com',
        client-id => 'my-app',
        redirect-uri => 'http://localhost:9999/callback',
    );

Key methods:

=item C<.discover-metadata(--> Promise)> — Fetch OAuth server metadata from well-known endpoint.
=item C<.authorization-url(--> Str)> — Build the authorization URL with PKCE challenge.
=item C<.exchange-code(Str $code --> Promise)> — Exchange authorization code for tokens.
=item C<.refresh-token(--> Promise)> — Refresh an expired access token.
=item C<.register-client(--> Promise)> — Perform dynamic client registration.
=item C<.access-token(--> Str)> — Get the current access token.

=end pod

use MCP::OAuth;
use JSON::Fast;

class OAuthClientHandler is export {
    has Str $.resource-url is required;
    has Str $.client-id is rw;
    has Str $.client-secret is rw;
    has @.scopes;
    has &.authorization-callback is required; # Str $url --> Str $code
    has Str $.redirect-uri = 'http://localhost:8080/callback';

    has TokenResponse $.token is rw;
    has AuthServerMetadata $.auth-metadata is rw;
    has ProtectedResourceMetadata $.resource-metadata is rw;
    has ClientRegistrationResponse $.registration is rw;
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
            {
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
            # Auto-register if no client-id and server supports dynamic registration
            if !$!client-id.defined && $!auth-metadata.registration-endpoint.defined {
                await self.register;
            }
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
                body => %body,
            );
            my $body = await $resp.body;
            my %token-data = $body ~~ Hash ?? $body !! from-json($body);
            $!token = TokenResponse.from-hash(%token-data);
            $!pkce-verifier = Nil;  # Single-use per RFC 7636
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
                body => %body,
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

    method register(ClientRegistrationRequest :$request --> Promise) {
        start {
            die X::MCP::OAuth::Discovery.new(message => 'Must call discover() first')
                unless $!auth-metadata.defined;
            die X::MCP::OAuth::Registration.new(
                message => 'Authorization server does not support dynamic registration'
            ) unless $!auth-metadata.registration-endpoint.defined;

            my $client = self!cro-client;
            my $req = $request // ClientRegistrationRequest.new(
                redirect-uris => [$!redirect-uri],
                grant-types => ['authorization_code', 'refresh_token'],
                response-types => ['code'],
                token-endpoint-auth-method => 'none',
                scope => @!scopes.join(' ') || Str,
            );

            my $resp = await $client.post(
                $!auth-metadata.registration-endpoint,
                content-type => 'application/json',
                body => to-json($req.Hash),
            );
            my $body = await $resp.body;
            my %reg-data = $body ~~ Hash ?? $body !! from-json($body);
            $!registration = ClientRegistrationResponse.from-hash(%reg-data);
            $!client-id = $!registration.client-id;
            $!client-secret = $!registration.client-secret if $!registration.client-secret.defined;
            $!registration
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

    method !cro-client() { # UNCOVERABLE
        require ::('Cro::HTTP::Client'); # UNCOVERABLE
        return ::('Cro::HTTP::Client').new; # UNCOVERABLE
        CATCH { # UNCOVERABLE
            default { # UNCOVERABLE
                die X::MCP::OAuth::Discovery.new( # UNCOVERABLE
                    message => 'Cro::HTTP is required for OAuth client' # UNCOVERABLE
                ); # UNCOVERABLE
            } # UNCOVERABLE
        } # UNCOVERABLE
    } # UNCOVERABLE

    sub uri-encode(Str $s --> Str) {
        $s.subst(/<-[A..Za..z0..9\-._~]>/, { .Str.encode('utf-8').list.map({ '%' ~ .fmt('%02X') }).join }, :g)
    }
}

#| OAuth 2.1 client credentials handler for machine-to-machine authentication (SEP-1046)
class OAuthM2MClient is export {
    has Str $.resource-url is required;
    has Str $.client-id is required;
    has Str $.client-secret is required;
    has @.scopes;

    has TokenResponse $.token is rw;
    has AuthServerMetadata $.auth-metadata is rw;
    has ProtectedResourceMetadata $.resource-metadata is rw;

    method discover(--> Promise) {
        start {
            my $client = self!cro-client;

            my $resource-url = $!resource-url.subst(/ '/' $ /, '');
            my $rm-url = "$resource-url/.well-known/oauth-protected-resource";
            my $rm-resp = await $client.get($rm-url);
            my $rm-body = await $rm-resp.body;
            $!resource-metadata = ProtectedResourceMetadata.from-hash(
                $rm-body ~~ Hash ?? $rm-body !! from-json($rm-body)
            );

            my $issuer = $!resource-metadata.authorization-servers[0]
                // die X::MCP::OAuth::Discovery.new(message => 'No authorization server found');

            my $issuer-base = $issuer.subst(/ '/' $ /, '');
            my $as-body;
            {
                my $as-resp = await $client.get("$issuer-base/.well-known/oauth-authorization-server");
                $as-body = await $as-resp.body;
                CATCH {
                    default {
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

    method authenticate(--> Promise) {
        start {
            await self.discover unless $!auth-metadata.defined;
            await self.request-token;
            True
        }
    }

    method request-token(--> Promise) {
        start {
            die X::MCP::OAuth::Discovery.new(message => 'Must call discover() first')
                unless $!auth-metadata.defined;

            my $client = self!cro-client;
            my %body =
                grant_type    => 'client_credentials',
                client_id     => $!client-id,
                client_secret => $!client-secret,
                resource      => $!resource-url;
            %body<scope> = @!scopes.join(' ') if @!scopes;

            my $resp = await $client.post(
                $!auth-metadata.token-endpoint,
                content-type => 'application/x-www-form-urlencoded',
                body => %body,
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
            } else {
                await self.request-token
            }
        }
    }

    method authorization-header(--> Promise) {
        start {
            my $token = await self.get-token;
            "Bearer {$token.access-token}"
        }
    }

    method !cro-client() { # UNCOVERABLE
        require ::('Cro::HTTP::Client'); # UNCOVERABLE
        return ::('Cro::HTTP::Client').new; # UNCOVERABLE
        CATCH { # UNCOVERABLE
            default { # UNCOVERABLE
                die X::MCP::OAuth::Discovery.new( # UNCOVERABLE
                    message => 'Cro::HTTP is required for OAuth M2M client' # UNCOVERABLE
                ); # UNCOVERABLE
            } # UNCOVERABLE
        } # UNCOVERABLE
    } # UNCOVERABLE
}

#| Enterprise-managed authorization client (SEP-990)
#| Implements the Identity Assertion Authorization Grant flow for
#| enterprise IdP policy controls during MCP OAuth flows.
class OAuthEnterpriseClient is export {
    has Str $.resource-url is required;
    has Str $.client-id is required;
    has Str $.client-secret;
    has @.scopes;

    # IdP configuration
    has Str $.idp-token-endpoint is required;
    has Str $.idp-client-id is required;
    has Str $.idp-client-secret;
    has Str $.subject-token is rw;          # ID token or SAML assertion
    has Str $.subject-token-type = 'urn:ietf:params:oauth:token-type:id_token';

    has TokenResponse $.token is rw;
    has AuthServerMetadata $.auth-metadata is rw;
    has ProtectedResourceMetadata $.resource-metadata is rw;
    has TokenExchangeResponse $.id-jag is rw;

    method discover(--> Promise) {
        start {
            my $client = self!cro-client;

            my $resource-url = $!resource-url.subst(/ '/' $ /, '');
            my $rm-url = "$resource-url/.well-known/oauth-protected-resource";
            my $rm-resp = await $client.get($rm-url);
            my $rm-body = await $rm-resp.body;
            $!resource-metadata = ProtectedResourceMetadata.from-hash(
                $rm-body ~~ Hash ?? $rm-body !! from-json($rm-body)
            );

            my $issuer = $!resource-metadata.authorization-servers[0]
                // die X::MCP::OAuth::Discovery.new(message => 'No authorization server found');

            my $issuer-base = $issuer.subst(/ '/' $ /, '');
            my $as-body;
            {
                my $as-resp = await $client.get("$issuer-base/.well-known/oauth-authorization-server");
                $as-body = await $as-resp.body;
                CATCH {
                    default {
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

    #| Step 1: Exchange identity assertion for ID-JAG at the IdP (RFC 8693)
    method exchange-token(--> Promise) {
        start {
            die X::MCP::OAuth::TokenExchange.new(
                message => 'No subject token available'
            ) unless $!subject-token.defined;
            die X::MCP::OAuth::Discovery.new(message => 'Must call discover() first')
                unless $!auth-metadata.defined;

            my $client = self!cro-client;
            my %body =
                grant_type           => 'urn:ietf:params:oauth:grant-type:token-exchange',
                requested_token_type => 'urn:ietf:params:oauth:token-type:id-jag',
                audience             => $!auth-metadata.issuer,
                resource             => $!resource-url,
                subject_token        => $!subject-token,
                subject_token_type   => $!subject-token-type,
                client_id            => $!idp-client-id;
            %body<client_secret> = $!idp-client-secret if $!idp-client-secret.defined;
            %body<scope> = @!scopes.join(' ') if @!scopes;

            my $resp = await $client.post(
                $!idp-token-endpoint,
                content-type => 'application/x-www-form-urlencoded',
                body => %body,
            );
            my $body = await $resp.body;
            my %data = $body ~~ Hash ?? $body !! from-json($body);

            if %data<error>:exists {
                die X::MCP::OAuth::TokenExchange.new(
                    error             => %data<error>,
                    error-description => %data<error_description>,
                );
            }

            $!id-jag = TokenExchangeResponse.from-hash(%data);
            $!id-jag
        }
    }

    #| Step 2: Use ID-JAG to obtain access token from MCP auth server (RFC 7523)
    method request-token(--> Promise) {
        start {
            die X::MCP::OAuth::TokenExchange.new(
                message => 'No ID-JAG available; call exchange-token() first'
            ) unless $!id-jag.defined;

            my $client = self!cro-client;
            my %body =
                grant_type => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                assertion  => $!id-jag.access-token,
                client_id  => $!client-id;
            %body<client_secret> = $!client-secret if $!client-secret.defined;

            my $resp = await $client.post(
                $!auth-metadata.token-endpoint,
                content-type => 'application/x-www-form-urlencoded',
                body => %body,
            );
            my $body = await $resp.body;
            my %token-data = $body ~~ Hash ?? $body !! from-json($body);
            $!token = TokenResponse.from-hash(%token-data);
            $!token
        }
    }

    #| Full enterprise auth flow: discover, exchange, request token
    method authenticate(--> Promise) {
        start {
            await self.discover unless $!auth-metadata.defined;
            await self.exchange-token;
            await self.request-token;
            True
        }
    }

    method get-token(--> Promise) {
        start {
            if $!token.defined && !$!token.is-expired {
                $!token
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

    method !cro-client() { # UNCOVERABLE
        require ::('Cro::HTTP::Client'); # UNCOVERABLE
        return ::('Cro::HTTP::Client').new; # UNCOVERABLE
        CATCH { # UNCOVERABLE
            default { # UNCOVERABLE
                die X::MCP::OAuth::Discovery.new( # UNCOVERABLE
                    message => 'Cro::HTTP is required for OAuth enterprise client' # UNCOVERABLE
                ); # UNCOVERABLE
            } # UNCOVERABLE
        } # UNCOVERABLE
    } # UNCOVERABLE
}
