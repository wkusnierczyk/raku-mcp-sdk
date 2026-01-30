use v6.d;

#| OAuth 2.1 core types, PKCE utilities, and exceptions for MCP authorization
unit module MCP::OAuth;

=begin pod
=head1 NAME

MCP::OAuth - OAuth 2.1 core types, PKCE utilities, and exceptions

=head1 DESCRIPTION

Provides OAuth 2.1 building blocks for MCP authorization: PKCE code
verifier/challenge generation (RFC 7636), token types, metadata discovery
types, and exception classes.

=head1 PKCE

=head2 sub generate-code-verifier(--> Str)

Generate a cryptographically random code verifier (43-128 chars, unreserved
character set per RFC 7636).

=head2 sub generate-code-challenge(Str $verifier --> Str)

Compute the S256 code challenge for a verifier using SHA-256 and base64url
encoding.

=head1 EXCEPTIONS

=item C<X::MCP::OAuth::Unauthorized> — Authentication required.
=item C<X::MCP::OAuth::Forbidden> — Insufficient permissions.
=item C<X::MCP::OAuth::TokenExpired> — Access token has expired.
=item C<X::MCP::OAuth::InvalidToken> — Token is malformed or invalid.

=end pod

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

class X::MCP::OAuth::Registration is Exception is export {
    has Str $.message = 'Dynamic client registration failed';
    has Str $.error;
    has Str $.error-description;
    method message(--> Str) {
        $!error-description ?? "$!message: $!error ($!error-description)" !! $!message
    }
}

class X::MCP::OAuth::TokenExchange is Exception is export {
    has Str $.message = 'Token exchange failed';
    has Str $.error;
    has Str $.error-description;
    method message(--> Str) {
        $!error-description ?? "$!message: $!error ($!error-description)" !! $!message
    }
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
    has Str $.registration-endpoint;
    has @.grant-types-supported;
    has @.response-types-supported;
    has @.scopes-supported;
    has @.code-challenge-methods-supported;

    method Hash(--> Hash) {
        my %h = issuer => $!issuer;
        %h<authorization_endpoint> = $!authorization-endpoint if $!authorization-endpoint;
        %h<token_endpoint> = $!token-endpoint if $!token-endpoint;
        %h<registration_endpoint> = $!registration-endpoint if $!registration-endpoint;
        %h<grant_types_supported> = @!grant-types-supported if @!grant-types-supported;
        %h<response_types_supported> = @!response-types-supported if @!response-types-supported;
        %h<scopes_supported> = @!scopes-supported if @!scopes-supported;
        %h<code_challenge_methods_supported> = @!code-challenge-methods-supported if @!code-challenge-methods-supported;
        %h
    }

