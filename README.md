# verzly/mise-php

> [!IMPORTANT]
> The plugin requires a MISE installation to be used. <a href="https://github.com/jdx/mise#quickstart" target="_blank">Go to Quickstart</a>

## How does it differ from the other mise-php plugins?

Although several PHP plugins are available for MISE, they often encounter errors on either Windows or various Linux distributions. The most common issue is locating the correct PHP versions. This is because PHP maintains its latest and older releases on different sites. Moreover, Windows and Linux installers are separated.

In the `verzly/php` repository, we collect these installers with daily updates and bundle all installers under a single release, associating them with the appropriate PHP version. The sole purpose of the `verzly/mise-php` plugin is to serve the necessary PHP version installers for both Windows and Linux systems based on the version numbers from `verzly/php`.

## Get started

```none
# Install the plugin
mise plugin install php https://github.com/verzly/mise-php

# Install development tools: gcc, g++, make, and other build essentials
sudo dnf groupinstall "Development Tools"

# Install PHP lexer/parser tools required by buildconf
sudo dnf install bison re2c

# Install locate utility for searching files
# Use plocate instead of mlocate
sudo dnf install plocate
sudo updatedb  # Update the locate database

# Install development headers/libraries for PHP dependencies
# Use --enablerepo=crb flag for oniguruma-devel and libzip-devel
sudo dnf install \
  libxml2-devel bzip2 bzip2-devel zlib-devel \
  libjpeg-turbo-devel libpng-devel freetype-devel icu libicu-devel \
  oniguruma oniguruma-devel readline-devel libzip-devel openssl-devel \
  curl curl-devel libedit-devel libxslt-devel \
  --enablerepo=crb

# Optional: required if building PHP-FPM
sudo dnf install systemd-devel

# Install version
mise install php@8.4
```

## Contributing

```none
# Link your plugin for development
mise plugin link php /path/to/verzly-php
```

## License

This project is a plugin created for MISE by [Zoltán Rózsa](https://github.com/rozsazoltan) under the [GNU Affero General Public License v3.0 (AGPL-3.0)](https://www.gnu.org/licenses/agpl-3.0.html).

Copyright (C) 2020–present [Zoltán Rózsa](https://github.com/rozsazoltan) & [Verzly](https://github.com/verzly)

This version is licensed under the AGPL-3.0.  
For full license terms, see the [LICENSE](./LICENSE) file.

## Credits

This project is made possible by much love and the other open source software.

|Name|License|
|:---|:---|
|[verzly/php](https://github.com/verzly/php)|MIT License © [Zoltán Rózsa](https://github.com/verzly/mise-php) & [Verzly](https://github.com/verzly)|

## Thanks

Appreciation goes to [GitHub Actions](https://github.com/features/actions) for enabling a dependable continuous integration system, which has been essential throughout the development process.

Finally, a heartfelt thank you to the broader [open-source](https://github.com/open-source) community and to the maintainers of the libraries used in this project. Your ongoing efforts make projects like this possible.

**Motivation:** Because _together_, nothing is impossible.
