#!/bin/bash
# Complete local build script for Newifi D2 minimal OpenWrt master + PassWall2 firmware.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/openwrt/openwrt}"
REPO_BRANCH="${REPO_BRANCH:-master}"
WORKDIR="${WORKDIR:-$PWD/workdir-newifi-d2}"
JOBS="${JOBS:-$(nproc)}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for required_file in \
  files/etc/init.d/passwall2-geodata \
  files/usr/share/passwall2/volatile-geodata.sh; do
  if [ ! -x "$ROOT_DIR/$required_file" ]; then
    echo "Missing executable $required_file." >&2
    exit 1
  fi
done
grep -q '^CONFIG_PACKAGE_geoview=y$' "$ROOT_DIR/newifi3.config" || {
  echo "CONFIG_PACKAGE_geoview=y is required for volatile Geo rules." >&2
  exit 1
}
grep -q '^CONFIG_TARGET_SQUASHFS_BLOCK_SIZE=1024$' "$ROOT_DIR/newifi3.config" || {
  echo "A 1024 KiB SquashFS block is required to fit the verified Geo fallback." >&2
  exit 1
}

sudo apt-get update
sudo apt-get install -y build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses5-dev libssl-dev python3-distutils rsync unzip zlib1g-dev \
  file wget curl ccache libelf-dev subversion swig time xsltproc

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d openwrt/.git ]; then
  git clone --depth 1 "$REPO_URL" -b "$REPO_BRANCH" openwrt
else
  git -C openwrt fetch --depth 1 origin "$REPO_BRANCH"
  git -C openwrt checkout "$REPO_BRANCH"
  git -C openwrt reset --hard "origin/$REPO_BRANCH"
fi

cd openwrt
cp "$ROOT_DIR/feeds.conf.default" feeds.conf.default
bash "$ROOT_DIR/DIY/diy-part1-d2-passwall2.sh"
./scripts/feeds update -a
PASSWALL2_MAKEFILE="feeds/passwall2/luci-app-passwall2/Makefile"
if [ ! -f "$PASSWALL2_MAKEFILE" ]; then
  echo "Missing $PASSWALL2_MAKEFILE after feeds update." >&2
  exit 1
fi
sed -i 's/[[:space:]]+geoview +v2ray-geoip +v2ray-geosite[[:space:]]*\\/ \\/' "$PASSWALL2_MAKEFILE"
if grep -qE '\+(geoview|v2ray-geoip|v2ray-geosite)' "$PASSWALL2_MAKEFILE"; then
  echo "Failed to remove bundled geodata dependencies from PassWall2." >&2
  exit 1
fi
./scripts/feeds install -a
cp "$ROOT_DIR/newifi3.config" .config
rm -rf files
cp -a "$ROOT_DIR/files" files
bash "$ROOT_DIR/DIY/diy-part2-d2.sh"
for geo_file in geoip.dat geosite.dat; do
  test -s "files/usr/share/passwall2-bootstrap/$geo_file" || {
    echo "Missing verified bootstrap $geo_file after DIY customization." >&2
    exit 1
  }
done
make defconfig
make download -j"$JOBS"
find dl -size -1024c -print -delete
make -j"$JOBS" || make -j1 V=s

printf '\nFirmware output: %s\n' "$PWD/bin/targets/ramips/mt7621"
