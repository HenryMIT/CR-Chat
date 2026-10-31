<?php

namespace App\Support;

use libphonenumber\NumberParseException;
use libphonenumber\PhoneNumberFormat;
use libphonenumber\PhoneNumberUtil;

/**
 * Teléfonos en E.164 estricto. Primero el patrón exacto del contrato (^\+[1-9][0-9]{7,14}$),
 * que ya rechaza cualquier cosa con forma de email (cierra el robo de cuenta del login), y después
 * libphonenumber para comprobar que la longitud es posible para el país.
 */
final class Phone
{
    public const PATTERN = '/^\+[1-9][0-9]{7,14}$/';

    public static function looksE164(string $value): bool
    {
        return preg_match(self::PATTERN, $value) === 1;
    }

    /** Devuelve el teléfono normalizado o null si no es válido. */
    public static function normalize(mixed $value): ?string
    {
        if (!is_string($value) || !self::looksE164($value)) {
            return null;
        }
        $util = PhoneNumberUtil::getInstance();
        try {
            $number = $util->parse($value, null);
        } catch (NumberParseException) {
            return null;
        }
        if (!$util->isPossibleNumber($number)) {
            return null;
        }
        $e164 = $util->format($number, PhoneNumberFormat::E164);
        return self::looksE164($e164) ? $e164 : null;
    }

    /** Versión enmascarada para logs (+5068****01). */
    public static function mask(string $phone): string
    {
        return strlen($phone) > 6 ? substr($phone, 0, 5) . str_repeat('*', strlen($phone) - 7) . substr($phone, -2) : '***';
    }
}
