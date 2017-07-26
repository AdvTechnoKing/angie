#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for stream_ssl_preread module.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_map stream_ssl_preread/)
	->has(qw/stream_ssl stream_return/)->has_daemon('openssl')
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    log_format status $status;

    map $ssl_preread_server_name $name {
        ""       127.0.0.1:8093;
        default  $ssl_preread_server_name;
    }

    upstream foo {
        server 127.0.0.1:8091;
    }

    upstream bar {
        server 127.0.0.1:8092;
    }

    upstream next {
        server 127.0.0.1:8094;
        server 127.0.0.1:8080;
    }

    ssl_preread  on;

    server {
        listen       127.0.0.1:8080;
        return       $name;
    }

    server {
        listen       127.0.0.1:8081;
        proxy_pass   $name;
    }

    server {
        listen       127.0.0.1:8082;
        proxy_pass   $name;
        ssl_preread  off;
    }

    server {
        listen       127.0.0.1:8083;
        proxy_pass   $name;

        preread_timeout      2s;
        preread_buffer_size  42;

        access_log %%TESTDIR%%/status.log status;
    }

    server {
        listen       127.0.0.1:8084;
        proxy_pass   next;

        proxy_connect_timeout  2s;
        preread_buffer_size    8;
    }

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:8091 ssl;
        listen       127.0.0.1:8092 ssl;
        listen       127.0.0.1:8093 ssl;
        ssl_preread  off;
        return       $server_port;
    }
}

EOF

eval { require IO::Socket::SSL; die if $IO::Socket::SSL::VERSION < 1.56; };
plan(skip_all => 'IO::Socket::SSL version >= 1.56 required') if $@;

eval {
	if (IO::Socket::SSL->can('can_client_sni')) {
		IO::Socket::SSL->can_client_sni() or die;
	}
};
plan(skip_all => 'IO::Socket::SSL with OpenSSL SNI support required') if $@;

eval {
	my $ctx = Net::SSLeay::CTX_new() or die;
	my $ssl = Net::SSLeay::new($ctx) or die;
	Net::SSLeay::set_tlsext_host_name($ssl, 'example.org') == 1 or die;
};
plan(skip_all => 'Net::SSLeay with OpenSSL SNI support required') if $@;

$t->plan(12);

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 1024
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config '$d/openssl.conf' -subj '/CN=$name/' "
		. "-out '$d/$name.crt' -keyout '$d/$name.key' "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run();

###############################################################################

my ($p1, $p2, $p3, $p4) = (port(8091), port(8092), port(8093), port(8084));

is(get_ssl('foo', 8081), $p1, 'sni');
is(get_ssl('foo', 8081), $p1, 'sni again');

is(get_ssl('bar', 8081), $p2, 'sni 2');
is(get_ssl('bar', 8081), $p2, 'sni 2 again');

# fallback to an empty value for some reason

is(get_ssl('', 8081), $p3, 'no sni');
is(get_ssl('foo', 8082), $p3, 'preread off');
is(get_ssl('foo', 8083), undef, 'preread buffer full');
is(stream()->io('x' x 1000), "127.0.0.1:$p3", 'not a handshake');

TODO: {
local $TODO = 'not yet';

is(stream("127.0.0.1:$p4")->io('x' x 16), "127.0.0.1:$p3",
	'pending buffers on next upstream');

}

# no junk in variable due to short ClientHello length value

is(get_short(), "127.0.0.1:$p3", 'short client hello');

# allow record with older SSL version, such as 3.0

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.11.8');

is(get_oldver(), 'foo', 'older version in ssl record');

}

$t->stop();

is($t->read_file('status.log'), "400\n", 'preread buffer full - log');

###############################################################################

sub get_short {
	my $r = pack("N*", 0x16030100, 0x38010000, 0x330303eb);
	$r .= pack("N*", 0x6357cdba, 0xa6b8d853, 0xf1f6ac0f);
	$r .= pack("N*", 0xdf03178c, 0x0ae41824, 0xe7643682);
	$r .= pack("N*", 0x3c1b273f, 0xbfde4b00, 0x00000000);
	$r .= pack("CN3", 0x0c, 0x00000008, 0x00060000, 0x03666f6f);

	http($r);
}

sub get_oldver {
	my $r = pack("N*", 0x16030000, 0x38010000, 0x340303eb);
	$r .= pack("N*", 0x6357cdba, 0xa6b8d853, 0xf1f6ac0f);
	$r .= pack("N*", 0xdf03178c, 0x0ae41824, 0xe7643682);
	$r .= pack("N*", 0x3c1b273f, 0xbfde4b00, 0x00000000);
	$r .= pack("CN3", 0x0c, 0x00000008, 0x00060000, 0x03666f6f);

	http($r);
}

sub get_ssl {
	my ($host, $port) = @_;
	my $s = stream("127.0.0.1:$port");

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		local $SIG{PIPE} = sub { die "sigpipe\n" };
		alarm(2);
		IO::Socket::SSL->start_SSL($s->{_socket},
			SSL_hostname => $host,
			SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
			SSL_error_trap => sub { die $_[1] }
		);
		alarm(0);
	};
	alarm(0);

	if ($@) {
		log_in("died: $@");
		return undef;
	}

	return $s->read();
}

###############################################################################
