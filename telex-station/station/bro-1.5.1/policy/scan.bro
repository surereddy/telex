# $Id: scan.bro 6883 2009-08-19 21:08:09Z vern $

@load conn
@load notice
@load port-name
@load hot
@load drop
@load trw-impl

module Scan;

export {
	redef enum Notice += {
		PortScan,	# the source has scanned a number of ports
		AddressScan,	# the source has scanned a number of addrs
		BackscatterSeen,
			# apparent flooding backscatter seen from source

		ScanSummary,	# summary of scanning activity
		PortScanSummary,	# summary of distinct ports per scanner
		LowPortScanSummary, # summary of distinct low ports per scanner

		PasswordGuessing, # source tried many user/password combinations
		SuccessfulPasswordGuessing,	# same, but a login succeeded

		Landmine,	# source touched a landmine destination
		ShutdownThresh,	# source reached shut_down_thresh
		LowPortTrolling,	# source touched privileged ports
	};

	# If true, we suppress scan-checking (we still do account-tried
	# accounting).  This is provided because scan-checking can consume
	# a lot of memory.
	const suppress_scan_checks = F &redef;

	# Whether to consider UDP "connections" for scan detection.
	# Can lead to false positives due to UDP fanout from some P2P apps.
	const suppress_UDP_scan_checks = F &redef;

	const activate_priv_port_check = T &redef;
	const activate_landmine_check = F &redef;
	const landmine_thresh_trigger = 5 &redef;

	const landmine_address: set[addr] &redef;

	const scan_summary_trigger = 25 &redef;
	const port_summary_trigger = 20 &redef;
	const lowport_summary_trigger = 10 &redef;

	# Raise ShutdownThresh after this many failed attempts
	const shut_down_thresh = 100 &redef;

	# Which services should be analyzed when detecting scanning
	# (not consulted if analyze_all_services is set).
	const analyze_services: set[port] &redef;
	const analyze_all_services = T &redef;

	# Track address scaners only if at least these many hosts contacted.
	const addr_scan_trigger = 0 &redef;

	# Ignore address scanners for further scan detection after
	# scanning this many hosts.
	# 0 disables.
	const ignore_scanners_threshold = 0 &redef;

	# Report a scan of peers at each of these points.
	const report_peer_scan: vector of count = {
		20, 100, 1000, 10000, 50000, 100000, 250000, 500000, 1000000,
	} &redef;

	const report_outbound_peer_scan: vector of count = {
		100, 1000, 10000,
	} &redef;

	# Report a scan of ports at each of these points.
	const report_port_scan: vector of count = {
		50, 250, 1000, 5000, 10000, 25000, 65000,
	} &redef;

	# Once a source has scanned this many different ports (to however many
	# different remote hosts), start tracking its per-destination access.
	const possible_port_scan_thresh = 20 &redef;

	# Threshold for scanning privileged ports.
	const priv_scan_trigger = 5 &redef;
	const troll_skip_service = {
		smtp, ftp, ssh, 20/tcp, http,
	} &redef;

	const report_accounts_tried: vector of count = {
		20, 100, 1000, 10000, 100000, 1000000,
	} &redef;

	const report_remote_accounts_tried: vector of count = {
		100, 500,
	} &redef;

	# Report a successful password guessing if the source attempted
	# at least this many.
	const password_guessing_success_threshhold = 20 &redef;

	const skip_accounts_tried: set[addr] &redef;

	const addl_web = {
		81/tcp, 443/tcp, 8000/tcp, 8001/tcp, 8080/tcp, }
	&redef;

	const skip_services = { ident, } &redef;
	const skip_outbound_services = { Hot::allow_services, ftp, addl_web, }
		&redef;

	const skip_scan_sources = {
		255.255.255.255,	# who knows why we see these, but we do

		# AltaVista.  Here just as an example of what sort of things
		# you might list.
		test-scooter.av.pa-x.dec.com,
	} &redef;

	const skip_scan_nets: set[subnet] = {} &redef;

	# List of well known local server/ports to exclude for scanning
	# purposes.
	const skip_dest_server_ports: set[addr, port] = {} &redef;

	# Reverse (SYN-ack) scans seen from these ports are considered
	# to reflect possible SYN-flooding backscatter, and not true
	# (stealth) scans.
	const backscatter_ports = {
		http, 53/tcp, 53/udp, bgp, 6666/tcp, 6667/tcp,
	} &redef;

	const report_backscatter: vector of count = {
		20,
	} &redef;

	global check_scan:
		function(c: connection, established: bool, reverse: bool): bool;

	# The following tables are defined here so that we can redef
	# the expire timeouts.
	# FIXME: should we allow redef of attributes on IDs which
	# are not exported?

	# How many different hosts connected to with a possible
	# backscatter signature.
	global distinct_backscatter_peers: table[addr] of table[addr] of count
		&read_expire = 15 min;

	# Expire functions that trigger summaries.
	global scan_summary:
		function(t: table[addr] of set[addr], orig: addr): interval;
	global port_summary:
		function(t: table[addr] of set[port], orig: addr): interval;
	global lowport_summary:
		function(t: table[addr] of set[port], orig: addr): interval;

	# Indexed by scanner address, yields # distinct peers scanned.
	# pre_distinct_peers tracks until addr_scan_trigger hosts first.
	global pre_distinct_peers: table[addr] of set[addr]
		&read_expire = 15 mins &redef;

	global distinct_peers: table[addr] of set[addr]
		&read_expire = 15 mins &expire_func=scan_summary &redef;
	global distinct_ports: table[addr] of set[port]
		&read_expire = 15 mins &expire_func=port_summary &redef;
	global distinct_low_ports: table[addr] of set[port]
		&read_expire = 15 mins &expire_func=lowport_summary &redef;

	# Indexed by scanner address, yields a table with scanned hosts
	# (and ports).
	global scan_triples: table[addr] of table[addr] of set[port];

	global remove_possible_source:
		function(s: set[addr], idx: addr): interval;
	global possible_scan_sources: set[addr]
		&expire_func=remove_possible_source &read_expire = 15 mins;

	# Indexed by source address, yields user name & password tried.
	global accounts_tried: table[addr] of set[string, string]
		&read_expire = 1 days;

	global ignored_scanners: set[addr] &create_expire = 1 day &redef;

	# These tables track whether a threshold has been reached.
	# More precisely, the counter is the next index of threshold vector.
	global shut_down_thresh_reached: table[addr] of bool &default=F;
	global rb_idx: table[addr] of count
			&default=1 &read_expire = 1 days &redef;
	global rps_idx: table[addr] of count
			&default=1 &read_expire = 1 days &redef;
	global rops_idx: table[addr] of count
			&default=1 &read_expire = 1 days &redef;
	global rpts_idx: table[addr,addr] of count
			&default=1 &read_expire = 1 days &redef;
	global rat_idx: table[addr] of count
			&default=1 &read_expire = 1 days &redef;
	global rrat_idx: table[addr] of count
			&default=1 &read_expire = 1 days &redef;
}

