set -euo pipefail

cat > mise.toml <<'TOML'
[tools.php]
version = "8.5.9"
prebuilt_static = true
prebuilt_static_flavor = "minimal"
configure_options = "--disable-all"
extra_configure_options = "--enable-option-checking=fatal"
pecl_extensions = "redis,xdebug"
pie_extensions = "amphp/ext-uv"

[env._.php]
skip_deps = true
verbose = true
TOML

  mise trust "${GITHUB_WORKSPACE}" || true
  for option in prebuilt_static prebuilt_static_flavor configure_options extra_configure_options pecl_extensions pie_extensions; do
  case "$option" in
  prebuilt_static) expected=true ;;
  prebuilt_static_flavor) expected=minimal ;;
  configure_options) expected=--disable-all ;;
  extra_configure_options) expected=--enable-option-checking=fatal ;;
  pecl_extensions) expected=redis,xdebug ;;
  pie_extensions) expected=amphp/ext-uv ;;
  esac
  actual="$(mise config get "tools.php.${option}")"
  if [ "$actual" != "$expected" ]; then
  echo "tools.php.${option}: expected '${expected}', got '${actual}'"
  exit 1
  fi
  done

  mise env --dotenv | tee mise-env.out
  if grep -Eq '^PHP_(PREBUILT_STATIC|PREBUILT_STATIC_FLAVOR|CONFIGURE_OPTIONS|EXTRA_CONFIGURE_OPTIONS|PECL_EXTENSIONS|PIE_EXTENSIONS)=' mise-env.out; then
  echo "Tool options were unexpectedly exported as PHP_* environment variables"
  exit 1
  fi

  # Legacy installation options must remain accepted through env._.php.
cat > mise.toml <<'TOML'
[env._.php]
skip_deps = true
verbose = true
prebuilt_static = true
prebuilt_static_flavor = "minimal"
configure_options = "--disable-all"
extra_configure_options = "--enable-option-checking=fatal"
pecl_extensions = "redis,xdebug"
pie_extensions = "amphp/ext-uv"
TOML

  mise env --dotenv | tee mise-env.out

  require_env() {
  key="$1"
  expected="$2"
  actual="$(grep -E "^${key}=" mise-env.out | tail -n 1 | cut -d= -f2- | sed "s/^['\"]//; s/['\"]$//")"

  if [ "$actual" != "$expected" ]; then
  echo "${key}: expected '${expected}', got '${actual}'"
  exit 1
  fi
  }

  require_env PHP_SKIP_DEPS 1
  require_env PHP_VERBOSE 1
  require_env PHP_PREBUILT_STATIC 1
  require_env PHP_PREBUILT_STATIC_FLAVOR minimal
  require_env PHP_CONFIGURE_OPTIONS --disable-all
  require_env PHP_EXTRA_CONFIGURE_OPTIONS --enable-option-checking=fatal
  require_env PHP_PECL_EXTENSIONS redis,xdebug
  require_env PHP_PIE_EXTENSIONS amphp/ext-uv

  echo "Tool options and legacy env._.php compatibility verified"
