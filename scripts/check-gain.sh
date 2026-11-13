#!/bin/bash
# Show what gain the RSPduo actually applied, next to what was configured.
#
# The two can differ: ogn-rf asks for a total gain, the backend turns it into an IF gain
# reduction and clamps it, and in dual mode each tuner has its own registers. The status page
# now carries both rows, so this script just runs the receiver and prints them.
#
#   check-gain.sh <config> [seconds]
#
set -u
CONF=$1
SECS=${2:-12}
DIR=$HOME/ogn-captures
LOG=$DIR/gaincheck.log
BIN=$HOME/projects/RSPduo/ogn-rf/ogn-rf

pkill -x ogn-rf 2>/dev/null
sleep 1
cd "$DIR" || exit 1
rm -f ogn-rf.fifo "$LOG"

( sleep $((SECS+20)) | stdbuf -oL -eL "$BIN" "$CONF" > "$LOG" 2>&1 ) &

for _ in $(seq 1 100); do [ -p ogn-rf.fifo ] && break; sleep 0.3; done
cat ogn-rf.fifo > /dev/null &
READER=$!
sleep "$SECS"

echo "=== configured vs applied ==="
curl -s --max-time 3 http://127.0.0.1:8095/ | sed -e 's/<[^>]*>/ /g' \
  | grep -E 'OGN\.Gain|Gain applied|Sample rate|Delivered to host|Live Time|overruns'
echo "=== overload events in ${SECS}s ==="
echo "  detected : $(grep -c 'overload detected'  "$LOG")"
echo "  corrected: $(grep -c 'overload corrected' "$LOG")"

kill $READER 2>/dev/null
pkill -x ogn-rf 2>/dev/null
