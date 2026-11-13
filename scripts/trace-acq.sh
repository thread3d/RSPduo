#!/bin/bash
# Run the ACQ_TRACE build with a working FIFO reader and summarise the trace.
#
# The reader must be attached only once ogn-rf has created the FIFO, or it fails
# with "No such file or directory" and the demodulator blocks instead - which
# looks exactly like a slow acquisition loop. So poll for the FIFO, and assert
# afterwards that bytes actually flowed.
#
#   trace-acq.sh <config> [seconds]
#
set -u
CONF=$1
SECS=${2:-40}
DIR=$HOME/ogn-captures
LOG=$DIR/trace-$(basename "$CONF" .conf).log
SINK=$DIR/trace-fifo.bin
BIN=$DIR/trace/ogn-rf-trace

pkill -x ogn-rf 2>/dev/null
pkill -x ogn-rf-trace 2>/dev/null
pkill -f 'ogn-rf.fifo' 2>/dev/null
sleep 1
cd "$DIR" || exit 1
rm -f ogn-rf.fifo "$SINK" "$LOG"

( sleep $((SECS+30)) | "$BIN" "$CONF" > "$LOG" 2>&1 ) &

# Wait for the FIFO to appear (ogn-rf creates it on the first write attempt).
for _ in $(seq 1 60); do [ -p ogn-rf.fifo ] && break; sleep 0.5; done
if [ ! -p ogn-rf.fifo ]; then echo "no FIFO appeared - is ogn-rf running?"; fi
cat ogn-rf.fifo > "$SINK" &
READER=$!
sleep 3

sleep "$SECS"
pkill -x ogn-rf-trace 2>/dev/null
kill $READER 2>/dev/null

echo "=== $(basename "$CONF") ==="
grep -E 'RSPduo::Open\(\)' "$LOG" | head -3
MB=$(awk -v b="$(stat -c%s "$SINK" 2>/dev/null || echo 0)" 'BEGIN{printf "%.1f", b/1048576}')
echo "fifo reader received ${MB} MB  (0 means the reader never attached)"
printf 'reads=%s skips=%s tunes=%s dropped=%s half=%s\n' \
  "$(grep -c 'ACQ read' "$LOG")" "$(grep -c 'ACQ skip' "$LOG")" \
  "$(grep -c 'ACQ tune' "$LOG")" "$(grep -c 'Dropped a slot' "$LOG")" \
  "$(grep -c 'Half time slot' "$LOG")"

echo "--- reads: want / got / dt / gap ---"
grep 'ACQ read' "$LOG" | head -8
echo "--- tunes (dt = cost of the retune) ---"
grep 'ACQ tune' "$LOG" | head -8
echo "--- summary ---"
grep 'ACQ read' "$LOG" | awk '
  { for(i=1;i<=NF;i++){ if($i ~ /^dt=/){split($i,a,"=");dt=a[2]} if($i ~ /^t=/){split($i,b,"=");t=b[2]}
                        if($i ~ /^want=/){split($i,c,"=");want=c[2]} }
    n++; sdt+=dt; if(prev!=""){si+=t-prev; ni++} prev=t }
  END{ if(n) printf "reads=%d mean_read_dt=%.3f s  mean_interval=%.3f s  reads/s=%.2f  want=%d\n",
        n, sdt/n, si/ni, (ni?ni/si:0), want }'
grep 'ACQ tune' "$LOG" | awk '
  { for(i=1;i<=NF;i++) if($i ~ /^dt=/){split($i,a,"=");dt=a[2]}
    n++; s+=dt; if(dt>mx)mx=dt }
  END{ if(n) printf "tunes=%d mean_tune_dt=%.3f s  max=%.3f s\n", n, s/n, mx }'
