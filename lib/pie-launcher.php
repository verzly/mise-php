<?php
declare(strict_types=1);

function pie_fail(string $message): never
{
    fwrite(STDERR, "mise-php PIE: {$message}\n");
    exit(2);
}

set_error_handler(static function (int $severity, string $message): never {
    throw new RuntimeException($message);
});

function pie_output(array $command, ?array $env = null): string
{
    $process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => STDERR], $pipes, null, $env);
    if (!is_resource($process)) throw new RuntimeException('cannot inspect managed toolchain');
    fclose($pipes[0]);
    $output = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    if (proc_close($process) !== 0) throw new RuntimeException('managed toolchain inspection failed');
    return trim($output);
}

function pie_inside(string $path, string $sdk): bool
{
    $real = realpath($path);
    return $real !== false && str_starts_with($real, $sdk . DIRECTORY_SEPARATOR);
}

function pie_canonical(string $path): string
{
    if ($path === '' || $path[0] !== '/') throw new RuntimeException('expected absolute managed directory');
    $parts = explode('/', $path); $resolved = '';
    foreach ($parts as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') { $resolved = dirname($resolved); continue; }
        $resolved = rtrim($resolved, '/') . '/' . $part;
        if (is_link($resolved) && realpath($resolved) === false) throw new RuntimeException('broken managed directory symlink');
        if (file_exists($resolved)) $resolved = realpath($resolved);
    }
    return $resolved;
}

function pie_state(string $sdk, string $php, string $config, string $version): array
{
    $result = []; $packages = [];
    foreach (glob($sdk . '/.pie/php*/vendor/composer/installed.json') ?: [] as $file) {
        if (!pie_inside($file, $sdk)) throw new RuntimeException('PIE metadata escapes managed SDK');
        $json = file_get_contents($file);
        $document = json_decode($json, false, 512, JSON_THROW_ON_ERROR);
        if (!$document instanceof stdClass || !is_array($document->packages ?? null)) throw new RuntimeException('invalid PIE installed.json schema');
        $state = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        foreach ($state['packages'] as $package) {
            if (!is_array($package)) throw new RuntimeException('invalid PIE package metadata');
            if (!in_array($package['type'] ?? null, ['php-ext', 'php-ext-zend'], true)) continue;
            $extra = $package['extra'] ?? [];
            if (!is_array($extra)) throw new RuntimeException('invalid PIE extension metadata');
            if (!isset($extra['pie-installed-binary'])) continue;
            if (!is_string($extra['pie-target-platform-php-path'] ?? null) || realpath($extra['pie-target-platform-php-path']) !== realpath($php)) continue;
            if (!is_string($extra['pie-target-platform-php-config-path'] ?? null) || realpath($extra['pie-target-platform-php-config-path']) !== realpath($config)) continue;
            if (($extra['pie-target-platform-php-version'] ?? null) !== $version) continue;
            $packageName = $package['name'] ?? '';
            if (!is_string($packageName) || !preg_match('~^[a-z0-9_.-]+/[a-z0-9_.-]+$~i', $packageName)) throw new RuntimeException('invalid PIE package name');
            $meta = $package['php-ext'] ?? [];
            if (!is_array($meta)) throw new RuntimeException('invalid php-ext metadata');
            $name = $meta['extension-name'] ?? null;
            if (!is_string($name) || $name === '') $name = basename($packageName);
            if (is_string($name) && str_starts_with($name, 'ext-')) $name = substr($name, 4);
            if (!is_string($name) || !preg_match('/^[A-Za-z][a-zA-Z0-9_]+$/', $name)) throw new RuntimeException('invalid PIE extension name');
            $priority = $meta['priority'] ?? 80;
            if (!is_int($priority) || $priority < 10 || $priority > 99) throw new RuntimeException('invalid PIE extension priority');
            $binary = $extra['pie-installed-binary']; $checksum = $extra['pie-installed-binary-checksum'] ?? null;
            $key = strtolower($name);
            if (isset($result[$key]) || isset($packages[$packageName])) throw new RuntimeException("ambiguous PIE state for {$name}");
            $packages[$packageName] = true;
            $result[$key] = [$packageName, $name, $priority, $package['type'] === 'php-ext-zend' ? 'zend_extension' : 'extension', $checksum, hash('sha256', json_encode($package, JSON_THROW_ON_ERROR)), $binary];
        }
    }
    return $result;
}

