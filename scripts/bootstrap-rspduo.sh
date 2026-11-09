#!/bin/bash
# bootstrap-rspduo.sh - install the SDRplay API and verify the RSPduo end to end
#
#     sudo ./bootstrap-rspduo.sh
#
# One command, because the hardware verification is only possible once the root-owned daemon
# exists, and root is only needed for that one step. Everything after the install deliberately
# drops back to the invoking user, so the checks run the way ogn-rf will actually run - as a
# normal user talking to the daemon over its socket, not as root.
#
# It leaves a report at ~/rspduo-bootstrap-report.txt containing every measurement, so the
# result of the bring-up is a file rather than scrollback.
#
# What it does, in order:
#   1. installs the API (the vendor payload, non-interactively)
#   2. confirms the daemon is up and the library is in the linker cache
#   3. builds and runs the standalone probe, without ogn-rf, and reports the statistics that
#      settle the 8-bit conversion scale
#   4. captures one second of 868.3 MHz and reports the spectrum, including both OGN channels
#   5. builds ogn-rf with the RSPduo backend, which is only possible now that the headers exist
#   6. runs ogn-rf for a few seconds and captures its log
#
# Steps 3-6 are best-effort: a failure is recorded and the script continues, so one run reports
# everything that is wrong rather than stopping at the first problem.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run this with sudo (it installs a root daemon)" >&2
  exit 1
fi

TARGET_USER=${SUDO_USER:-threaded}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "${TARGET_HOME:-}" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "error: cannot resolve the home directory of user '$TARGET_USER'" >&2
  exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)
REPORT=$TARGET_HOME/rspduo-bootstrap-report.txt
PROBE_CAP=$TARGET_HOME/rspduo-868.u8

