#!/usr/bin/env bash
#
# install-smartdns.sh — Install, configure and tune SmartDNS on Ubuntu 22.04
# for VPN / proxy servers that serve thousands of concurrent clients.
#
# How it returns the best IP for every site
#   1. Every cache miss is sent to several independent upstream resolvers in
#      parallel (plain DNS: Cloudflare, Google, Quad9-ECS). They map CDNs
#      differently, so together they yield more candidate addresses.
#   2. SmartDNS probes every candidate from THIS server (ICMP ping, falling back
#      to a TCP SYN on :443, then :80) and answers with the fastest one first.
#      VPN traffic reaches the internet from here, so this is exactly the path
#      your users' connections take.
#   3. Answers are cached, then re-resolved and re-measured in the background
#      (prefetch + serve-stale): peak-hour traffic is answered from memory while
#      the chosen IP keeps tracking changing network conditions.
#
# Production features
#   * Official release .deb from GitHub, sha256-verified (or --deb for offline)
#   * Transactional: everything touched is backed up; if SmartDNS does not come
#     up healthy, the previous state (including the system resolver) is restored
#   * Idempotent: re-run at any time to upgrade or change settings
#   * Never an open resolver: SmartDNS ACL + nftables guard (+ ufw rules)
#   * Unprivileged runtime user, systemd sandbox, liveness watchdog
#   * Kernel tuning that only ever raises limits, never lowers existing ones
#   * Programs already using 127.0.0.53 (the host itself, host-network
#     containers such as Xray / sing-box nodes) move to SmartDNS with no restart
#
# Usage: sudo bash install-smartdns.sh [options]        (see --help)
#
set -Eeuo pipefail
shopt -s inherit_errexit
umask 022
export LC_ALL=C

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME=${0##*/}
readonly TESTED_RELEASE="Release48.4"
readonly GH_REPO="pymumu/smartdns"

# ---- Files and paths ---------------------------------------------------------
readonly SD_BIN=/usr/sbin/smartdns
readonly SD_CONF_DIR=/etc/smartdns
readonly SD_CONF=$SD_CONF_DIR/smartdns.conf
readonly SD_CONF_D=$SD_CONF_DIR/conf.d
readonly SD_GUARD_NFT=$SD_CONF_DIR/guard.nft
readonly SD_DATA_DIR=/var/lib/smartdns
readonly SD_LOG_DIR=/var/log/smartdns
readonly SD_USER=smartdns
readonly SD_DROPIN=/etc/systemd/system/smartdns.service.d/10-vpn-tuning.conf
readonly GUARD_UNIT=/etc/systemd/system/smartdns-guard.service
readonly HC_BIN=/usr/local/sbin/smartdns-healthcheck
readonly HC_SERVICE=/etc/systemd/system/smartdns-healthcheck.service
readonly HC_TIMER=/etc/systemd/system/smartdns-healthcheck.timer
readonly RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/90-smartdns.conf
readonly SYSCTL_FILE=/etc/sysctl.d/99-zz-smartdns.conf
readonly MODPROBE_FILE=/etc/modprobe.d/smartdns-conntrack.conf
readonly MODULES_FILE=/etc/modules-load.d/smartdns-conntrack.conf
readonly STATE_DIR=/var/lib/smartdns-installer
readonly STATE_FILE=$STATE_DIR/state
readonly BACKUP_ROOT=/var/backups/smartdns-installer
readonly INSTALL_LOG=/var/log/smartdns-installer.log
readonly LOCK_FILE=/run/smartdns-installer.lock
readonly HEALTH_NAME=health.smartdns.internal
readonly NFT_TABLE=smartdns_guard

# ---- Defaults (all overridable from the command line) ------------------------
# Client networks allowed to query, in addition to loopback: RFC 1918, CGNAT
# (Tailscale, many VPN pools, carrier NAT) and IPv6 ULA.
readonly DEFAULT_ALLOW=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7)
# Plain DNS (UDP, TCP on truncation). Primaries are queried in parallel on
# every cache miss; Quad9's 9.9.9.11 forwards EDNS Client Subnet for better CDN
# mapping. Fallbacks are only used when the primaries fail or time out.
readonly DEFAULT_UPSTREAMS=(
	"1.1.1.1"
	"8.8.8.8"
	"1.0.0.1 -fallback"
	"8.8.4.4 -fallback"
)

ACTION=install
ALLOW_CIDRS=()
LISTEN_ADDRS=()
UPSTREAMS=()
PORT=53
IPV6_MODE=auto
RESPONSE_MODE=fastest-ip
SPEED_CHECK=ping,tcp-syn:443,tcp-syn:80
MAX_IPS=3
CACHE_SIZE=auto
TTL_MIN=300
TTL_MAX=3600
TTL_REPLY_MAX=60
RATE_LIMIT=0
FIREWALL=1
KERNEL_TUNING=1
AUDIT=0
LOG_LEVEL=warn
SD_RELEASE=latest
LOCAL_DEB=
FORCE=0
PURGE=0
DRY_RUN=0

# ---- Runtime state -----------------------------------------------------------
WORK_DIR='' DRY_ROOT='' BACKUP_DIR=''
SD_ARCH='' MEM_MB=0 RELEASE_TAG='' PKG_FILE=''
IPV6_SOCKETS=0 IPV6_ENABLED=0 CONNTRACK=0 CACHE_ENTRIES=0
BIND_SPECS=() ACL_CIDRS=()
TXN_ACTIVE=0 CHANGED=0 NEED_RESTART=0 SMARTDNS_WAS_ACTIVE=0 RESOLVED_TOUCHED=0 GUARD_OK=0
CREATED_FILES=() REPLACED_FILES=() ENABLED_UNITS=() UFW_ADDED=()
STATE_RELEASE='' STATE_PORT='' STATE_UFW_RULES='' STATE_ORIG_RESOLV_BACKUP=''

# ==============================================================================
#  Output, errors, rollback
# ==============================================================================
if [[ -t 1 ]]; then
	C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_0=$'\e[0m'
else
	C_R='' C_G='' C_Y='' C_B='' C_0=''
fi

