#!/usr/bin/env bash
set -e

# Ensure the application logs directory exists and is owned by appuser
if [ -d /app ]; then
    mkdir -p /app/logs
    chown -R appuser:appuser /app/logs
fi

# If we're root, drop privileges to appuser for the actual command
if [ "$(id -u)" = "0" ]; then
    exec gosu appuser "$@"
fi

exec "$@"
