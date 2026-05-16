#!/bin/bash
# build script for wayland overlay apps
# Usage:
#   ./build.sh [app] [mode]
#   app:  neko (default), or any directory with a main.odin
#   mode: build (default), debug, run, clean
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP="${1:-neko}"
MODE="${2:-build}"

# If only one arg and it looks like a mode, treat it as mode with default app
case "$APP" in
    build|debug|run|clean)
        MODE="$APP"
        APP="neko"
        ;;
esac

if [ ! -d "$APP" ]; then
    echo "error: app directory '$APP' not found"
    echo "available apps:"
    for d in */; do
        [ -f "$d/main.odin" ] && echo "  ${d%/}"
    done
    exit 1
fi

OUT="bin/$APP"
mkdir -p bin

case "$MODE" in
    build)
        echo "building $APP..."
        odin build "$APP/" \
            -out:"$OUT" \
            -o:speed
        echo "done → ./$OUT"
        ;;
    debug)
        echo "building $APP (debug)..."
        odin build "$APP/" \
            -out:"$OUT" \
            -debug
        echo "done → ./$OUT (debug)"
        ;;
    run)
        "$0" "$APP" build
        echo ""
        ./"$OUT"
        ;;
    clean)
        rm -f "$OUT"
        echo "cleaned $APP."
        ;;
    *)
        echo "usage: $0 [app] {build|debug|run|clean}"
        echo "       $0 neko build"
        echo "       $0 neko run"
        exit 1
        ;;
esac
