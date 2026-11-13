#!/bin/bash
# Extended soak test of ogn-rf on an RSPduo: does it stay up, keep reading a slot a second,
# and keep selection diversity working over a long run?
#
# Everything is sampled from the running receiver rather than inferred: Live Time, the backend's
# ring overruns, the diversity choice counters, the demodulator's output volume, and the process's
# own CPU and memory. A reader is attached to ogn-rf.fifo, without which Inp_FFT blocks on
# open(O_WRONLY) and every figure below measures the missing decoder instead of the radio.
#
#   extended-test.sh <config> <minutes> [sample_seconds]
#
set -u
CONF=${1:?usage: extended-test.sh <config> <minutes> [sample_seconds]}
MINS=${2:-15}
STEP=${3:-30}
SECS=$((MINS*60))
STAMP=$(date +%Y%m%d-%H%M%S)
NAME=extended-$STAMP
DIR=$HOME/ogn-captures/$NAME
BIN=${BIN:-$HOME/projects/RSPduo/ogn-rf/ogn-rf}

mkdir -p "$DIR"
LOG=$DIR/ogn-rf.log
CSV=$DIR/samples.csv
SUM=$DIR/summary.txt

# --- pre-flight -------------------------------------------------------------------------------
{
  echo "=== extended soak test $STAMP ==="
  echo "config   : $CONF"
  echo "duration : ${MINS} min, sampled every ${STEP} s"
  echo "host     : $(hostname), $(uptime | sed 's/^ *//')"
  echo "daemon   : $(systemctl is-active sdrplay.service 2>/dev/null) (pid $(pidof sdrplay_apiService 2>/dev/null))"
  echo "device   : $(lsusb | grep -i 1df7 || echo MISSING)"
  echo "binary   : $BIN"
  grep -E '^ *(DualTuner|SelectionDiversity|SampleRate|Gain) ' "$CONF" | sed 's/^ */  cfg: /'
} > "$SUM" 2>&1

# Refuse to start on top of another ogn-rf: two harnesses that each kill "ogn-rf" at teardown
# will kill each other's receiver, which is exactly what happened the first time this ran.
if pgrep -x ogn-rf >/dev/null; then
  echo "another ogn-rf is already running (pid $(pgrep -x ogn-rf | tr '\n' ' ')) - stop it first" >&2
  exit 1
fi
sleep 1
cd "$DIR" || exit 1
rm -f ogn-rf.fifo "$LOG"

# stdin has to stay open for the whole run: ogn-rf exits the moment it reaches EOF. Keep the
# feeder's pid so teardown does not have to sit through the rest of its sleep.
( sleep $((SECS+120)) | stdbuf -oL -eL "$BIN" "$CONF" > "$LOG" 2>&1 ) &
RUNNER=$!
FEEDER=$(pgrep -P $RUNNER -x sleep | head -1)

for _ in $(seq 1 120); do [ -p ogn-rf.fifo ] && break; sleep 0.5; done
cat ogn-rf.fifo > "$DIR/fifo.bin" &
READER=$!
sleep 5

PID=$(pgrep -x ogn-rf | head -1)
echo "process  : pid ${PID:-NONE}" >> "$SUM"

echo "t_s,live_time_pct,overrun_a,overrun_b,div_a,div_b,div_switches,fifo_MB,cpu_pct,rss_MB,threads" > "$CSV"

