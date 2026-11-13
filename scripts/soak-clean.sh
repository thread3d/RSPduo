#!/bin/bash
# Stop every extended-test harness, FIFO reader and receiver left behind by one.
#
# Careful: a shell whose command line merely *mentions* this script's targets (for instance the
# shell that is about to start one) matches the same patterns, so a naive pkill -f kills its own
# caller - which is exactly what happened once, ending an ssh session with no error message worth
# having. So walk up the ancestor chain first and never signal ourselves or anything above us.
set -u

skip=" $$ "
p=$PPID
while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
  skip="$skip$p "
  p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
done

kill_matching() {   # $1 = pgrep pattern
  for p in $(pgrep -f "$1" 2>/dev/null); do
    case "$skip" in *" $p "*) continue;; esac
    kill "$p" 2>/dev/null
  done
}

kill_matching 'bash .*ogn-captures/extended-test\.sh'
kill_matching 'cat .*ogn-rf\.fifo'
kill_matching 'overload-variant\.sh'

# The receiver itself: only an ogn-rf that is not an ancestor (it never is) is a leftover.
for p in $(pgrep -x ogn-rf 2>/dev/null); do
  case "$skip" in *" $p "*) continue;; esac
  kill "$p" 2>/dev/null
done

sleep 1
echo "remaining: harness=$(pgrep -c -f 'bash .*ogn-captures/extended-test\.sh') fifo_readers=$(pgrep -c -f 'cat .*ogn-rf\.fifo') ogn-rf=$(pgrep -cx ogn-rf)"