log_file() {
	(( DRY_RUN )) && return 0
	printf '%s %-5s %s\n' "$(date '+%F %T')" "$1" "$2" >>"$INSTALL_LOG" 2>/dev/null || true
}
step() { log_file STEP "$*"; printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
info() { log_file INFO "$*"; printf '    %s\n' "$*"; }
ok()   { log_file OK "$*"; printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { log_file WARN "$*"; printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { log_file ERROR "$*"; printf '  %s✖%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

on_err() {
	local rc=$? line=$1 cmd=$2
	err "Command failed (exit $rc) at line $line: $cmd"
	exit "$rc"
}

on_exit() {
	local rc=$?
	set +e
	trap - ERR
	if (( rc != 0 && TXN_ACTIVE )); then rollback; fi
	[[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf "$WORK_DIR"
	if (( rc != 0 && ! DRY_RUN && EUID == 0 )); then printf '\n    Details: %s\n' "$INSTALL_LOG" >&2; fi
	exit "$rc"
}

trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'exit 130' INT TERM

# Undo everything this run changed. Runs from the EXIT trap after a failure.
rollback() {
	(( TXN_ACTIVE )) || return 0
	TXN_ACTIVE=0
	step "Rolling back this run's changes"
	local f u c

	systemctl stop smartdns-healthcheck.timer smartdns.service >/dev/null 2>&1
	for u in "${ENABLED_UNITS[@]}"; do systemctl disable "$u" >/dev/null 2>&1; done
	if [[ " ${CREATED_FILES[*]} " == *" $SD_GUARD_NFT "* ]]; then
		nft delete table inet "$NFT_TABLE" >/dev/null 2>&1
	fi

	for f in "${REPLACED_FILES[@]}"; do
		rm -f "$f" && cp -a "$BACKUP_DIR$f" "$f" && info "restored $f"
	done
	for f in "${CREATED_FILES[@]}"; do
		rm -f "$f" && info "removed $f"
	done
	rmdir "${SD_DROPIN%/*}" 2>/dev/null
	# First install: give the (now disabled) package its stock config back.
	if [[ ! -e $SD_CONF && -e $SD_CONF.dpkg-dist ]]; then mv -f "$SD_CONF.dpkg-dist" "$SD_CONF"; fi
	systemctl daemon-reload

	for c in "${UFW_ADDED[@]}"; do ufw delete allow from "$c" to any port "$PORT" >/dev/null 2>&1; done
	if [[ " ${REPLACED_FILES[*]} " == *" $SD_GUARD_NFT "* ]]; then
		systemctl restart smartdns-guard.service >/dev/null 2>&1
	fi
	if (( RESOLVED_TOUCHED )); then systemctl restart systemd-resolved.service; fi
	if (( SMARTDNS_WAS_ACTIVE )); then
		systemctl start smartdns.service && info "previous SmartDNS restarted"
	fi

	if getent ahosts one.one.one.one >/dev/null 2>&1; then
		ok "Rolled back; this host resolves names again"
	else
		warn "Rolled back, but this host still cannot resolve names — check /etc/resolv.conf"
	fi
	if [[ -n $BACKUP_DIR ]]; then info "Backups kept in $BACKUP_DIR"; fi
}

# ==============================================================================
#  Small utilities
# ==============================================================================
usage() {
	cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — SmartDNS for high-traffic VPN servers (Ubuntu 22.04)

Usage: sudo bash ${SCRIPT_NAME} [options]

Actions (default: install or upgrade, then configure):
  --verify                Health-check the running SmartDNS and exit
  --uninstall [--purge]   Remove SmartDNS and restore the previous resolver
                          (--purge also deletes config, cache, logs and user)
  --dry-run               Render every file into a temp dir; change nothing

Clients and listeners:
  --allow CIDR[,CIDR]     Client networks allowed to query (repeatable).
                          Loopback is always allowed. Default: 10.0.0.0/8,
                          172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, fc00::/7
  --listen IP[,IP]        Bind only these addresses (default: all interfaces)
  --port N                DNS port (default 53). Any other port leaves this
                          host's own resolver untouched (handy for trials)
  --ipv6 auto|on|off      Hand out AAAA records (default auto: only when this
                          server has IPv6 connectivity)

Resolution:
  --upstream SPEC         SmartDNS 'server' spec; repeatable; replaces the
                          defaults, e.g. --upstream 208.67.222.222
  --response-mode MODE    fastest-ip (default) | first-ping | fastest-response
  --speed-check LIST      Probe order (default ${SPEED_CHECK})
  --max-ips N             Addresses per answer, fastest first (default ${MAX_IPS})
  --cache-size N          Cache entries (default: auto, about RAM/64)
  --ttl-min SECONDS       Minimum cache TTL (default ${TTL_MIN}); answers and
  --ttl-max SECONDS       their chosen IP are re-measured between these (${TTL_MAX})
  --ttl-reply-max SECONDS Longest TTL handed to clients (default ${TTL_REPLY_MAX})

System:
  --rate-limit QPS        Per-client UDP query limit in nftables (default: off)
  --no-firewall           Skip the nftables guard and ufw rules
  --no-kernel-tuning      Skip sysctl / conntrack tuning
  --audit                 Log every query (off by default: privacy and I/O)
  --log-level LEVEL       off|fatal|error|warn|notice|info|debug (default warn)

Package:
  --release TAG           SmartDNS release, e.g. Release48.4 (default: latest)
  --deb FILE              Install this local .deb (offline or pinned installs)
  --force                 Continue on OS releases other than Ubuntu 22.04
  -h, --help              Show this help

Environment:
  GITHUB_TOKEN            Optional; avoids GitHub API rate limits
EOF
}

join_by() {
	local sep=$1 out=${2-} x
	shift 2 || { printf '%s' "$out"; return 0; }
	for x in "$@"; do out+=$sep$x; done
	printf '%s' "$out"
}

# split_into ARRAY "a,b c" — append comma/space separated items to ARRAY.
split_into() {
	local -n _split_dst=$1
	local -a _split_parts=()
	IFS=$', \t' read -r -a _split_parts <<<"$2"
	_split_dst+=("${_split_parts[@]}")
}

dedupe() {
	local -n _dd_arr=$1
	local -A _dd_seen=()
	local -a _dd_out=()
	local _dd_x
	for _dd_x in "${_dd_arr[@]}"; do
		[[ -z $_dd_x || -n ${_dd_seen[$_dd_x]:-} ]] && continue
		_dd_seen[$_dd_x]=1
		_dd_out+=("$_dd_x")
	done
	_dd_arr=("${_dd_out[@]}")
}

clamp() {
	local -n _cl_v=$1
	(( _cl_v < $2 )) && _cl_v=$2
	(( _cl_v > $3 )) && _cl_v=$3
	return 0
}

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

is_ipv4() {
	local IFS=. o
	[[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	for o in $1; do (( 10#$o <= 255 )) || return 1; done
}

is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]; }

# Print "ip[/len]" as a network CIDR with host bits cleared; fail on bad input.
normalize_cidr() {
	local ip=${1%/*} len='' a b c d n mask
	[[ $1 == */* ]] && len=${1##*/}
	if is_ipv4 "$ip"; then
		len=${len:-32}
		if ! [[ $len =~ ^[0-9]{1,2}$ ]] || (( len > 32 )); then return 1; fi
		IFS=. read -r a b c d <<<"$ip"
		n=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
		mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
		n=$(( n & mask ))
		printf '%d.%d.%d.%d/%d\n' $(( n >> 24 & 255 )) $(( n >> 16 & 255 )) $(( n >> 8 & 255 )) $(( n & 255 )) "$len"
	elif is_ipv6 "$ip"; then
		len=${len:-128}
		if ! [[ $len =~ ^[0-9]{1,3}$ ]] || (( len > 128 )); then return 1; fi
		if have python3; then
			python3 -c 'import ipaddress, sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' \
				"$ip/$len" 2>/dev/null || return 1
		else
			printf '%s/%s\n' "$ip" "$len"
		fi
	else
		return 1
	fi
}

smartdns_version() {
	local v
	v=$("$SD_BIN" -v 2>/dev/null) || true
	printf '%s' "${v%%$'\n'*}"
}

# dns_q SERVER NAME TYPE [dig options...] — short answer lines, never fails.
dns_q() {
	local server=$1 name=$2 type=$3
	shift 3
	dig +short +time=2 +tries=1 -p "$PORT" "@$server" "$@" "$name" "$type" 2>/dev/null || true
}

first_ip() { grep -m1 -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+:[0-9a-fA-F:]*$'; }

ufw_active() {
	local s
	have ufw || return 1
	s=$(ufw status 2>/dev/null) || return 1
	[[ $s == *"Status: active"* ]]
}

acquire_lock() {
	exec 9>"$LOCK_FILE"
	flock -n 9 || die "Another run of ${SCRIPT_NAME} is in progress."
}

load_state() {
	# shellcheck source=/dev/null
	if [[ -r $STATE_FILE ]]; then source "$STATE_FILE"; fi
	return 0
}

save_state() {
	local -a ufw_rules=()
	split_into ufw_rules "$STATE_UFW_RULES"
	ufw_rules+=("${UFW_ADDED[@]}")
	dedupe ufw_rules
	install -d -m 0700 "$STATE_DIR"
	{
		printf '# %s state (used by --verify / --uninstall). Do not edit.\n' "$SCRIPT_NAME"
		printf 'STATE_RELEASE=%q\n' "$RELEASE_TAG"
		printf 'STATE_PORT=%q\n' "$PORT"
		printf 'STATE_UFW_RULES=%q\n' "${ufw_rules[*]}"
		printf 'STATE_ORIG_RESOLV_BACKUP=%q\n' "$STATE_ORIG_RESOLV_BACKUP"
		printf 'STATE_UPDATED=%q\n' "$(date -u '+%FT%TZ')"
	} >"$STATE_FILE.tmp"
	mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# ==============================================================================
#  Transactional file writes
# ==============================================================================
backup_file() {
	local src=$1
	if [[ -z $BACKUP_DIR ]]; then BACKUP_DIR=$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S'); fi
	if [[ -e $BACKUP_DIR$src || -L $BACKUP_DIR$src ]]; then return 0; fi
	install -d -m 0700 "$BACKUP_ROOT" "$BACKUP_DIR"
	cp -a --parents "$src" "$BACKUP_DIR/"
}

# write_file DEST MODE OWNER:GROUP < content
# Atomically installs DEST (backing up any previous version for rollback).
# Sets CHANGED=1 when DEST was created or modified, 0 when already identical.
write_file() {
	local dest=$1 mode=$2 owner=$3 tmp
	CHANGED=0
	if (( DRY_RUN )); then
		dest=$DRY_ROOT$dest
		mkdir -p "${dest%/*}"
		cat >"$dest"
		chmod "$mode" "$dest"
		CHANGED=1
		return 0
	fi
	mkdir -p "${dest%/*}"
	tmp=$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX")
	cat >"$tmp"
	chmod "$mode" "$tmp"
	chown "$owner" "$tmp"
	if [[ -f $dest && ! -L $dest ]] && cmp -s "$tmp" "$dest" &&
		[[ $(stat -c '%a %U:%G' "$dest") == "${mode#0} $owner" ]]; then
		rm -f "$tmp"
		return 0
	fi
	if [[ -e $dest || -L $dest ]]; then
		backup_file "$dest"
		REPLACED_FILES+=("$dest")
	else
		CREATED_FILES+=("$dest")
	fi
	mv -f "$tmp" "$dest"
	CHANGED=1
}

# install_rendered DEST MODE OWNER render_function [args...]
install_rendered() {
	local dest=$1 mode=$2 owner=$3 tmp
	shift 3
	tmp=$(mktemp "$WORK_DIR/render.XXXXXX")
	"$@" >"$tmp"
	write_file "$dest" "$mode" "$owner" <"$tmp"
}

remove_file() {
	local f=$1
	if [[ -e $f || -L $f ]]; then
		backup_file "$f"
		REPLACED_FILES+=("$f")
		rm -f "$f"
	fi
}

# ==============================================================================
#  Arguments
# ==============================================================================
need_value() { [[ $# -ge 2 && -n $2 ]] || die "Option $1 needs a value."; }

parse_args() {
	local opt val
	while (( $# )); do
		opt=$1
		if [[ $opt == --*=* ]]; then
			val=${opt#*=}
			opt=${opt%%=*}
			shift
			set -- "$opt" "$val" "$@"
		fi
		case $opt in
			-h | --help) usage; exit 0 ;;
			--verify) ACTION=verify; shift ;;
			--uninstall) ACTION=uninstall; shift ;;
			--purge) PURGE=1; shift ;;
			--dry-run) DRY_RUN=1; shift ;;
			--allow) need_value "$@"; split_into ALLOW_CIDRS "$2"; shift 2 ;;
			--listen) need_value "$@"; split_into LISTEN_ADDRS "$2"; shift 2 ;;
			--port) need_value "$@"; PORT=$2; shift 2 ;;
			--ipv6) need_value "$@"; IPV6_MODE=$2; shift 2 ;;
			--upstream) need_value "$@"; UPSTREAMS+=("$2"); shift 2 ;;
			--response-mode) need_value "$@"; RESPONSE_MODE=$2; shift 2 ;;
			--speed-check) need_value "$@"; SPEED_CHECK=$2; shift 2 ;;
			--max-ips) need_value "$@"; MAX_IPS=$2; shift 2 ;;
			--cache-size) need_value "$@"; CACHE_SIZE=$2; shift 2 ;;
			--ttl-min) need_value "$@"; TTL_MIN=$2; shift 2 ;;
			--ttl-max) need_value "$@"; TTL_MAX=$2; shift 2 ;;
			--ttl-reply-max) need_value "$@"; TTL_REPLY_MAX=$2; shift 2 ;;
			--rate-limit) need_value "$@"; RATE_LIMIT=$2; shift 2 ;;
			--no-firewall) FIREWALL=0; shift ;;
			--no-kernel-tuning) KERNEL_TUNING=0; shift ;;
			--audit) AUDIT=1; shift ;;
			--log-level) need_value "$@"; LOG_LEVEL=$2; shift 2 ;;
			--release) need_value "$@"; SD_RELEASE=$2; shift 2 ;;
			--deb) need_value "$@"; LOCAL_DEB=$2; shift 2 ;;
			--force) FORCE=1; shift ;;
			*) usage >&2; die "Unknown option: $opt" ;;
		esac
	done
	validate_args
}

