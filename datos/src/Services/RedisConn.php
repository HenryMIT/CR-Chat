<?php

namespace App\Services;

use App\Support\Config;
use App\Support\Log;
use Redis;
use Throwable;

/**
 * Conexión perezosa a Redis (phpredis) con timeouts de 1 s. Si Redis no responde devuelve null
 * y quien llama degrada con elegancia (sesiones -> BD, rate limit -> abierto, eventos -> se pierden).
 */
class RedisConn
{
    private ?Redis $redis = null;
    private float $retryAfter = 0.0;

    public function __construct(private readonly Config $config)
    {
    }

    public function get(): ?Redis
    {
        if ($this->redis !== null) {
            return $this->redis;
        }
        if (microtime(true) < $this->retryAfter) {
            return null;
        }
        try {
            $r = new Redis();
            @$r->connect($this->config->redis['host'], $this->config->redis['port'], 1.0, null, 0, 1.0);
            if ($this->config->redis['password'] !== null) {
                $r->auth($this->config->redis['password']);
            }
            if ($this->config->redis['db'] !== 0) {
                $r->select($this->config->redis['db']);
            }
            return $this->redis = $r;
        } catch (Throwable $e) {
            Log::warning('redis_unavailable', ['error' => $e->getMessage()]);
            $this->retryAfter = microtime(true) + 5;
            return null;
        }
    }

    /** Ejecuta $fn con la conexión; ante error la descarta y devuelve $fallback. */
    public function run(callable $fn, mixed $fallback = null): mixed
    {
        $r = $this->get();
        if ($r === null) {
            return $fallback;
        }
        try {
            return $fn($r);
        } catch (Throwable $e) {
            Log::warning('redis_error', ['error' => $e->getMessage()]);
            $this->redis = null;
            return $fallback;
        }
    }

    public function ping(): bool
    {
        return $this->run(fn(Redis $r) => (bool) $r->ping(), false);
    }
}