global thresh_check: function(v: vector of count, idx: table[addr] of count,
				orig: addr, n: count): bool;
global thresh_check_2: function(v: vector of count,
				idx: table[addr,addr] of count, orig: addr,
				resp: addr, n: count): bool;

function scan_summary(t: table[addr] of set[addr], orig: addr): interval
	{
	local num_distinct_peers = orig in t ? |t[orig]| : 0;

	if ( num_distinct_peers >= scan_summary_trigger )
		NOTICE([$note=ScanSummary, $src=orig, $n=num_distinct_peers,
			$msg=fmt("%s scanned a total of %d hosts",
					orig, num_distinct_peers)]);

	return 0 secs;
	}

function port_summary(t: table[addr] of set[port], orig: addr): interval
	{
	local num_distinct_ports = orig in t ? |t[orig]| : 0;

	if ( num_distinct_ports >= port_summary_trigger )
		NOTICE([$note=PortScanSummary, $src=orig, $n=num_distinct_ports,
			$msg=fmt("%s scanned a total of %d ports",
					orig, num_distinct_ports)]);

	return 0 secs;
	}

function lowport_summary(t: table[addr] of set[port], orig: addr): interval
	{
	local num_distinct_lowports = orig in t ? |t[orig]| : 0;

	if ( num_distinct_lowports >= lowport_summary_trigger )
		NOTICE([$note=LowPortScanSummary, $src=orig,
			$n=num_distinct_lowports,
			$msg=fmt("%s scanned a total of %d low ports",
					orig, num_distinct_lowports)]);

	return 0 secs;
	}

function ignore_addr(a: addr)
	{
	add ignored_scanners[a];

	delete distinct_peers[a];
	delete distinct_ports[a];
	delete distinct_low_ports[a];
	delete scan_triples[a];
	delete possible_scan_sources[a];
	delete distinct_backscatter_peers[a];
	delete pre_distinct_peers[a];
	delete rb_idx[a];
	delete rps_idx[a];
	delete rops_idx[a];
	delete rat_idx[a];
	delete rrat_idx[a];
	}

