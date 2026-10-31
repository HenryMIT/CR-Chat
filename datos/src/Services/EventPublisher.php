<?php

namespace App\Services;

use App\Support\Log;
use App\Support\Time;
use App\Support\Uuid;
use Redis;

/**
 * Publica eventos en Redis pub/sub para el servidor WS (docs/contratos/ws-eventos.md §4.1).
 * Se llama siempre DESPUÉS del COMMIT (cada función de BD es atómica en autocommit).
 * Si Redis falla, la petición REST no falla: se registra un aviso y el cliente resincroniza.
 */
class EventPublisher
{
    public function __construct(private readonly RedisConn $redis)
    {
    }

    public static function envelope(string $type, array $data): array
    {
        return ['type' => $type, 'id' => Uuid::v4(), 'ts' => Time::now(), 'data' => $data];
    }

    /** Un sobre por usuario: $events = [userId => [type, data]] o el mismo evento para todos. */
    public function toUsers(array $userIds, string $type, array $data): void
    {
        $event = self::envelope($type, $data);
        $this->publishMany(array_map(fn($u) => ["user:$u", $event], array_values(array_unique($userIds))));
    }

    public function toUser(string $userId, string $type, array $data): void
    {
        $this->publishMany([["user:$userId", self::envelope($type, $data)]]);
    }

    /** Evento interno: el WS cierra las conexiones de esas sesiones con 4401 (session_revoked). */
    public function sessionsRevoked(array $sessionIds, string $reason): void
    {
        $this->publishMany(array_map(
            fn($sid) => ["session:$sid", self::envelope('session.revoked', ['session_id' => $sid, 'reason' => $reason])],
            $sessionIds
        ));
    }

    /** @param list<array{0:string,1:array}> $items canal => sobre */
    public function publishMany(array $items): void
    {
        if (!$items) {
            return;
        }
        $ok = $this->redis->run(function (Redis $r) use ($items) {
            $p = $r->multi(Redis::PIPELINE);
            foreach ($items as [$channel, $event]) {
                $p->publish($channel, json_encode($event, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
            }
            $p->exec();
            return true;
        }, false);
        if (!$ok) {
            Log::warning('event_publish_failed', ['types' => array_values(array_unique(array_map(fn($i) => $i[1]['type'], $items)))]);
        }
    }
}
