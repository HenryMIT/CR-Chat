<?php

namespace App\Support;

// Deriva un nombre legible de dispositivo (p. ej. "Firefox en Linux") si el cliente no envía device_name.
final class UserAgent
{
    public static function deviceName(string $ua): string
    {
        if (trim($ua) === '') {
            return 'Dispositivo desconocido';
        }
        $browser = match (true) {
            str_contains($ua, 'Edg/') => 'Edge',
            str_contains($ua, 'OPR/') => 'Opera',
            str_contains($ua, 'Firefox/') => 'Firefox',
            str_contains($ua, 'Chrome/') => 'Chrome',
            str_contains($ua, 'Safari/') => 'Safari',
            str_starts_with($ua, 'curl/') => 'curl',
            str_starts_with($ua, 'Python') || str_contains($ua, 'python') => 'Python',
            str_contains($ua, 'okhttp') => 'Android (app)',
            default => null,
        };
        $os = match (true) {
            str_contains($ua, 'Android') => 'Android',
            str_contains($ua, 'iPhone') || str_contains($ua, 'iPad') => 'iOS',
            str_contains($ua, 'Windows') => 'Windows',
            str_contains($ua, 'Mac OS X') || str_contains($ua, 'Macintosh') => 'macOS',
            str_contains($ua, 'CrOS') => 'ChromeOS',
            str_contains($ua, 'Linux') => 'Linux',
            default => null,
        };
        $name = match (true) {
            $browser !== null && $os !== null => "$browser en $os",
            $browser !== null => $browser,
            $os !== null => "Navegador en $os",
            default => 'Dispositivo desconocido',
        };
        return mb_substr($name, 0, 100);
    }
}
