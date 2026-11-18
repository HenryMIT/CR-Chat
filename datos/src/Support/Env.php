<?php

namespace App\Support;

// Lectura de variables de entorno (docker `environment`, `.env` cargado por phpdotenv o getenv()).
final class Env
{
    public static function get(string $name, ?string $default = null): ?string
    {
        $value = $_ENV[$name] ?? $_SERVER[$name] ?? getenv($name);
        if ($value === false || $value === null || $value === '') {
            return $default;
        }
        return (string) $value;
    }

    public static function int(string $name, int $default): int
    {
        $value = self::get($name);
        return $value === null ? $default : (int) $value;
    }

    public static function bool(string $name, bool $default = false): bool
    {
        $value = self::get($name);
        return $value === null ? $default : filter_var($value, FILTER_VALIDATE_BOOLEAN);
    }

    /** Lista separada por comas, sin elementos vacíos. */
    public static function list(string $name, array $default = []): array
    {
        $value = self::get($name);
        if ($value === null) {
            return $default;
        }
        return array_values(array_filter(array_map('trim', explode(',', $value)), fn($v) => $v !== ''));
    }

    public static function required(string $name): string
    {
        $value = self::get($name);
        if ($value === null) {
            throw new \RuntimeException("Falta la variable de entorno obligatoria $name.");
        }
        return $value;
    }
}
