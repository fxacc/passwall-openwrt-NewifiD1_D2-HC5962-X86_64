#!/bin/bash
#=================================================
# Description: Newifi D2 minimal PassWall2 firmware customizations
# License: MIT
#=================================================
set -euo pipefail

BUILD_DATE="$(TZ=Asia/Shanghai date '+%Y.%m.%d')"
BUILD_TIME="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %Z')"

# Keep a hard image-size safety margin. The physical firmware partition is
# 32448 KiB; limiting generated images to 30000 KiB prevents future core growth
# from silently consuming the last couple of MiB needed by overlay metadata and
# small persistent configuration changes.
DEVICE_IMAGE_MAKEFILE="target/linux/ramips/image/mt7621.mk"
sed -i '/define Device\/d-team_newifi-d2/,/endef/ s/IMAGE_SIZE := 32448k/IMAGE_SIZE := 30000k/' "$DEVICE_IMAGE_MAKEFILE"
grep -A8 'define Device/d-team_newifi-d2' "$DEVICE_IMAGE_MAKEFILE" | grep -q 'IMAGE_SIZE := 30000k' || {
  echo "Unable to reserve the Newifi D2 image-size safety margin." >&2
  exit 1
}

# Default LAN IP: 192.168.2.1
sed -i 's/192\.168\.1\.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# Hostname: Newifi-D2
sed -i 's/OpenWrt/Newifi-D2/g' package/base-files/files/bin/config_generate
sed -i 's/ImmortalWrt/Newifi-D2/g' package/base-files/files/bin/config_generate

# Version string contains the compile date.
sed -i '/^DISTRIB_DESCRIPTION=/d' package/base-files/files/etc/openwrt_release
cat >> package/base-files/files/etc/openwrt_release <<EOF_RELEASE
DISTRIB_DESCRIPTION='Newifi-D2 minimal PassWall2 build ${BUILD_DATE} @ %D %V'
DISTRIB_BUILD_DATE='${BUILD_TIME}'
EOF_RELEASE

# DNS cache tuning for long-running routers; avoid appending duplicate lines on reruns.
DNSMASQ_CONF="package/network/services/dnsmasq/files/dnsmasq.conf"
sed -i '/^# Newifi D2 DNS cache tuning$/,/^min-cache-ttl=3600$/d' "$DNSMASQ_CONF"
cat >> "$DNSMASQ_CONF" <<'EOF_DNS'
# Newifi D2 DNS cache tuning
#max-ttl=600
neg-ttl=600
min-cache-ttl=3600
EOF_DNS

# Ship a pinned, known-good Geo fallback in the read-only SquashFS. Runtime
# updates go to /tmp, so a failed mirror or proxy line can never remove this
# bootable fallback or consume overlay space.
GEO_SEED_COMMIT="9b775de81b488d5d2e03348797e6dd540aaabbcd"
GEO_SEED_DIR="files/usr/share/passwall2-bootstrap"
mkdir -p "$GEO_SEED_DIR" files/etc/rc.d

download_geo_seed() {
  local name="$1"
  local expected="$2"
  local destination="$GEO_SEED_DIR/$name"
  local temporary="$destination.download"
  local base

  for base in \
    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@${GEO_SEED_COMMIT}" \
    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@${GEO_SEED_COMMIT}" \
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${GEO_SEED_COMMIT}"; do
    if curl -fL --retry 3 --connect-timeout 10 --max-time 600 \
      -o "$temporary" "$base/$name" && \
      echo "$expected  $temporary" | sha256sum -c - >/dev/null 2>&1; then
      mv -f "$temporary" "$destination"
      return 0
    fi
  done

  rm -f "$temporary"
  echo "Unable to download verified bootstrap $name." >&2
  return 1
}

download_geo_seed geoip.dat b406dd3759037188b0674b110dcaf33664a699c0518152d0ca0d9023fc774c6b
download_geo_seed geosite.dat 3ee29666b49513e1e09be27b83b996c06866aaae7a47d53cfa91bcd0c453cf60
ln -snf ../init.d/passwall2-geodata files/etc/rc.d/S98passwall2-geodata


# Remove unwanted package directories if any script or feed brings them in, ensuring the image stays minimal.
# OpenWrt master plus PassWall feeds provide the required PassWall2 components.
rm -rf \
  package/small \
  package/openwrt-packages \
  feeds/packages/net/adguardhome \
  feeds/packages/net/zerotier \
  feeds/luci/applications/luci-app-adguardhome \
  feeds/luci/applications/luci-app-zerotier \
  package/feeds/luci/luci-app-openclash \
  package/feeds/luci/luci-app-ssr-plus \
  package/feeds/packages/adguardhome \
  package/feeds/packages/zerotier
