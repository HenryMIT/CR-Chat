<?php

namespace App\Ws;

use App\Support\Log;
use Workerman\Connection\AsyncTcpConnection;
use Workerman\Timer;

/**
 * Suscriptor asíncrono mínimo de Redis (RESP2) para el bucle de eventos de Workerman:
 * AUTH + PSUBSCRIBE de los patrones y reconexión automática (con nueva suscripción) si Redis cae.
 * Se escribió a mano (~100 líneas) para no depender de un cliente asíncrono completo: solo hace falta
 * recibir `pmessage`. Los comandos normales (PUBLISH, INCR...) van por phpredis (síncrono, rápido).
 */
class RedisSubscriber
{
    private ?AsyncTcpConnection $conn = null;
    private string $buffer = '';

    /** @param callable(string $channel, string $payload): void $onMessage */
    public function __construct(
        private readonly string $host,
        private readonly int $port,
        private readonly ?string $password,
        private readonly array $patterns,
        private $onMessage
    ) {
    }

    public function start(): void
    {
        $this->buffer = '';
        $conn = new AsyncTcpConnection("tcp://{$this->host}:{$this->port}");
        $conn->onConnect = function (AsyncTcpConnection $c) {
            $cmds = '';
            if ($this->password !== null) {
                $cmds .= self::command(['AUTH', $this->password]);
            }
            $cmds .= self::command(array_merge(['PSUBSCRIBE'], $this->patterns));
            $c->send($cmds);
            Log::info('ws_redis_subscribed', ['patterns' => $this->patterns]);
        };
        $conn->onMessage = function (AsyncTcpConnection $c, string $data) {
            $this->buffer .= $data;
            $offset = 0;
            while (($value = self::parse($this->buffer, $offset)) !== null) {
                $this->buffer = substr($this->buffer, $offset);
                $offset = 0;
                $this->dispatch($value[0]);
            }
        };
        $conn->onClose = function () {
            Log::warning('ws_redis_disconnected');
            Timer::add(2, fn() => $this->start(), [], false);
        };
        $conn->onError = function ($c, $code, $msg) {
            Log::warning('ws_redis_error', ['code' => $code, 'error' => $msg]);
        };
        $this->conn = $conn;
        $conn->connect();
    }

    private function dispatch(mixed $value): void
    {
        if ($value instanceof RespError) {
            Log::error('ws_redis_reply_error', ['error' => $value->message]);
            return;
        }
        if (is_array($value) && ($value[0] ?? null) === 'pmessage' && count($value) === 4) {
            try {
                ($this->onMessage)((string) $value[2], (string) $value[3]);
            } catch (\Throwable $e) {
                Log::error('ws_dispatch_failed', ['error' => $e->getMessage(), 'where' => basename($e->getFile()) . ':' . $e->getLine()]);
            }
        }
    }

    public static function command(array $parts): string
    {
        $out = '*' . count($parts) . "\r\n";
        foreach ($parts as $p) {
            $p = (string) $p;
            $out .= '$' . strlen($p) . "\r\n" . $p . "\r\n";
        }
        return $out;
    }

    /**
     * Analiza un valor RESP desde $offset. Devuelve [valor] y avanza $offset, o null si el
     * buffer aún no contiene el valor completo.
     */
    public static function parse(string $buf, int &$offset): ?array
    {
        $end = strpos($buf, "\r\n", $offset);
        if ($end === false) {
            return null;
        }
        $type = $buf[$offset];
        $line = substr($buf, $offset + 1, $end - $offset - 1);
        $next = $end + 2;
        switch ($type) {
            case '+':
                $offset = $next;
                return [$line];
            case '-':
                $offset = $next;
                return [new RespError($line)];
            case ':':
                $offset = $next;
                return [(int) $line];
            case '$':
                $len = (int) $line;
                if ($len < 0) {
                    $offset = $next;
                    return [null];
                }
                if (strlen($buf) < $next + $len + 2) {
                    return null;
                }
                $offset = $next + $len + 2;
                return [substr($buf, $next, $len)];
            case '*':
                $count = (int) $line;
                $items = [];
                $pos = $next;
                for ($i = 0; $i < $count; $i++) {
                    $item = self::parse($buf, $pos);
                    if ($item === null) {
                        return null;
                    }
                    $items[] = $item[0];
                }
                $offset = $pos;
                return [$count < 0 ? null : $items];
            default:
                throw new \UnexpectedValueException('Respuesta RESP inválida.');
        }
    }
}
