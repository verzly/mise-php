set -euo pipefail

  source_projects="${RUNNER_TEMP}/php-variants-source"
  static_projects="${RUNNER_TEMP}/php-variants-static"
  source_version="${PHP_TEST_VERSION}"
  static_version="8.5.9"
  mkdir -p "${source_projects}/with-pie" \
  "${static_projects}/bulk" \
  "${static_projects}/common" \
  "${static_projects}/invalid-option"

  write_source_config() {
  cat > "${source_projects}/with-pie/mise.toml" <<TOML
[settings]
experimental = true
install_layout = "identity"

[tools.php]
version = "${source_version}"
pie_extensions = "xdebug/xdebug"
TOML
  }

  write_static_config() {
  dir="$1"
  flavor="$2"
  cat > "${dir}/mise.toml" <<TOML
[settings]
experimental = true
install_layout = "identity"

[tools.php]
version = "${static_version}"
prebuilt_static = true
prebuilt_static_flavor = "${flavor}"
TOML
  }

  write_source_config
  write_static_config "${static_projects}/bulk" "bulk"
  write_static_config "${static_projects}/common" "common"

  cat > "${static_projects}/invalid-option/mise.toml" <<TOML
[settings]
experimental = true
install_layout = "identity"

[tools.php]
version = "${static_version}"
prebuilt_static = true
skip_deps = {}
TOML

  for project in "${source_projects}/with-pie" \
  "${static_projects}/bulk" \
  "${static_projects}/common" \
  "${static_projects}/invalid-option"; do
  mise trust "$project" >/dev/null 2>&1 || true
  done

  mise -C "${source_projects}/with-pie" install php 2>&1 | tee "${RUNNER_TEMP}/variant-source-pie.log"

  # Hostile ambient values must not override explicit tool options.
  PHP_PREBUILT_STATIC=0 \
  PHP_PREBUILT_STATIC_FLAVOR=minimal \
  mise -C "${static_projects}/bulk" install php 2>&1 | tee "${RUNNER_TEMP}/variant-static-bulk.log"
  mise -C "${static_projects}/common" install php 2>&1 | tee "${RUNNER_TEMP}/variant-static-common.log"

  if ! grep -q "compiled from source" "${RUNNER_TEMP}/variant-source-pie.log"; then
  echo "The source variant did not build PHP from source"
  exit 1
  fi

  if grep -q "compiled from source" "${RUNNER_TEMP}/variant-static-bulk.log" "${RUNNER_TEMP}/variant-static-common.log"; then
  echo "A prebuilt variant fell back to a source build"
  exit 1
  fi

  for project in "${source_projects}/with-pie" "${static_projects}/bulk" "${static_projects}/common"; do
  if ! mise -C "$project" install -n 2>&1 | grep -q "all tools are installed"; then
  echo "${project} was not reported as already installed"
  exit 1
  fi
  done

  pie_state="$(mise -C "${source_projects}/with-pie" exec -- php -r 'echo PHP_VERSION, " debug=", PHP_DEBUG ? "yes" : "no", " xdebug=", extension_loaded("xdebug") ? "yes" : "no", " version=", extension_loaded("xdebug") ? phpversion("xdebug") : "none";')"
  case "$pie_state" in
  "${source_version} debug=no xdebug=yes version="*) ;;
  *)
  echo "Expected a loaded PIE Xdebug in the source variant, got: ${pie_state}"
  exit 1
  ;;
  esac

  bulk_path="$(mise -C "${static_projects}/bulk" where php)"
  common_path="$(mise -C "${static_projects}/common" where php)"

  if [ -z "$bulk_path" ] || [ -z "$common_path" ] || [ "$bulk_path" = "$common_path" ]; then
  echo "Expected separate static install identities, got '${bulk_path}' and '${common_path}'"
  exit 1
  fi

  for project in bulk common; do
  actual="$(mise -C "${static_projects}/${project}" exec -- php -r 'echo PHP_VERSION;')"
  if [ "$actual" != "${static_version}" ]; then
  echo "${project} ran PHP ${actual} instead of ${static_version}"
  exit 1
  fi

  state="$(mise -C "${static_projects}/${project}" exec -- php -r 'echo "xdebug=", extension_loaded("xdebug") ? "yes" : "no";')"
  if [ "$state" != "xdebug=no" ]; then
  echo "${project} unexpectedly loaded an extension: ${state}"
  exit 1
  fi
  done

  mise -C "${static_projects}/bulk" exec -- php -m | sort > "${RUNNER_TEMP}/modules-bulk.txt"
  mise -C "${static_projects}/common" exec -- php -m | sort > "${RUNNER_TEMP}/modules-common.txt"

  for modules in bulk common; do
  if ! grep -qx "openssl" "${RUNNER_TEMP}/modules-${modules}.txt"; then
  echo "The ${modules} prebuilt flavor is missing openssl"
  exit 1
  fi
  done

  if diff -q "${RUNNER_TEMP}/modules-bulk.txt" "${RUNNER_TEMP}/modules-common.txt"; then
  echo "Both prebuilt flavors produced the same extension set"
  exit 1
  fi

  if output="$(mise -C "${static_projects}/invalid-option" install php 2>&1)"; then
  echo "An unsupported tool option type was accepted"
  exit 1
  fi

  if ! printf '%s' "$output" | grep -q "skip_deps must be a boolean or string"; then
  echo "Unexpected failure for an unsupported tool option type: ${output}"
  exit 1
  fi

  echo "Source PIE variant: ${pie_state}"
  echo "Static variant paths: ${bulk_path} ${common_path}"
  echo "bulk modules: $(wc -l < "${RUNNER_TEMP}/modules-bulk.txt"), common modules: $(wc -l < "${RUNNER_TEMP}/modules-common.txt")"
  echo "PHP installation variants stay isolated"
