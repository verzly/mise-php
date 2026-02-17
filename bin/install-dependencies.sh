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

# NOTES:
#   * --with-libedit can be used to replace libreadline-dev with libedit-dev
#   * libcurl4-openssl-dev may be used with PHP 5.6 or higher, but it will conflict
#     with custom openssl 1.0.2 builds required for PHP 5.5 and lower.

case $DISTRO in
	debian)
		export DEBIAN_FRONTEND=nointeractive
    $SUDO apt-get install -q -y --no-install-recommends build-essential autoconf bison re2c pkg-config \
      libxml2-dev libssl-dev libicu-dev libzip-dev libonig-dev \
      libcurl4-openssl-dev libpng-dev libjpeg-dev libfreetype6-dev \
      libwebp-dev libgmp-dev libsodium-dev libreadline-dev libbz2-dev
    ;;
	rhel)
		$SUDO dnf install -y yum-utils epel-release
		if [[ "$VERSION_ID" =~ ^8 ]]; then
			# $SUDO dnf config-manager --set-enabled powertools
			# libmcrypt official
			$SUDO dnf install -y libmcrypt-devel
		elif [[ "$VERSION_ID" =~ ^9 ]]; then
			# $SUDO dnf config-manager --set-enabled crb
			# libmcrypt official
			$SUDO dnf install -y libmcrypt-devel
		else
			# $SUDO dnf config-manager --set-enabled crb
			# libmcrypt alternative from rhel 10 # https://stackoverflow.com/questions/41272257/mcrypt-is-deprecated-what-is-the-alternative
			$SUDO dnf install -y libsodium-devel
		fi
		$SUDO dnf groupinstall "Development Tools"
    $SUDO dnf install autoconf bison re2c pkgconfig \
      libxml2-devel openssl-devel libicu-devel libzip-devel oniguruma-devel \
      libcurl-devel libpng-devel libjpeg-devel freetype-devel \
      libwebp-devel gmp-devel readline-devel bzip2-devel # libsodium-devel
		;;
	darwin)
		# brew install will fail if a package is already installed
		# using brew bundle seems to be the recommended alternative
		# https://github.com/Homebrew/brew/issues/2491
		xcode-select --install
    brew install autoconf bison re2c pkg-config \
        libxml2 openssl@3 icu4c zlib libzip oniguruma \
        freetype jpeg libpng webp gmp libsodium readline bzip2
		;;
	*)
esac
