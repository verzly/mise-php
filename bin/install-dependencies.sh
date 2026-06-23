#!/bin/sh
set -eu

# Install native system dependencies required by mise-php source builds.
#
# This script intentionally keeps the dependency logic close to the source build
# logic used by lib/source_php.lua. The goal is not to install every package that
# could ever be used by PHP. The goal is to install the packages needed for:
#
# 1. The default mise-php source build configuration
# 2. The requested PHP version
# 3. User-provided configure flags
# 4. Requested PECL or PIE extension packages with known native dependencies
#
# Important design rules:
#
# - Default source builds should work on common developer and CI systems without
#   making the user discover low-level package names manually.
# - Distribution packages are preferred whenever they are new enough.
# - Source-built build tools are used only as a compatibility fallback for older
#   enterprise distributions, for example re2c on EL7/EL8 when building PHP 8.3+.
# - Optional native libraries are installed only when mise-php enables the matching
#   PHP feature by default, the user asks for a configure flag, or a requested
#   PECL/PIE extension is known to require that library.
# - RHEL-compatible systems are handled by major version because EL7, EL8, EL9,
#   and EL10 differ in repository layout, package versions, and EPEL/CRB handling.
#
# Environment variables read by this script:
#
#   PHP_BUILD_VERSION
#     PHP version being built. The plugin passes this automatically. Used for
#     version-specific decisions such as PHP 8.3+ requiring re2c >= 1.0.3.
#
#   PHP_CONFIGURE_OPTIONS / PHP_EXTRA_CONFIGURE_OPTIONS
#     User-provided configure flags. These are scanned so native dependencies are
#     installed only when the user asks for the matching PHP feature.
#
#   PHP_PECL_EXTENSIONS / PHP_PIE_EXTENSIONS
#     Requested extension packages. These are scanned for known packages that need
#     extra native libraries, such as imagick, yaml, memcached, amqp, rdkafka, or
#     ext-uv.

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

numeric_component() {
  printf '%s' "${1:-0}" | sed 's/[^0-9].*$//' | sed 's/^$/0/'
}

version_component() {
  value="${1:-0}"
  index="$2"
  IFS=.
  set -- $value
  unset IFS

  case "$index" in
    1) numeric_component "${1:-0}" ;;
    2) numeric_component "${2:-0}" ;;
    3) numeric_component "${3:-0}" ;;
    *) printf '0' ;;
  esac
}

version_at_least() {
  current="$1"
  required="$2"

  current_major="$(version_component "$current" 1)"
  current_minor="$(version_component "$current" 2)"
  current_patch="$(version_component "$current" 3)"

  required_major="$(version_component "$required" 1)"
  required_minor="$(version_component "$required" 2)"
  required_patch="$(version_component "$required" 3)"

  [ "$current_major" -gt "$required_major" ] && return 0
  [ "$current_major" -lt "$required_major" ] && return 1
  [ "$current_minor" -gt "$required_minor" ] && return 0
  [ "$current_minor" -lt "$required_minor" ] && return 1
  [ "$current_patch" -ge "$required_patch" ]
}

php_version_at_least() {
  [ -n "${PHP_BUILD_VERSION:-}" ] || return 0
  version_at_least "$PHP_BUILD_VERSION" "$1"
}

php_version_before() {
  [ -n "${PHP_BUILD_VERSION:-}" ] || return 1
  ! version_at_least "$PHP_BUILD_VERSION" "$1"
}

requested_configure_options() {
  printf '%s %s' "${PHP_CONFIGURE_OPTIONS:-}" "${PHP_EXTRA_CONFIGURE_OPTIONS:-}"
}

requested_extensions() {
  printf '%s %s' "${PHP_PECL_EXTENSIONS:-}" "${PHP_PIE_EXTENSIONS:-}" |
    tr ',;' '  ' |
    tr '[:upper:]' '[:lower:]'
}

configure_requests() {
  options="$(requested_configure_options)"

  for flag in "$@"; do
    case " $options " in
      *"$flag"*) return 0 ;;
    esac
  done

  return 1
}

