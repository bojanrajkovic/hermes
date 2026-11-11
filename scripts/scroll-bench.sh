#!/bin/bash
# usage: bench.sh <name>  — records a time profile while the in-app scroll benchmark runs
S="${TMPDIR:-/tmp}"
PID=$(pgrep -f "Hermes.app/Contents/MacOS/Hermes")
rm -rf $S/$1.trace $S/bench.txt
(xcrun xctrace record --template 'Time Profiler' --attach $PID --time-limit 9s --output $S/$1.trace >/dev/null 2>&1 &)
sleep 2
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.coderinserepeat.hermes.scrollBenchmark", $(), $(), true)' >/dev/null
sleep 11
cat $S/bench.txt
xcrun xctrace export --input $S/$1.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > $S/$1.xml 2>/dev/null
grep -c "<row>" $S/$1.xml
