PLUGIN = {}

PLUGIN.name = "php"
PLUGIN.version = "0.10.1"
PLUGIN.homepage = "https://github.com/verzly/mise-php"
PLUGIN.license = "AGPL-3.0"
PLUGIN.description = "PHP version manager plugin for mise (by verzly)"
PLUGIN.minRuntimeVersion = "0.3.2"
PLUGIN.manifestUrl = "https://github.com/verzly/mise-php/releases/download/manifest/manifest.json"
PLUGIN.notes = {
    "Compiles PHP from source. Requires: C compiler, make, autoconf, bison, re2c.",
    "macOS: brew install autoconf bison re2c libxml2 openssl@3 icu4c pkg-config",
    "Linux: apt install build-essential autoconf bison re2c libxml2-dev libssl-dev libicu-dev",
    "Windows: uses prebuilt PHP binaries by default.",
    "Automatically installs Composer after PHP.",
    "Dependency handling is install-path aware; source builds verify dependencies in the installer.",
}
