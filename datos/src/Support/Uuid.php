<?php

namespace App\Support;

// Los ids públicos son UUID opacos (la BD genera v4); no se asume ninguna versión.
final class Uuid
{
    private const PATTERN = '/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i';

    public static function isValid(mixed $value): bool
    {
        return is_string($value) && preg_match(self::PATTERN, $value) === 1;
    }

    public static function v4(): string
    {
        $b = random_bytes(16);
        $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
        $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
        return self::fromBytes($b);
    }

    public static function toBytes(string $uuid): string
    {
        return hex2bin(str_replace('-', '', $uuid));
    }

    public static function fromBytes(string $bytes): string
    {
        $h = bin2hex($bytes);
        return sprintf('%s-%s-%s-%s-%s', substr($h, 0, 8), substr($h, 8, 4), substr($h, 12, 4), substr($h, 16, 4), substr($h, 20));
    }
}