# Run a command as the invoking user, with their own environment.
runas()
{ runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"; }

say()
{ echo "$@" | tee -a "$REPORT"; }

: > "$REPORT"
say "RSPduo bootstrap - $(date -u '+%Y-%m-%d %H:%M:%SZ')"
say "host: $(uname -n)  arch: $(uname -m)  user: $TARGET_USER"
say ""

FAILED=0

# ---------------------------------------------------------------------------------------------
# 1. Install
# ---------------------------------------------------------------------------------------------
say "=================================================================="
say "1. Installing the SDRplay API"
say "=================================================================="
if [ ! -x "$HERE/install-sdrplay-api.sh" ]; then
  say "FAIL: $HERE/install-sdrplay-api.sh is missing"
  exit 1
fi
"$HERE/install-sdrplay-api.sh" 2>&1 | tee -a "$REPORT"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  say "FAIL: the installer reported a problem (see above)"
  FAILED=1
fi
say ""

# ---------------------------------------------------------------------------------------------
# 2. Daemon and library
# ---------------------------------------------------------------------------------------------
say "=================================================================="
say "2. API service and library"
say "=================================================================="
if systemctl is-active --quiet sdrplay; then
  say "PASS: sdrplay.service is active"
else
  say "FAIL: sdrplay.service is not active"
  systemctl status sdrplay --no-pager 2>&1 | head -20 | sed 's/^/    /' | tee -a "$REPORT"
  FAILED=1
fi
if ldconfig -p 2>/dev/null | grep -q libsdrplay_api; then
  say "PASS: libsdrplay_api is in the linker cache"
  ldconfig -p | grep libsdrplay_api | sed 's/^/    /' | tee -a "$REPORT"
else
  say "FAIL: libsdrplay_api is not in the linker cache"
  FAILED=1
fi
say "device seen by the bus:"
lsusb -d 1df7: 2>&1 | sed 's/^/    /' | tee -a "$REPORT"
say ""

# ---------------------------------------------------------------------------------------------
# 3. Standalone probe: the measurement that settles the conversion scale
# ---------------------------------------------------------------------------------------------
say "=================================================================="
say "3. Probe: is the device alive, and what does it deliver?"
say "=================================================================="
if [ ! -x "$HERE/probe-rspduo.sh" ]; then
  say "SKIP: probe-rspduo.sh is missing"
else
  runas "$HERE/probe-rspduo.sh" 2>&1 | tee -a "$REPORT"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then say "FAIL: the probe did not complete"; FAILED=1; fi
fi
say ""

# ---------------------------------------------------------------------------------------------
# 4. Spectrum of the OGN band
# ---------------------------------------------------------------------------------------------
say "=================================================================="
say "4. What is on the air at 868.3 MHz?"
say "=================================================================="
if [ -x "$HERE/probe-rspduo.sh" ] && [ -f "$HERE/../tools/spectrum.py" ]; then
  runas "$HERE/probe-rspduo.sh" -o "$PROBE_CAP" >/dev/null 2>&1
  if [ -s "$PROBE_CAP" ]; then
    runas python3 "$HERE/../tools/spectrum.py" "$PROBE_CAP" --rate 2000000 --freq 868300000 \
          2>&1 | tee -a "$REPORT"
    runas python3 "$HERE/../tools/spectrum.py" "$PROBE_CAP" --rate 2000000 --freq 868300000 \
          --plot "$TARGET_HOME/rspduo-868.png" >/dev/null 2>&1
    if [ -f "$TARGET_HOME/rspduo-868.png" ]; then
      say "plot saved: $TARGET_HOME/rspduo-868.png"
    fi
  else
    say "SKIP: no capture was produced"
  fi
else
  say "SKIP: probe or spectrum.py unavailable"
fi
say ""

# ---------------------------------------------------------------------------------------------
# 5. Build ogn-rf with the RSPduo backend
# ---------------------------------------------------------------------------------------------
say "=================================================================="
say "5. Building ogn-rf with the RSPduo backend"
say "=================================================================="
if [ -x "$HERE/build-ogn-rf.sh" ]; then
  runas "$HERE/build-ogn-rf.sh" 2>&1 | tee -a "$REPORT"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then say "FAIL: the ogn-rf build failed"; FAILED=1; fi
else
  say "SKIP: build-ogn-rf.sh is missing"
  FAILED=1
fi
say ""

# ---------------------------------------------------------------------------------------------
# 6. Run ogn-rf briefly
# ---------------------------------------------------------------------------------------------
say "=================================================================="
say "6. Running ogn-rf against the RSPduo for 12 seconds"
say "=================================================================="
OGN_BIN=$TARGET_HOME/projects/RSPduo/ogn-rf/ogn-rf
CONF=$HERE/../config/ogn-rf-rspduo.conf
if [ -x "$OGN_BIN" ] && [ -r "$CONF" ]; then
  # stdin has to stay open or ogn-rf leaves its command loop at once; see run-ogn-rf.sh.
  runas bash -c "cd '$TARGET_HOME/projects/RSPduo/ogn-rf' && sleep 12 | stdbuf -oL -eL ./ogn-rf '$CONF'" \
        2>&1 | head -60 | tee -a "$REPORT"
  say ""
  say "checking the log for the things that matter:"
  LOGPASS=1
  if grep -qi "ServiceNotResponding" "$REPORT"; then say "  FAIL: ServiceNotResponding"; LOGPASS=0; fi
  if grep -qi "SDR: RSPduo support was not compiled in" "$REPORT"; then say "  FAIL: binary lacks USE_RSPDUO"; LOGPASS=0; fi
  if grep -qiE "Init\(\) failed|SelectDevice\(\) failed|GetDeviceParams\(\) failed" "$REPORT"; then
    say "  FAIL: the backend could not start the stream"; LOGPASS=0; fi
  if grep -q "RSPduo::Open()" "$REPORT"; then
    say "  PASS: the backend opened the device:"
    grep "RSPduo::Open()" "$REPORT" | head -6 | sed 's/^/    /'
  else
    say "  FAIL: no RSPduo::Open() line, the device was never opened"; LOGPASS=0
  fi
  if grep -q "Half time slot" "$REPORT"; then
    say "  NOTE: 'Half time slot' seen - the demodulator is not keeping up"
  fi
  [ "$LOGPASS" -eq 1 ] || FAILED=1
else
  say "SKIP: no ogn-rf binary or no config"
fi

# ---------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------
say ""
say "=================================================================="
if [ "$FAILED" -eq 0 ]; then
  say "RESULT: RSPduo installed, opened, and streaming into ogn-rf."
else
  say "RESULT: completed with problems - see the FAIL lines above."
fi
say "report: $REPORT"
say "=================================================================="

chown "$TARGET_USER" "$REPORT" 2>/dev/null || true
exit "$FAILED"
