#!/bin/sh
set -eu

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

if [ -f /etc/debian_version ]; then
  DISTRO=debian
elif [ -f /etc/arch-release ]; then
  DISTRO=arch
elif [ -f /etc/os-release ]; then
  case "${ID:-}" in
    fedora)
      DISTRO=fedora
      ;;
    rhel|centos|rocky|almalinux)
      DISTRO=rhel
      ;;
    *)
      if [ -f /etc/redhat-release ]; then
        DISTRO=rhel
      fi
      ;;
  esac
elif [ "$(uname -s)" = "Darwin" ]; then
  DISTRO=darwin
fi

if [ -z "${DISTRO:-}" ]; then
  echo "Unsupported operating system"
  exit 1
fi

if command -v sudo > /dev/null 2>&1; then
  SUDO=sudo
else
  SUDO=
fi

case "$DISTRO" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -q
    $SUDO apt-get install -q -y --no-install-recommends \
      build-essential autoconf bison re2c pkg-config \
      libxml2-dev libssl-dev libicu-dev libzip-dev libonig-dev \
      libcurl4-openssl-dev libpng-dev libjpeg-dev libfreetype6-dev \
      libwebp-dev libgmp-dev libsodium-dev libreadline-dev libbz2-dev \
      libsqlite3-dev libgd-dev libhiredis-dev
    ;;
  fedora)
    $SUDO dnf install -y --skip-unavailable \
      @development-tools \
      @c-development \
      gawk \
      autoconf bison re2c \
      libxml2-devel openssl-devel libicu-devel libzip-devel oniguruma-devel \
      libcurl-devel libpng-devel libjpeg-devel freetype-devel \
      libwebp-devel gmp-devel libsodium-devel readline-devel bzip2-devel \
      sqlite-devel gd-devel hiredis-devel
    ;;
  rhel)
    case "${VERSION_ID:-}" in
      10*)
        # libsodium available in base repo on RHEL/Rocky/Alma 10+
        ;;
      *)
        # RHEL/Rocky/Alma 8 and 9 need EPEL for libsodium
        $SUDO dnf install -y yum-utils epel-release
        ;;
    esac

    $SUDO dnf install -y @"Development Tools" \
      autoconf bison re2c pkgconfig \
      libxml2-devel openssl-devel libicu-devel libzip-devel oniguruma-devel \
      libcurl-devel libpng-devel libjpeg-devel freetype-devel \
      libwebp-devel gmp-devel libsodium-devel readline-devel bzip2-devel \
      sqlite-devel gd-devel hiredis-devel
    ;;
  arch)
    $SUDO pacman -Sy --noconfirm --needed \
      base-devel autoconf bison re2c pkgconf \
      libxml2 openssl icu libzip oniguruma \
      curl libpng libjpeg-turbo freetype2 \
      libwebp gmp libsodium readline bzip2 \
      sqlite gd hiredis
    ;;
  darwin)
    xcode-select --install 2>/dev/null || true
    brew install autoconf bison re2c pkg-config \
      libxml2 openssl@3 icu4c zlib libzip oniguruma \
      freetype jpeg libpng webp gmp libsodium readline bzip2 \
      sqlite gd hiredis
    ;;
esac
