#!/bin/bash
#
# Build a Slurm .deb for this cluster on Ubuntu 24.04.
#
# Produces /opt/lucid-hpc/slurm_debs/slurm-<VERSION>-<ITERATION>_<UBUNTU>_amd64.deb
# matching the filename convention consumed by playbooks/roles/slurm
# (slurm-{{slurm_version}}_{{ansible_distribution_version}}_amd64.deb).
#
# The build installs into /usr/local (slurm_exec in roles/slurm/vars/
# ubuntu_vars.yml) with config in /etc/slurm. Run on the controller or any
# scratch 24.04 box of the same arch.
#
# Alternative (more churn, better long-term): SchedMD's native debuild
# producing slurm-smd-* packages installing under /usr — requires changing
# slurm_exec and the install task in roles/slurm.
#
set -euo pipefail

# Read os-release first: it defines VERSION/VERSION_ID and must not clobber ours
source /etc/os-release
UBUNTU_VERSION="$VERSION_ID"

VERSION="${SLURM_VERSION:-24.05.1}"
ITERATION="${SLURM_ITERATION:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/lucid-hpc/slurm_debs}"
JOBS=$(nproc)
DEB_NAME="slurm-${VERSION}-${ITERATION}_${UBUNTU_VERSION}_amd64.deb"

BUILD_ROOT=$(mktemp -d /tmp/slurm-build.XXXXXX)
trap 'rm -rf "$BUILD_ROOT"' EXIT

echo "== Installing build dependencies"
sudo apt-get update
sudo apt-get -y install build-essential fakeroot ruby ruby-dev rubygems \
  libmunge-dev libpam0g-dev libjwt-dev libhttp-parser-dev libyaml-dev \
  libjson-c-dev libmariadb-dev libpmix-dev libhwloc-dev libdbus-1-dev \
  liblua5.4-dev libreadline-dev libcurl4-openssl-dev man2html-base wget
sudo gem install --no-document fpm

echo "== Downloading Slurm ${VERSION}"
cd "$BUILD_ROOT"
wget -q "https://download.schedmd.com/slurm/slurm-${VERSION}.tar.bz2"
tar xjf "slurm-${VERSION}.tar.bz2"
cd "slurm-${VERSION}"

echo "== Building"
# --with-pam_dir is load-bearing: without it slurm installs PAM modules to
# /lib/security, which fpm below silently drops (it only packages usr etc),
# and compute_pam.yml stats /usr/local/lib/security/pam_slurm_adopt.so.
# configure rejects a pam_dir that doesn't exist on the build host.
sudo mkdir -p /usr/local/lib/security
./configure --prefix=/usr/local --sysconfdir=/etc/slurm \
  --with-pmix --enable-pam --with-jwt \
  --with-pam_dir=/usr/local/lib/security
make -j"$JOBS" > /dev/null
make install DESTDIR="$BUILD_ROOT/pkg" > /dev/null
# PAM modules — must build; a silent miss ships a deb whose stat-guard in
# compute_pam.yml quietly skips the SSH hardening it is supposed to enable.
make -C contribs/pam install DESTDIR="$BUILD_ROOT/pkg" < /dev/null
make -C contribs/pam_slurm_adopt install DESTDIR="$BUILD_ROOT/pkg" < /dev/null
test -e "$BUILD_ROOT/pkg/usr/local/lib/security/pam_slurm_adopt.so" || {
  echo "ERROR: pam_slurm_adopt.so missing from the package tree" >&2; exit 1; }

echo "== Packaging ${DEB_NAME}"
mkdir -p "$OUTPUT_DIR"
fpm -s dir -t deb \
  -n slurm -v "$VERSION" --iteration "$ITERATION" \
  --description "Slurm workload manager (local build for the on-prem cluster)" \
  --depends munge --depends libmunge2 --depends libjwt2 \
  --depends libpmix-bin --depends libhwloc15 --depends libmariadb3 \
  -p "$OUTPUT_DIR/$DEB_NAME" \
  -C "$BUILD_ROOT/pkg" usr etc 2>/dev/null || \
fpm -s dir -t deb \
  -n slurm -v "$VERSION" --iteration "$ITERATION" \
  --description "Slurm workload manager (local build for the on-prem cluster)" \
  --depends munge --depends libmunge2 --depends libjwt2 \
  --depends libpmix-bin --depends libhwloc15 --depends libmariadb3 \
  -p "$OUTPUT_DIR/$DEB_NAME" \
  -C "$BUILD_ROOT/pkg" usr

echo "== Done: $OUTPUT_DIR/$DEB_NAME"
echo "Set slurm_version: \"${VERSION}-${ITERATION}\" in playbooks/roles/slurm/defaults/main.yml if it differs."
