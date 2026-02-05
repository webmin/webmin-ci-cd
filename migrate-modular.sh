#!/bin/sh
# migrate-modular.sh (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Embedded migration script for Webmin monolithic to modular, while keeping
# enabled modules

# This file is meant to be sourced by a parent installer script, and if the
# parent didn't provide download function, do nothing
command -v download_content >/dev/null 2>&1 || {
	echo "migrate-modular.sh: meant to be sourced" >&2
	echo "from Virtualmin install script (missing download_content)" >&2
	(return 0) 2>/dev/null || exit 0
}

# Detect package ecosystem (rpm/deb) by scanning existing repo config files for
# a given repo host, and prints "rpm" or "deb" and returns 0 when found
get_repo_pkg_type() {
	host="$1"

	for d in /etc/yum.repos.d /etc/dnf/repos.d; do
		[ -d "$d" ] || continue
		if grep -RqsE "(^|[[:space:]])(baseurl|mirrorlist)=" "$d" && \
		   grep -RqsF "$host" "$d"; then
			echo "rpm"
			return 0
		fi
	done

	for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
		[ -f "$f" ] || continue
		if grep -qsE "^[[:space:]]*deb[[:space:]]" "$f" && \
		   grep -qsF "$host" "$f"; then
			echo "deb"
			return 0
		fi
	done

	return 1
}

# Reinstall (or install) the base "webmin" package using the new active repo
# with the correct package manager based on mode (rpm/deb)
reinstall_webmin_by_mode() {
	mode="$1"

	case "$mode" in
		rpm)
			# Try dnf, fall back to yum
			dnf -y makecache >/dev/null 2>&1 || yum -y makecache >/dev/null 2>&1 || :
			dnf -y reinstall webmin >/dev/null 2>&1 \
				|| yum -y reinstall webmin >/dev/null 2>&1 \
				|| dnf -y install webmin >/dev/null 2>&1 \
				|| yum -y install webmin >/dev/null 2>&1
			;;
		deb)
			apt-get update >/dev/null 2>&1 || apt update >/dev/null 2>&1 || :
			DEBIAN_FRONTEND=noninteractive apt-get -y --reinstall install webmin >/dev/null 2>&1 \
				|| DEBIAN_FRONTEND=noninteractive apt-get -y install webmin >/dev/null 2>&1
			;;
	esac
}

# Install modular Webmin packages listed in a file (one module name per line)
# where each module is installed as "webmin-<name>" for both rpm and deb
# families
install_webmin_modules_from_file_by_mode() {
	mode="$1"
	mods_file="$2"
	[ -r "$mods_file" ] || return 0

	case "$mode" in
		rpm)
			while IFS= read -r m; do
				[ -n "$m" ] || continue
				p="webmin-$m"
				dnf -y install "$p" >/dev/null 2>&1 || yum -y install "$p" >/dev/null 2>&1 || :
			done < "$mods_file"
			;;
		deb)
			while IFS= read -r m; do
				[ -n "$m" ] || continue
				p="webmin-$m"
				DEBIAN_FRONTEND=noninteractive apt-get -y install "$p" >/dev/null 2>&1 || :
			done < "$mods_file"
			;;
	esac
}

# List enabled, non-core Webmin modules on the currently installed system by
# reading the Webmin config to find the Webmin root, then using Webmin libs to
# get enabled modules validated against the full and core module lists
get_enabled_webmin_modules() {
	config_file="/etc/webmin/miniserv.conf"

	[ -r "$config_file" ] || return 0

	root=$(awk -F= '/^root=/ {print $2; exit}' "$config_file" 2>/dev/null)
	[ -n "$root" ] || return 0
	[ -d "$root" ] || return 0

	# Try latest release tag, fall back to master
	repo="webmin/webmin"
	ref="master"
	api_url="https://api.github.com/repos/${repo}/releases/latest"
	json=$(download_content "$api_url" 2>/dev/null) || json=""
	if [ -n "$json" ]; then
		tag=$(printf '%s\n' "$json" \
			| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
			| head -n 1)
		case "$tag" in
			""|*' '*|*'	'*) : ;;
			*) ref="$tag" ;;
		esac
	fi

	base_url="https://raw.githubusercontent.com/${repo}/${ref}"

	full_list_file="$root/.webmin-migrate-full.$$"
	core_list_file="$root/.webmin-migrate-core.$$"

	: >"$full_list_file" 2>/dev/null || return 0
	: >"$core_list_file" 2>/dev/null || { rm -f "$full_list_file"; return 0; }

	download_content "${base_url}/mod_full_list.txt" >"$full_list_file" 2>/dev/null || :
	download_content "${base_url}/mod_core_list.txt" >"$core_list_file" 2>/dev/null || :

	tmp="$root/.webmin-migrate-mods.$$.pl"

	cat >"$tmp" <<'PERL'
