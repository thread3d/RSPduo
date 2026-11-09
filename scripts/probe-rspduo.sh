#!/bin/bash
# Build and run the standalone RSPduo receive checker.
#
# This is the first thing to run after installing the SDRplay API: it is independent of ogn-rf,
# so a failure here is a device or API problem rather than a receiver problem.
#
# Usage:  ./probe-rspduo.sh [options passed to rspduo_probe]
#   ./probe-rspduo.sh                         # tune 868.3 MHz, capture 1 s, report statistics
#   ./probe-rspduo.sh -g 30                   # less gain
#   ./probe-rspduo.sh -o /tmp/868.u8          # also save I/Q for tools/spectrum.py
#   ./probe-rspduo.sh -f 433920000            # look somewhere else
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../src/rspduo_probe.c
BIN=$HERE/../rspduo_probe
RSPDUO_PREFIX=${RSPDUO_PREFIX:-/usr/local}

if [ ! -f "$RSPDUO_PREFIX/include/sdrplay_api.h" ]; then
  echo "the SDRplay API headers are missing from $RSPDUO_PREFIX/include" >&2
  echo "run scripts/install-sdrplay-api.sh with sudo first" >&2
  exit 1
fi

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  echo "building $BIN"
  gcc -O2 -Wall -I"$RSPDUO_PREFIX/include" -o "$BIN" "$SRC" \
      -L"$RSPDUO_PREFIX/lib" -Wl,-rpath,"$RSPDUO_PREFIX/lib" \
      -lsdrplay_api -lpthread -lm || exit 1
fi

exec "$BIN" "$@"