try {
    if ($argc < 2 || ($sdk = realpath($argv[1])) === false) pie_fail('usage: pie-launcher.php SDK_PATH [PIE_ARGUMENTS...]');
    $args = array_slice($argv, 2);
    $php = $sdk . '/bin/php'; $config = $sdk . '/bin/php-config'; $phpize = $sdk . '/bin/phpize'; $phar = $sdk . '/pie.phar';
    if (!is_executable($php) || !is_file($phar)) pie_fail('managed PHP or PIE is missing');
    $targetCommands = ['install', 'upgrade', 'install-extensions-for-project', 'uninstall', 'download', 'build', 'check-build-tools'];
    $otherCommands = ['info', 'show', 'search', 'list', 'help', 'self-update', 'self-verify', 'completion'];
    $command = null; $commandIndex = null; $skip = false; $help = false; $requested = [];
    $flags = ['--help', '-h', '--version', '-V', '--quiet', '-q', '--verbose', '-v', '-vv', '-vvv', '--ansi', '--no-ansi', '--no-interaction', '-n'];
    $values = ['--working-dir', '-d', '--make-parallel-jobs', '-j', '--select', '--format', '--suppress-download-url-method'];
    $commandFlags = ['--skip-enable-extension', '--force', '--no-cache', '--from-lock', '--allow-non-interactive-project-install', '--no-dev', '--auto-install-build-tools', '--no-build-tools-check', '--auto-install-system-dependencies', '--no-system-dependencies-check', '--all', '--nightly', '--preview', '--stable'];
    foreach ($args as $arg) {
        if ($arg === '--') break;
        $option = explode('=', $arg, 2)[0];
        foreach (['--with-php-path', '--with-php-config', '--with-phpize-path'] as $managedOption) {
            if (str_starts_with($option, '--') && str_starts_with($managedOption, $option)) pie_fail('managed PHP target override flags are not allowed');
        }
    }
    $end = false;
    for ($i = 0; $i < count($args); $i++) {
        $arg = $args[$i];
        if (!$end && $arg === '--') { $end = true; continue; }
        if (!$end && in_array($arg, $flags, true)) {
            if (in_array($arg, ['--help', '-h', '--version', '-V'], true)) $help = true;
            continue;
        }
        if ($command === null) {
            if ($end || !in_array($arg, array_merge($targetCommands, $otherCommands), true)) pie_fail("unsupported command or global option: {$arg}");
            $command = $arg; $commandIndex = $i; continue;
        }
        if (!$end && str_starts_with($arg, '-')) {
            [$option] = explode('=', $arg, 2);
            if (in_array($option, $values, true)) {
                if (!str_contains($arg, '=') && (!isset($args[++$i]) || str_starts_with($args[$i], '-'))) pie_fail("missing value for {$option}");
            } elseif (in_array($arg, $commandFlags, true)) {
                if ($arg === '--skip-enable-extension') $skip = true;
            } elseif (!in_array($command, ['install', 'build', 'download'], true) || !preg_match('/^--[A-Za-z][A-Za-z0-9-]*(?:=.*)?$/s', $arg)) {
                pie_fail("unsupported PIE option: {$arg}");
            }
            continue;
        }
        if (preg_match('~^([a-z0-9_.-]+/[a-z0-9_.-]+)(?::[^\s]+)?$~i', $arg, $match)) $requested[$match[1]] = true;
    }
    if ($command === null && !$help) pie_fail('expected a supported PIE command');
    $target = !$help && in_array($command, $targetCommands, true);
    $register = $target && in_array($command, ['install', 'upgrade', 'install-extensions-for-project'], true) && !$skip;
    $scan = $sdk . '/conf.d'; $before = []; $owned = []; $loadedFiles = []; $marker = "; Managed by mise-php PIE.\n";
    $env = getenv();
    $env['PATH'] = $sdk . '/bin' . PATH_SEPARATOR . ($env['PATH'] ?? '');
    $env['PHPRC'] = $sdk; $env['PHP_INI_SCAN_DIR'] = $scan; $env['PIE_WORKING_DIRECTORY'] = $sdk . '/.pie';
    if ($target) {
        if (($env['INSTALL_ROOT'] ?? '') !== '') pie_fail('INSTALL_ROOT is not supported');
        foreach ([$scan, $sdk . '/.pie'] as $directory) {
            if ((file_exists($directory) || is_link($directory)) && (!is_dir($directory) || !pie_inside($directory, $sdk))) pie_fail('managed directory escapes SDK');
        }
        if (!is_executable($config)) pie_fail('managed php-config is unavailable');
        if (realpath(pie_output([$config, '--php-binary'])) !== realpath($php)) pie_fail('managed php-config targets a different PHP');
        $extDir = pie_output([$config, '--extension-dir']);
        $extDir = pie_canonical($extDir);
        if (!str_starts_with($extDir, $sdk . '/')) pie_fail('managed extension directory mismatch');
        $version = pie_output([$php, '-n', '-r', 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION,".",PHP_RELEASE_VERSION;']);
        if (!preg_match('/^\d+\.\d+\.\d+$/', $version)) pie_fail('invalid managed PHP version');
        if (is_link($sdk . '/php.ini') && !pie_inside($sdk . '/php.ini', $sdk)) pie_fail('php.ini escapes managed SDK');
        foreach (is_dir($scan) ? new DirectoryIterator($scan) : [] as $entry) {
            if ($entry->isDot()) continue;
            $ini = $entry->getPathname();
            if (!pie_inside($ini, $sdk)) pie_fail('ini file escapes managed SDK');
            if (is_file($ini) && str_ends_with($ini, '.ini') && str_starts_with(file_get_contents($ini), $marker)) $owned[$ini] = true;
        }
        if ($extDir !== pie_canonical(pie_output([$php, '-r', 'echo ini_get("extension_dir");'], $env))) pie_fail('managed extension directory mismatch');
        $loaded = json_decode(pie_output([$php, '-r', 'echo json_encode([php_ini_loaded_file(), php_ini_scanned_files()]);'], $env), true, 512, JSON_THROW_ON_ERROR);
        foreach (array_merge($loaded[0] ? [$loaded[0]] : [], $loaded[1] ? preg_split('/,\s*/', trim($loaded[1])) : []) as $ini) {
            if (!pie_inside(trim($ini), $sdk)) pie_fail('loaded ini file escapes managed SDK');
            $loadedFiles[] = trim($ini);
        }
        $insert = ['--with-php-config=' . $config];
        if ($command !== 'uninstall') {
            if (!is_executable($phpize)) pie_fail('managed phpize is unavailable');
            $insert[] = '--with-phpize-path=' . $phpize;
        }
        if (in_array($command, ['install', 'upgrade', 'install-extensions-for-project', 'download', 'build'], true) && !$skip) $insert[] = '--skip-enable-extension';
        array_splice($args, $commandIndex + 1, 0, $insert);
        if ($register) $before = pie_state($sdk, $php, $config, $version);
    }
    $process = proc_open(array_merge([$php, $phar], $args), [0 => STDIN, 1 => STDOUT, 2 => STDERR], $pipes, null, $env);
    if (!is_resource($process)) pie_fail('could not start managed PIE');
    $status = proc_close($process);
    if ($status !== 0 || !$register) exit($status);
    clearstatcache(true);
    foreach ([$scan, $sdk . '/.pie'] as $directory) {
        if ((file_exists($directory) || is_link($directory)) && (!is_dir($directory) || !pie_inside($directory, $sdk))) pie_fail('managed directory escapes SDK');
    }
    $after = pie_state($sdk, $php, $config, $version);
    foreach ($requested as $package => $_) {
        if (!array_filter($after, static fn(array $entry): bool => $entry[0] === $package)) pie_fail("missing installed PIE metadata for {$package}");
    }
    $writes = [];
    $iniFiles = array_unique(array_merge($loadedFiles, is_file($sdk . '/php.ini') ? [$sdk . '/php.ini'] : [], glob($scan . '/*.ini') ?: []));
    foreach ($after as $key => $entry) {
        [$package, $name, $priority, $directive] = $entry;
        $old = [];
        foreach ($owned as $path => $_) if (str_ends_with($path, '-mise-pie-' . $name . '.ini')) $old[] = $path;
        if (!isset($requested[$package]) && ($before[$key] ?? null) === $entry && !$old) continue;
        $module = realpath($extDir . '/' . $name . '.so');
        $checksum = $entry[4]; $binary = $entry[6];
        if (!is_string($binary) || !is_string($checksum) || !preg_match('/^[a-f0-9]{64}$/i', $checksum) || $module === false || !pie_inside($module, $sdk) || realpath($binary) !== $module || !hash_equals(strtolower($checksum), hash_file('sha256', $module))) pie_fail("PIE binary verification failed for {$name}");
        $path = sprintf('%s/%02d-mise-pie-%s.ini', $scan, $priority, $name);
        if ((file_exists($path) || is_link($path)) && (!isset($owned[$path]) || is_link($path))) pie_fail("refusing to overwrite user ini for {$name}");
        foreach ($iniFiles as $ini) {
            if (!pie_inside($ini, $sdk)) pie_fail('ini file escapes managed SDK');
            if (in_array($ini, $old, true)) continue;
            foreach (file($ini, FILE_IGNORE_NEW_LINES) as $line) {
                if (!preg_match('/^\s*(?:zend_extension|extension)\s*=\s*(.*?)\s*(?:;.*)?$/i', $line, $match)) continue;
                $loaded = basename(str_replace('\\', '/', trim($match[1], " \t\"'")));
                $loaded = preg_replace('/\.(?:so|dll)$/i', '', $loaded);
                if (strcasecmp($loaded, $name) === 0) pie_fail("extension {$name} is already enabled in {$ini}");
            }
        }
        $writes[] = [$path, $marker . $directive . '=' . $name . "\n", $old];
    }
    if ($writes && !is_dir($scan) && !mkdir($scan, 0777, true)) pie_fail('cannot create managed conf.d');
    foreach ($writes as [$path, $contents, $old]) {
        $tmp = tempnam($scan, '.mise-pie-');
        if ($tmp === false) pie_fail('cannot create registration temporary file');
        try {
            if (file_put_contents($tmp, $contents, LOCK_EX) !== strlen($contents) || !rename($tmp, $path)) throw new RuntimeException('cannot register extension');
        } finally {
            if (file_exists($tmp)) unlink($tmp);
        }
        foreach ($old as $obsolete) if ($obsolete !== $path) unlink($obsolete);
    }
    exit($status);
} catch (Throwable $error) {
    pie_fail($error->getMessage());
}
