<?php

namespace App\Support;

use DateTimeImmutable;
use DateTimeZone;

// Fechas RFC 3339 en UTC con milisegundos (2026-10-29T14:03:12.123Z).
final class Time
{
    public static function now(): string
    {
        return self::format(new DateTimeImmutable('now'));
    }

    public static function fromUnix(int $seconds): string
    {
        return self::format((new DateTimeImmutable())->setTimestamp($seconds));
    }

    /** Convierte un timestamptz de PostgreSQL (o null) a RFC 3339 UTC. */
    public static function rfc3339(?string $value): ?string
    {
        if ($value === null || $value === '') {
            return null;
        }
        return self::format(new DateTimeImmutable($value));
    }

    private static function format(DateTimeImmutable $d): string
    {
        return $d->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\TH:i:s.v\Z');
    }
}
