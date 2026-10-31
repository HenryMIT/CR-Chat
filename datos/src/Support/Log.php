<?php

namespace App\Support;

/**
 * Logs estructurados (una línea JSON por evento) hacia stderr / log de Apache.
 * Nunca se registran contraseñas, tokens, contenido de mensajes ni teléfonos completos.
 */
final class Log
{
    public static ?string $requestId = null;

    public static function info(string $msg, array $ctx = []): void
    {
        self::write('info', $msg, $ctx);
    }

    public static function warning(string $msg, array $ctx = []): void
    {
        self::write('warning', $msg, $ctx);
    }

    public static function error(string $msg, array $ctx = []): void
    {
        self::write('error', $msg, $ctx);
    }

    private static function write(string $level, string $msg, array $ctx): void
    {
        $line = ['ts' => Time::now(), 'level' => $level, 'msg' => $msg] + $ctx;
        if (self::$requestId !== null) {
            $line['request_id'] = self::$requestId;
        }
        $json = json_encode($line, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
        if (PHP_SAPI === 'cli') {
            fwrite(STDERR, $json . PHP_EOL);
        } else {
            error_log($json);
        }
    }
}