validate_args() {
	local u
	if ! is_uint "$PORT" || (( PORT < 1 || PORT > 65535 )); then die "--port must be 1-65535"; fi
	[[ $IPV6_MODE =~ ^(auto|on|off)$ ]] || die "--ipv6 must be auto, on or off"
	[[ $RESPONSE_MODE =~ ^(fastest-ip|first-ping|fastest-response)$ ]] ||
		die "--response-mode must be fastest-ip, first-ping or fastest-response"
	[[ $SPEED_CHECK =~ ^(none|(ping|tcp(-syn)?:[0-9]{1,5})(,(ping|tcp(-syn)?:[0-9]{1,5}))*)$ ]] ||
		die "--speed-check must look like ping,tcp-syn:443,tcp:80 (or none)"
	if ! is_uint "$MAX_IPS" || (( MAX_IPS < 1 || MAX_IPS > 16 )); then die "--max-ips must be 1-16"; fi
	[[ $CACHE_SIZE == auto ]] || is_uint "$CACHE_SIZE" || die "--cache-size must be a number or 'auto'"
	if ! { is_uint "$TTL_MIN" && is_uint "$TTL_MAX" && is_uint "$TTL_REPLY_MAX"; }; then
		die "TTL values must be whole seconds"
	fi
	(( TTL_MIN <= TTL_MAX )) || die "--ttl-min must not exceed --ttl-max"
	(( TTL_REPLY_MAX >= 1 )) || die "--ttl-reply-max must be at least 1"
	is_uint "$RATE_LIMIT" || die "--rate-limit must be a number of queries per second"
	[[ $LOG_LEVEL =~ ^(off|fatal|error|warn|notice|info|debug)$ ]] || die "Invalid --log-level '$LOG_LEVEL'"
	for u in "${UPSTREAMS[@]}"; do
		[[ ! $u =~ [[:cntrl:]] ]] || die "Invalid --upstream value"
	done
	[[ $SD_RELEASE =~ ^[0-9] ]] && SD_RELEASE=Release$SD_RELEASE
	if [[ -n $LOCAL_DEB && ! -r $LOCAL_DEB ]]; then die "--deb: cannot read '$LOCAL_DEB'"; fi
	if (( PURGE )) && [[ $ACTION != uninstall ]]; then die "--purge only makes sense with --uninstall"; fi
	return 0
}

# ==============================================================================
#  Detection and derived settings
# ==============================================================================
preflight() {
	if (( EUID != 0 && ! DRY_RUN )); then die "Please run as root (sudo)."; fi
	if ! { have systemctl && [[ -d /run/systemd/system ]]; }; then die "systemd must be the init system."; fi
	if ! { have dpkg && have apt-get; }; then die "This installer needs dpkg/apt (Ubuntu)."; fi

	local os_id os_ver os_name
	os_id=$({ . /etc/os-release && printf '%s' "${ID:-}"; } 2>/dev/null) || true
	os_ver=$({ . /etc/os-release && printf '%s' "${VERSION_ID:-}"; } 2>/dev/null) || true
	os_name=$({ . /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown OS}"; } 2>/dev/null) || true
	if [[ $os_id != ubuntu || $os_ver != 22.04 ]]; then
		if (( FORCE )); then
			warn "Built and tested for Ubuntu 22.04; running on ${os_name:-unknown OS} because of --force"
		else
			die "Built and tested for Ubuntu 22.04, found ${os_name:-unknown OS}. Use --force to try anyway."
		fi
	fi

	case $(dpkg --print-architecture) in
		amd64) SD_ARCH=x86_64 ;;
		arm64) SD_ARCH=aarch64 ;;
		armhf | armel) SD_ARCH=arm ;;
		i386) SD_ARCH=x86 ;;
		*) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
	esac
}

