# verzly/mise-php

> [!IMPORTANT]
> The plugin requires a MISE installation to be used. <a href="https://github.com/jdx/mise#quickstart" target="_blank">Go to Quickstart</a>

## How does it differ from the other mise-php plugins?

Although some PHP plugins are available for MISE, they often encounter errors on either Windows or various Linux distributions. The most common issue is locating the correct PHP versions. This is because PHP maintains its latest and older releases on different sites. Moreover, Windows and Linux installers are separated.

The officially released PHP versions are provided by `verzly/mise-php` for Linux, macOS, and Windows. Additionally, it installs a dedicated Composer for each PHP version to help you avoid version conflicts.

### Pre-binaries

On Windows, we can work quickly using precompiled binaries.

### Build from source

For Linux and macOS systems, precompiling for each system is time-consuming, so the `verzly/mise-php` plugin builds the necessary binaries from the PHP source on each user's system when installing the given version. This process is time-consuming and can take anywhere from 1 to 5 minutes, depending on the machine (or virtual machine). The dependencies required for this are listed in `/bin/install-dependencies.sh`, which the system runs automatically.

### Cleanup

Before starting the process, it is recommended to make sure that no PHP or Composer installations exist on your system from other sources. If there are, it is advisable to remove them, as from this point onward, `verzly/mise-php` will be responsible for providing access to the PHP and Composer executables.

## Get started

To install PHP versions on any operating system using the `verzly/mise-php` plugin, you first need a one-time setup.

```none
# Install the plugin
mise plugin install php https://github.com/verzly/mise-php

# Install/Select version globally
mise use -g php@8

# Install/Select version locally (for current directory)
cd /path/to/php/project
mise use php@7.3
```

Once the plugin is installed, you can [start managing PHP versions](#usage).

### Up-to-date

These are stable versions, but plugin updates may occur, which you can later install with a single command.

```none
# Upgrade plugin to latest version instantly
mise plugin upgrade php
```

## Usage

After installing the plugin, Mise enables the installation of packages named php via the `verzly/mise-php` plugin.

### PHP

You can install multiple PHP versions simultaneously. You can select a version to use globally, but you can also specify project-specific versions for individual projects. We work with official PHP releases - anything released on php.net can be installed.

```none
# Check available PHP versions
mise ls-remote php

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
```

The list of version numbers is not gathered directly from [`php/php-src`](https://github.com/php/php-src/releases), because the GitHub API enforces rate limiting after a certain number of requests. Instead, we update our `versions.txt` file from a `cache` branch once per day, so it's possible that a release may only be installable via the `verzly/mise-php` plugin with a one-day delay, or may require a manual update.

### Composer for PHP

Each PHP version uses its own Composer binary, while sharing the global Composer configuration and cache (`~/.config/composer`, `~/.cache/composer`). This means repositories, authentication, and cache are reused across PHP versions, but Composer always runs against the currently active PHP runtime.

> [!WARNING]
> Global packages are not fully version-independent. If a package only supports a specific PHP range (e.g. 8.1-8.5), switching to an older PHP version (e.g. 8.0 or 7.4) may require reinstalling a compatible (older) version of that package.

```none
# Latest Composer major
composer self-update

# Latest Composer 2 minor, patch
composer self-update 2

# Latest Composer 2.7 patch
composer self-update 2.7

# Only Composer 2.7.9 patch
composer self-update 2.7.9

# Roll back to the previous version
composer self-update --rollback

# Update to latest preview/RC version
composer self-update --preview

# Update to latest snapshot/development version
composer self-update --snapshot

# Check current Composer version
composer --version
```

Have you used Composer before installing verzly/mise-php? Check for and remove any unnecessary Composer binaries.

```none
# Linux / macOS
type -a composer

sudo rm -f /path/to/composer
# Do NOT remove the verzly/mise-php Composer:
# ~/.local/share/mise/installs/php/8.5.4/bin/composer

# Windows (PowerShell)
Get-Command composer -All

Remove-Item "C:\path\to\composer.exe" -Force
# Do NOT remove the verzly/mise-php Composer:
# %LOCALAPPDATA%\mise\shims\composer.exe
```

## Contributing

```none
# Link your plugin for development
mise plugin link php /path/to/verzly/mise-php
```

## License & Acknowledgments

This project would not exist without the PHP Foundation and the creators and contributors of Mise-en-Place. It is open source and released under the [GNU Affero General Public License v3.0 (AGPL-3.0)](https://www.gnu.org/licenses/agpl-3.0.html).

We are grateful to the PHP Foundation for maintaining PHP, and to the creators and contributors of Mise-en-Place for the robust version management ecosystem and plugin support.

Copyright (C) 2020–present [Zoltán Rózsa](https://github.com/rozsazoltan) & [Verzly](https://github.com/verzly)
