#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BENCH_BUILD="${BENCH_BUILD_DIR:-/private/tmp/typstedit-benchmark-build}"
mkdir -p "$BENCH_BUILD/module-cache"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$BENCH_BUILD/module-cache" \
  Sources/GitDecorations.swift Sources/LineNumberRulerView.swift Sources/SyntaxHighlighter.swift Tests/Benchmark.swift -o "$BENCH_BUILD/index"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$BENCH_BUILD/module-cache" \
  Sources/SyntaxHighlighter.swift Tests/TokenBenchmark.swift -o "$BENCH_BUILD/token"
"$BENCH_BUILD/index"
python3 - "$BENCH_BUILD/token" <<'PY'
import subprocess, re, statistics, sys
samples = {'legacy': [], 'new': []}
for _ in range(5):
    for mode in samples:
        result = subprocess.run(['/usr/bin/time', '-l', sys.argv[1], mode], capture_output=True, text=True, check=True)
        elapsed = float(re.search(r'([0-9.]+) seconds', result.stdout).group(1))
        peak = int(re.search(r'(\d+)\s+maximum resident set size', result.stderr).group(1)) / 1048576
        samples[mode].append((elapsed, peak))
for mode, results in samples.items():
    print(f'{mode}: 100k-line tokenization median {statistics.median(x[0] for x in results)*1000:.1f} ms; '
          f'isolated process peak RSS median {statistics.median(x[1] for x in results):.1f} MiB (5 samples)')
PY
