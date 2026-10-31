<?php

namespace App\Support;

final class Base64Url
{
    public static function encode(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }

    public static function decode(string $data): ?string
    {
        if (preg_match('/^[A-Za-z0-9_-]*$/', $data) !== 1) {
            return null;
        }
        $raw = base64_decode(strtr($data, '-_', '+/'), true);
        return $raw === false ? null : $raw;
    }
}