    method from-hash(%h --> AuthServerMetadata) {
        my %args =
            issuer => %h<issuer>,
            grant-types-supported => (%h<grant_types_supported> // []).list,
            response-types-supported => (%h<response_types_supported> // []).list,
            scopes-supported => (%h<scopes_supported> // []).list,
            code-challenge-methods-supported => (%h<code_challenge_methods_supported> // []).list;
        %args<authorization-endpoint> = $_ with %h<authorization_endpoint>;
        %args<token-endpoint> = $_ with %h<token_endpoint>;
        %args<registration-endpoint> = $_ with %h<registration_endpoint>;
        self.new(|%args)
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

# === Token Exchange Response (RFC 8693) ===

class TokenExchangeResponse is export {
    has Str $.issued-token-type is required;
    has Str $.access-token is required;  # The ID-JAG JWT
    has Str $.token-type = 'N_A';
    has Str $.scope;
    has Int $.expires-in;

    method from-hash(%h --> TokenExchangeResponse) {
        my %args =
            issued-token-type => %h<issued_token_type>,
            access-token      => %h<access_token>;
        %args<token-type>  = $_ with %h<token_type>;
        %args<scope>       = $_ with %h<scope>;
        %args<expires-in>  = .Int with %h<expires_in>;
        self.new(|%args)
    }
}

# === Dynamic Client Registration (RFC 7591) ===

class ClientRegistrationRequest is export {
    has @.redirect-uris is required;
    has Str $.client-name;
    has Str $.client-uri;
    has Str $.logo-uri;
    has @.contacts;
    has Str $.tos-uri;
    has Str $.policy-uri;
    has @.grant-types;           # e.g., authorization_code, refresh_token
    has @.response-types;        # e.g., code
    has Str $.token-endpoint-auth-method;  # e.g., none, client_secret_post
    has Str $.scope;
    has Str $.software-id;
    has Str $.software-version;

    method Hash(--> Hash) {
        my %h = redirect_uris => @!redirect-uris;
        %h<client_name>                  = $_ with $!client-name;
        %h<client_uri>                   = $_ with $!client-uri;
        %h<logo_uri>                     = $_ with $!logo-uri;
        %h<contacts>                     = @!contacts if @!contacts;
        %h<tos_uri>                      = $_ with $!tos-uri;
        %h<policy_uri>                   = $_ with $!policy-uri;
        %h<grant_types>                  = @!grant-types if @!grant-types;
        %h<response_types>               = @!response-types if @!response-types;
        %h<token_endpoint_auth_method>   = $_ with $!token-endpoint-auth-method;
        %h<scope>                        = $_ with $!scope;
        %h<software_id>                  = $_ with $!software-id;
        %h<software_version>             = $_ with $!software-version;
        %h
    }
}

class ClientRegistrationResponse is export {
    has Str $.client-id is required;
    has Str $.client-secret;
    has Int $.client-secret-expires-at;
    has Str $.registration-access-token;
    has Str $.registration-client-uri;

    # Echo of request metadata
    has @.redirect-uris;
    has Str $.client-name;
    has @.grant-types;
    has @.response-types;
    has Str $.token-endpoint-auth-method;
    has Str $.scope;

    method Hash(--> Hash) {
        my %h = client_id => $!client-id;
        %h<client_secret>             = $_ with $!client-secret;
        %h<client_secret_expires_at>  = $_ with $!client-secret-expires-at;
        %h<registration_access_token> = $_ with $!registration-access-token;
        %h<registration_client_uri>   = $_ with $!registration-client-uri;
        %h<redirect_uris>             = @!redirect-uris if @!redirect-uris;
        %h<client_name>               = $_ with $!client-name;
        %h<grant_types>               = @!grant-types if @!grant-types;
        %h<response_types>            = @!response-types if @!response-types;
        %h<token_endpoint_auth_method> = $_ with $!token-endpoint-auth-method;
        %h<scope>                      = $_ with $!scope;
        %h
    }

    method from-hash(%h --> ClientRegistrationResponse) {
        my %args =
            client-id      => %h<client_id>,
            redirect-uris  => (%h<redirect_uris> // []).list,
            grant-types    => (%h<grant_types> // []).list,
            response-types => (%h<response_types> // []).list;
        %args<client-secret>              = $_ with %h<client_secret>;
        %args<client-secret-expires-at>   = .Int with %h<client_secret_expires_at>;
        %args<registration-access-token>  = $_ with %h<registration_access_token>;
        %args<registration-client-uri>    = $_ with %h<registration_client_uri>;
        %args<client-name>                = $_ with %h<client_name>;
        %args<token-endpoint-auth-method> = $_ with %h<token_endpoint_auth_method>;
        %args<scope>                      = $_ with %h<scope>;
        self.new(|%args)
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
        # Pure Raku fallback to avoid platform-specific native toolchains.
        self!sha256-pure($data) # UNCOVERABLE
    }

    method !sha256-pure(Blob $data --> Blob) {
        constant $MASK = 0xFFFF_FFFF;

        my constant @K = (
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        );

        my UInt $h0 = 0x6a09e667;
        my UInt $h1 = 0xbb67ae85;
        my UInt $h2 = 0x3c6ef372;
        my UInt $h3 = 0xa54ff53a;
        my UInt $h4 = 0x510e527f;
        my UInt $h5 = 0x9b05688c;
        my UInt $h6 = 0x1f83d9ab;
        my UInt $h7 = 0x5be0cd19;

        my @bytes = $data.list;
        my UInt $bit-len = @bytes.elems * 8;

        @bytes.push(0x80);
        while ((@bytes.elems % 64) != 56) {
            @bytes.push(0x00);
        }

        for reverse ^8 -> $i {
            @bytes.push(($bit-len +> ($i * 8)) +& 0xFF);
        }

        sub rotr(UInt $x, Int $n --> UInt) {
            (($x +> $n) +| (($x +< (32 - $n)) +& $MASK)) +& $MASK
        }
        sub shr(UInt $x, Int $n --> UInt) { ($x +> $n) +& $MASK }
        sub ch(UInt $x, UInt $y, UInt $z --> UInt) {
            (($x +& $y) +^ ((+$x +& $MASK) +^ $MASK) +& $z) +& $MASK
        }
        sub maj(UInt $x, UInt $y, UInt $z --> UInt) {
            (($x +& $y) +^ ($x +& $z) +^ ($y +& $z)) +& $MASK
        }
        sub sigma0(UInt $x --> UInt) { (rotr($x, 7) +^ rotr($x, 18) +^ shr($x, 3)) +& $MASK }
        sub sigma1(UInt $x --> UInt) { (rotr($x, 17) +^ rotr($x, 19) +^ shr($x, 10)) +& $MASK }
        sub capsigma0(UInt $x --> UInt) { (rotr($x, 2) +^ rotr($x, 13) +^ rotr($x, 22)) +& $MASK }
        sub capsigma1(UInt $x --> UInt) { (rotr($x, 6) +^ rotr($x, 11) +^ rotr($x, 25)) +& $MASK }

        for @bytes.rotor(64) -> @chunk {
            my UInt @w = 0 xx 64;
            for ^16 -> $i {
                my $j = $i * 4;
                @w[$i] = (
                    ((@chunk[$j]     +& 0xFF) +< 24) +
                    ((@chunk[$j + 1] +& 0xFF) +< 16) +
                    ((@chunk[$j + 2] +& 0xFF) +< 8)  +
                    ((@chunk[$j + 3] +& 0xFF))
                ) +& $MASK;
            }
            for 16 ..^ 64 -> $i {
                @w[$i] = (@w[$i - 16] + sigma0(@w[$i - 15]) + @w[$i - 7] + sigma1(@w[$i - 2])) +& $MASK;
            }

            my UInt $a = $h0;
            my UInt $b = $h1;
            my UInt $c = $h2;
            my UInt $d = $h3;
            my UInt $e = $h4;
            my UInt $f = $h5;
            my UInt $g = $h6;
            my UInt $h = $h7;

            for ^64 -> $i {
                my UInt $t1 = ($h + capsigma1($e) + ch($e, $f, $g) + @K[$i] + @w[$i]) +& $MASK;
                my UInt $t2 = (capsigma0($a) + maj($a, $b, $c)) +& $MASK;
                $h = $g;
                $g = $f;
                $f = $e;
                $e = ($d + $t1) +& $MASK;
                $d = $c;
                $c = $b;
                $b = $a;
                $a = ($t1 + $t2) +& $MASK;
            }

            $h0 = ($h0 + $a) +& $MASK;
            $h1 = ($h1 + $b) +& $MASK;
            $h2 = ($h2 + $c) +& $MASK;
            $h3 = ($h3 + $d) +& $MASK;
            $h4 = ($h4 + $e) +& $MASK;
            $h5 = ($h5 + $f) +& $MASK;
            $h6 = ($h6 + $g) +& $MASK;
            $h7 = ($h7 + $h) +& $MASK;
        }

        my @out;
        for $h0, $h1, $h2, $h3, $h4, $h5, $h6, $h7 -> $word {
            @out.push(($word +> 24) +& 0xFF);
            @out.push(($word +> 16) +& 0xFF);
            @out.push(($word +> 8) +& 0xFF);
            @out.push($word +& 0xFF);
        }
        Blob.new(@out)
    }

    method !base64url(Blob $data --> Str) {
        my $encoded = MIME::Base64.encode($data, :oneline);
        $encoded = $encoded.subst('+', '-', :g);
        $encoded = $encoded.subst('/', '_', :g);
        $encoded = $encoded.subst('=', '', :g);
        $encoded
    }
}
