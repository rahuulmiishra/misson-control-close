#!/bin/bash
# Builds the AX discovery probe. Run ./build-probe.sh then ./probe/probe [depth]
set -e
cd "$(dirname "$0")"
swiftc -O probe/probe.swift -o probe/probe \
  -framework ApplicationServices -framework AppKit
echo "Built probe/probe"