extension_uses_group() {
  group="$1"
  extensions="$(requested_extensions)"

  for ext in $extensions; do
    case "$group:$ext" in
      amqp:*amqp*) return 0 ;;
      imagick:*imagick*|imagick:*imagemagick*) return 0 ;;
      memcached:*memcached*) return 0 ;;
      rdkafka:*rdkafka*|rdkafka:*kafka*) return 0 ;;
      uv:*ext-uv*|uv:*uv) return 0 ;;
      yaml:*yaml*) return 0 ;;
    esac
  done

  return 1
}

# Native groups enabled by the default mise-php source build when the matching
# library is available. These are installed by default because lib/source_php.lua
# either enables the feature explicitly or probes for it before adding the flag.
source_build_uses_group_by_default() {
  case "$1" in
    bz2|gd|gmp|pgsql|sodium|zip)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Native groups required by PHP version behavior.
# mcrypt was removed from PHP core in PHP 7.2, so it is only relevant for older
# PHP versions or explicit custom configure flags.
php_version_uses_group() {
  group="$1"

  case "$group" in
    mcrypt)
      php_version_before 7.2
      ;;
    *)
      return 1
      ;;
  esac
}

configure_uses_group() {
  group="$1"

  case "$group" in
    bz2) configure_requests --with-bz2 ;;
    ffi) configure_requests --with-ffi ;;
    gd) configure_requests --enable-gd --with-gd --with-external-gd --with-jpeg --with-freetype --with-webp --with-xpm ;;
    gmp) configure_requests --with-gmp ;;
    imap) configure_requests --with-imap --with-imap-ssl ;;
    ldap) configure_requests --with-ldap ;;
    mcrypt) configure_requests --with-mcrypt ;;
    pgsql) configure_requests --with-pdo-pgsql --with-pgsql ;;
    snmp) configure_requests --with-snmp ;;
    sodium) configure_requests --with-sodium ;;
    tidy) configure_requests --with-tidy ;;
    xsl) configure_requests --with-xsl ;;
    zip) configure_requests --with-zip ;;
    *) return 1 ;;
  esac
}


want_group() {
  group="$1"

  source_build_uses_group_by_default "$group" && return 0
  php_version_uses_group "$group" && return 0
  configure_uses_group "$group" && return 0
  extension_uses_group "$group" && return 0

  return 1
}

install_group_note() {
  group="$1"
  if want_group "$group"; then
    log "Installing native dependency group: $group"
    return 0
  fi

  return 1
}

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

if [ "$(uname -s)" = "Darwin" ]; then
  DISTRO=darwin
elif [ -f /etc/alpine-release ]; then
  DISTRO=alpine
elif [ -f /etc/debian_version ]; then
  DISTRO=debian
elif [ -f /etc/arch-release ]; then
  DISTRO=arch
elif [ -f /etc/os-release ]; then
  case "${ID:-}" in
    fedora)
      DISTRO=fedora
      ;;
    amzn|amazonlinux)
      DISTRO=amazonlinux
      ;;
    rhel|centos|rocky|almalinux|ol|olinux)
      DISTRO=rhel
      ;;
    *)
      case " ${ID_LIKE:-} " in
        *" rhel "*|*" fedora "*) DISTRO=rhel ;;
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

if have sudo; then
  SUDO=sudo
else
  SUDO=
fi

el_major() {
  major="${VERSION_ID:-}"
  major="${major%%.*}"

  if [ -z "$major" ] && have rpm; then
    major="$(rpm -E '%{?rhel}' 2>/dev/null || true)"
  fi

  printf '%s' "$major"
}

linux_arch() {
  uname -m
}

apt_install() {
  $SUDO apt-get install -q -y --no-install-recommends "$@"
}

dnf_install() {
  $SUDO dnf install -y --allowerasing --nobest "$@"
}

microdnf_install() {
  $SUDO microdnf install -y "$@"
}

yum_install() {
  $SUDO yum install -y "$@"
}

rhel_install() {
  if have dnf; then
    dnf_install "$@"
  elif have microdnf; then
    microdnf_install "$@"
  elif have yum; then
    yum_install "$@"
  else
    echo "No supported RHEL package manager found"
    exit 1
  fi
}

