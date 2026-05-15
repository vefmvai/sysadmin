#!/bin/bash
# generate-qr.sh — генерация QR-кода для vless://-ссылки.
#
# Использует qrencode (на macOS: brew install qrencode; на Linux: apt install qrencode).
#
# Вход:
#   Аргумент 1: vless://-URI или путь к файлу с URI.
#   ENV OUTPUT_PATH: путь к PNG (default: stdout как PNG-binary).
#   ENV SIZE: размер блока пикселя (default: 8).
#   ENV MARGIN: отступ (default: 2).
#   ENV ASCII: если 1 — печатать ASCII-QR в stdout (для терминала).
#
# Выход:
#   PNG-файл по OUTPUT_PATH ИЛИ ASCII-art в stdout (если ASCII=1).

set -euo pipefail

if [ "$#" -ge 1 ]; then
    INPUT="$1"
else
    INPUT="$(cat)"
fi

# Если это путь к файлу — читаем
if [ -f "$INPUT" ]; then
    INPUT="$(cat "$INPUT")"
fi

INPUT="$(echo "$INPUT" | tr -d '[:space:]')"

if ! [[ "$INPUT" =~ ^vless:// ]]; then
    echo "ERROR: вход должен быть vless://-URI или файл с ним" >&2
    exit 1
fi

if ! command -v qrencode >/dev/null 2>&1; then
    echo "ERROR: qrencode не установлен" >&2
    echo "  macOS: brew install qrencode" >&2
    echo "  Linux (Debian/Ubuntu): apt-get install qrencode" >&2
    echo "  Linux (RHEL/Fedora): dnf install qrencode" >&2
    exit 1
fi

SIZE="${SIZE:-8}"
MARGIN="${MARGIN:-2}"

if [ "${ASCII:-0}" = "1" ]; then
    # ASCII-art в stdout
    echo "$INPUT" | qrencode -t ANSIUTF8 -m "$MARGIN"
else
    OUTPUT_PATH="${OUTPUT_PATH:-/dev/stdout}"
    echo "$INPUT" | qrencode -o "$OUTPUT_PATH" -s "$SIZE" -m "$MARGIN"
    if [ "$OUTPUT_PATH" != "/dev/stdout" ]; then
        echo "[qr] Saved: $OUTPUT_PATH" >&2
    fi
fi

exit 0
