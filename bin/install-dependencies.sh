#!/bin/sh
set -eu

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

if [ "$(uname -s)" = "Darwin" ]; then
  DISTRO=darwin
elif [ -f /etc/debian_version ]; then
  DISTRO=debian
elif [ -f /etc/arch-release ]; then
  DISTRO=arch
elif [ -f /etc/os-release ]; then
  case "${ID:-}" in
    fedora)
      DISTRO=fedora
      ;;
    rhel|centos|rocky|almalinux|ol)
      DISTRO=rhel
      ;;
    *)
      case " ${ID_LIKE:-} " in
        *" rhel "*|*" fedora "*)
          DISTRO=rhel
          ;;
      esac
      ;;
  esac
elif [ -f /etc/redhat-release ]; then
  DISTRO=rhel
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

have() {
  command -v "$1" >/dev/null 2>&1
}

el_major() {
  major="${VERSION_ID:-}"
  major="${major%%.*}"

  if [ -z "$major" ] && have rpm; then
    major="$(rpm -E '%{?rhel}' 2>/dev/null || true)"
  fi

  printf '%s' "$major"
}

fix_centos_7_repos() {
  # Official CentOS 7 reached EOL and the old mirrorlist endpoints may no longer work.
  # Keep this best-effort and only rewrite classic CentOS 7 repo files.
  if [ "${ID:-}" = "centos" ] && [ "$(el_major)" = "7" ]; then
    for repo in /etc/yum.repos.d/CentOS-*.repo; do
      [ -f "$repo" ] || continue
      $SUDO sed -i \
        -e 's/^mirrorlist=/#mirrorlist=/g' \
        -e 's|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=http://vault.centos.org/7.9.2009|g' \
        -e 's|^#baseurl=http://mirror.centos.org/centos/$releasever|baseurl=http://vault.centos.org/7.9.2009|g' \
        "$repo" || true
    done
  fi
}

pm_install() {
  if have dnf; then
    $SUDO dnf install -y --allowerasing --nobest "$@"
  elif have yum; then
    $SUDO yum install -y "$@"
  else
    echo "No supported RHEL package manager found"
    exit 1
  fi
}

pm_group_install() {
  if have dnf; then
    $SUDO dnf group install -y --allowerasing --nobest "$@"
  elif have yum; then
    $SUDO yum groupinstall -y "$@"
  else
    echo "No supported RHEL package manager found"
    exit 1
  fi
}

pm_install_optional() {
  pm_install "$@" || true
}

pm_install_any() {
  for pkg in "$@"; do
    if pm_install "$pkg"; then
      return 0
    fi
  done

  echo "Unable to install any of: $*"
  return 1
}

version_at_least() {
  current="$1"
  required="$2"

  current_major="${current%%.*}"
  current_rest="${current#*.}"
  current_minor="${current_rest%%.*}"
  current_patch="${current_rest#*.}"
  [ "$current_patch" != "$current_rest" ] || current_patch=0

  required_major="${required%%.*}"
  required_rest="${required#*.}"
  required_minor="${required_rest%%.*}"
  required_patch="${required_rest#*.}"
  [ "$required_patch" != "$required_rest" ] || required_patch=0

  current_major="${current_major:-0}"
  current_minor="${current_minor:-0}"
  current_patch="${current_patch:-0}"
  required_major="${required_major:-0}"
  required_minor="${required_minor:-0}"
  required_patch="${required_patch:-0}"

  [ "$current_major" -gt "$required_major" ] && return 0
  [ "$current_major" -lt "$required_major" ] && return 1
  [ "$current_minor" -gt "$required_minor" ] && return 0
  [ "$current_minor" -lt "$required_minor" ] && return 1
  [ "$current_patch" -ge "$required_patch" ]
}

re2c_version() {
  if ! have re2c; then
    return 1
  fi

  re2c --version 2>/dev/null | sed -n 's/^re2c[[:space:]]*//p' | awk '{print $1}'
}

ensure_re2c() {
  required="1.0.3"
  current="$(re2c_version || true)"

  if [ -n "$current" ] && version_at_least "$current" "$required"; then
    return 0
  fi

  case "$DISTRO" in
    rhel)
      case "$(el_major)" in
        7|8)
          ;;
        *)
          echo "re2c $required or newer is required, but found ${current:-none}"
          return 1
          ;;
      esac
      ;;
    *)
      echo "re2c $required or newer is required, but found ${current:-none}"
      return 1
      ;;
  esac

  re2c_source_version="1.3"
  tmp_dir="$(mktemp -d)"

  echo "Installing re2c ${re2c_source_version} from source because ${current:-no packaged re2c} is too old for PHP 8.3+"

  (
    cd "$tmp_dir"
    curl -fsSL "https://github.com/skvadrik/re2c/releases/download/${re2c_source_version}/re2c-${re2c_source_version}.tar.xz" -o re2c.tar.xz
    tar -xJf re2c.tar.xz --strip-components=1
    ./configure
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
    $SUDO make install
  )

  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true

  current="$(re2c_version || true)"
  if [ -z "$current" ] || ! version_at_least "$current" "$required"; then
    echo "Failed to install re2c $required or newer"
    return 1
  fi
}