# --- sampling loop ----------------------------------------------------------------------------
START=$(date +%s)
END=$((START+SECS))
PREV_CPU=0
while [ "$(date +%s)" -lt "$END" ]; do
  sleep "$STEP"
  NOW=$(( $(date +%s) - START ))
  PAGE=$(curl -s --max-time 4 http://127.0.0.1:8095/ | sed -e 's/<[^>]*>/ /g')

  LT=$(   echo "$PAGE" | awk '/Live Time/{print $NF}' | tr -d '% ')
  # Row is "Ring overruns A / B   0 / 0": the counts are the 6th and 8th tokens, not the 5th and
  # 7th (those are the "B" label and a slash - which is how this silently recorded "B/0" once).
  OV=$(   echo "$PAGE" | awk '/Ring overruns/{print $6"/"$8}')
  OA=$(   echo "${OV%%/*}")
  OB=$(   echo "${OV##*/}")
  # The row reads "Selection diversity A 18 / B 0, 0 switches": take the number after the A,
  # the number after the B, and the number before "switches".
  DA=$(   echo "$PAGE" | awk '/Selection diversity/{for(i=1;i<=NF;i++) if($i=="A") a=$(i+1)} END{print a}')
  DB=$(   echo "$PAGE" | awk '/Selection diversity/{for(i=1;i<=NF;i++) if($i=="B") b=$(i+1)} END{print b}' | tr -d ',')
  SW=$(   echo "$PAGE" | awk '/Selection diversity/{for(i=1;i<=NF;i++) if($i=="switches") s=$(i-1)} END{print s}')
  MB=$(   awk -v b="$(stat -c%s "$DIR/fifo.bin" 2>/dev/null || echo 0)" 'BEGIN{printf "%.1f", b/1048576}')
  if [ -n "${PID:-}" ] && [ -d "/proc/$PID" ]; then
    CPU=$(awk '{print $14+$15}' "/proc/$PID/stat")
    RSS=$(awk '/VmRSS/{print $2}' "/proc/$PID/status")
    THR=$(awk '/^Threads/{print $2}' "/proc/$PID/status")
    CPUPC=$(awk -v c="$CPU" -v p="$PREV_CPU" -v s="$STEP" 'BEGIN{printf "%.1f", 100.0*(c-p)/100.0/s}')
    PREV_CPU=$CPU
    RSSMB=$(awk -v k="$RSS" 'BEGIN{printf "%.1f", k/1024}')
  else
    CPUPC=NA; RSSMB=NA; THR=NA
  fi
  echo "$NOW,${LT:-NA},${OA:-NA},${OB:-NA},${DA:-NA},${DB:-NA},${SW:-NA},$MB,${CPUPC:-NA},${RSSMB:-NA},${THR:-NA}" >> "$CSV"
  printf '  t=%4ds  LiveTime=%-6s overruns=%s/%s  div=%s/%s(%s sw)  fifo=%sMB  cpu=%s%%  rss=%sMB\n' \
    "$NOW" "${LT:-NA}" "${OA:-NA}" "${OB:-NA}" "${DA:-NA}" "${DB:-NA}" "${SW:-NA}" "$MB" "${CPUPC:-NA}" "${RSSMB:-NA}"
done

# --- teardown and summary ---------------------------------------------------------------------
# Kill only what this run started, by pid, so a harness sharing the host cannot take out someone
# else's receiver.
kill $READER 2>/dev/null
[ -n "${FEEDER:-}" ] && kill "$FEEDER" 2>/dev/null
[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
wait $RUNNER 2>/dev/null

{
  echo
  echo "--- samples ---"
  cat "$CSV"
  echo
  echo "--- Live Time over the run ---"
  awk -F, 'NR>1 && $2!="NA"{n++; s+=$2; if(min==""||$2<min)min=$2; if($2>max)max=$2}
           END{printf "  samples=%d  mean=%.1f%%  min=%.1f%%  max=%.1f%%\n", n, s/n, min, max}' "$CSV"
  echo "--- ring overruns (first sample -> last sample) ---"
  awk -F, 'NR==2{fa=$3; fb=$4} NR>1{la=$3; lb=$4} END{printf "  tuner A: %s -> %s   tuner B: %s -> %s\n", fa, la, fb, lb}' "$CSV"
  echo "--- diversity ---"
  awk -F, 'NR>1{la=$5; lb=$6; ls=$7} END{printf "  chose A=%s B=%s switches=%s (final sample)\n", la, lb, ls}' "$CSV"
  echo "--- log counters ---"
  printf '  half_time_slot=%s  dropped_slot=%s  adc_overload_detected=%s  adc_overload_corrected=%s\n' \
    "$(grep -c 'Half time slot' "$LOG")" "$(grep -c 'Dropped a slot' "$LOG")" \
    "$(grep -c 'overload detected' "$LOG")" "$(grep -c 'overload corrected' "$LOG")"
  echo "--- errors / faults in the log (should be empty) ---"
  grep -nE 'failed|failure|removed|Cannot|cannot|Error|error|ServiceNotResponding' "$LOG" | head -10
  echo "--- device still present? ---"
  lsusb | grep -i 1df7 || echo "  DEVICE GONE"
  echo "--- fifo volume ---"
  awk -v b="$(stat -c%s "$DIR/fifo.bin" 2>/dev/null || echo 0)" 'BEGIN{printf "  %.1f MB in %d s = %.2f MB/s\n", b/1048576, '"$SECS"', b/1048576/'"$SECS"'}' 
  echo "--- first 8 log lines ---"
  head -8 "$LOG" | sed 's/^/  /'
} >> "$SUM" 2>&1

echo
echo "results in $DIR"
cat "$SUM"
