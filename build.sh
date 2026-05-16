#!/bin/bash
# neko build script
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

case "${1:-build}" in
    build)
        echo "building neko..."
        odin build src/ \
            -out:neko \
            -o:speed
        echo "done → ./neko"
        ;;
    debug)
        echo "building neko (debug)..."
        odin build src/ \
            -out:neko \
            -debug
        echo "done → ./neko (debug)"
        ;;
    run)
        "$0" build
        echo ""
        ./neko
        ;;
    clean)
        rm -f neko
        echo "cleaned."
        ;;
    *)
        echo "usage: $0 {build|debug|run|clean}"
        exit 1
        ;;
esac
