#!/bin/bash
# Build ogn-rf with the RSPduo backend on the XavierAGX (or any host with the SDRplay API).
#
# Three things are unusual compared to a plain "make":
#
#  * libsdrplay_api, its headers and the sdrplay_apiService daemon are a system-wide install
#    from the vendor's payload. scripts/install-sdrplay-api.sh does that; the Makefile
#    auto-detects /usr/local/include/sdrplay_api.h, and this script passes USE_RSPDUO=1
#    anyway so a half-installed system fails loudly here instead of silently building an
#    RTL-SDR-only binary.
#
#  * libconfig and librtlsdr are not available as Ubuntu packages here, so they come from a
#    local prefix that the KrakenSDR work built (see PREFIX below). Point PREFIX elsewhere if
#    you have them system-wide. librtlsdr is needed even when driving an RSPduo, because
#    ogn-rf's RTLSDR class is compiled in unconditionally.
#
#  * FLAGS and LIBS are passed on the make command line, which OVERRIDES the Makefile's own
#    FLAGS. The Makefile therefore keeps -DUSE_RSPDUO and -lsdrplay_api in separate variables
#    (RSP_FLAGS / RSP_LIBS) that survive an override; if you add flags here, do not expect the
#    Makefile's -DUSE_RSPDUO to be added for you.
#
# Usage:  ./build-ogn-rf.sh [source-tree] [output-name]
#   source-tree  the ogn-rf checkout (default: ~/projects/RSPduo/ogn-rf)
#   output-name  name for the binary  (default: ogn-rf)
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# Default: the ogn-rf checkout that sits beside this repository.
DEFAULT_SRC=$HERE/../ogn-rf
[ -d "$DEFAULT_SRC" ] || DEFAULT_SRC=$HOME/projects/RSPduo/ogn-rf
SRC=${1:-$DEFAULT_SRC}
OUT=${2:-ogn-rf}

# Where libconfig / librtlsdr headers and libs live
PREFIX=${PREFIX:-$HOME/projects/KrakenSDR/krakensdr/deps/prefix}
PREFIX=${PREFIX%/}
RSPDUO_PREFIX=${RSPDUO_PREFIX:-/usr/local}

if [ ! -d "$SRC" ]; then
  echo "no source tree at $SRC" >&2
  echo "(clone it first:  git clone https://github.com/thread3d/ogn-rf.git $SRC && (cd $SRC && git checkout rspduo))" >&2
  exit 1
fi

if [ ! -f "$RSPDUO_PREFIX/include/sdrplay_api.h" ]; then
  echo "the SDRplay API headers are missing from $RSPDUO_PREFIX/include" >&2
  echo "run scripts/install-sdrplay-api.sh with sudo first" >&2
  exit 1
fi

# The daemon must be up: libsdrplay_api is only a client, and every hardware call goes through it.
if command -v systemctl >/dev/null; then
  if ! systemctl is-active --quiet sdrplay; then
    echo "warning: sdrplay.service is not running; ogn-rf will fail at open with ServiceNotResponding" >&2
    echo "         fix with:  sudo systemctl start sdrplay" >&2
  fi
fi

INCS="-I$PREFIX/include -I$RSPDUO_PREFIX/include"
LIBS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib -L$RSPDUO_PREFIX/lib -Wl,-rpath,$RSPDUO_PREFIX/lib -lpthread -lm -ljpeg -lconfig -lrt"

if [ ! -d "$PREFIX" ]; then
  echo "warning: $PREFIX not found - hoping libconfig and librtlsdr are system-wide" >&2
fi

echo "source  : $SRC"
echo "prefix  : $PREFIX"
echo "sdrplay : $RSPDUO_PREFIX"
echo "output  : $OUT"

cd "$SRC" || exit 1
exec make USE_RSPDUO=1 \
     FLAGS="-Wall -O3 -ffast-math -DVERSION=0.2.6 $INCS" \
     LIBS="$LIBS" \
     "$OUT"
