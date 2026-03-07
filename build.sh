#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/ClaudeSidebar.app"
echo "Building Claude Sidebar..."
swiftc -O -o "$APP/Contents/MacOS/ClaudeSidebar" \
    -framework AppKit \
    -target arm64-apple-macos13.0 \
    "$DIR/main.swift" \
    "$DIR"/Sources/*.swift
echo "Built: $APP"
echo "Run:   open $APP"