#!/usr/bin/env perl
use strict;
use warnings;

sub parse_list_file
{
my ($file) = @_;
my %list;

open(my $fh, "<", $file) || return %list;

while (my $line = <$fh>) {
	chomp($line);
	next if ($line =~ /^\s*#/);
	next if ($line =~ /^\s*$/);

	foreach my $mod (split(/\s+/, $line)) {
		next if (!defined($mod) || $mod eq "");
		$list{$mod} = 1;
		}
	}
close($fh);

return %list;
}

sub main
{
my ($full_list_file, $core_list_file) = @ARGV;

my $conf = "/etc/webmin";
my $config_file = "$conf/miniserv.conf";
my ($root, $var_dir);

open(my $fh, "<", $config_file) or return 0;

while (my $line = <$fh>) {
	chomp($line);
	if ($line =~ /^root=(.+)/) {
		($root = $1) =~ s/\s+$//;
		}
	elsif ($line =~ /^env_WEBMIN_VAR=(.+)/) {
		($var_dir = $1) =~ s/\s+$//;
		}
	}
close($fh);

return 0 if (!defined($root) || $root eq "" || !-d $root);

$var_dir = "/var/webmin" if (!defined($var_dir) || $var_dir eq "");

$ENV{'WEBMIN_CONFIG'} = $conf;
$ENV{'WEBMIN_VAR'}    = $var_dir;
$ENV{'PERLLIB'}       = $root;
delete($ENV{'MINISERV_CONFIG'});

unshift(@INC, $root);
unshift(@INC, "$root/vendor_perl") if (-d "$root/vendor_perl");

require WebminCore;
require "$root/webmin/webmin-lib.pl";

my $installed = build_installed_modules(1);

my %full_list = parse_list_file($full_list_file);
my %core_list = parse_list_file($core_list_file);
my $has_lists = scalar(keys %full_list) ? 1 : 0;

foreach my $mod (sort keys %{$installed}) {
	next if (!$installed->{$mod});

	if ($has_lists) {
		next if (!$full_list{$mod});
		next if ($core_list{$mod});
		}

	print "$mod\n";
	}

return 0;
}

exit main();
PERL

	chmod 0700 "$tmp" 2>/dev/null || {
		rm -f "$tmp" "$full_list_file" "$core_list_file"
		return 1
	}

	"$tmp" "$full_list_file" "$core_list_file"
	ret=$?

	rm -f "$tmp" "$full_list_file" "$core_list_file"
	return $ret
}

# If the old repo host is present in current repo configs, capture the list of
# enabled non-core modules while monolithic Webmin is still installed
pre_migration_capture() {
	host="$1"

	mods_file=""
	old_repo_found=0

	# Check rpm repos
	for d in /etc/yum.repos.d /etc/dnf/repos.d; do
		[ -d "$d" ] || continue
		if grep -RqsE "(^|[[:space:]])(baseurl|mirrorlist)=" "$d" && \
		   grep -RqsF "$host" "$d"; then
			old_repo_found=1
			break
		fi
	done

	# Check apt sources (if not already found)
	if [ "$old_repo_found" -eq 0 ]; then
		for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
			[ -f "$f" ] || continue
			if grep -qsE "^[[:space:]]*deb[[:space:]]" "$f" && \
			   grep -qsF "$host" "$f"; then
				old_repo_found=1
				break
			fi
		done
	fi

	# Exit if no old repo
	[ "$old_repo_found" -eq 1 ] || { echo ""; return 0; }

	# Capture enabled non-core modules while monolithic Webmin is still installed
	mods_file="/tmp/webmin-mods.$$"
	get_enabled_webmin_modules >"$mods_file" 2>/dev/null || : >"$mods_file"

	echo "$mods_file"
	return 0
}

# After repos are updated migrate to modular Webmin by detecting rpm or deb from
# repo configs for the new host reinstalling base Webmin from the new repo
# installing previously enabled module packages from the captured list
post_migration_apply() {
	mods_file="$1"
	host="$2"

	[ -n "$mods_file" ] || return 0
	[ -r "$mods_file" ] || { rm -f "$mods_file"; return 0; }
	[ -n "$host" ] || { rm -f "$mods_file"; return 0; }

	# Determine rpm/deb based on newly configured repo files
	mode=$(get_repo_pkg_type "$host") || mode=""

	if [ -n "$mode" ]; then
		reinstall_webmin_by_mode "$mode"
		install_webmin_modules_from_file_by_mode "$mode" "$mods_file"
	fi

	rm -f "$mods_file"
	return 0
}