enable_rhel_repo() {
  repo="$1"

  if have dnf; then
    $SUDO dnf config-manager --set-enabled "$repo" >/dev/null 2>&1 || \
      $SUDO dnf config-manager --enable "$repo" >/dev/null 2>&1 || true
  elif have yum-config-manager; then
    $SUDO yum-config-manager --enable "$repo" >/dev/null 2>&1 || true
  fi
}

enable_rhel_repositories() {
  major="$(el_major)"

  fix_centos_7_repos

  if have dnf; then
    pm_install_optional dnf-plugins-core
  elif have yum; then
    pm_install_optional yum-utils
  fi

  case "$major" in
    7)
      pm_install_optional epel-release
      pm_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm"
      ;;
    8)
      enable_rhel_repo powertools
      enable_rhel_repo PowerTools
      enable_rhel_repo crb
      pm_install_optional epel-release
      pm_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
      case "${ID:-}" in
        centos)
          pm_install_optional "https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-8.noarch.rpm"
          ;;
      esac
      ;;
    9)
      enable_rhel_repo crb
      pm_install_optional epel-release
      pm_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
      case "${ID:-}" in
        centos)
          pm_install_optional "https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm"
          ;;
      esac
      ;;
    10)
      enable_rhel_repo crb
      pm_install_optional epel-release
      pm_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"
      ;;
    *)
      enable_rhel_repo crb
      enable_rhel_repo powertools
      enable_rhel_repo PowerTools
      pm_install_optional epel-release
      ;;
  esac

  if have crb; then
    $SUDO crb enable >/dev/null 2>&1 || true
  fi

  case "$major" in
    8)
      enable_rhel_repo powertools
      enable_rhel_repo PowerTools
      enable_rhel_repo crb
      ;;
    9|10)
      enable_rhel_repo crb
      ;;
  esac
}

install_rhel_dependencies() {
  enable_rhel_repositories

  pm_install_optional ca-certificates curl git tar gzip xz unzip findutils which sudo

  pm_group_install "Development Tools" || \
    pm_install gcc gcc-c++ make patch diffutils file redhat-rpm-config

  pm_install \
    autoconf bison re2c gawk \
    libxml2-devel openssl-devel libicu-devel zlib-devel oniguruma-devel \
    libcurl-devel libpng-devel libjpeg-turbo-devel freetype-devel \
    libwebp-devel gmp-devel readline-devel bzip2-devel \
    sqlite-devel gd-devel gettext-devel

  pm_install_any pkgconf-pkg-config pkgconfig

  # CentOS/RHEL 7 commonly ships a libzip version that is too old for modern PHP.
  # Do not install it automatically there; PHP can still be configured without zip support.
  if [ "$(el_major)" != "7" ]; then
    pm_install_optional libzip-devel
  fi

  pm_install_optional libsodium-devel
  pm_install_optional libxcrypt-devel
  pm_install_optional libpq-devel
  pm_install_optional postgresql-devel

  ensure_re2c
}

case "$DISTRO" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -q
    $SUDO apt-get install -q -y --no-install-recommends \
      ca-certificates curl git tar gzip xz-utils unzip \
      build-essential autoconf bison re2c pkg-config \
      libxml2-dev libssl-dev libicu-dev zlib1g-dev libzip-dev libonig-dev \
      libcurl4-openssl-dev libpng-dev libjpeg-dev libfreetype6-dev \
      libwebp-dev libgmp-dev libsodium-dev libreadline-dev libbz2-dev \
      libsqlite3-dev libgd-dev libpq-dev gettext
    ;;
  fedora)
    $SUDO dnf install -y --allowerasing --nobest \
      @development-tools \
      @c-development \
      ca-certificates curl git tar gzip xz unzip findutils which \
      gawk \
      autoconf bison re2c pkgconf-pkg-config \
      libxml2-devel openssl-devel libicu-devel zlib-devel libzip-devel oniguruma-devel \
      libcurl-devel libpng-devel libjpeg-turbo-devel freetype-devel \
      libwebp-devel gmp-devel libsodium-devel readline-devel bzip2-devel \
      sqlite-devel gd-devel libpq-devel gettext-devel libxcrypt-devel
    ;;
  rhel)
    install_rhel_dependencies
    ;;
  arch)
    $SUDO pacman -Sy --noconfirm --needed \
      ca-certificates curl git tar gzip xz unzip which \
      base-devel autoconf bison re2c pkgconf \
      libxml2 openssl icu zlib libzip oniguruma \
      curl libpng libjpeg-turbo freetype2 \
      libwebp gmp libsodium readline bzip2 \
      sqlite gd postgresql-libs gettext libxcrypt
    ;;
  darwin)
    xcode-select --install 2>/dev/null || true
    brew install autoconf bison re2c pkg-config \
      libxml2 openssl@3 icu4c zlib libzip oniguruma \
      freetype jpeg libpng webp gmp libsodium libiconv readline bzip2 \
      sqlite gd libpq gettext
    ;;
esac
