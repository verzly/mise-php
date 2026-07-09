local windows_pie = {}

function windows_pie.normalizer_script()
    return [=[<?php
declare(strict_types=1);

$phpPath = realpath(__DIR__ . DIRECTORY_SEPARATOR . 'php.exe') ?: (__DIR__ . DIRECTORY_SEPARATOR . 'php.exe');
$extensionDir = ini_get('extension_dir') ?: (__DIR__ . DIRECTORY_SEPARATOR . 'ext');
$extensionDir = rtrim((string) $extensionDir, "\\/");
$pieRoot = getenv('APPDATA') ? getenv('APPDATA') . DIRECTORY_SEPARATOR . 'PIE' : null;

if ($pieRoot === null || ! is_dir($pieRoot) || ! is_dir($extensionDir)) {
    exit(0);
}

$normalizePath = static function (string $path): string {
    $real = realpath($path);
    $path = $real !== false ? $real : $path;
    return strtolower(str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $path));
};

$phpPathNormalized = $normalizePath($phpPath);
$extensionDirNormalized = $normalizePath($extensionDir);
$iniPath = php_ini_loaded_file() ?: null;
$iniContent = $iniPath !== null && is_file($iniPath) ? file_get_contents($iniPath) : false;
$iniChanged = false;

$iterator = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($pieRoot, FilesystemIterator::SKIP_DOTS)
);

foreach ($iterator as $file) {
    if ($file->getFilename() !== 'installed.json') {
        continue;
    }

    $jsonPath = $file->getPathname();
    $json = json_decode((string) file_get_contents($jsonPath), true);

    if (! is_array($json) || ! isset($json['packages']) || ! is_array($json['packages'])) {
        continue;
    }

    $changed = false;

    foreach ($json['packages'] as &$package) {
        if (! isset($package['extra']) || ! is_array($package['extra'])) {
            continue;
        }

        $extra = &$package['extra'];
        $targetPhp = $extra['pie-target-platform-php-path'] ?? null;
        $installedBinary = $extra['pie-installed-binary'] ?? null;

        if (! is_string($targetPhp) || ! is_string($installedBinary)) {
            continue;
        }

        if ($normalizePath($targetPhp) !== $phpPathNormalized) {
            continue;
        }

        if (! is_file($installedBinary)) {
            continue;
        }

        $binaryDirectory = dirname($installedBinary);
        if ($normalizePath($binaryDirectory) !== $extensionDirNormalized) {
            continue;
        }

        $binaryName = basename($installedBinary);
        if (! preg_match('/^php_([A-Za-z0-9_]+)\.dll$/', $binaryName, $matches)) {
            continue;
        }

        $extensionName = strtolower($matches[1]);
        $aliasBinary = $extensionDir . DIRECTORY_SEPARATOR . $extensionName . '.dll';

        if (! is_file($aliasBinary) || hash_file('sha256', $aliasBinary) !== hash_file('sha256', $installedBinary)) {
            copy($installedBinary, $aliasBinary);
        }

        $sourcePdb = preg_replace('/\.dll$/i', '.pdb', $installedBinary);
        $aliasPdb = preg_replace('/\.dll$/i', '.pdb', $aliasBinary);
        if (is_string($sourcePdb) && is_string($aliasPdb) && is_file($sourcePdb) && ! is_file($aliasPdb)) {
            copy($sourcePdb, $aliasPdb);
        }

        if (($extra['pie-installed-binary'] ?? null) !== $aliasBinary) {
            $extra['pie-installed-binary'] = $aliasBinary;
            $changed = true;
        }

        if ($iniContent !== false) {
            $pattern = '/^(\s*(?:zend_extension|extension)\s*=\s*)"?' . preg_quote($extensionName, '/') . '"?\s*$/mi';
            $replacement = '$1' . $extensionName . '.dll';
            $updatedIni = preg_replace($pattern, $replacement, $iniContent);

            if (is_string($updatedIni) && $updatedIni !== $iniContent) {
                $iniContent = $updatedIni;
                $iniChanged = true;
            }
        }
    }
    unset($package);

    if ($changed) {
        file_put_contents(
            $jsonPath,
            json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL,
            LOCK_EX
        );
    }
}

if ($iniChanged && $iniPath !== null && is_string($iniContent)) {
    file_put_contents($iniPath, $iniContent, LOCK_EX);
}
]=]
end

return windows_pie
