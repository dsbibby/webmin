#!/usr/local/bin/perl
# Called by the let's encrypt client to add a DNS record for validation

$no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*)\/[^\/]+$/) {
        chdir($pwd = $1);
        }
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/letsencrypt-dns.pl";
require './webmin-lib.pl';
&foreign_require("bind8");

# Validate params
my $dname = $ENV{'CERTBOT_DOMAIN'};
my $val = $ENV{'CERTBOT_VALIDATION'};
$dname || die "Missing CERTBOT_DOMAIN environment variable";
$val || die "Missing CERTBOT_VALIDATION environment variable";

# Find the DNS domain and records
$d = &get_virtualmin_for_domain($dname);
my ($zone, $zname) = &get_bind_zone_for_domain($dname);
my ($recs, $file);
my $wapi;
if ($zone) {
	# Use BIND module API calls
	$zone->{'file'} || die "Zone $dname does not have a records file";
	&lock_file(&bind8::make_chroot(&bind8::absolute_path($zone->{'file'})));
	$recs = [ &bind8::read_zone_file($zone->{'file'}, $zname) ];
	$file = $zone->{'file'};
	$wapi = 0;
	}
elsif ($d) {
	# Use Virtualmin API calls
	&virtual_server::obtain_lock_dns($d);
	($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	$wapi = 1;
	}
else {
	die "No DNS zone named $dname found";
	}

# Remove any existing record
my ($r) = grep { $_->{'name'} eq "_acme-challenge.".$dname."." } @$recs;
if ($r) {
	if ($wapi) {
		&virtual_server::delete_dns_record($recs, $file, $r);
		}
	else {
		&bind8::delete_record($file, $r);
		}
	}

# Create the needed DNS record
$r = { 'name' => "_acme-challenge.".$dname.".",
       'type' => 'TXT',
       'ttl' => 5,
       'values' => [ $val ] };
if ($wapi) {
	&virtual_server::create_dns_record($recs, $file, $r);
	}
else {
	&bind8::create_record($file, $r->{'name'}, $r->{'ttl'}, "IN",
			      $r->{'type'}, $r->{'values'}->[0]);
	}

# Create via dynamic update for dynamic zones
use Net::DNS;
my $update = Net::DNS::Update->new( $dname );
$update->push( update => rr_add('_acme-challenge.'.$dname.' 5 TXT "'.$val.'"') );
my $resolver = Net::DNS::Resolver->new();
$resolver->nameservers('127.0.0.1');
my $reply = $resolver->send($update);

my $err;
if (!$wapi) {
	# Apply using BIND API calls
	&bind8::bump_soa_record($file, $recs);
	&bind8::sign_dnssec_zone_if_key($zone, $recs);
	&unlock_file(&bind8::make_chroot(&bind8::absolute_path($file)));
	&bind8::restart_zone($zone->{'name'}, $zone->{'view'});
	}
else {
	# Apply using Virtualmin API
	$err = &virtual_server::post_records_change($d, $recs, $file);
	&virtual_server::release_lock_dns($d);
	&virtual_server::reload_bind_records($d);
	}
die $err if ($err);
sleep($config{'letsencrypt_dns_wait'} || 10);	# Wait for DNS propagation
&webmin_log("letsencryptdns", undef, $dname);
exit(0);