rhel_group_install() {
  if have dnf; then
    $SUDO dnf group install -y --allowerasing --nobest "$@"
  elif have yum; then
    $SUDO yum groupinstall -y "$@"
  else
    return 1
  fi
}

rhel_install_optional() {
  rhel_install "$@" || true
}

rhel_install_any() {
  for pkg in "$@"; do
    if rhel_install "$pkg"; then
      return 0
    fi
  done

  echo "Unable to install any of: $*"
  return 1
}

brew_install() {
  brew install "$@"
}

pacman_install() {
  $SUDO pacman -Sy --noconfirm --needed "$@"
}

apk_install() {
  $SUDO apk add --no-cache "$@"
}

fix_centos_7_repos() {
  # CentOS Linux 7 is EOL. Classic CentOS 7 images can still appear in developer
  # or production environments, but their normal mirrorlist URLs may no longer be
  # reliable. Only for classic CentOS 7, rewrite stock repo files to the final
  # 7.9.2009 vault location before installing dependencies.
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

enable_rhel_repo() {
  repo="$1"

  if have dnf; then
    $SUDO dnf config-manager --set-enabled "$repo" >/dev/null 2>&1 || \
      $SUDO dnf config-manager --enable "$repo" >/dev/null 2>&1 || true
  fi

  if have yum-config-manager; then
    $SUDO yum-config-manager --enable "$repo" >/dev/null 2>&1 || true
  fi
}

enable_codeready_builder() {
  major="$(el_major)"
  arch="$(linux_arch)"

  # RHEL uses subscription-manager repository IDs. Community rebuilds and CentOS
  # Stream usually expose equivalent content as crb or PowerTools.
  if have subscription-manager; then
    $SUDO subscription-manager repos --enable "codeready-builder-for-rhel-${major}-${arch}-rpms" >/dev/null 2>&1 || true
    $SUDO subscription-manager repos --enable "codeready-builder-for-rhel-${major}-$(uname -m)-rpms" >/dev/null 2>&1 || true
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

  # Oracle Linux exposes the CodeReady Builder equivalent under Oracle-specific
  # repository IDs instead of the community crb/PowerTools names. Enable these
  # best-effort so Oracle Linux 8/9/10 can use the same EL-compatible package
  # groups without special-casing every dependency.
  case "${ID:-}" in
    ol|olinux)
      enable_rhel_repo "ol${major}_codeready_builder"
      enable_rhel_repo "ol${major}_developer_EPEL"
      ;;
  esac

  if have crb; then
    $SUDO crb enable >/dev/null 2>&1 || true
  fi
}

install_epel() {
  major="$(el_major)"

  case "$major" in
    7)
      rhel_install_optional epel-release
      rhel_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm"
      ;;
    8)
      rhel_install_optional epel-release
      rhel_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
      if [ "${ID:-}" = "centos" ]; then
        rhel_install_optional "https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-8.noarch.rpm"
      fi
      ;;
    9)
      rhel_install_optional epel-release
      rhel_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
      if [ "${ID:-}" = "centos" ]; then
        rhel_install_optional "https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm"
      fi
      ;;
    10)
      rhel_install_optional epel-release
      rhel_install_optional "https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"
      ;;
    *)
      rhel_install_optional epel-release
      ;;
  esac
}

enable_rhel_repositories() {
  fix_centos_7_repos

  # config-manager is required for CRB/PowerTools repository toggles.
  if have dnf; then
    rhel_install_optional dnf-plugins-core
  elif have yum; then
    rhel_install_optional yum-utils
  fi

  enable_codeready_builder
  install_epel
  enable_codeready_builder
}

re2c_version() {
  if ! have re2c; then
    return 1
  fi

  re2c --version 2>/dev/null | sed -n 's/^re2c[[:space:]]*//p' | awk '{print $1}'
}

build_re2c_from_source() {
  re2c_source_version="1.3"
  tmp_dir="$(mktemp -d)"

  log "Installing re2c ${re2c_source_version} from source because the packaged re2c is too old for PHP ${PHP_BUILD_VERSION:-unknown}"

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
}

