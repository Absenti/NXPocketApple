#!/bin/bash
# Prints the UDID of an available iPhone simulator on the newest iOS runtime of the runner.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    match = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
    return (int(match[1]), int(match[2])) if match else None
runtimes = sorted((r for r in devices if version(r) and devices[r]), key=version)
for runtime in reversed(runtimes):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[-1]["udid"])
        break
else:
    sys.exit("no iPhone simulator")
'
