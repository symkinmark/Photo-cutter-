#!/bin/bash
# Runs all tests. Needs lua5.1 and python3 with numpy + Pillow.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for f in HalfFrameSplitter.lrplugin/*.lua tests/*.lua; do luac5.1 -p "$f"; done
python3 tests/gen_fixtures.py
rm -rf tests/fixtures/flow
lua5.1 tests/run_tests.lua
lua5.1 tests/run_plugin_test.lua
