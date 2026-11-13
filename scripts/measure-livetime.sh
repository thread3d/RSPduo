#!/bin/bash
# Measure ogn-rf's Live Time for one configuration, with or without a downstream
# reader on ogn-rf.fifo.
#
# Why the reader matters: Inp_FFT hands each demodulated slot to the decoder
# through the FIFO and opens it O_WRONLY, which blocks until a reader appears.
# With nothing reading, the demodulation chain stops, RF_Acq's queue fills and
# every later slot is dropped - so Live Time measures the missing decoder, not
# the radio.
#
#   measure-livetime2.sh <config> <seconds> <reader|noreader>
#
set -u
CONF=$1
SECS=${2:-60}
READER=${3:-reader}
NAME=$(basename "$CONF" .conf)-$READER
DIR=$HOME/ogn-captures
LOG=$DIR/run-$NAME.log
SINK=$DIR/fifo-$NAME.bin
BIN=$HOME/projects/RSPduo/ogn-rf/ogn-rf

field() { curl -s --max-time 3 http://127.0.0.1:8095/ | sed -e 's/<[^>]*>/ /g' \
          | awk -v k="$1" 'index($0,k){print $NF; exit}'; }

pkill -x ogn-rf 2>/dev/null
pkill -f 'cat ogn-rf.fifo' 2>/dev/null
sleep 1
cd "$DIR" || exit 1
rm -f ogn-rf.fifo "$SINK" "$LOG"

( sleep $((SECS+30)) | stdbuf -oL -eL "$BIN" "$CONF" > "$LOG" 2>&1 ) &
sleep 5                                   # let it open the radio first

RD=0
if [ "$READER" = reader ]; then
  sleep 3                                 # let ogn-rf create the FIFO
  cat ogn-rf.fifo > "$SINK" &
  RD=$!
  echo "reader attached (pid $RD)"
else
  echo "no reader: the demodulator will block on the FIFO"
fi

for i in $(seq 1 $((SECS/10))); do
  sleep 10
  printf 't=%3ds  LiveTime=%-7s ring_overrun=%-7s dropped=%-4s fifo_MB=%s\n' \
    $((i*10)) "$(field 'Live Time')" "$(field 'Ring overruns' | tr -d ' ')" \
    "$(grep -c 'Dropped a slot' "$LOG")" \
    "$(awk -v b="$(stat -c%s "$SINK" 2>/dev/null || echo 0)" 'BEGIN{printf "%.1f", b/1048576}')"
done

[ "$RD" != 0 ] && kill "$RD" 2>/dev/null
pkill -x ogn-rf 2>/dev/null
echo "--- $LOG"
grep -E 'RSPduo::Open\(\)' "$LOG" | head -4
printf 'half_time_slot=%s dropped=%s overload=%s\n' \
  "$(grep -c 'Half time slot' "$LOG")" "$(grep -c 'Dropped a slot' "$LOG")" "$(grep -c 'ADC overload' "$LOG")"

# A Live Time figure without a working reader measures the blocked demodulator, not the radio, so
# refuse to let one stand. See docs/status-log.md, session 17.
if [ "$READER" = reader ] && [ "$(stat -c%s "$SINK" 2>/dev/null || echo 0)" -eq 0 ]; then
  echo "ERROR: the FIFO reader received no data - the numbers above are NOT a Live Time measurement." >&2
  exit 2
fi