ensure_re2c_for_php_version() {
  # PHP 8.3+ requires re2c 1.0.3 or newer. EL7/EL8 can ship older versions, so
  # install a newer re2c from source only when the requested PHP version needs it.
  php_version_at_least 8.3 || return 0

  required="1.0.3"
  current="$(re2c_version || true)"

  if [ -n "$current" ] && version_at_least "$current" "$required"; then
    return 0
  fi

  if [ "$DISTRO" = "rhel" ]; then
    case "$(el_major)" in
      7|8)
        build_re2c_from_source
        ;;
      *)
        echo "re2c $required or newer is required for PHP ${PHP_BUILD_VERSION:-unknown}, but found ${current:-none}"
        return 1
        ;;
    esac
  else
    echo "re2c $required or newer is required for PHP ${PHP_BUILD_VERSION:-unknown}, but found ${current:-none}"
    return 1
  fi

  current="$(re2c_version || true)"
  if [ -z "$current" ] || ! version_at_least "$current" "$required"; then
    echo "Failed to install re2c $required or newer"
    return 1
  fi
}

install_debian_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -q

  apt_install \
    ca-certificates curl git tar gzip xz-utils unzip \
    build-essential autoconf libtool bison re2c pkg-config gawk \
    libxml2-dev libssl-dev libicu-dev zlib1g-dev libonig-dev \
    libcurl4-openssl-dev libreadline-dev libsqlite3-dev gettext

  if install_group_note bz2; then apt_install libbz2-dev; fi
  if install_group_note gmp; then apt_install libgmp-dev; fi
  if install_group_note sodium; then apt_install libsodium-dev; fi
  if install_group_note zip; then apt_install libzip-dev; fi
  if install_group_note pgsql; then apt_install libpq-dev; fi
  if install_group_note gd; then apt_install libgd-dev libpng-dev libjpeg-dev libfreetype6-dev libwebp-dev; fi
  if install_group_note ffi; then apt_install libffi-dev; fi
  if install_group_note ldap; then apt_install libldap2-dev; fi
  if install_group_note xsl; then apt_install libxslt1-dev; fi
  if install_group_note tidy; then apt_install libtidy-dev; fi
  if install_group_note snmp; then apt_install libsnmp-dev; fi
  if install_group_note imap; then apt_install libc-client-dev libkrb5-dev; fi
  if install_group_note mcrypt; then apt_install libmcrypt-dev || warn "libmcrypt-dev is unavailable on this Debian/Ubuntu release"; fi

  if install_group_note imagick; then apt_install libmagickwand-dev; fi
  if install_group_note yaml; then apt_install libyaml-dev; fi
  if install_group_note memcached; then apt_install libmemcached-dev libsasl2-dev; fi
  if install_group_note amqp; then apt_install librabbitmq-dev; fi
  if install_group_note rdkafka; then apt_install librdkafka-dev; fi
  if install_group_note uv; then apt_install libuv1-dev; fi
}

install_fedora_dependencies() {
  dnf_install \
    @development-tools \
    @c-development \
    ca-certificates curl git tar gzip xz unzip findutils which \
    gawk autoconf libtool bison re2c pkgconf-pkg-config \
    libxml2-devel openssl-devel libicu-devel zlib-devel oniguruma-devel \
    libcurl-devel readline-devel sqlite-devel gettext-devel libxcrypt-devel

  if install_group_note bz2; then dnf_install bzip2-devel; fi
  if install_group_note gmp; then dnf_install gmp-devel; fi
  if install_group_note sodium; then dnf_install libsodium-devel; fi
  if install_group_note zip; then dnf_install libzip-devel; fi
  if install_group_note pgsql; then dnf_install libpq-devel; fi
  if install_group_note gd; then dnf_install gd-devel libpng-devel libjpeg-turbo-devel freetype-devel libwebp-devel; fi
  if install_group_note ffi; then dnf_install libffi-devel; fi
  if install_group_note ldap; then dnf_install openldap-devel; fi
  if install_group_note xsl; then dnf_install libxslt-devel; fi
  if install_group_note tidy; then dnf_install libtidy-devel; fi
  if install_group_note snmp; then dnf_install net-snmp-devel; fi
  if install_group_note imap; then dnf_install libc-client-devel krb5-devel; fi
  if install_group_note mcrypt; then dnf_install libmcrypt-devel || warn "libmcrypt-devel is unavailable on this Fedora release"; fi

  if install_group_note imagick; then dnf_install ImageMagick-devel; fi
  if install_group_note yaml; then dnf_install libyaml-devel; fi
  if install_group_note memcached; then dnf_install libmemcached-devel cyrus-sasl-devel; fi
  if install_group_note amqp; then dnf_install librabbitmq-devel; fi
  if install_group_note rdkafka; then dnf_install librdkafka-devel; fi
  if install_group_note uv; then dnf_install libuv-devel; fi
}

