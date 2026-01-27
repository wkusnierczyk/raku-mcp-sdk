use v6.d;

#| OAuth 2.1 core types, PKCE utilities, and exceptions for MCP authorization
unit module MCP::OAuth;

use MIME::Base64;

# === Exceptions ===

class X::MCP::OAuth::Unauthorized is Exception is export {
    has Str $.message = 'Unauthorized';
    method message(--> Str) { $!message }
}

class X::MCP::OAuth::Forbidden is Exception is export {
    has Str $.message = 'Forbidden';
    has @.scopes;
    method message(--> Str) { $!message }
}

class X::MCP::OAuth::Discovery is Exception is export {
    has Str $.message = 'OAuth discovery failed';
    method message(--> Str) { $!message }
}

# === Protected Resource Metadata (RFC 9728) ===

class ProtectedResourceMetadata is export {
    has Str $.resource is required;
    has @.authorization-servers;
    has @.scopes-supported;

    method Hash(--> Hash) {
        my %h = resource => $!resource;
        %h<authorization_servers> = @!authorization-servers if @!authorization-servers;
        %h<scopes_supported> = @!scopes-supported if @!scopes-supported;
        %h
    }

    method from-hash(%h --> ProtectedResourceMetadata) {
        self.new(
            resource => %h<resource>,
            authorization-servers => (%h<authorization_servers> // []).list,
            scopes-supported => (%h<scopes_supported> // []).list,
        )
    }
}

# === Authorization Server Metadata (RFC 8414) ===

class AuthServerMetadata is export {
    has Str $.issuer is required;
    has Str $.authorization-endpoint;
    has Str $.token-endpoint;
    has @.grant-types-supported;
    has @.response-types-supported;
    has @.scopes-supported;
    has @.code-challenge-methods-supported;

    method Hash(--> Hash) {
        my %h = issuer => $!issuer;
        %h<authorization_endpoint> = $!authorization-endpoint if $!authorization-endpoint;
        %h<token_endpoint> = $!token-endpoint if $!token-endpoint;
        %h<grant_types_supported> = @!grant-types-supported if @!grant-types-supported;
        %h<response_types_supported> = @!response-types-supported if @!response-types-supported;
        %h<scopes_supported> = @!scopes-supported if @!scopes-supported;
        %h<code_challenge_methods_supported> = @!code-challenge-methods-supported if @!code-challenge-methods-supported;
        %h
    }

    method from-hash(%h --> AuthServerMetadata) {
        self.new(
            issuer => %h<issuer>,
            authorization-endpoint => %h<authorization_endpoint>,
            token-endpoint => %h<token_endpoint>,
            grant-types-supported => (%h<grant_types_supported> // []).list,
            response-types-supported => (%h<response_types_supported> // []).list,
            scopes-supported => (%h<scopes_supported> // []).list,
            code-challenge-methods-supported => (%h<code_challenge_methods_supported> // []).list,
        )
    }
}

# === Token Response ===

class TokenResponse is export {
    has Str $.access-token is required;
    has Str $.token-type = 'Bearer';
    has Int $.expires-in;
    has $.refresh-token;
    has $.scope;
    has Instant $.created-at = now;

    method is-expired(--> Bool) {
        return False unless $!expires-in.defined;
        my $expiry = $!created-at + $!expires-in - 30; # 30s buffer
        now > $expiry
    }

    method from-hash(%h --> TokenResponse) {
        self.new(
            access-token => %h<access_token>,
            token-type => %h<token_type> // 'Bearer',
            expires-in => %h<expires_in> ?? %h<expires_in>.Int !! Int,
            refresh-token => %h<refresh_token>,
            scope => %h<scope>,
        )
    }
}

# === PKCE (RFC 7636) ===

class PKCE is export {
    method generate-verifier(--> Str) {
        my @chars = flat('A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~');
        (^64).map({ @chars.pick }).join
    }

    method generate-challenge(Str $verifier --> Str) {
        my $sha = self!sha256($verifier.encode('utf-8'));
        self!base64url($sha)
    }

    method challenge-method(--> Str) { 'S256' }

    method !sha256(Blob $data --> Blob) {
        try {
            my $mod = (require ::('Digest::SHA256::Native'));
            my &sha256-func = ::('Digest::SHA256::Native').WHO<&sha256>;
            if &sha256-func.defined {
                return sha256-func($data);
            }
        }
        # Fallback: use OpenSSL via shell
        my $proc = run('openssl', 'dgst', '-sha256', '-binary', :in, :out);
        $proc.in.write($data);
        $proc.in.close;
        my $result = $proc.out.slurp(:bin);
        $result
    }

    method !base64url(Blob $data --> Str) {
        my $encoded = MIME::Base64.encode($data, :oneline);
        $encoded = $encoded.subst('+', '-', :g);
        $encoded = $encoded.subst('/', '_', :g);
        $encoded = $encoded.subst('=', '', :g);
        $encoded
    }
}
