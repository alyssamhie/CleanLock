#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p CleanLock.app/Contents/MacOS
cp Info.plist CleanLock.app/Contents/Info.plist
swiftc -O -swift-version 5 main.swift -o CleanLock.app/Contents/MacOS/CleanLock
codesign --force --sign - CleanLock.app
echo "Built $(pwd)/CleanLock.app"
