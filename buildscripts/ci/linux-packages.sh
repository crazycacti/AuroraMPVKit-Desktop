#!/bin/bash
set -euo pipefail

meson_version=${MESON_VERSION:-1.12.1}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	build-essential binutils file git curl ca-certificates xz-utils bzip2 \
	pkg-config nasm ninja-build cmake gperf python3 python3-pip patchelf \
	libva-dev libdrm-dev libegl-dev libgl-dev libpulse-dev libasound2-dev \
	libfontconfig-dev zlib1g-dev hwdata
python3 -m pip install --no-cache-dir "meson==$meson_version"