install_rhel_dependencies() {
  enable_rhel_repositories
  major="$(el_major)"

  rhel_install_optional ca-certificates curl git tar gzip xz unzip findutils which sudo

  rhel_group_install "Development Tools" || \
    rhel_install gcc gcc-c++ make patch diffutils file redhat-rpm-config

  rhel_install \
    autoconf libtool bison re2c gawk \
    libxml2-devel openssl-devel libicu-devel zlib-devel oniguruma-devel \
    libcurl-devel readline-devel sqlite-devel gettext-devel

  rhel_install_any pkgconf-pkg-config pkgconfig
  rhel_install_optional libxcrypt-devel

  if install_group_note bz2; then rhel_install bzip2-devel; fi
  if install_group_note gmp; then rhel_install gmp-devel; fi
  if install_group_note sodium; then rhel_install_optional libsodium-devel; fi
  if install_group_note pgsql; then rhel_install_any libpq-devel postgresql-devel; fi
  if install_group_note ffi; then rhel_install_optional libffi-devel; fi
  if install_group_note ldap; then rhel_install_optional openldap-devel; fi
  if install_group_note xsl; then rhel_install_optional libxslt-devel; fi
  if install_group_note tidy; then rhel_install_optional libtidy-devel; fi
  if install_group_note snmp; then rhel_install_optional net-snmp-devel; fi
  if install_group_note imap; then rhel_install_optional libc-client-devel krb5-devel; fi
  if install_group_note mcrypt; then rhel_install_optional libmcrypt-devel; fi

  if install_group_note zip; then
    case "$major" in
      7)
        warn "Skipping libzip-devel on EL7 because the packaged libzip is commonly too old for modern PHP"
        ;;
      *)
        rhel_install_optional libzip-devel
        ;;
    esac
  fi

  if install_group_note gd; then
    case "$major" in
      7)
        warn "Skipping gd-devel on EL7 because gd 2.0.x is too old for PHP's external GD check"
        ;;
      *)
        rhel_install_optional gd-devel libpng-devel libjpeg-turbo-devel freetype-devel libwebp-devel
        ;;
    esac
  fi

  if install_group_note imagick; then rhel_install ImageMagick-devel; fi
  if install_group_note yaml; then rhel_install libyaml-devel; fi
  if install_group_note memcached; then rhel_install libmemcached-devel cyrus-sasl-devel; fi
  if install_group_note amqp; then rhel_install librabbitmq-devel; fi
  if install_group_note rdkafka; then rhel_install librdkafka-devel; fi
  if install_group_note uv; then rhel_install libuv-devel; fi

  ensure_re2c_for_php_version
}

