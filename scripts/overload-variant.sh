#!/bin/bash
# Does the "ADC overload detected" stream depend on what the FIFO reader does with the data?
#
# Two runs of the same receiver and configuration, differing only in where ogn-rf.fifo is sent:
# /dev/null, or a file on the same disk. ogn-rf's demodulator output is ~13 MB/s, so a file sink
# adds steady write pressure that a /dev/null sink does not - which is the only difference between
# the short checks that reported no overloads and the 15-minute soak that reported 3096 of them.
#
#   overload-variant.sh <config> <seconds> <null|file>
#
set -u
CONF=$1
SECS=${2:-120}
SINK_KIND=${3:-null}
DIR=$HOME/ogn-captures
TAG=overload-$SINK_KIND-$(date +%H%M%S)
LOG=$DIR/$TAG.log
BIN=${BIN:-$HOME/projects/RSPduo/ogn-rf/ogn-rf}

pkill -x ogn-rf 2>/dev/null
sleep 1
cd "$DIR" || exit 1
rm -f ogn-rf.fifo "$LOG"

( sleep $((SECS+40)) | stdbuf -oL -eL "$BIN" "$CONF" > "$LOG" 2>&1 ) &
for _ in $(seq 1 120); do [ -p ogn-rf.fifo ] && break; sleep 0.5; done

if [ "$SINK_KIND" = file ]; then
  cat ogn-rf.fifo > "$DIR/$TAG.fifo.bin" &
else
  cat ogn-rf.fifo > /dev/null &
fi
READER=$!

sleep "$SECS"
kill $READER 2>/dev/null
pkill -x ogn-rf 2>/dev/null
sleep 1

SIZE=$(stat -c%s "$DIR/$TAG.fifo.bin" 2>/dev/null || echo 0)
printf '%-6s %4ds  overload_detected=%-5s corrected=%-4s  fifo_data=%s MB  dropped=%s\n' \
  "$SINK_KIND" "$SECS" \
  "$(grep -c 'overload detected' "$LOG")" "$(grep -c 'overload corrected' "$LOG")" \
  "$(awk -v b="$SIZE" 'BEGIN{printf "%.0f", b/1048576}')" \
  "$(grep -c 'Dropped a slot' "$LOG")"
[ "$SINK_KIND" = file ] && rm -f "$DIR/$TAG.fifo.bin"
