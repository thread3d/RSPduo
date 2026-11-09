#!/bin/bash
#
# install-sdrplay-api.sh - install the SDRplay API for the RSPduo on aarch64 Ubuntu
#
#   sudo ./install-sdrplay-api.sh [--run-file /path/to/SDRplay_RSP_API-Linux-3.15.2.run]
#
# The vendor's .run installer is interactive (it pages the licence, then asks a
# series of y/n questions) which makes it useless in a scripted bring-up. This
# script does the same installation the vendor's install_lib.sh does, but
# non-interactively and idempotently, so the result is auditable and repeatable.
#
# Everything it writes, all of it with root privileges:
#
#   /opt/sdrplay_api/sdrplay_apiService            the API daemon (runs as root)
#   /usr/local/lib/libsdrplay_api.so.3.15          client library + .so.3 / .so links
#   /usr/local/include/sdrplay_api*.h              the API headers
#   /etc/udev/rules.d/66-sdrplay.rules             makes the 1df7 USB nodes rw
#   /etc/udev/hwdb.d/20-sdrplay.hwdb               so lsusb names the model
#   /etc/systemd/system/sdrplay.service            starts the daemon at boot
#
# Why root is genuinely required (there is no non-root option):
#   * the RSPduo's USB node is root:root 0664, so the daemon cannot open it
#     until the udev rule lands, and udev rules are root-only;
#   * API 3.x moved all hardware access into sdrplay_apiService, which the
#     vendor ships as a root systemd unit. Client programs talk to it over a
#     socket and never touch USB themselves.
#
# Reference: this mirrors install_lib.sh from the vendor payload, section by
# section. The licence text is the vendor's EULA, accepted by running this.

set -euo pipefail

VERS="3.15"                 # library soname version, as shipped
MAJVERS="3"                 # soname major, for the .so.3 link
LOC_SERVICE="/opt/sdrplay_api"
LOC_HEADER="/usr/local/include"
LOC_LIB="/usr/local/lib"

RUN_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --run-file) RUN_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "error: this script must run as root (sudo $0)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate the vendor payload
# ---------------------------------------------------------------------------
if [ -z "$RUN_FILE" ]; then
  for candidate in \
      /home/threaded/rspduo-deps/SDRplay_RSP_API-Linux-${VERS}.2.run \
      /home/threaded/rspduo-deps/SDRplay_RSP_API-Linux-${VERS}.1.run \
      "$PWD/SDRplay_RSP_API-Linux-${VERS}.2.run"
  do
    [ -f "$candidate" ] && RUN_FILE="$candidate" && break
  done
fi
if [ -z "$RUN_FILE" ] || [ ! -f "$RUN_FILE" ]; then
  echo "error: vendor installer not found; pass --run-file" >&2
  exit 1
fi
echo "payload: $RUN_FILE"

# ---------------------------------------------------------------------------
# Architecture: the payload carries arm64, armhf and amd64 slices
# ---------------------------------------------------------------------------
case "$(uname -m)" in
  aarch64|arm64) ARCHDIR="arm64" ;;
  armv7l|armhf)  ARCHDIR="armhf" ;;
  x86_64|amd64)  ARCHDIR="amd64" ;;
  *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
echo "arch:    $(uname -m) -> payload slice '$ARCHDIR'"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --tar xf unpacks the payload without starting the vendor's installer
( cd "$WORK" && sh "$RUN_FILE" --tar xf )