function check_scan(c: connection, established: bool, reverse: bool): bool
	{
	if ( suppress_scan_checks )
		return F;

	local id = c$id;

	local service = "ftp-data" in c$service ? 20/tcp
			: (reverse ? id$orig_p : id$resp_p);
	local rev_service = reverse ? id$resp_p : id$orig_p;
	local orig = reverse ? id$resp_h : id$orig_h;
	local resp = reverse ? id$orig_h : id$resp_h;
	local outbound = is_local_addr(orig);

	# The following works better than using get_conn_transport_proto()
	# because c might not correspond to an active connection (which
	# causes the function to fail).
	if ( suppress_UDP_scan_checks &&
	     service >= 0/udp && service <= 65535/udp )
		return F;

	if ( service in skip_services && ! outbound )
		return F;

	if ( outbound && service in skip_outbound_services )
		return F;

	if ( orig in skip_scan_sources )
		return F;

	if ( orig in skip_scan_nets )
		return F;

	# Don't include well known server/ports for scanning purposes.
	if ( ! outbound && [resp, service] in skip_dest_server_ports )
		return F;

	if ( orig in ignored_scanners)
		return F;

	if ( (! established || service !in Hot::allow_services) &&
		# not established, service not expressly allowed

		# not known peer set
	     (orig !in distinct_peers || resp !in distinct_peers[orig]) &&

		# want to consider service for scan detection
	     (analyze_all_services || service in analyze_services) )
		{
		if ( reverse && rev_service in backscatter_ports &&
		     # reverse, non-priv backscatter port
		     service >= 1024/tcp )
			{
			if ( orig !in distinct_backscatter_peers )
				{
				local empty_bs_table:
					table[addr] of count &default=0;
				distinct_backscatter_peers[orig] =
					empty_bs_table;
				}

			if ( ++distinct_backscatter_peers[orig][resp] <= 2 &&
			     # The test is <= 2 because we get two check_scan()
			     # calls, once on connection attempt and once on
			     # tear-down.

			     distinct_backscatter_peers[orig][resp] == 1 &&

			     # Looks like backscatter, and it's not scanning
			     # a privileged port.

			     thresh_check(report_backscatter, rb_idx, orig,
					|distinct_backscatter_peers[orig]|)
			   )
				{
				local rev_svc = rev_service in port_names ?
					port_names[rev_service] :
					fmt("%s", rev_service);

				NOTICE([$note=BackscatterSeen, $src=orig,
					$p=rev_service,
					$msg=fmt("backscatter seen from %s (%d hosts; %s)",
						orig, |distinct_backscatter_peers[orig]|, rev_svc)]);
				}

			if ( ignore_scanners_threshold > 0 &&
			     |distinct_backscatter_peers[orig]| >
					ignore_scanners_threshold )
				ignore_addr(orig);
			}

		else
			{ # done with backscatter check
			local ignore = F;

			local svc = service in port_names ?
				port_names[service] : fmt("%s", service);

			if ( orig !in distinct_peers && addr_scan_trigger > 0 )
				{
				if ( orig !in pre_distinct_peers )
					pre_distinct_peers[orig] = set();

				add pre_distinct_peers[orig][resp];
				if ( |pre_distinct_peers[orig]| < addr_scan_trigger )
					ignore = T;
				}

			if ( ! ignore )
				{ # XXXXX

				if ( orig !in distinct_peers )
					distinct_peers[orig] = set() &mergeable;

				if ( resp !in distinct_peers[orig] )
					add distinct_peers[orig][resp];

				local n = |distinct_peers[orig]|;

				if ( activate_landmine_check &&
				     n >= landmine_thresh_trigger &&
				     mask_addr(resp, 24) in landmine_address )
					{
					local msg2 = fmt("landmine address trigger %s%s ", orig, svc);
					NOTICE([$note=Landmine, $src=orig,
						$p=service, $msg=msg2]);
					}

				# Check for threshold if not outbound.
				if ( ! shut_down_thresh_reached[orig] &&
				     n >= shut_down_thresh &&
				     ! outbound && orig !in neighbor_nets )
					{
					shut_down_thresh_reached[orig] = T;
					local msg = fmt("shutdown threshold reached for %s", orig);
					NOTICE([$note=ShutdownThresh, $src=orig,
						$p=service, $msg=msg]);
					}

				else
					{
					local address_scan = F;
					if ( outbound &&
					     # inside host scanning out?
					     thresh_check(report_outbound_peer_scan, rops_idx, orig, n) )
						address_scan = T;

					if ( ! outbound &&
					     thresh_check(report_peer_scan, rps_idx, orig, n) )
						address_scan = T;

					if ( address_scan )
						NOTICE([$note=AddressScan,
							$src=orig, $p=service,
							$n=n,
							$msg=fmt("%s has scanned %d hosts (%s)",
								orig, n, svc)]);

					if ( address_scan &&
					     ignore_scanners_threshold > 0 &&
					     n > ignore_scanners_threshold )
						ignore_addr(orig);
					}
				}
			} # XXXX
		}

	if ( established )
		# Don't consider established connections for port scanning,
		# it's too easy to be mislead by FTP-like applications that
		# legitimately gobble their way through the port space.
		return F;

	# Coarse search for port-scanning candidates: those that have made
	# connections (attempts) to possible_port_scan_thresh or more
	# distinct ports.
	if ( orig !in distinct_ports || service !in distinct_ports[orig] )
		{
		if ( orig !in distinct_ports )
			distinct_ports[orig] = set() &mergeable;

		if ( service !in distinct_ports[orig] )
			add distinct_ports[orig][service];

		if ( |distinct_ports[orig]| >= possible_port_scan_thresh &&
			orig !in scan_triples )
			{
			scan_triples[orig] = table() &mergeable;
			add possible_scan_sources[orig];
			}
		}

	# Check for low ports.
	if ( activate_priv_port_check && ! outbound && service < 1024/tcp &&
	     service !in troll_skip_service )
		{
		if ( orig !in distinct_low_ports ||
		     service !in distinct_low_ports[orig] )
			{
			if ( orig !in distinct_low_ports )
				distinct_low_ports[orig] = set() &mergeable;

			add distinct_low_ports[orig][service];

			if ( |distinct_low_ports[orig]| == priv_scan_trigger &&
			     orig !in neighbor_nets )
				{
				local s = service in port_names ? port_names[service] :
						fmt("%s", service);
				local svrc_msg = fmt("low port trolling %s %s", orig, s);
				NOTICE([$note=LowPortTrolling, $src=orig,
					$p=service, $msg=svrc_msg]);
				}

			if ( ignore_scanners_threshold > 0 &&
			     |distinct_low_ports[orig]| >
					ignore_scanners_threshold )
				ignore_addr(orig);
			}
		}

	# For sources that have been identified as possible scan sources,
	# keep track of per-host scanning.
	if ( orig in possible_scan_sources )
		{
		if ( orig !in scan_triples )
			scan_triples[orig] = table() &mergeable;

		if ( resp !in scan_triples[orig] )
			scan_triples[orig][resp] = set() &mergeable;

		if ( service !in scan_triples[orig][resp] )
			{
			add scan_triples[orig][resp][service];

			if ( thresh_check_2(report_port_scan, rpts_idx,
					    orig, resp,
					    |scan_triples[orig][resp]|) )
				{
				local m = |scan_triples[orig][resp]|;
				NOTICE([$note=PortScan, $n=m, $src=orig,
					$p=service,
					$msg=fmt("%s has scanned %d ports of %s",
					orig, m, resp)]);
				}
			}
		}

	return T;
	}


