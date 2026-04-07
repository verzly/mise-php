#!/bin/sh
set -eu

if [ -f /etc/os-release ]; then
	. /etc/os-release
fi

if [ -f /etc/debian_version ]; then
	DISTRO=debian
elif [ -f /etc/redhat-release ]; then
	DISTRO=rhel
elif [ "$(uname -s)" = "Darwin" ]; then
	DISTRO=darwin
else
	echo "Unsupported operating system"
	exit 1
fi

if command -v sudo; then
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
			libsqlite3-dev libgd-dev
		;;
	rhel)
		$SUDO dnf install -y yum-utils epel-release

		case "${VERSION_ID:-}" in
			8*)
				$SUDO dnf install -y libmcrypt-devel
				;;
			9*)
				$SUDO dnf install -y libmcrypt-devel
				;;
			*)
				$SUDO dnf install -y libsodium-devel
				;;
		esac

		$SUDO dnf groupinstall -y "Development Tools"
		$SUDO dnf install -y \
			autoconf bison re2c pkgconfig \
			libxml2-devel openssl-devel libicu-devel libzip-devel oniguruma-devel \
			libcurl-devel libpng-devel libjpeg-devel freetype-devel \
			libwebp-devel gmp-devel readline-devel bzip2-devel \
			sqlite-devel gd-devel
		;;
	darwin)
		xcode-select --install 2>/dev/null || true
		brew install autoconf bison re2c pkg-config \
			libxml2 openssl@3 icu4c zlib libzip oniguruma \
			freetype jpeg libpng webp gmp libsodium readline bzip2 \
			sqlite gd
		;;
esac