install_arch_dependencies() {
  pacman_install \
    ca-certificates curl git tar gzip xz unzip which \
    base-devel autoconf libtool bison re2c pkgconf \
    libxml2 openssl icu zlib oniguruma \
    readline sqlite gettext libxcrypt

  if install_group_note bz2; then pacman_install bzip2; fi
  if install_group_note gmp; then pacman_install gmp; fi
  if install_group_note sodium; then pacman_install libsodium; fi
  if install_group_note zip; then pacman_install libzip; fi
  if install_group_note pgsql; then pacman_install postgresql-libs; fi
  if install_group_note gd; then pacman_install gd libpng libjpeg-turbo freetype2 libwebp; fi
  if install_group_note ffi; then pacman_install libffi; fi
  if install_group_note ldap; then pacman_install libldap; fi
  if install_group_note xsl; then pacman_install libxslt; fi
  if install_group_note tidy; then pacman_install tidy; fi
  if install_group_note snmp; then pacman_install net-snmp; fi
  if install_group_note imap; then pacman_install uw-imap krb5; fi
  if install_group_note mcrypt; then pacman_install libmcrypt; fi

  if install_group_note imagick; then pacman_install imagemagick; fi
  if install_group_note yaml; then pacman_install libyaml; fi
  if install_group_note memcached; then pacman_install libmemcached libsasl; fi
  if install_group_note amqp; then pacman_install rabbitmq-c; fi
  if install_group_note rdkafka; then pacman_install librdkafka; fi
  if install_group_note uv; then pacman_install libuv; fi
}


install_amazonlinux_dependencies() {
  # Amazon Linux 2023 is not an Enterprise Linux rebuild, but its development
  # packages and dnf behavior are close enough to Fedora/EL that keeping a
  # dedicated adapter is clearer than forcing it through the EL repository setup.
  dnf_install \
    ca-certificates curl git tar gzip xz unzip findutils which sudo \
    gcc gcc-c++ make patch diffutils file \
    autoconf libtool bison re2c pkgconf-pkg-config gawk \
    libxml2-devel openssl-devel libicu-devel zlib-devel oniguruma-devel \
    libcurl-devel readline-devel sqlite-devel gettext-devel libxcrypt-devel

  if install_group_note bz2; then dnf_install bzip2-devel; fi
  if install_group_note gmp; then dnf_install gmp-devel; fi
  if install_group_note sodium; then dnf_install libsodium-devel; fi
  if install_group_note zip; then dnf_install libzip-devel; fi
  if install_group_note pgsql; then dnf_install libpq-devel || dnf_install postgresql-devel; fi
  if install_group_note gd; then dnf_install gd-devel libpng-devel libjpeg-turbo-devel freetype-devel libwebp-devel; fi
  if install_group_note ffi; then dnf_install libffi-devel; fi
  if install_group_note ldap; then dnf_install openldap-devel; fi
  if install_group_note xsl; then dnf_install libxslt-devel; fi
  if install_group_note tidy; then dnf_install libtidy-devel || warn "libtidy-devel is unavailable on this Amazon Linux release"; fi
  if install_group_note snmp; then dnf_install net-snmp-devel; fi
  if install_group_note imap; then dnf_install libc-client-devel krb5-devel || warn "IMAP development packages are unavailable on this Amazon Linux release"; fi
  if install_group_note mcrypt; then dnf_install libmcrypt-devel || warn "libmcrypt-devel is unavailable on this Amazon Linux release"; fi

  if install_group_note imagick; then dnf_install ImageMagick-devel; fi
  if install_group_note yaml; then dnf_install libyaml-devel; fi
  if install_group_note memcached; then dnf_install libmemcached-devel cyrus-sasl-devel; fi
  if install_group_note amqp; then dnf_install librabbitmq-devel; fi
  if install_group_note rdkafka; then dnf_install librdkafka-devel; fi
  if install_group_note uv; then dnf_install libuv-devel; fi

  ensure_re2c_for_php_version
}

