<?php

namespace App\Services;

use App\Support\Config;
use Redis;

/**
 * Comprobación de sesión activa en cada petición (A-07) y en el WS.
 *   sess:{sid}      = uuid del usuario (caché positiva; TTL = vida del access o 60 s tras consultar la BD)
 *   sess:rev:{sid}  = marca de revocación (TTL > vida del access), se consulta primero
 * Si falta la caché se consulta fn_tocar_sesion (BD, pool rw). Así logout, revocación, cambio de
 * contraseña o baja invalidan el access token al momento, aunque Redis no esté disponible.
 */
class SessionGuard
{
    public function __construct(
        private readonly Db $db,
        private readonly RedisConn $redis,
        private readonly Config $config
    ) {
    }

    public function isActive(string $userId, string $sessionId): bool
    {
        $cached = $this->redis->run(function (Redis $r) use ($sessionId) {
            [$revoked, $owner] = $r->multi(Redis::PIPELINE)->exists("sess:rev:$sessionId")->get("sess:$sessionId")->exec();
            return $revoked ? 'revoked' : ($owner ?: null);
        });
        if ($cached === 'revoked') {
            return false;
        }
        if ($cached === $userId) {
            return true;
        }
        $active = (bool) $this->db->value('fn_tocar_sesion', ['p_usuario' => $userId, 'p_sesion' => $sessionId]);
        if ($active) {
            $this->redis->run(fn(Redis $r) => $r->setex("sess:$sessionId", 60, $userId));
        }
        return $active;
    }

    /** Tras login / refresh: la sesión queda en caché durante la vida del access token. */
    public function remember(string $userId, string $sessionId): void
    {
        $this->redis->run(fn(Redis $r) => $r->setex("sess:$sessionId", $this->config->accessTtl, $userId));
    }

    /** Tras revocar (después del COMMIT): borra la caché y deja la marca de revocación. */
    public function revoked(array $sessionIds): void
    {
        if (!$sessionIds) {
            return;
        }
        $ttl = $this->config->accessTtl + $this->config->jwtLeeway + 60;
        $this->redis->run(function (Redis $r) use ($sessionIds, $ttl) {
            $p = $r->multi(Redis::PIPELINE);
            foreach ($sessionIds as $sid) {
                $p->del("sess:$sid")->setex("sess:rev:$sid", $ttl, '1');
            }
            return $p->exec();
        });
    }
}