event account_tried(c: connection, user: string, passwd: string)
	{
	local src = c$id$orig_h;

	if ( src !in accounts_tried )
		accounts_tried[src] = set();

	if ( [user, passwd] in accounts_tried[src] )
		return;

	local threshold_check = F;

	if ( is_local_addr(src) )
		{
		if ( thresh_check(report_remote_accounts_tried, rrat_idx, src,
					|accounts_tried[src]|) )
			threshold_check = T;
		}
	else
		{
		if ( thresh_check(report_accounts_tried, rat_idx, src,
					|accounts_tried[src]|) )
			 threshold_check = T;
		}

	if ( threshold_check && src !in skip_accounts_tried )
		{
		local m = |accounts_tried[src]|;
		NOTICE([$note=PasswordGuessing, $src=src, $n=m,
			$user=user, $sub=passwd, $p=c$id$resp_p,
			$msg=fmt("%s has tried %d username/password combinations (latest: %s@%s)",
				src, m,	user, c$id$resp_h)]);
		}

	add accounts_tried[src][user, passwd];
	}

# Check for a successful login attempt from a scan.
event login_successful(c: connection, user: string)
	{
	local id = c$id;
	local src = id$orig_h;

	if ( src in accounts_tried &&
	     |accounts_tried[src]| >= password_guessing_success_threshhold )
		NOTICE([$note=SuccessfulPasswordGuessing, $src=src, $conn=c,
			$msg=fmt("%s successfully logged in user '%s' after trying %d username/password combinations",
				src, user, |accounts_tried[src]|)]);
	}