install_alpine_dependencies() {
  # Alpine is musl-based, so it is intentionally handled as its own family
  # rather than as a generic Linux target. Build packages use the *-dev naming
  # convention and build-base provides gcc, g++, make, libc headers, and friends.
  apk_install \
    ca-certificates curl git tar gzip xz unzip bash findutils file which \
    build-base linux-headers autoconf libtool bison re2c pkgconf gawk \
    libxml2-dev openssl-dev icu-dev zlib-dev oniguruma-dev \
    curl-dev readline-dev sqlite-dev gettext-dev

  if install_group_note bz2; then apk_install bzip2-dev; fi
  if install_group_note gmp; then apk_install gmp-dev; fi
  if install_group_note sodium; then apk_install libsodium-dev; fi
  if install_group_note zip; then apk_install libzip-dev; fi
  if install_group_note pgsql; then apk_install postgresql-dev; fi
  if install_group_note gd; then apk_install gd-dev libpng-dev libjpeg-turbo-dev freetype-dev libwebp-dev; fi
  if install_group_note ffi; then apk_install libffi-dev; fi
  if install_group_note ldap; then apk_install openldap-dev; fi
  if install_group_note xsl; then apk_install libxslt-dev; fi
  if install_group_note tidy; then apk_install tidyhtml-dev || warn "tidyhtml-dev is unavailable on this Alpine release"; fi
  if install_group_note snmp; then apk_install net-snmp-dev; fi
  if install_group_note imap; then apk_install imap-dev || warn "IMAP development packages are unavailable on this Alpine release"; fi
  if install_group_note mcrypt; then apk_install libmcrypt-dev || warn "libmcrypt-dev is unavailable on this Alpine release"; fi

  if install_group_note imagick; then apk_install imagemagick-dev; fi
  if install_group_note yaml; then apk_install yaml-dev; fi
  if install_group_note memcached; then apk_install libmemcached-dev cyrus-sasl-dev; fi
  if install_group_note amqp; then apk_install rabbitmq-c-dev; fi
  if install_group_note rdkafka; then apk_install librdkafka-dev; fi
  if install_group_note uv; then apk_install libuv-dev; fi

  ensure_re2c_for_php_version
}

install_macos_dependencies() {
  xcode-select --install 2>/dev/null || true

  brew_install \
    autoconf libtool bison re2c pkg-config \
    libxml2 openssl@3 icu4c zlib oniguruma curl readline sqlite gettext \
    libiconv krb5 libedit

  if install_group_note bz2; then brew_install bzip2; fi
  if install_group_note gmp; then brew_install gmp; fi
  if install_group_note sodium; then brew_install libsodium; fi
  if install_group_note zip; then brew_install libzip; fi
  if install_group_note pgsql; then brew_install libpq; fi
  if install_group_note gd; then brew_install gd freetype jpeg libpng webp; fi
  if install_group_note ffi; then brew_install libffi; fi
  if install_group_note ldap; then brew_install openldap; fi
  if install_group_note xsl; then brew_install libxslt; fi
  if install_group_note tidy; then brew_install tidy-html5; fi
  if install_group_note snmp; then brew_install net-snmp; fi
  if install_group_note imap; then brew_install imap-uw krb5; fi
  if install_group_note mcrypt; then brew_install mcrypt || warn "mcrypt is unavailable or deprecated in Homebrew"; fi

  if install_group_note imagick; then brew_install imagemagick; fi
  if install_group_note yaml; then brew_install libyaml; fi
  if install_group_note memcached; then brew_install libmemcached; fi
  if install_group_note amqp; then brew_install rabbitmq-c; fi
  if install_group_note rdkafka; then brew_install librdkafka; fi
  if install_group_note uv; then brew_install libuv; fi
}

log "Installing PHP source build dependencies"
log "Detected dependency target: $DISTRO${VERSION_ID:+ $VERSION_ID}"
if [ -n "${PHP_BUILD_VERSION:-}" ]; then
  log "PHP build version: $PHP_BUILD_VERSION"
fi
if [ -n "${PHP_PECL_EXTENSIONS:-}${PHP_PIE_EXTENSIONS:-}" ]; then
  log "Requested PECL extensions: ${PHP_PECL_EXTENSIONS:-none}"
  log "Requested PIE extensions: ${PHP_PIE_EXTENSIONS:-none}"
fi

case "$DISTRO" in
  debian)
    install_debian_dependencies
    ;;
  fedora)
    install_fedora_dependencies
    ;;
  amazonlinux)
    install_amazonlinux_dependencies
    ;;
  rhel)
    install_rhel_dependencies
    ;;
  alpine)
    install_alpine_dependencies
    ;;
  arch)
    install_arch_dependencies
    ;;
  darwin)
    install_macos_dependencies
    ;;
  *)
    echo "Unsupported operating system: $DISTRO"
    exit 1
    ;;
esac

log "PHP source build dependency installation complete"
