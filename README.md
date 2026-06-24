# verzly/mise-php

![verzly-mise-php-example](https://github.com/user-attachments/assets/c57759f1-0ffc-4175-b96a-ca259a9c814d)

`verzly/mise-php` is a [jdx/mise](https://github.com/jdx/mise) plugin for installing and managing PHP on Linux, macOS, and Windows.

It provides an integrated PHP toolchain with built-in support for:
- **Composer** (per-version dependency management)
- **PIE** (next-generation extension installer, PHP ≥ 8.1)
- **PECL** (legacy extension support, PHP ≤ 8.4)

Install multiple PHP versions side by side, each with its own isolated runtime, Composer, and extension environment. Switch between versions globally or per project, and customize the build configuration to fit your exact needs.

- [How it works](#how-does-it-differ-from-the-other-mise-php-plugins)
  - [Pre-binaries](#pre-binaries)
  - [Build from source](#build-from-source)
  - [Cleanup](#cleanup)
- [Get started](#get-started)
  - [Install mise](#get-started)
  - [Activate mise](#get-started)
  - [Install plugin](#get-started)
  - [Upgrade](#up-to-date)
- [Usage](#usage)
  - [PHP](#php)
  - [Source build dependencies](#source-build-dependencies)
  - [Prebuilt static PHP](#prebuilt-static-php)
  - [Composer](#composer-for-php)
  - [PIE](#pie-for-php)
  - [PECL](#pecl-for-php)
  - [Environment variables](#environment-variables)
  - [Custom configure options](#custom-configure-options-macos-and-linux)
  - [Skip dependency installation](#skip-dependency-installation)
- [Debugging](#debugging)
- [Known Issues](#known-issues)
- [Contributing](#contributing)

Read on to learn why `verzly/mise-php` was created and what makes it work the way it does. Or jump straight to [Get started](#get-started) for quick installation steps, or to [Upgrade](#up-to-date) if you are already using the plugin.

## How does it differ from the other mise-php plugins?

Although some PHP plugins are available for [jdx/mise](https://github.com/jdx/mise), they often encounter errors on either Windows or various Linux distributions. The most common issue is locating the correct PHP versions. This is because PHP maintains its latest and older releases on different sites. Moreover, Windows and Linux installers are separated.

The officially released PHP versions are provided by `verzly/mise-php` for Linux, macOS, and Windows. Additionally, it installs a dedicated Composer for each PHP version to help you avoid version conflicts.

### Pre-binaries

On Windows, we can work quickly using precompiled binaries.

You can optionally use prebuilt static PHP binaries provided by static-php-cli. This is disabled by default because fewer PHP versions may be available, and newly released PHP versions may appear later than source builds.

### Build from source

For Linux and macOS systems, source builds remain the default. The `verzly/mise-php` plugin builds the necessary binaries from the PHP source on each user's system when installing the given version. This process is time-consuming and can take anywhere from 1 to 5 minutes, depending on the machine (or virtual machine). The dependencies required for this are listed in `/bin/install-dependencies.sh`, which the system runs automatically.

### Cleanup

Before starting the process, it is recommended to make sure that no PHP or Composer installations exist on your system from other sources. If there are, it is advisable to remove them, as from this point onward, `verzly/mise-php` will be responsible for providing access to the PHP and Composer executables.

## Get started

> [!IMPORTANT]
> The plugin requires a [jdx/mise](https://github.com/jdx/mise) installation to be used. <a href="https://mise.jdx.dev/getting-started.html" target="_blank">Go to install guide</a>
>
> ```sh
> # Linux or macOS
> curl https://mise.run | sh
>
> # Windows
> winget install jdx.mise
> ```
>
> Activation in your shell profile is required for global use and for registering commands. <a href="https://mise.jdx.dev/getting-started.html#activate-mise" target="_blank">Go to activate guide</a>
>
> ```sh
> # Linux or macOS
> echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
>
> # Windows
> (&mise activate pwsh) | Out-String | Invoke-Expression
> ```

To install PHP versions on any operating system using the `verzly/mise-php` plugin, you first need a one-time setup.

```sh
# Install the plugin
# NOTE: If you are not contributing and want to use stable releases, always use the `#latest` suffix to avoid tracking the development branch.
mise plugin install php https://github.com/verzly/mise-php#latest

# Install/Select version globally
mise use -g php@8

# Install/Select version locally (for current directory)
cd /path/to/php/project
mise use php@7.3
```

Once the plugin is installed, you can [start managing PHP versions](#usage).

> [!TIP]
> Once PHP is installed and dependencies are in place, you can permanently skip the dependency installation step on future installs.<br>
> See [Skip dependency installation](#skip-dependency-installation) for details.
>
> ```sh
> # First install
> mise use -g php@latest
>
> # Disable dependency installation for future installs
> mise config set env._.php.skip_deps true
> ```

> [!TIP]
> You can persist any combination of plugin options in `mise.toml` instead of passing them on every install.<br>
> See [Custom configure options](#custom-configure-options-macos-and-linux) for details.
>
> ```sh
> [env]
> _.php = { extra_configure_options = "--with-pdo-sqlite" }
> ```
>
> Or set individual options via CLI:
>
> ```sh
> mise config set env._.php.extra_configure_options "--with-pdo-sqlite"
> ```

> [!TIP]
> You can use prebuilt static PHP binaries instead of compiling PHP from source on Linux/macOS, or instead of the default windows.php.net installer on Windows.
> See [Prebuilt static PHP](#prebuilt-static-php) for details.
>
> ```sh
> mise config set env._.php.prebuilt_static true
> mise use php@latest
> ```

### Up-to-date

These are stable versions, but plugin updates may occur, which you can later install with a single command.

```sh
# Upgrade plugin (follows the originally installed target, e.g. `#latest`)
# NOTE: If the plugin was installed with `#latest`, this will continue to track and update to the latest stable release automatically.
mise plugin upgrade php

# Upgrade plugin to latest version instantly (recommended, avoids dev branch)
mise plugin upgrade php#latest

# Upgrade plugin to a specific release tag
mise plugin upgrade php#v0.6.0

# Upgrade plugin to a specific commit
mise plugin upgrade php#7a6858b
```

## Usage

After installing the plugin, [jdx/mise](https://github.com/jdx/mise) enables the installation of packages named php via the `verzly/mise-php` plugin.

### PHP

You can install multiple PHP versions simultaneously. You can select a version to use globally, but you can also specify project-specific versions for individual projects. We work with official PHP releases - anything released on php.net can be installed.

```sh
# List stable PHP versions only
mise ls-remote php

# List stable PHP versions plus prereleases, including alpha, beta, and RC tags
mise ls-remote --prerelease php

# Check installed PHP versions
mise ls php

# Latest PHP major
mise use php@latest

# Latest PHP 8 minor, patch
mise use php@8

# Latest PHP 8.4 patch
mise use php@8.4

# Only PHP 8.4.3 patch
mise use php@8.4.3

# Change globally selected PHP version
mise use -g php@8.4.3

# Check current PHP version
php --version

# Check current Composer version
composer --version

# Check current PIE version (available from PHP 8.1)
pie --version

# Check current PECL version (deprecated on PHP 8.5+, use PIE instead)
pecl version
```

The list of version numbers is not gathered directly from [`php/php-src`](https://github.com/php/php-src/releases), because the GitHub API enforces rate limiting after a certain number of requests. Instead, we update our `versions.txt` file from a `cache` branch once per day, so it's possible that a release may only be installable via the `verzly/mise-php` plugin with a one-day delay, or may require a manual update.

When prebuilt static PHP is enabled, version listing switches to the available static-php-cli binaries for the current operating system, CPU architecture, and selected flavor.

### Source build dependencies

Source builds need native system packages for the selected PHP version, configure options, and requested PECL/PIE extensions. By default, `mise-php` detects the current platform and installs the matching dependency set automatically.

Supported installers cover Debian and Ubuntu, Fedora, Enterprise Linux-compatible systems, Amazon Linux 2023, Arch Linux, Alpine Linux, and macOS through Homebrew. Enterprise Linux-compatible systems are handled by major version, such as EL8, EL9, and EL10, so RHEL-style systems, CentOS Stream, Rocky Linux, AlmaLinux, and Oracle Linux can receive version-specific repository, dependency, and build-flag handling.

Some PHP/platform combinations need extra handling, such as a newer `re2c` for PHP 8.3+ on older Enterprise Linux releases or PIC/PIE build flags for PHP 8.5+ on EL8-compatible systems. Static PHP installs skip this step because they use prebuilt binaries with a fixed extension set.

For permanent or one-time disabling, see [Skip dependency installation](#skip-dependency-installation). For package names, repository setup, and version-specific notes, see [`bin/install-dependencies.sh`](bin/install-dependencies.sh).

### Prebuilt static PHP

By default, Linux and macOS installs build PHP from source, while Windows uses the regular windows.php.net binary installer. If you prefer faster static builds and can accept a smaller version set, enable prebuilt static PHP binaries. When enabled, the default static-php-cli flavor uses the broadest available extension set for the current platform: `bulk` on Linux/macOS and `spc-max` on Windows.

```sh
# Enable globally
mise config set env._.php.prebuilt_static true

# Optional: choose a different static-php-cli binary flavor
# Default: bulk on Linux/macOS, spc-max on Windows
# Cross-platform supported: bulk, minimal
# Linux/macOS only: common, gnu-bulk
# Windows aliases: spc-max, spc-min
mise config set env._.php.prebuilt_static_flavor minimal

# Install from the prebuilt static PHP list
mise install php@latest
```

```toml
[env]
_.php = { prebuilt_static = true, prebuilt_static_flavor = "bulk" }
```

Available versions are filtered to binaries that exist for your current platform and selected flavor. If a PHP version exists in `php/php-src` but no matching static-php-cli binary exists yet, it will not be listed while this option is enabled.

Available flavors:

| Flavor | Linux/macOS | Windows | Notes |
|---|---|---|---|
| `bulk` | `bulk` | `spc-max` | Default. Largest available prebuilt extension set. |
| `common` | `common` | not supported | Medium Linux/macOS build. |
| `gnu-bulk` | `gnu-bulk` | not supported | Linux/macOS GNU-oriented bulk build. |
| `minimal` | `minimal` | `spc-min` | Smaller prebuilt build. |
| `spc-max` | alias of `bulk` | `spc-max` | Explicit Windows maximum build. |
| `spc-min` | alias of `minimal` | `spc-min` | Explicit Windows minimum build. |

> [!WARNING]
> Prebuilt static PHP is intended as a faster install path. It may provide fewer PHP versions than source builds, and newly released PHP versions may become available later.

> [!NOTE]
> PECL and PIE extension requests configured via `pecl_extensions` or `pie_extensions` are skipped for prebuilt static PHP installs. Static builds ship with a fixed extension set.

To switch back to source builds:

```sh
mise config set env._.php.prebuilt_static false
mise install php@latest
```

### Composer for PHP

Each PHP version uses its own Composer binary, while sharing the global Composer configuration and cache (`~/.config/composer`, `~/.cache/composer`). This means repositories, authentication, and cache are reused across PHP versions, but Composer always runs against the currently active PHP runtime.

> [!WARNING]
> Global packages are not fully version-independent. If a package only supports a specific PHP range (e.g. 8.1-8.5), switching to an older PHP version (e.g. 8.0 or 7.4) may require reinstalling a compatible (older) version of that package.

```sh
# Manage Composer versions (self-update commands)

# Update to the latest major version
composer self-update
# Update within a specific major version (latest minor/patch)
composer self-update 2
# Update within a specific minor version (latest patch)
composer self-update 2.7
# Install a specific version
composer self-update 2.7.9
# Roll back to the previously installed version
composer self-update --rollback

# Switch release channels
# Use stable releases (recommended, default)
composer self-update --stable
# Use preview / release candidate versions
composer self-update --preview
# Use development snapshot versions
composer self-update --snapshot

# Check current Composer version
composer --version
```

Have you used Composer before installing `verzly/mise-php`? Check for and remove any unnecessary Composer binaries.

```sh
# Linux / macOS
type -a composer

sudo rm -f /path/to/composer
# Do NOT remove the verzly/mise-php Composer:
# ~/.local/share/mise/installs/php/8.5.4/bin/composer
# or the shim managed by mise:
# ~/.local/share/mise/shims/composer

# Windows (PowerShell)
Get-Command composer -All

Remove-Item "C:\path\to\composer.exe" -Force
# Do NOT remove the verzly/mise-php Composer:
# %LOCALAPPDATA%\mise\installs\php\<version>\composer.bat
# or the shim managed by mise:
# %LOCALAPPDATA%\mise\shims\composer.exe
```

### PIE for PHP

[PIE](https://github.com/php/pie) is the modern replacement for PECL and the official installer for PHP extensions. It works similarly to Composer, but installs extensions directly into the active PHP runtime.

PIE can be used with PHP 8.1 and newer, and on PHP 8.5 and newer it is the recommended way to install extensions.

`verzly/mise-php` automatically installs PIE for supported PHP versions, and can also install configured PIE extensions during PHP installation. This allows you to persist your preferred extensions and have them installed automatically for every new PHP version.

Each PHP version has its own dedicated PIE executable, which always operates on the currently active PHP runtime managed by `mise`.

> [!NOTE]
> Installed packages are stored in a central location, but they are handled separately for each PHP version based on the detected PHP runtime.

List of available PIE extensions:
- <https://packagist.org/extensions>

```sh
# Check current PHP version
php --version

# Install extensions for the active PHP version
pie install redis/phpredis
pie install xdebug/xdebug

# In a PHP project, install missing top-level extensions from composer.json
pie install

# Show installed extensions for the active PHP version
pie show
```

You can install extensions during PHP installation by providing a list via `PHP_PIE_EXTENSIONS`:

```sh
# One-time use (Linux / macOS / Bash)
PHP_PIE_EXTENSIONS="redis/phpredis xdebug/xdebug" mise install php@8.5.0

# One-time use (Windows PowerShell)
$env:PHP_PIE_EXTENSIONS="redis/phpredis xdebug/xdebug"; mise install php@8.5.0
```

You can also persist commonly used extensions so they are automatically installed whenever a new PHP version is installed:

```sh
# Persist PIE extensions globally (set this before installing a PHP version)
mise config set env._.php.pie_extensions "redis/phpredis xdebug/xdebug"
```

```toml
[env]
_.php = { pie_extensions = "redis/phpredis xdebug/xdebug" }
```

Within a given PHP version, you can install a specific PIE version or update it to the latest version, similar to Composer.

```sh
# Manage PIE versions (similar to Composer self-update)

# Update to the latest stable major version
pie self-update
# Update within a specific major version (latest minor/patch)
pie self-update 1
# Update within a specific minor version (latest patch)
pie self-update 1.4
# Install a specific version
pie self-update 1.4.1

# Verify the installed PIE binary
pie self-verify

# Switch release channels
# Use stable releases (recommended, default)
pie self-update --stable
# Use preview / release candidate versions
pie self-update --preview

# Check current PIE version
pie --version
```

Have you used PIE before installing `verzly/mise-php`? Check for and remove any unnecessary PIE binaries.

```sh
# Linux / macOS
type -a pie

sudo rm -f /path/to/pie
# Do NOT remove the verzly/mise-php PIE:
# ~/.local/share/mise/installs/php/<version>/bin/pie
# or the shim managed by mise:
# ~/.local/share/mise/shims/pie

# Windows (PowerShell)
Get-Command pie -All

Remove-Item "C:\path\to\pie.exe" -Force
# Do NOT remove the verzly/mise-php PIE:
# %LOCALAPPDATA%\mise\installs\php\<version>\pie.bat
# or the shim managed by mise:
# %LOCALAPPDATA%\mise\shims\pie.exe
```

### PECL for PHP

> [!WARNING]
> PECL is deprecated and is not supported for PHP 8.5 and newer. Use [PIE](#pie-for-php) instead.

> [!WARNING]
> `pecl install` performs a direct source build and install of extensions. It does not provide version isolation, dependency management, or reproducibility guarantees.

PECL is the legacy installer for PHP extensions. It can be used with PHP 8.4 and older versions.

`verzly/mise-php` can automatically install PECL extensions during PHP installation, allowing you to persist your preferred extensions and have them installed automatically for every new PHP version.

Each PHP version uses its own extension directory, ensuring isolation between PHP versions.

List of available PECL extensions:
- <https://pecl.php.net/packages.php>

```sh
# Update PECL channel metadata (refresh available packages list)
pecl channel-update pecl.php.net

# Install extensions for the active PHP version
pecl install redis
pecl install xdebug

# Show installed PECL extensions
pecl list

# Check current PECL version
pecl version
```

You can install extensions during PHP installation by providing a list via `PHP_PECL_EXTENSIONS`:

```sh
# One-time use (Linux / macOS / Bash)
PHP_PECL_EXTENSIONS="redis xdebug" mise install php@8.4.3

# One-time use (Windows PowerShell)
$env:PHP_PECL_EXTENSIONS="redis xdebug"; mise install php@8.4.3
```

You can also persist commonly used extensions so they are automatically installed whenever a new PHP version is installed:

```sh
mise config set env._.php.pecl_extensions "redis xdebug"
```

```toml
[env]
_.php = { pecl_extensions = "redis xdebug" }
```

> [!TIP]
> Extension names differ from PIE (e.g. `redis` vs `redis/phpredis`).

### Environment variables

This plugin sets the following environment variables:

| Variable | OS | Value |
|---|---|---|
| `PATH` | Windows | `<install_dir>` |
| `PATH` | macOS, Linux | `<install_dir>/bin`, `<install_dir>/sbin` |
| `LD_LIBRARY_PATH` | Linux only | `<install_dir>/lib` |

The following installation options can be set through `mise config set env._.php.<option> ...` or the `[env] _.php = { ... }` table in `mise.toml`:

| Option | Environment variable | Default | Description |
|---|---|---|---|
| `prebuilt_static` | `PHP_PREBUILT_STATIC` | `false` | Use prebuilt static PHP binaries instead of source builds on supported platforms. |
| `prebuilt_static_flavor` | `PHP_PREBUILT_STATIC_FLAVOR` | `bulk` | Select the static-php-cli binary flavor. Defaults to the largest flavor: `bulk` on Linux/macOS and `spc-max` on Windows. |
| `skip_deps` | `PHP_SKIP_DEPS` | `false` | Skip automatic build dependency installation for source builds. |
| `verbose` | `PHP_VERBOSE` | `false` | Show commands, failure summaries, and temporary log file paths for debugging. |
| `extra_configure_options` | `PHP_EXTRA_CONFIGURE_OPTIONS` | empty | Append extra configure options to the default source build configuration. |
| `configure_options` | `PHP_CONFIGURE_OPTIONS` | empty | Replace configure options entirely while preserving the install prefix. |
| `pecl_extensions` | `PHP_PECL_EXTENSIONS` | empty | Install PECL extensions after source builds where PECL is available. |
| `pie_extensions` | `PHP_PIE_EXTENSIONS` | empty | Install PIE extension packages after source builds where PIE is available. |

Static PHP flavor notes:

| Flavor | Linux/macOS | Windows | Notes |
|---|---|---|---|
| `bulk` | `bulk` | `spc-max` | Default. Largest available prebuilt extension set. |
| `common` | `common` | not supported | Medium Linux/macOS build. |
| `gnu-bulk` | `gnu-bulk` | not supported | Linux/macOS GNU-oriented bulk build. |
| `minimal` | `minimal` | `spc-min` | Smaller prebuilt build. |
| `spc-max` | alias of `bulk` | `spc-max` | Explicit Windows maximum build. |
| `spc-min` | alias of `minimal` | `spc-min` | Explicit Windows minimum build. |

### Custom configure options (macOS and Linux)

> [!Note]
> On Windows, PHP is installed from prebuilt binaries. With `prebuilt_static = true`, the plugin uses static-php-cli Windows builds; otherwise it uses binaries from [windows.php.net](https://windows.php.net). Configure options do not apply.

> [!NOTE]
> When using custom configure options, the dependency installer scans `configure_options` and `extra_configure_options` and installs known optional native libraries only for matching flags. Unknown extension-specific dependencies must still be installed manually.

Add extra configure options on top of the defaults:

```sh
# One-time use (Linux / macOS / Bash)
PHP_EXTRA_CONFIGURE_OPTIONS="--with-pdo-sqlite" mise install php@8.4.3

# One-time use (Windows PowerShell)
$env:PHP_EXTRA_CONFIGURE_OPTIONS="--with-pdo-sqlite"; mise install php@8.4.3

# Save permanently
mise config set env._.php.extra_configure_options "--with-pdo-sqlite"
# Subsequent installs will apply the extra configure options automatically
mise install php@8.4.3

# Remove saved value
mise config set env._.php.extra_configure_options false
# Default options will be used again
mise install php@8.4.3
```

Override all configure options (prefix is always preserved):

```sh
# One-time use (Linux / macOS / Bash)
PHP_CONFIGURE_OPTIONS="--with-openssl --enable-mbstring" mise install php@8.4.3

# One-time use (Windows PowerShell)
$env:PHP_CONFIGURE_OPTIONS="--with-openssl --enable-mbstring"; mise install php@8.4.3

# Save permanently
mise config set env._.php.configure_options "--with-openssl --enable-mbstring"
# Subsequent installs will use the custom configure options automatically
mise install php@8.4.3

# Remove saved value
mise config set env._.php.configure_options false
# Default options will be used again
mise install php@8.4.3
```

#### Defaults

```none
--enable-bcmath --enable-calendar --enable-dba --enable-exif --enable-fpm
--enable-ftp --enable-gd --enable-intl --enable-mbregex --enable-mbstring
--enable-mysqlnd --enable-pcntl --enable-shmop --enable-soap --enable-sockets
--enable-sysvmsg --enable-sysvsem --enable-sysvshm --with-curl --with-mhash
--with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-zlib --with-pear
--with-openssl --with-readline --with-gettext --without-pcre-jit --without-snmp
```

The following options are additionally detected based on available libraries:

| Option | macOS | Linux |
|---|---|---|
| `--with-gmp` | if `brew install gmp` | |
| `--with-sodium` | if `brew install libsodium` | |
| `--with-freetype` | if `brew install freetype` | |
| `--with-jpeg` | if `brew install jpeg` | |
| `--with-webp` | if `brew install webp` | |
| `--with-png` | if `brew install libpng` | |
| `--with-bz2` | if `brew install bzip2` | |
| `--with-iconv` | if `brew install libiconv` | |
| `--with-external-gd` | if freetype + jpeg + libpng installed | if `gdlib >= 2.1.0` via pkg-config |
| `--with-pdo-pgsql` | if `brew install libpq` | if `pg_config` in PATH |
| `--with-zip` | if `brew install libzip` | if `libzip` via pkg-config |

### Skip dependency installation

By default, the plugin automatically installs required build dependencies before
compiling PHP. Set `PHP_SKIP_DEPS=1` to skip this step entirely.

```sh
# One-time use (Linux / macOS / Bash)
PHP_SKIP_DEPS=1 mise install php@8.4.3

# One-time use (Windows PowerShell)
$env:PHP_SKIP_DEPS=1; mise install php@8.4.3

# Enable permanently
mise config set env._.php.skip_deps true
# Subsequent installs will skip dependency installation automatically
mise install php@8.4.3

# Disable
mise config set env._.php.skip_deps false
# Dependency installation will run again
mise install php@8.4.3
```

Useful when dependencies are already present or managed externally
(e.g. CI environments, containers, custom setups).

## Debugging

### PHP_VERBOSE=1 - mise-php debug output

By default, dependency and build output is captured to temporary log files to keep installation output readable. Set `PHP_VERBOSE=1` to show commands, concise failure summaries, and the temporary log file paths.

`buildconf`, `configure`, and `make` output is still written to timestamped files under `/tmp`. Files from the same source build share the same log id, for example `mise-php-8.5.5-20260525T075628Z-configure-output.log` and `mise-php-8.5.5-20260525T075628Z-make.log`. When a failure occurs, mise-php prints the relevant error context directly in the terminal and includes the full log path for deeper debugging.

```sh
# One-time use (Linux / macOS / Bash)
PHP_VERBOSE=1 mise install php@8.4.3

# One-time use (Windows PowerShell)
$env:PHP_VERBOSE=1; mise install php@8.4.3

# Enable permanently
mise config set env._.php.verbose true
# Subsequent installs will show commands, failure summaries, and log paths automatically
mise install php@8.4.3

# Disable
mise config set env._.php.verbose false
# Build output will be captured quietly again
mise install php@8.4.3
```

### MISE_VERBOSE=1 - mise-en-place debug output

`MISE_VERBOSE` enables verbose output for the [mise-en-place](https://github.com/jdx/mise) tool itself (plugin downloads,
file handling, hook execution). It does not affect PHP build output.

```sh
MISE_VERBOSE=1 mise install php@8.4.3

# or
mise install php@8.4.3 --verbose
```

Both can be combined:

```sh
# With only env variables
# Linux / macOS / Bash
PHP_VERBOSE=1 MISE_VERBOSE=1 mise install php@8.4.3
# Windows PowerShell
$env:PHP_VERBOSE=1; $env:MISE_VERBOSE=1; mise install php@8.4.3

# or with --verbose flag & env variable
# Linux / macOS / Bash
PHP_VERBOSE=1 mise install php@8.4.3 --verbose
# Windows PowerShell
$env:PHP_VERBOSE=1; mise install php@8.4.3 --verbose

# or enable PHP verbose permanently, then combine with --verbose as needed
mise config set env._.php.verbose true
mise install php@8.4.3 --verbose
```

## Known Issues

### WSL: Windows PATH exposure

WSL exposes Windows PATH entries inside Linux by default, which can cause the installer
to pick up a Windows PHP binary (`/mnt/c/...`) or hang waiting for it.

Add the following to `/etc/wsl.conf` and restart WSL:

```ini
[interop]
appendWindowsPath=false
```

```sh
printf '\n[interop]\nappendWindowsPath=false\n' | sudo tee -a /etc/wsl.conf
```

Then from Windows PowerShell:

```sh
wsl --shutdown
```

### PHP < 8.1 OpenSSL incompatibility (Linux and macOS only)

PHP versions below 8.1 are not compatible with OpenSSL 3.x, which ships by default on most modern Linux distributions.

> [!TIP]
> Use PHP 8.1 or newer, or build against OpenSSL 1.1 instead.

Workaround for PHP 7.4.x / 8.0.x:

1. Open `ext/openssl/openssl.c`
2. Remove or comment out:
```c
   REGISTER_LONG_CONSTANT("OPENSSL_SSLV23_PADDING", RSA_SSLV23_PADDING, CONST_CS|CONST_PERSISTENT);
```
3. Re-run the build

> [!WARNING]
> Full compatibility is not guaranteed. This is a best-effort workaround only.

### PHP < 7.2 requires libmcrypt (Linux and macOS only)

PHP versions below 7.2 depend on `libmcrypt`, which is not installed automatically. Install it manually before running `mise install`:

| Distro | Command |
|---|---|
| Debian/Ubuntu | `sudo apt-get install libmcrypt-dev` |
| Fedora | `sudo dnf install libmcrypt-devel` |
| RHEL/Rocky/Alma | `sudo dnf install epel-release && sudo dnf install libmcrypt-devel` |
| Arch | `sudo pacman -S libmcrypt` |

> [!Note]
> `mcrypt` was removed in PHP 7.2. Consider using PHP 7.2 or newer instead.

## Contributing

```sh
# Link your plugin for development
mise plugin link php-dev /path/to/verzly/mise-php

# Enable force PHP verbose
mise config set env._.php-dev.verbose true

# Test
mise install php-dev@latest
```

## License & Acknowledgments

This project would not exist without the PHP Foundation and the creators and contributors of [mise-en-place](https://github.com/jdx/mise). It is open source and released under the [GNU Affero General Public License v3.0 (AGPL-3.0)](https://www.gnu.org/licenses/agpl-3.0.html).

We are grateful to the PHP Foundation for maintaining PHP, and to the creators and contributors of [mise-en-place](https://github.com/jdx/mise) for the robust version management ecosystem and plugin support.

Copyright (C) 2020–present [Zoltán Rózsa](https://github.com/rozsazoltan) & [Verzly](https://github.com/verzly)