# Hook into the catch&release dropping. When an address gets restored, we reset
# the source to allow dropping it again.
event address_restored(a: addr)
	{
	delete ignored_scanners[a];
	delete shut_down_thresh_reached[a];
	}

# When removing a possible scan source, we automatically delete its scanned
# hosts and ports.  But we do not want the deletion propagated, because every
# peer calls the expire_function on its own (and thus applies the delete
# operation on its own table).
function remove_possible_source(s: set[addr], idx: addr): interval
	{
	suspend_state_updates();
	delete scan_triples[idx];
	resume_state_updates();

	return 0 secs;
	}

# To recognize whether a certain threshhold vector (e.g. report_peer_scans)
# has been transgressed, a global variable containing the next vector index
# (idx) must be incremented.  This cumbersome mechanism is necessary because
# values naturally don't increment by one (e.g. replayed table merges).
function thresh_check(v: vector of count, idx: table[addr] of count,
			orig: addr, n: count): bool
	{
	if ( ignore_scanners_threshold > 0 && n > ignore_scanners_threshold )
		{
		ignore_addr(orig);
		return F;
		}

	if ( idx[orig] <= |v| && n >= v[idx[orig]] )
		{
		++idx[orig];
		return T;
		}
	else
		return F;
	}

# Same as above, except the index has a different type signature.
function thresh_check_2(v: vector of count, idx: table[addr, addr] of count,
			orig: addr, resp: addr, n: count): bool
	{
	if ( ignore_scanners_threshold > 0 && n > ignore_scanners_threshold )
		{
		ignore_addr(orig);
		return F;
		}

	if ( idx[orig,resp] <= |v| && n >= v[idx[orig, resp]] )
		{
		++idx[orig,resp];
		return T;
		}
	else
		return F;
	}

event connection_established(c: connection)
	{
	local is_reverse_scan = (c$orig$state == TCP_INACTIVE);
	Scan::check_scan(c, T, is_reverse_scan);

	local trans = get_port_transport_proto(c$id$orig_p);
	if ( trans == tcp && ! is_reverse_scan && TRW::use_TRW_algorithm )
		TRW::check_TRW_scan(c, conn_state(c, trans), F);
	}

event partial_connection(c: connection)
	{
	Scan::check_scan(c, T, F);
	}

event connection_attempt(c: connection)
	{
	Scan::check_scan(c, F, c$orig$state == TCP_INACTIVE);

	local trans = get_port_transport_proto(c$id$orig_p);
	if ( trans == tcp && TRW::use_TRW_algorithm )
		TRW::check_TRW_scan(c, conn_state(c, trans), F);
	}

event connection_half_finished(c: connection)
	{
	# Half connections never were "established", so do scan-checking here.
	Scan::check_scan(c, F, F);
	}

event connection_rejected(c: connection)
	{
	local is_reverse_scan = c$orig$state == TCP_RESET;

	Scan::check_scan(c, F, is_reverse_scan);

	local trans = get_port_transport_proto(c$id$orig_p);
	if ( trans == tcp && TRW::use_TRW_algorithm )
		TRW::check_TRW_scan(c, conn_state(c, trans), is_reverse_scan);
	}

event connection_reset(c: connection)
	{
	if ( c$orig$state == TCP_INACTIVE || c$resp$state == TCP_INACTIVE )
		# We never heard from one side - that looks like a scan.
		Scan::check_scan(c, c$orig$size + c$resp$size > 0,
				c$orig$state == TCP_INACTIVE);
	}

event connection_pending(c: connection)
	{
	if ( c$orig$state == TCP_PARTIAL && c$resp$state == TCP_INACTIVE )
		Scan::check_scan(c, F, F);
	}

# Report the remaining entries in the tables.
event bro_done()
	{
	for ( orig in distinct_peers )
		scan_summary(distinct_peers, orig);

	for ( orig in distinct_ports )
		port_summary(distinct_ports, orig);

	for ( orig in distinct_low_ports )
		lowport_summary(distinct_low_ports, orig);
	}
