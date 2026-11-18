<?php

namespace App\Support;

use Normalizer;

// Normalización NFC y rechazo de caracteres de control (G-06).
final class Text
{
    /** Texto de una línea (nombres, alias, descripción): NFC, recortado, sin caracteres de control. */
    public static function line(string $value): ?string
    {
        $value = self::nfc($value);
        if ($value === null || preg_match('/[\p{Cc}\x{2028}\x{2029}]/u', $value) === 1) {
            return null;
        }
        return trim($value);
    }

    /** Texto multilínea (mensajes): NFC, admite \n y \t, sin otros caracteres de control. */
    public static function multiline(string $value): ?string
    {
        $value = self::nfc(str_replace("\r\n", "\n", $value));
        if ($value === null || preg_match('/[^\P{Cc}\n\t]/u', $value) === 1) {
            return null;
        }
        return $value;
    }

    public static function length(string $value): int
    {
        return mb_strlen($value, 'UTF-8');
    }

    private static function nfc(string $value): ?string
    {
        if (!mb_check_encoding($value, 'UTF-8')) {
            return null;
        }
        $normalized = Normalizer::normalize($value, Normalizer::FORM_C);
        return $normalized === false ? null : $normalized;
    }
}