detect_system() {
	MEM_MB=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
	[[ -e /proc/net/if_inet6 ]] && IPV6_SOCKETS=1
	[[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] && CONNTRACK=1
	return 0
}

has_ipv6_egress() {
	(( IPV6_SOCKETS )) || return 1
	[[ -n $(ip -6 route show default 2>/dev/null) ]] || return 1
	[[ -n $(ip -6 -o addr show scope global 2>/dev/null) ]]
}

resolve_settings() {
	local c n a
	local -a allow=(127.0.0.0/8 ::1/128)

	# Clients (ACL + firewall guard)
	if (( ${#ALLOW_CIDRS[@]} )); then allow+=("${ALLOW_CIDRS[@]}"); else allow+=("${DEFAULT_ALLOW[@]}"); fi
	ALLOW_CIDRS=()
	for c in "${allow[@]}"; do
		[[ -n $c ]] || continue
		n=$(normalize_cidr "$c") || die "Invalid network in --allow: '$c'"
		ALLOW_CIDRS+=("$n")
	done
	dedupe ALLOW_CIDRS

	# The ACL also admits this host's own addresses: local programs that query
	# the public IP arrive over loopback with that IP as source.
	ACL_CIDRS=("${ALLOW_CIDRS[@]}")
	while read -r a; do
		[[ -n $a ]] || continue
		if [[ $a == *:* ]]; then ACL_CIDRS+=("$a/128"); else ACL_CIDRS+=("$a/32"); fi
	done < <(ip -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }')
	dedupe ACL_CIDRS

	# Listeners
	for a in "${LISTEN_ADDRS[@]}"; do
		is_ipv4 "$a" || is_ipv6 "$a" || die "Invalid --listen address: '$a'"
	done
	BIND_SPECS=()
	if (( ${#LISTEN_ADDRS[@]} )); then
		local -a addrs=("${LISTEN_ADDRS[@]}" 127.0.0.1)
		(( PORT == 53 )) && addrs+=(127.0.0.53)
		[[ -n $(ip -6 addr show dev lo 2>/dev/null) ]] && addrs+=(::1)
		dedupe addrs
		for a in "${addrs[@]}"; do
			if [[ $a == *:* ]]; then BIND_SPECS+=("[$a]:$PORT"); else BIND_SPECS+=("$a:$PORT"); fi
		done
	elif (( IPV6_SOCKETS )); then
		BIND_SPECS=("[::]:$PORT")   # dual-stack: also accepts IPv4 clients
	else
		BIND_SPECS=("0.0.0.0:$PORT")
	fi

	# AAAA answers
	case $IPV6_MODE in
		on) IPV6_ENABLED=1 ;;
		off) IPV6_ENABLED=0 ;;
		auto) if has_ipv6_egress; then IPV6_ENABLED=1; else IPV6_ENABLED=0; fi ;;
	esac

	# Cache: ~32 entries per MiB of RAM (SmartDNS uses ~0.5 KiB per entry),
	# i.e. roughly RAM/64 at most, within sane bounds.
	if [[ $CACHE_SIZE == auto ]]; then
		CACHE_ENTRIES=$(( MEM_MB * 32 ))
		clamp CACHE_ENTRIES 32768 1048576
	else
		CACHE_ENTRIES=$CACHE_SIZE
	fi

	(( ${#UPSTREAMS[@]} )) || UPSTREAMS=("${DEFAULT_UPSTREAMS[@]}")
	return 0
}

# Would binding our listeners collide with whatever already holds the port?
bind_collides() {
	local host=$1 a
	(( ${#LISTEN_ADDRS[@]} == 0 )) && return 0
	case $host in 0.0.0.0 | :: | '*') return 0 ;; esac
	for a in "${LISTEN_ADDRS[@]}" 127.0.0.1 127.0.0.53 ::1; do
		[[ $a == "$host" ]] && return 0
	done
	return 1
}

check_port_conflicts() {
	local listing proto addr proc host
	local -a conflicts=()
	listing=$(ss -H -lnptu "sport = :$PORT" 2>/dev/null) || true
	while read -r proto _ _ _ addr _ proc; do
		[[ -n ${proto:-} ]] || continue
		[[ $proc == *'"systemd-resolve"'* || $proc == *'"smartdns"'* ]] && continue
		host=${addr%:*}
		host=${host%%\%*}
		host=${host#[}
		host=${host%]}
		if bind_collides "$host"; then conflicts+=("$proto $addr ${proc:-(unknown process)}"); fi
	done <<<"$listing"
	if (( ${#conflicts[@]} )); then
		err "Port $PORT is already in use:"
		printf '      %s\n' "${conflicts[@]}" >&2
		die "Stop that service first, or bind SmartDNS to specific addresses with --listen."
	fi
	ok "Port $PORT is available"
}

check_environment() {
	local avail virt
	virt=$(systemd-detect-virt --container 2>/dev/null) || true
	if [[ -n $virt && $virt != none ]]; then
		warn "Running inside a '$virt' container: some kernel/firewall tuning may be unavailable"
	fi
	avail=$(df -Pm /var 2>/dev/null | awk 'NR == 2 { print $4 }') || true
	if [[ -n $avail ]] && (( avail < 500 )); then
		warn "Only ${avail} MB free on /var; the persistent cache and logs need a few hundred MB"
	fi
	return 0
}

ensure_deps() {
	local -A need=([curl]=curl [jq]=jq [dig]=bind9-dnsutils [ss]=iproute2 [sysctl]=procps [flock]=util-linux)
	local -a missing=()
	local cmd
	(( FIREWALL )) && need[nft]=nftables
	for cmd in "${!need[@]}"; do have "$cmd" || missing+=("${need[$cmd]}"); done
	[[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
	(( ${#missing[@]} )) || { ok "Prerequisites present"; return 0; }

	info "Installing prerequisites: ${missing[*]}"
	apt-get -o DPkg::Lock::Timeout=300 -q update >>"$INSTALL_LOG" 2>&1 || warn "apt-get update reported errors"
	DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -q -y \
		install --no-install-recommends "${missing[@]}" >>"$INSTALL_LOG" 2>&1 ||
		die "Could not install prerequisites: ${missing[*]}"
	ok "Prerequisites installed"
}

# ==============================================================================
#  Package
# ==============================================================================
gh_api() {
	local -a hdr=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
	[[ -n ${GITHUB_TOKEN:-} ]] && hdr+=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --retry 4 --retry-delay 2 --retry-connrefused --connect-timeout 15 --max-time 60 \
		"${hdr[@]}" "https://api.github.com/repos/$GH_REPO/$1"
}

fetch_release() {
	local path json asset name url digest installed
	if [[ $SD_RELEASE == latest ]]; then path=releases/latest; else path=releases/tags/$SD_RELEASE; fi
	json=$(gh_api "$path") ||
		die "Cannot query GitHub ($path). If rate-limited set GITHUB_TOKEN, or install offline with --deb FILE."
	RELEASE_TAG=$(jq -r '.tag_name' <<<"$json")
	asset=$(jq -c --arg re "\\.${SD_ARCH}-debian-all\\.deb\$" \
		'[.assets[] | select(.name | test($re))][0] // empty' <<<"$json")
	[[ -n $asset ]] || die "Release $RELEASE_TAG has no Debian package for $SD_ARCH"
	name=$(jq -r '.name' <<<"$asset")
	url=$(jq -r '.browser_download_url' <<<"$asset")
	digest=$(jq -r '.digest // ""' <<<"$asset")

	# Asset names embed the package version (smartdns.1.<version>.<arch>-...).
	installed=$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' smartdns 2>/dev/null) || true
	if [[ $installed == "ii |"* && $name == *".${installed#*|}.${SD_ARCH}-"* ]]; then
		PKG_FILE=''
		ok "SmartDNS ${installed#*|} ($RELEASE_TAG) is installed and current"
		return 0
	fi

	info "Downloading $name ($RELEASE_TAG)"
	PKG_FILE=$WORK_DIR/$name
	curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused --connect-timeout 15 --max-time 600 \
		-o "$PKG_FILE" "$url" || die "Download failed: $url"
	if [[ $digest == sha256:* ]]; then
		printf '%s  %s\n' "${digest#sha256:}" "$PKG_FILE" | sha256sum -c --quiet - >/dev/null 2>&1 ||
			die "sha256 mismatch for $name — refusing to install"
		ok "sha256 verified"
	else
		warn "GitHub published no checksum for $name; relying on HTTPS only"
	fi
	if [[ $RELEASE_TAG != "$TESTED_RELEASE" ]]; then
		info "(this installer was validated against $TESTED_RELEASE; pin it with --release $TESTED_RELEASE)"
	fi
}

obtain_package() {
	step "Fetching SmartDNS"
	if [[ -n $LOCAL_DEB ]]; then
		PKG_FILE=$(readlink -f "$LOCAL_DEB")
		RELEASE_TAG="local package"
	else
		fetch_release
		[[ -n $PKG_FILE ]] || return 0   # already current
	fi
	[[ $(dpkg-deb -f "$PKG_FILE" Package 2>/dev/null) == smartdns ]] || die "$PKG_FILE is not a SmartDNS package"
	ok "Package ${PKG_FILE##*/} (version $(dpkg-deb -f "$PKG_FILE" Version))"
}

install_package() {
	local new cur
	[[ -n $PKG_FILE ]] || return 0
	new=$(dpkg-deb -f "$PKG_FILE" Version)
	cur=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' smartdns 2>/dev/null) || true
	if [[ $cur == "ii  $new" ]]; then
		ok "SmartDNS $new already installed"
		return 0
	fi
	step "Installing SmartDNS $new"
	# --force-confold keeps our generated smartdns.conf across package upgrades.
	DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -q -y \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
		install "$PKG_FILE" >>"$INSTALL_LOG" 2>&1 || die "Package installation failed"
	NEED_RESTART=1
	ok "Installed $(smartdns_version)"
}

ensure_runtime_user() {
	if ! getent passwd "$SD_USER" >/dev/null; then
		useradd --system --user-group --no-create-home --home-dir "$SD_DATA_DIR" \
			--shell /usr/sbin/nologin --comment "SmartDNS resolver" "$SD_USER"
		ok "Created system user '$SD_USER'"
	fi
	install -d -m 0755 -o root -g root "$SD_CONF_DIR" "$SD_CONF_D"
	# SmartDNS re-owns these as <user>:<user> 0750 at start-up anyway; match it.
	install -d -m 0750 -o "$SD_USER" -g "$SD_USER" "$SD_DATA_DIR" "$SD_LOG_DIR"
	# Files left by an earlier root-run SmartDNS must stay writable after the privilege drop.
	chown -R "$SD_USER:$SD_USER" "$SD_DATA_DIR" "$SD_LOG_DIR"
}

# ==============================================================================
#  Rendered files
# ==============================================================================
render_smartdns_conf() {
	local b c u
	cat <<EOF
# =============================================================================
#  SmartDNS — generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
#
#  DO NOT EDIT: this file is rewritten on every installer run. Put local
#  additions in ${SD_CONF_D}/*.conf (loaded last, so they win), then run
#  systemctl restart smartdns
# =============================================================================

# --- Listeners ----------------------------------------------------------------
EOF
	for b in "${BIND_SPECS[@]}"; do printf 'bind %s\nbind-tcp %s\n' "$b" "$b"; done
	cat <<EOF
# SmartDNS caps itself at 10240 open files. UDP clients need none, but every
# idle TCP client holds one, so close idle TCP connections quickly.
tcp-idle-time 30
# Kernel buffers for listening/upstream sockets: absorb peak-hour query bursts.
socket-buff-size 4M

# --- Access control -----------------------------------------------------------
# Only these networks are answered; everyone else is REFUSED, so this is never
# an open resolver. The nftables guard enforces the same list in the kernel.
acl-enable yes
EOF
	for c in "${ACL_CIDRS[@]}"; do printf 'client-rules %s\n' "$c"; done
	cat <<EOF

# --- Upstream resolvers -------------------------------------------------------
# Each cache miss goes to ALL primaries in parallel. Independent providers map
# CDNs differently, so together they return more candidate addresses, which
# SmartDNS then measures. '-fallback' servers are only used when the primaries
# fail or time out.
EOF
	# Only needed if a custom --upstream uses DNS-over-TLS/HTTPS/QUIC.
	if [[ " ${UPSTREAMS[*]}" == *://* ]]; then
		printf 'ca-file /etc/ssl/certs/ca-certificates.crt\n'
	fi
	for u in "${UPSTREAMS[@]}"; do printf 'server %s\n' "$u"; done
	printf '\n# --- Best-IP selection --------------------------------------------------------\n'
	case $RESPONSE_MODE in
		fastest-ip) cat <<'EOF'
# fastest-ip: measure every candidate before answering and return the lowest-
# latency address first. Repeat queries are served from cache with the winner
# already chosen; it is re-measured on every background refresh.
EOF
		;;
		first-ping) cat <<'EOF'
# first-ping: answer as soon as the first candidate replies to a probe (usually
# the fastest); the full ranking is cached for the queries that follow.
EOF
		;;
		fastest-response) cat <<'EOF'
# fastest-response: answer with the first upstream reply without waiting for
# probes; cached answers are still ranked by measured latency.
EOF
		;;
	esac
	cat <<EOF
response-mode ${RESPONSE_MODE}
# Probes run in this order; the next one is used for hosts that do not answer
# the previous one (e.g. hosts that ignore ping). tcp-syn:<port> times a TCP
# handshake to that port.
speed-check-mode ${SPEED_CHECK}
# The fastest address always comes first. Up to $(( MAX_IPS - 1 )) more follow only if they
# are nearly as fast (within ~10% RTT), giving clients a failover target.
max-reply-ip-num ${MAX_IPS}
EOF
	if (( IPV6_ENABLED )); then
		cat <<'EOF'
# Dual stack: answer with whichever address family is faster from here.
dualstack-ip-selection yes
dualstack-ip-selection-threshold 10
EOF
	else
		cat <<'EOF'
# AAAA answers off (no IPv6 egress here, or --ipv6 off): clients would otherwise
# stall trying IPv6 through the tunnel before falling back to IPv4.
dualstack-ip-selection no
force-AAAA-SOA yes
EOF
	fi
	cat <<EOF

# --- Cache --------------------------------------------------------------------
cache-size ${CACHE_ENTRIES}
cache-persist yes
cache-file ${SD_DATA_DIR}/smartdns.cache
# Hourly snapshot (written by a forked child, no query stalls): restarts and
# reboots come back warm instead of stampeding the upstreams.
cache-checkpoint-time 3600
# Names in use are refreshed (and their addresses re-measured) in the background.
prefetch-domain yes
# Never make a client wait on an expired entry: answer from cache with a short
# TTL while the refresh runs. Entries unused for 3 days are dropped.
serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 3
serve-expired-prefetch-time 21600
# Answers (and their chosen IP) are re-resolved and re-measured when their TTL,
# clamped to ${TTL_MIN}-${TTL_MAX} s, runs out. Clients cache for at most
# ${TTL_REPLY_MAX} s, so they pick up a new winner quickly.
rr-ttl-min ${TTL_MIN}
rr-ttl-max ${TTL_MAX}
rr-ttl-reply-max ${TTL_REPLY_MAX}

# --- Local answers ------------------------------------------------------------
# Liveness probe used by the watchdog; answered locally, never forwarded.
address /${HEALTH_NAME}/127.0.0.1
# Firefox canary: keeps Firefox from switching to its own DoH resolver, so
# browsers use this server (and its best-IP answers).
address /use-application-dns.net/#

# --- Runtime ------------------------------------------------------------------
# Drop root right after start-up, keeping only CAP_NET_BIND_SERVICE, CAP_NET_RAW
# (latency probes), CAP_NET_ADMIN and CAP_DAC_READ_SEARCH.
user ${SD_USER}
log-level ${LOG_LEVEL}
log-file ${SD_LOG_DIR}/smartdns.log
log-size 16M
log-num 4
log-file-mode 640
EOF
	if (( AUDIT )); then
		cat <<EOF
audit-enable yes
audit-file ${SD_LOG_DIR}/smartdns-audit.log
audit-size 64M
audit-num 4
audit-file-mode 640
EOF
	else
		printf '# Per-query audit log disabled (privacy, disk I/O). Enable with --audit.\naudit-enable no\n'
	fi
	cat <<EOF

# --- Local overrides (kept across installer runs) -----------------------------
conf-file ${SD_CONF_D}/*.conf
EOF
}

render_conf_d_readme() {
	cat <<'EOF'
# Local SmartDNS settings. Every *.conf file here is loaded after the generated
# smartdns.conf (so values here win) and survives installer re-runs.
# Apply changes with:  systemctl restart smartdns
#
# Examples:
#   address /intranet.example.com/10.8.0.10              # fixed answer
#   domain-rules /example.org/ -speed-check-mode none     # don't probe a domain
#   server 10.0.0.53 -group corp -exclude-default-group   # private resolver...
#   nameserver /corp.example.com/corp                     # ...used for one zone
EOF
}

render_service_dropin() {
	cat <<EOF
# Managed by ${SCRIPT_NAME}: resource limits and sandboxing for SmartDNS.
# Put local changes in a separate drop-in (e.g. 20-local.conf) in this directory.
[Unit]
StartLimitIntervalSec=0
EOF
	if (( FIREWALL && GUARD_OK )); then
		printf 'Wants=smartdns-guard.service\nAfter=smartdns-guard.service\n'
	fi
	cat <<EOF

[Service]
# (No LimitNOFILE: SmartDNS sets its own fixed limit of 10240 at start-up.)
# Every connection starts with a DNS lookup: keep SmartDNS scheduled and alive
# under CPU or memory pressure.
Nice=-5
OOMScoreAdjust=-500
Restart=always
RestartSec=2
TimeoutStopSec=30
UMask=0027

# Sandbox. SmartDNS itself switches to user '${SD_USER}' right after start-up.
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN CAP_SETUID CAP_SETGID CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
EOF
	# The 32-bit ARM build's launcher writes /proc/sys/abi/cp15_barrier.
	[[ $SD_ARCH == arm ]] || echo "ProtectKernelTunables=yes"
}

render_guard_nft() {
	local c a burst=$(( RATE_LIMIT * 2 )) to4='' to6='' guard4=1 guard6=1
	local -a v4=() v6=() dst4=() dst6=()
	for c in "${ALLOW_CIDRS[@]}"; do
		if [[ $c == *:* ]]; then v6+=("$c"); else v4+=("$c"); fi
	done
	# With --listen, guard only SmartDNS's own non-loopback addresses so other
	# services may still use port ${PORT} on other IPs; wildcard mode guards all.
	if (( ${#LISTEN_ADDRS[@]} )); then
		for a in "${LISTEN_ADDRS[@]}"; do
			case $a in 127.* | ::1) ;; *:*) dst6+=("$a") ;; *) dst4+=("$a") ;; esac
		done
		(( ${#dst4[@]} )) && to4="ip daddr { $(join_by ', ' "${dst4[@]}") } " || guard4=0
		(( ${#dst6[@]} )) && to6="ip6 daddr { $(join_by ', ' "${dst6[@]}") } " || guard6=0
	fi
	cat <<EOF
#!/usr/sbin/nft -f
# SmartDNS access guard — generated by ${SCRIPT_NAME}; re-run the installer to change it.
# Drops DNS (port ${PORT}) from anything outside the allowed client networks, so
# this server can never be abused as an open resolver / DDoS amplifier. It only
# ever drops port-${PORT} traffic and leaves every other firewall rule untouched.

table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}

table inet ${NFT_TABLE} {
	set allow_v4 {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $(join_by ', ' "${v4[@]}") }
	}

	set allow_v6 {
		type ipv6_addr
		flags interval
		auto-merge
		elements = { $(join_by ', ' "${v6[@]}") }
	}
EOF
	if (( RATE_LIMIT > 0 )); then
		cat <<EOF

	set flood_v4 {
		type ipv4_addr
		flags dynamic,timeout
		timeout 1m
		size 262144
	}

	set flood_v6 {
		type ipv6_addr
		flags dynamic,timeout
		timeout 1m
		size 262144
	}
EOF
	fi
	cat <<EOF

	chain input {
		type filter hook input priority filter - 5; policy accept;
		iif "lo" accept
EOF
	if (( guard4 )); then
		printf '\t\tmeta l4proto { tcp, udp } th dport %s %sip saddr != @allow_v4 counter drop\n' "$PORT" "$to4"
	fi
	if (( guard6 )); then
		printf '\t\tmeta l4proto { tcp, udp } th dport %s %sip6 saddr != @allow_v6 counter drop\n' "$PORT" "$to6"
	fi
	if (( RATE_LIMIT > 0 )); then
		printf '\t\t# Per-client flood protection (%s queries/s, bursts of %s).\n' "$RATE_LIMIT" "$burst"
		if (( guard4 )); then
			printf '\t\tudp dport %s %supdate @flood_v4 { ip saddr limit rate over %s/second burst %s packets } counter drop\n' \
				"$PORT" "$to4" "$RATE_LIMIT" "$burst"
		fi
		if (( guard6 )); then
			printf '\t\tudp dport %s %supdate @flood_v6 { ip6 saddr limit rate over %s/second burst %s packets } counter drop\n' \
				"$PORT" "$to6" "$RATE_LIMIT" "$burst"
		fi
	fi
	printf '\t}\n'
	if (( CONNTRACK )); then
		cat <<EOF

	# Loopback DNS (local Xray/sing-box/proxy cores, the host itself) bypasses
	# connection tracking: thousands of one-packet UDP exchanges per second
	# would otherwise churn and can exhaust the conntrack table.
	chain raw_output {
		type filter hook output priority raw; policy accept;
		oif "lo" udp dport ${PORT} notrack
		oif "lo" udp sport ${PORT} notrack
	}
EOF
	fi
	printf '}\n'
}

render_guard_unit() {
	local nft
	nft=$(command -v nft || echo /usr/sbin/nft)
	cat <<EOF
# Managed by ${SCRIPT_NAME}.
[Unit]
Description=SmartDNS access guard (nftables: DNS only from allowed client networks)
Documentation=file://${SD_GUARD_NFT}
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nft} -f ${SD_GUARD_NFT}
ExecReload=${nft} -f ${SD_GUARD_NFT}
ExecStop=-${nft} delete table inet ${NFT_TABLE}

[Install]
WantedBy=sysinit.target
EOF
}

render_healthcheck() {
	cat <<EOF
#!/usr/bin/env bash
# SmartDNS liveness probe — installed by ${SCRIPT_NAME}, run by smartdns-healthcheck.timer.
# Asks SmartDNS for a name it answers locally (no upstream involved). If it stays
# silent three times while systemd still reports it running — hung rather than
# crashed; crashes are handled by Restart=always — restart it.
set -u
systemctl -q is-active smartdns.service || exit 0
for _ in 1 2 3; do
	if dig +short +time=2 +tries=1 -p ${PORT} @127.0.0.1 ${HEALTH_NAME} A 2>/dev/null | grep -qx '127\\.0\\.0\\.1'; then
		exit 0
	fi
	sleep 2
done
logger -t smartdns-healthcheck -p daemon.err "SmartDNS did not answer on 127.0.0.1:${PORT} (3 attempts); restarting it"
exec systemctl restart smartdns.service
EOF
}

render_hc_service() {
	cat <<EOF
# Managed by ${SCRIPT_NAME}.
[Unit]
Description=SmartDNS liveness probe
After=smartdns.service

[Service]
Type=oneshot
ExecStart=${HC_BIN}
EOF
}

render_hc_timer() {
	cat <<EOF
# Managed by ${SCRIPT_NAME}.
[Unit]
Description=Run the SmartDNS liveness probe every 30 seconds

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
}

render_resolved_dropin() {
	cat <<EOF
# Managed by ${SCRIPT_NAME}: SmartDNS owns port 53 on this host.
# The stub listener is off; 127.0.0.53 (still named in /etc/resolv.conf and in
# the resolv.conf of host-network containers) is answered by SmartDNS itself.
[Resolve]
# The empty assignment clears DNS= lists merged from other resolved.conf files.
DNS=
DNS=127.0.0.1
Domains=~.
DNSStubListener=no
EOF
}

render_static_resolv_conf() {
	cat <<EOF
# Managed by ${SCRIPT_NAME}: resolve through the local SmartDNS.
nameserver 127.0.0.1
options edns0 trust-ad
EOF
}

write_all_configs() {
	install_rendered "$SD_CONF" 0644 root:root render_smartdns_conf
	(( CHANGED )) && NEED_RESTART=1
	if [[ ! -e $SD_CONF_D/00-local.conf ]]; then
		install_rendered "$SD_CONF_D/00-local.conf" 0644 root:root render_conf_d_readme
	fi
	if (( FIREWALL )); then write_guard; fi
	install_rendered "$SD_DROPIN" 0644 root:root render_service_dropin
	(( CHANGED )) && NEED_RESTART=1
	install_rendered "$HC_BIN" 0755 root:root render_healthcheck
	install_rendered "$HC_SERVICE" 0644 root:root render_hc_service
	install_rendered "$HC_TIMER" 0644 root:root render_hc_timer
	ok "Configuration written ($SD_CONF)"
}

# The guard is validated by nft before it is installed; if the kernel refuses
# it (e.g. restricted container), continue without it — the ACL still applies.
write_guard() {
	local tmp
	tmp=$(mktemp "$WORK_DIR/guard.XXXXXX")
	render_guard_nft >"$tmp"
	if have nft && (( EUID == 0 )) && ! nft -c -f "$tmp" >"$tmp.err" 2>&1; then
		warn "nftables rejected the guard ruleset; continuing without it (SmartDNS ACL still applies):"
		sed 's/^/      /' "$tmp.err" >&2
		GUARD_OK=0
		return 0
	fi
	GUARD_OK=1
	write_file "$SD_GUARD_NFT" 0644 root:root <"$tmp"
	install_rendered "$GUARD_UNIT" 0644 root:root render_guard_unit
}

# ==============================================================================
#  System integration
# ==============================================================================
# Raise-only: a limit that is already higher (e.g. tuned for the VPN) is kept.
apply_kernel_tuning() {
	(( KERNEL_TUNING )) || { info "Kernel tuning skipped (--no-kernel-tuning)"; return 0; }
	step "Kernel tuning (raise-only)"
	local -a want=(
		"net.core.rmem_max=16777216"         # lets socket-buff-size 4M take full effect
		"net.core.wmem_max=16777216"
		"net.core.netdev_max_backlog=16384"  # NIC -> stack queue at high packet rates
	)
	local ct=0 hs=0 kv key target path cur ro=0 raised=0 ct_raised=0
	local -a persist=()
	local -A persisted=()

	if (( CONNTRACK )); then
		ct=$(( MEM_MB * 64 ))
		clamp ct 262144 4194304
		want+=("net.netfilter.nf_conntrack_max=$ct")
	fi
	if (( ${#LISTEN_ADDRS[@]} )); then
		# Lets SmartDNS bind VPN addresses before the tunnel interface exists at boot.
		want+=("net.ipv4.ip_nonlocal_bind=1")
		(( IPV6_SOCKETS )) && want+=("net.ipv6.ip_nonlocal_bind=1")
	fi

	if [[ -f $SYSCTL_FILE ]]; then
		while IFS='= ' read -r key target; do
			[[ -n $key && $key != \#* ]] && persisted[$key]=$target
		done <"$SYSCTL_FILE"
	fi

	for kv in "${want[@]}"; do
		key=${kv%%=*}
		target=${kv#*=}
		path=/proc/sys/${key//.//}
		[[ -e $path ]] || continue
		cur=$(<"$path")
		if (( cur < target )); then
			if sysctl -q -w "$key=$target" >/dev/null 2>&1; then
				ok "$key: $cur -> $target"
				persist+=("$key = $target")
				raised=1
				[[ $key == net.netfilter.* ]] && ct_raised=1
			else
				ro=1
			fi
		elif [[ -n ${persisted[$key]:-} ]]; then
			persist+=("$key = $cur")   # raised by an earlier run: keep it persistent
		fi
	done

	if (( ${#persist[@]} )); then
		install_rendered "$SYSCTL_FILE" 0644 root:root \
			printf '%s\n' "# Managed by ${SCRIPT_NAME}: only values it had to raise." "${persist[@]}"
	elif [[ -f $SYSCTL_FILE ]]; then
		remove_file "$SYSCTL_FILE"
	fi

	# conntrack hash buckets (hashsize): sized at 1/4 of nf_conntrack_max.
	if (( CONNTRACK )) && [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
		hs=$(( ct / 4 ))
		cur=$(</sys/module/nf_conntrack/parameters/hashsize)
		if (( cur < hs )) && { echo "$hs" >/sys/module/nf_conntrack/parameters/hashsize; } 2>/dev/null; then
			ok "nf_conntrack hash buckets: $cur -> $hs"
			raised=1
			ct_raised=1
		else
			hs=$cur
		fi
		if (( ct_raised )) || [[ -f $MODPROBE_FILE ]]; then
			# Load conntrack early at boot so the sysctl above can be applied to it.
			install_rendered "$MODPROBE_FILE" 0644 root:root printf 'options nf_conntrack hashsize=%s\n' "$hs"
			install_rendered "$MODULES_FILE" 0644 root:root printf 'nf_conntrack\n'
		fi
	fi

	(( ro )) && warn "Some kernel parameters are read-only here (container/VPS?); they were left unchanged"
	(( raised || ro )) || ok "Kernel limits already sufficient; nothing changed"
	return 0
}

apply_firewall_extras() {
	(( FIREWALL )) || return 0
	local c out rules
	if ufw_active; then
		for c in "${ALLOW_CIDRS[@]}"; do
			[[ $c == 127.* || $c == ::1/128 ]] && continue
			if out=$(ufw allow from "$c" to any port "$PORT" comment 'SmartDNS clients' 2>&1); then
				[[ $out == *Skipping* ]] || UFW_ADDED+=("$c")
			else
				warn "ufw: ${out//$'\n'/ }"
			fi
		done
		(( ${#UFW_ADDED[@]} )) && ok "ufw: allowed DNS from ${UFW_ADDED[*]}"
	elif have iptables; then
		rules=$(iptables -S INPUT 2>/dev/null) || true
		if [[ $rules == *"-P INPUT DROP"* ]]; then
			warn "iptables INPUT policy is DROP: ensure VPN clients can reach port $PORT," \
				"e.g. iptables -I INPUT -i wg0 -p udp --dport $PORT -j ACCEPT"
		fi
	fi
	return 0
}

wait_resolved_released() {
	local listing
	for _ in {1..20}; do
		listing=$(ss -H -lnptu "sport = :$PORT" 2>/dev/null) || true
		[[ $listing == *'"systemd-resolve"'* ]] || return 0
		sleep 0.5
	done
	die "systemd-resolved still holds port $PORT"
}

# Port 53 means SmartDNS is also this host's resolver. With systemd-resolved,
# only its stub listener is switched off: /etc/resolv.conf keeps pointing at
# 127.0.0.53, which SmartDNS answers — so already-running programs and
# host-network containers switch over without a restart.
integrate_host_resolver() {
	if (( PORT != 53 )); then
		info "Port $PORT: this host's own resolver is left unchanged"
		return 0
	fi
	step "Making this host resolve through SmartDNS"
	local target
	if systemctl is-active --quiet systemd-resolved.service; then
		install_rendered "$RESOLVED_DROPIN" 0644 root:root render_resolved_dropin
		if (( CHANGED )); then
			RESOLVED_TOUCHED=1
			systemctl restart systemd-resolved.service
			ok "systemd-resolved: stub listener off, forwarding to SmartDNS"
		fi
		wait_resolved_released
		target=$(readlink /etc/resolv.conf 2>/dev/null) || true
		case $target in
			*/run/systemd/resolve/stub-resolv.conf | */run/systemd/resolve/resolv.conf)
				ok "/etc/resolv.conf unchanged; 127.0.0.53 is now answered by SmartDNS"
				return 0
				;;
		esac
	fi
	install_rendered /etc/resolv.conf 0644 root:root render_static_resolv_conf
	if (( CHANGED )); then
		if [[ -z $STATE_ORIG_RESOLV_BACKUP && -n $BACKUP_DIR &&
			( -e $BACKUP_DIR/etc/resolv.conf || -L $BACKUP_DIR/etc/resolv.conf ) ]]; then
			STATE_ORIG_RESOLV_BACKUP=$BACKUP_DIR/etc/resolv.conf
		fi
		ok "/etc/resolv.conf -> nameserver 127.0.0.1 (original saved for --uninstall)"
		if [[ -e /etc/NetworkManager/NetworkManager.conf || -x /sbin/resolvconf ]]; then
			warn "NetworkManager/resolvconf may rewrite /etc/resolv.conf; configure it to use 127.0.0.1"
		fi
	fi
	return 0
}

enable_unit() {
	local unit=$1
	systemctl is-enabled --quiet "$unit" 2>/dev/null && return 0
	systemctl enable "$unit" >>"$INSTALL_LOG" 2>&1 || die "Cannot enable $unit"
	ENABLED_UNITS+=("$unit")
}

show_diagnostics() {
	err "Last journal lines of smartdns.service:"
	journalctl -u smartdns.service -n 20 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
	if [[ -s $SD_LOG_DIR/smartdns.log ]]; then
		err "Last lines of $SD_LOG_DIR/smartdns.log:"
		tail -n 20 "$SD_LOG_DIR/smartdns.log" | sed 's/^/      /' >&2 || true
	fi
}

start_services() {
	step "Starting services"
	systemctl daemon-reload
	if (( FIREWALL && GUARD_OK )); then
		enable_unit smartdns-guard.service
		if systemctl restart smartdns-guard.service; then
			ok "nftables guard active (table inet $NFT_TABLE)"
		else
			warn "nftables guard failed to load (journalctl -u smartdns-guard); SmartDNS ACL still applies"
		fi
	fi
	enable_unit smartdns.service
	if (( NEED_RESTART )) || ! systemctl is-active --quiet smartdns.service; then
		if ! systemctl restart smartdns.service; then
			show_diagnostics
			die "smartdns.service failed to start"
		fi
	fi
	ok "smartdns.service running"
}

verify_smartdns() {
	local deadline ans
	systemctl is-active --quiet smartdns.service || { err "smartdns.service is not running"; return 1; }

	deadline=$(( SECONDS + 20 ))
	until [[ $(dns_q 127.0.0.1 "$HEALTH_NAME" A) == 127.0.0.1 ]]; do
		(( SECONDS < deadline )) || { err "SmartDNS does not answer on 127.0.0.1:$PORT"; return 1; }
		sleep 1
	done
	ok "Answering on 127.0.0.1:$PORT"

	# A never-seen random name cannot come from the (persistent) cache: any
	# authoritative reply (NOERROR/NXDOMAIN, not SERVFAIL) proves the upstreams answer.
	deadline=$(( SECONDS + 60 ))
	until [[ $(dig +time=4 +tries=1 -p "$PORT" @127.0.0.1 "selftest-$RANDOM$RANDOM.example.com" A 2>/dev/null) =~ status:\ (NOERROR|NXDOMAIN) ]]; do
		if (( SECONDS >= deadline )); then
			err "Upstream resolvers do not answer (outbound DNS blocked? see $SD_LOG_DIR/smartdns.log)"
			return 1
		fi
		sleep 2
	done
	ok "Upstream resolvers reachable"

	ans=$(dns_q 127.0.0.1 www.google.com A | first_ip) || { err "Could not resolve www.google.com"; return 1; }
	ok "Resolving (www.google.com -> $ans)"

	ans=$(dns_q 127.0.0.1 www.cloudflare.com A +tcp | first_ip) || { err "DNS over TCP failed"; return 1; }
	ok "TCP queries OK (www.cloudflare.com -> $ans)"

	if (( PORT == 53 )); then
		[[ $(dns_q 127.0.0.53 "$HEALTH_NAME" A) == 127.0.0.1 ]] ||
			{ err "127.0.0.53 is not answered by SmartDNS"; return 1; }
		getent ahosts one.one.one.one >/dev/null ||
			{ err "The host resolver (/etc/resolv.conf) cannot resolve names"; return 1; }
		ok "Host resolver (/etc/resolv.conf) goes through SmartDNS"
	fi
}

enable_watchdog() {
	systemctl daemon-reload
	enable_unit smartdns-healthcheck.timer
	systemctl restart smartdns-healthcheck.timer
	ok "Watchdog: smartdns-healthcheck.timer (every 30 s)"
}

# ==============================================================================
#  Reporting
# ==============================================================================
kv() { printf '  %-12s %s\n' "$1" "$2"; }

summary() {
	local -a names=()
	local u fallback=0 hints guard="off"
	for u in "${UPSTREAMS[@]}"; do
		if [[ $u == *-fallback* ]]; then (( fallback += 1 )); else names+=("${u%% *}"); fi
	done
	(( FIREWALL && GUARD_OK )) && guard="nftables table inet $NFT_TABLE"
	(( ${#UFW_ADDED[@]} )) && guard+=" + ufw rules"

	printf '\n%s✔ SmartDNS is live%s  (%s)\n\n' "$C_G" "$C_0" "$(smartdns_version)"
	kv Listening "$(join_by ', ' "${BIND_SPECS[@]}") (udp+tcp)"
	(( PORT == 53 )) && kv "" "also answers 127.0.0.53 for this host and host-network containers"
	kv Clients "$(join_by ', ' "${ALLOW_CIDRS[@]}")"
	kv Upstreams "$(join_by ', ' "${names[@]}")$( (( fallback )) && printf ' (+%d fallback)' "$fallback")"
	kv "Best IP" "$RESPONSE_MODE, probes $SPEED_CHECK, up to $MAX_IPS per answer (fastest first)"
	kv Cache "$CACHE_ENTRIES entries, persistent, re-measured every ${TTL_MIN}-${TTL_MAX} s"
	if (( IPV6_ENABLED )); then kv IPv6 "AAAA on, fastest family per site"; else kv IPv6 "AAAA off (no IPv6 egress)"; fi
	kv Guard "$guard"
	kv Watchdog "smartdns-healthcheck.timer (every 30 s)"
	kv Config "$SD_CONF (overrides: $SD_CONF_D/)"
	kv Logs "$SD_LOG_DIR/smartdns.log"
	[[ -n $BACKUP_DIR ]] && kv Backups "$BACKUP_DIR"

	hints=$(ip -o -4 addr show 2>/dev/null |
		awk '$2 ~ /^(wg|tun|tap|ppp|ipsec|vti|xfrm|tailscale|zt)/ { sub(/\/.*/, "", $4); printf "    %-12s DNS = %s\n", $2, $4 }') || true
	if [[ -n $hints ]]; then
		printf '\n  Point VPN clients at the tunnel address of this server:\n%s\n' "$hints"
	fi
	printf '\n  Health check any time:  sudo bash %s --verify\n' "$SCRIPT_NAME"
}

# ==============================================================================
#  Actions
# ==============================================================================
do_dry_run() {
	DRY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/smartdns-dry-run.XXXXXX")
	GUARD_OK=1
	write_all_configs >/dev/null
	if (( PORT == 53 )) && systemctl is-active --quiet systemd-resolved.service; then
		install_rendered "$RESOLVED_DROPIN" 0644 root:root render_resolved_dropin
	fi
	step "Dry run: nothing on this system was changed"
	kv Memory "$MEM_MB MiB -> cache $CACHE_ENTRIES entries"
	kv IPv6 "sockets=$IPV6_SOCKETS, AAAA answers=$IPV6_ENABLED"
	kv Conntrack "$( (( CONNTRACK )) && echo "active (loopback DNS notrack + table sizing)" || echo "not loaded")"
	kv Files "rendered under $DRY_ROOT:"
	(cd "$DRY_ROOT" && find . -type f | sed 's|^\.|      |' | sort)
	printf '\n%s--- %s ---%s\n' "$C_B" "$SD_CONF" "$C_0"
	cat "$DRY_ROOT$SD_CONF"
}

do_install() {
	preflight
	detect_system
	resolve_settings
	if (( DRY_RUN )); then do_dry_run; return 0; fi

	acquire_lock
	load_state
	log_file STEP "=== ${SCRIPT_NAME} v${SCRIPT_VERSION}: install"
	step "Pre-flight checks"
	check_port_conflicts
	check_environment
	ensure_deps
	obtain_package

	systemctl is-active --quiet smartdns.service && SMARTDNS_WAS_ACTIVE=1
	TXN_ACTIVE=1
	ensure_runtime_user
	step "Writing configuration"
	write_all_configs
	apply_kernel_tuning
	apply_firewall_extras
	# As late as possible: upgrading the package stops the running daemon.
	install_package
	integrate_host_resolver
	start_services

	step "Verifying"
	if ! verify_smartdns; then
		show_diagnostics
		die "SmartDNS failed its health checks"
	fi
	enable_watchdog
	TXN_ACTIVE=0
	save_state
	summary
}

do_verify() {
	(( EUID == 0 )) || die "Please run as root (sudo)."
	load_state
	PORT=${STATE_PORT:-$PORT}
	step "Checking SmartDNS ($(smartdns_version)${STATE_RELEASE:+, installed from $STATE_RELEASE})"
	local rc=0 recent
	verify_smartdns || rc=1
	if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then ok "nftables guard loaded"; else warn "nftables guard not loaded"; fi
	if systemctl is-active --quiet smartdns-healthcheck.timer; then ok "Watchdog timer active"; else warn "Watchdog timer inactive"; fi
	recent=$(grep -E '\[ *(WARN|ERROR|FATAL) *\]' "$SD_LOG_DIR/smartdns.log" 2>/dev/null | tail -n 5) || true
	if [[ -n $recent ]]; then
		info "Recent warnings in $SD_LOG_DIR/smartdns.log:"
		printf '%s\n' "$recent" | sed 's/^/      /'
	fi
	(( rc == 0 )) || die "Health check failed"
	ok "SmartDNS is healthy"
}

do_uninstall() {
	(( EUID == 0 )) || die "Please run as root (sudo)."
	acquire_lock
	load_state
	local port=${STATE_PORT:-53} c
	log_file STEP "=== ${SCRIPT_NAME} v${SCRIPT_VERSION}: uninstall (purge=$PURGE)"
	step "Removing SmartDNS"

	systemctl disable --now smartdns-healthcheck.timer >/dev/null 2>&1 || true
	systemctl disable --now smartdns.service >/dev/null 2>&1 || true
	systemctl disable --now smartdns-guard.service >/dev/null 2>&1 || true
	nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
	rm -f "$HC_TIMER" "$HC_SERVICE" "$HC_BIN" "$GUARD_UNIT" "$SD_DROPIN" "$SD_GUARD_NFT" \
		"$SYSCTL_FILE" "$MODPROBE_FILE" "$MODULES_FILE"
	rmdir "${SD_DROPIN%/*}" 2>/dev/null || true
	ok "Services, units, firewall guard and tuning files removed"

	if [[ -f $RESOLVED_DROPIN ]]; then
		rm -f "$RESOLVED_DROPIN"
		if systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null; then
			systemctl restart systemd-resolved.service
		fi
		ok "systemd-resolved stub listener restored"
	fi
	if [[ -n $STATE_ORIG_RESOLV_BACKUP ]] && [[ -e $STATE_ORIG_RESOLV_BACKUP || -L $STATE_ORIG_RESOLV_BACKUP ]]; then
		rm -f /etc/resolv.conf
		cp -a "$STATE_ORIG_RESOLV_BACKUP" /etc/resolv.conf
		ok "/etc/resolv.conf restored"
	fi
	systemctl daemon-reload

	if [[ -n $STATE_UFW_RULES ]] && have ufw; then
		for c in $STATE_UFW_RULES; do ufw delete allow from "$c" to any port "$port" >/dev/null 2>&1 || true; done
		ok "ufw rules removed"
	fi

	if dpkg-query -W smartdns >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -q -y \
			"$( (( PURGE )) && echo purge || echo remove)" smartdns >>"$INSTALL_LOG" 2>&1 ||
			warn "apt-get could not remove the smartdns package"
		ok "Package removed"
	fi
	if (( PURGE )); then
		rm -rf "$SD_CONF_DIR" "$SD_DATA_DIR" "$SD_LOG_DIR" "$STATE_DIR"
		getent passwd "$SD_USER" >/dev/null && userdel "$SD_USER" >/dev/null 2>&1
		ok "Configuration, cache, logs and user '$SD_USER' deleted"
	fi

	if getent ahosts one.one.one.one >/dev/null 2>&1; then
		ok "This host resolves names without SmartDNS"
	else
		warn "This host cannot resolve names right now — check /etc/resolv.conf"
	fi
	info "Raised kernel limits stay active until the next reboot."
}

main() {
	parse_args "$@"
	WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/smartdns-installer.XXXXXX")
	chmod 0755 "$WORK_DIR"   # apt's _apt sandbox user must be able to read the .deb
	case $ACTION in
		install) do_install ;;
		verify) do_verify ;;
		uninstall) do_uninstall ;;
	esac
}

main "$@"
