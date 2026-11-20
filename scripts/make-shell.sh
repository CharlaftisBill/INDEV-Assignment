#!/bin/bash
# Recipe shell for the Makefile. GNU make 3.81 (macOS) ignores .SHELLFLAGS, so the strict
# flags live here and apply on every make version.
exec /bin/bash -eu -o pipefail "$@"
