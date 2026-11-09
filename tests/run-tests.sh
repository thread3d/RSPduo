#!/bin/bash
# Build and run the host-side unit test for the RSPduo backend's ring-buffer bridge.
#
# This needs no SDRplay hardware and no installed vendor library: the test stubs the handful of
# sdrplay_api_* entry points that rspduo.h calls. It does need the vendor *headers*, an ogn-rf
# checkout containing rspduo.h, and the headers ogn-rf itself uses (libconfig, librtlsdr, fftw3),
# because rspduo.h is compiled in the same include context as the rest of ogn-rf.
#
# Usage:  ./run-tests.sh [ogn-rf-checkout]
#
# Environment:
#   OGN              ogn-rf checkout (default: ~/projects/RSPduo/ogn-rf)
#   RSPDUO_PREFIX    where sdrplay_api.h lives (default: /usr/local, falling back to the
#                    extracted vendor payload in ~/rspduo-deps/extracted)
#   PREFIX           where libconfig.h / rtl-sdr.h live (default: the KrakenSDR deps prefix)
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OGN=${1:-${OGN:-$HOME/projects/RSPduo/ogn-rf}}

PREFIX=${PREFIX:-$HOME/projects/KrakenSDR/krakensdr/deps/prefix}
PREFIX=${PREFIX%/}

# The vendor headers: the installed location first, then the extracted payload, which is what is
# available before the API has been installed.
if [ -n "${RSPDUO_PREFIX:-}" ] && [ -f "$RSPDUO_PREFIX/include/sdrplay_api.h" ]; then
  RSPINC=$RSPDUO_PREFIX/include
elif [ -f /usr/local/include/sdrplay_api.h ]; then
  RSPINC=/usr/local/include
elif [ -f "$HOME/rspduo-deps/extracted/inc/sdrplay_api.h" ]; then
  RSPINC=$HOME/rspduo-deps/extracted/inc
else
  echo "cannot find sdrplay_api.h; set RSPDUO_PREFIX" >&2
  exit 1
fi

if [ ! -f "$OGN/rspduo.h" ]; then
  echo "no rspduo.h in $OGN - check out the rspduo branch of ogn-rf there" >&2
  exit 1
fi

BIN=$HERE/test_rspduo_ring
echo "ogn-rf   : $OGN"
echo "sdrplay  : $RSPINC"
echo "prefix   : $PREFIX"
echo

set -o pipefail
g++ -O1 -Wall -Wextra \
    -I"$RSPINC" -I"$OGN" -I"$PREFIX/include" \
    -o "$BIN" "$HERE/test_rspduo_ring.cxx" -lpthread
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "build FAILED" >&2
  exit "$STATUS"
fi

# Unbuffered, so a crash still shows how far the test got.
stdbuf -o0 -e0 "$BIN"
exit $?