for f in "$WORK/$ARCHDIR/libsdrplay_api.so.$VERS" "$WORK/$ARCHDIR/sdrplay_apiService"; do
  [ -f "$f" ] || { echo "error: payload missing $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Client library and headers
# ---------------------------------------------------------------------------
echo "==> installing shared library into $LOC_LIB"
install -d -m 755 "$LOC_LIB" "$LOC_HEADER" "$LOC_SERVICE"

# clear any previous copy first, so a partial upgrade cannot leave a stale link
rm -f "$LOC_LIB"/libsdrplay_api.so*
install -m 644 "$WORK/$ARCHDIR/libsdrplay_api.so.$VERS" "$LOC_LIB/libsdrplay_api.so.$VERS"
ln -sfn "$LOC_LIB/libsdrplay_api.so.$VERS"   "$LOC_LIB/libsdrplay_api.so.$MAJVERS"
ln -sfn "$LOC_LIB/libsdrplay_api.so.$MAJVERS" "$LOC_LIB/libsdrplay_api.so"
ldconfig

echo "==> installing headers into $LOC_HEADER"
install -m 644 "$WORK"/inc/sdrplay_api*.h "$LOC_HEADER/"

# ---------------------------------------------------------------------------
# The daemon
# ---------------------------------------------------------------------------
echo "==> installing API service into $LOC_SERVICE"
install -m 755 "$WORK/$ARCHDIR/sdrplay_apiService" "$LOC_SERVICE/sdrplay_apiService"

# ---------------------------------------------------------------------------
# udev: all known SDRplay PIDs, mode 0666
#
# 3020 is the RSPduo. The client programs never open the device themselves, but
# the rule still matters: it lets diagnostics (lsusb, SoapySDR probes, anything
# reading the descriptors) work without root, and it is what the vendor
# installs. Removing a pre-existing 66-mirics.rules is the vendor's own advice;
# we leave other people's rules alone and simply skip it if it is not ours.
# ---------------------------------------------------------------------------
echo "==> installing udev rules"
cat > /etc/udev/rules.d/66-sdrplay.rules <<'EOF'
# SDRplay RSP receivers. Installed by rspduo/scripts/install-sdrplay-api.sh,
# replicating the vendor payload's install_lib.sh rules.
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="2500",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="3000",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="3010",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="3020",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="3030",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="3050",MODE:="0666"
SUBSYSTEM=="usb",ENV{DEVTYPE}=="usb_device",ATTRS{idVendor}=="1df7",ATTRS{idProduct}=="3060",MODE:="0666"
EOF
chmod 644 /etc/udev/rules.d/66-sdrplay.rules

echo "==> installing udev hardware database entry"
install -d -m 755 /etc/udev/hwdb.d
cat > /etc/udev/hwdb.d/20-sdrplay.hwdb <<'EOF'
usb:v1DF7*
 ID_VENDOR_FROM_DATABASE=SDRplay

usb:v1DF7p2500*
 ID_MODEL_FROM_DATABASE=RSP1

usb:v1DF7p3000*
 ID_MODEL_FROM_DATABASE=RSP1A

usb:v1DF7p3010*
 ID_MODEL_FROM_DATABASE=RSP2/RSP2pro

usb:v1DF7p3020*
 ID_MODEL_FROM_DATABASE=RSPduo

usb:v1DF7p3030*
 ID_MODEL_FROM_DATABASE=RSPdx

usb:v1DF7p3050*
 ID_MODEL_FROM_DATABASE=RSP1B

usb:v1DF7p3060*
 ID_MODEL_FROM_DATABASE=RSPdxR2
EOF
chmod 644 /etc/udev/hwdb.d/20-sdrplay.hwdb

systemd-hwdb update >/dev/null 2>&1 || true
udevadm trigger || true
udevadm settle || true
systemctl restart systemd-udevd 2>/dev/null || systemctl restart udev 2>/dev/null || true

# ---------------------------------------------------------------------------
# systemd unit, byte-for-byte the vendor's
# ---------------------------------------------------------------------------
echo "==> installing sdrplay.service"
if [ -f /etc/systemd/system/sdrplay.service ]; then
  systemctl stop sdrplay 2>/dev/null || true
  systemctl disable sdrplay 2>/dev/null || true
fi
cat > /etc/systemd/system/sdrplay.service <<EOF
[Unit]
Description=SDRplay API Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=on-failure
RestartSec=1
User=root
ExecStart=${LOC_SERVICE}/sdrplay_apiService

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/sdrplay.service
systemctl daemon-reload
systemctl enable sdrplay >/dev/null
systemctl start sdrplay

# the licence copy the vendor installer leaves in $HOME, for completeness
if [ -f "$WORK/sdrplay_license.txt" ] && [ -d /home/threaded ]; then
  cp "$WORK/sdrplay_license.txt" /home/threaded/sdrplay_license.txt
  chown threaded:threaded /home/threaded/sdrplay_license.txt
  chmod 644 /home/threaded/sdrplay_license.txt
fi

# ---------------------------------------------------------------------------
# Verification: report what actually landed rather than assuming
# ---------------------------------------------------------------------------
sleep 1
echo
echo "====================== verification ======================"
fail=0

echo "-- library"
if ldconfig -p | grep -q libsdrplay_api; then
  ldconfig -p | grep libsdrplay_api | sed 's/^/   /'
else
  echo "   MISSING: libsdrplay_api not in the linker cache"; fail=1
fi

echo "-- service binary"
ls -l "$LOC_SERVICE/sdrplay_apiService" 2>&1 | sed 's/^/   /' || fail=1

echo "-- daemon state"
if systemctl is-active --quiet sdrplay; then
  echo "   sdrplay.service: active"
else
  echo "   sdrplay.service: NOT ACTIVE"; fail=1
fi
systemctl is-enabled sdrplay 2>&1 | sed 's/^/   enabled: /'

echo "-- process"
pgrep -a sdrplay_apiService | sed 's/^/   /' || { echo "   no sdrplay_apiService process"; fail=1; }

echo "-- USB device"
if lsusb -d 1df7:3020 >/dev/null 2>&1; then
  lsusb -d 1df7:3020 | sed 's/^/   /'
else
  echo "   RSPduo (1df7:3020) not present on the bus"; fail=1
fi
echo "-- device-node permissions (what non-root callers may open)"
node_perm_ok=0
for node in /dev/bus/usb/*/*; do
  [ -e "$node" ] || continue
  # only the SDRplay nodes matter; the 3020 one is the RSPduo
  perm="$(stat -c '%a %U:%G' "$node" 2>/dev/null)" || continue
  case "$perm" in
    666*) echo "   $node  $perm"; node_perm_ok=1 ;;
  esac
done
if [ "$node_perm_ok" -eq 0 ]; then
  echo "   NOTE: no 0666 node seen yet; unplug and re-plug the RSPduo so udev re-applies"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: SDRplay API installed and the daemon is running."
else
  echo "RESULT: installation incomplete; see the MISSING/NOT ACTIVE lines above."
  exit 1
fi
