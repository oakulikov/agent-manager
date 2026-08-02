#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    create)
        printf '%s\n' "${FAKE_WORKSPACE:?}"
        ;;
    remove)
        touch "${ROLLBACK_MARKER:?}"
        ;;
    *)
        printf 'Unexpected fake workspace operation: %s\n' "${1:-}" >&2
        exit 2
        ;;
esac
