#!/bin/sh

ASSET_DIR="${ASSET_DIR:-/tmp/passwall2-geodata}"
WORK_DIR="${WORK_DIR:-/tmp/passwall2-geodata-update.$$}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/passwall2-geodata-previous}"
GEOVIEW="${GEOVIEW:-/usr/bin/geoview}"
PASSWALL_INIT="${PASSWALL_INIT:-/etc/init.d/passwall2}"
INITIAL_DELAY="${INITIAL_DELAY:-300}"
WEEKLY_DELAY="${WEEKLY_DELAY:-604800}"
DAILY_DELAY="${DAILY_DELAY:-86400}"
RESTART_DISABLED="${RESTART_DISABLED:-/tmp/passwall2-geodata-auto-restart-disabled}"

log() {
	logger -t passwall2-geodata -- "$*"
}

cleanup() {
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

sha256_file() {
	sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

validate_geo() {
	type="$1"
	file="$2"
	[ -s "$file" ] || return 1
	[ -x "$GEOVIEW" ] || return 1
	"$GEOVIEW" -type "$type" -action extract -input "$file" -list cn \
		-output "$WORK_DIR/validate-$type" -strict=true >/dev/null 2>&1
}

download_one() {
	type="$1"
	name="$type.dat"
	configured_url="$(uci -q get passwall2.@global_rules[0].${type}_url)"

	while IFS= read -r url; do
		[ -n "$url" ] || continue
		candidate="$WORK_DIR/$name"
		checksum="$WORK_DIR/$name.sha256sum"
		rm -f "$candidate" "$checksum"

		if ! curl -fLsS --retry 2 --connect-timeout 8 --max-time 300 \
			--speed-limit 32768 --speed-time 30 -o "$candidate" "$url"; then
			continue
		fi

		if curl -fLsS --retry 1 --connect-timeout 8 --max-time 30 \
			-o "$checksum" "$url.sha256sum"; then
			expected="$(awk 'NR == 1 && length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ { print tolower($1) }' "$checksum")"
			actual="$(sha256_file "$candidate")"
			[ -n "$expected" ] && [ "$expected" = "$actual" ] || continue
		fi

		if validate_geo "$type" "$candidate"; then
			printf '%s\n' "$url" > "$WORK_DIR/$name.source"
			return 0
		fi
	done <<EOF_URLS
$configured_url
https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/$name
https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/$name
https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/$name
EOF_URLS
	return 1
}

passwall_busy() {
	for lock in \
		/var/lock/passwall2.lock \
		/var/lock/passwall2_subscribe.lock \
		/var/lock/passwall2_rule_update.lock \
		/tmp/lock/passwall2_subscribe.lock \
		/tmp/lock/passwall2_rule_update.lock \
		/tmp/lock/passwall2_cron.lock \
		/tmp/lock/passwall2_ifup.lock \
		/tmp/lock/passwall2_socks_auto_switch_*.lock; do
		[ -e "$lock" ] && return 0
	done
	return 1
}

proxy_healthy() {
	port="$(uci -q get passwall2.@global[0].node_socks_port)"
	port="${port:-1070}"
	for url in \
		https://cp.cloudflare.com/generate_204 \
		https://www.gstatic.com/generate_204; do
		curl -fLsS --proxy "socks5h://127.0.0.1:$port" \
			--connect-timeout 5 --max-time 15 -o /dev/null "$url" && return 0
	done
	return 1
}

wait_for_proxy() {
	count=0
	while [ "$count" -lt 9 ]; do
		proxy_healthy && return 0
		count=$((count + 1))
		sleep 10
	done
	return 1
}

restart_passwall() {
	timeout 120 "$PASSWALL_INIT" restart >/dev/null 2>&1
}

update_once() {
	if [ -e "$RESTART_DISABLED" ]; then
		log "Geo auto-update is paused for this boot after a rollback; keeping the restored data."
		return 0
	fi

	available_kb="$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 { print $4 }')"
	if [ -n "$available_kb" ] && [ "$available_kb" -lt 98304 ]; then
		log "Less than 96 MiB is available in /tmp; keeping the bundled geodata."
		return 1
	fi

	passwall_busy && {
		log "PassWall2 is updating configuration or subscriptions; deferring the Geo update."
		return 1
	}

	mkdir -p "$WORK_DIR" || return 1
	log "Checking GeoIP and Geosite updates with mirror fallback."
	download_one geoip || {
		log "GeoIP download failed; keeping the bundled working data."
		return 1
	}
	download_one geosite || {
		log "Geosite download failed; keeping the bundled working data."
		return 1
	}

	old_geoip="$(sha256_file "$ASSET_DIR/geoip.dat")"
	old_geosite="$(sha256_file "$ASSET_DIR/geosite.dat")"
	new_geoip="$(sha256_file "$WORK_DIR/geoip.dat")"
	new_geosite="$(sha256_file "$WORK_DIR/geosite.dat")"
	if [ "$old_geoip" = "$new_geoip" ] && [ "$old_geosite" = "$new_geosite" ]; then
		log "Geo data is already current; no PassWall2 restart is needed."
		return 0
	fi

	passwall_busy && {
		log "PassWall2 became busy; discarding this update without restarting."
		return 1
	}

	rm -rf "$BACKUP_DIR"
	mkdir -p "$BACKUP_DIR" || return 1
	cp "$ASSET_DIR/geoip.dat" "$BACKUP_DIR/geoip.dat" || return 1
	cp "$ASSET_DIR/geosite.dat" "$BACKUP_DIR/geosite.dat" || return 1
	if ! mv -f "$WORK_DIR/geoip.dat" "$ASSET_DIR/geoip.dat" || \
		! mv -f "$WORK_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"; then
		log "Unable to install the complete Geo data pair; restoring the previous files without restarting."
		cp "$BACKUP_DIR/geoip.dat" "$ASSET_DIR/geoip.dat"
		cp "$BACKUP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"
		rm -rf "$BACKUP_DIR"
		return 1
	fi

	if ! proxy_healthy; then
		log "The current proxy line is not healthy; installed validated Geo data but deferred restart."
		rm -rf "$BACKUP_DIR"
		return 0
	fi
	passwall_busy && {
		log "PassWall2 became busy before restart; leaving validated Geo data for the next service start."
		rm -rf "$BACKUP_DIR"
		return 0
	}

	log "Validated Geo data changed; restarting PassWall2 once."
	if restart_passwall && wait_for_proxy; then
		log "PassWall2 passed the post-update connectivity check."
		rm -rf "$BACKUP_DIR"
		return 0
	fi

	log "Connectivity failed after the Geo update; rolling back and restarting once."
	touch "$RESTART_DISABLED"
	if ! cp "$BACKUP_DIR/geoip.dat" "$ASSET_DIR/geoip.dat" || \
		! cp "$BACKUP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"; then
		log "Unable to restore the previous Geo data; automatic restarts are disabled for this boot."
		return 1
	fi
	if restart_passwall && wait_for_proxy; then
		log "Rollback restored the previous working state; further automatic restarts are disabled for this boot."
	else
		log "Rollback restart did not restore connectivity; stopping without another restart."
	fi
	rm -rf "$BACKUP_DIR"
	return 1
}

if [ "${RUN_ONCE:-0}" = "1" ]; then
	update_once
	exit $?
fi

sleep "$INITIAL_DELAY"
failures=0
while :; do
	if update_once; then
		failures=0
		sleep "$WEEKLY_DELAY"
		continue
	fi

	failures=$((failures + 1))
	case "$failures" in
		1) delay=1800 ;;
		2) delay=7200 ;;
		*) delay="$DAILY_DELAY" ;;
	esac
	log "Geo update attempt failed; next attempt is in ${delay}s. No restart was requested."
	sleep "$delay"
done
