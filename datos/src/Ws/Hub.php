<?php

namespace App\Ws;

use App\Exceptions\DatabaseUnavailableException;
use App\Exceptions\DbException;
use App\Exceptions\InvalidTokenException;
use App\Services\Db;
use App\Services\EventPublisher;
use App\Services\RedisConn;
use App\Services\SessionGuard;
use App\Services\TokenService;
use App\Support\Config;
use App\Support\Log;
use App\Support\Time;
use App\Support\Uuid;
use Redis;
use Throwable;
use Workerman\Connection\TcpConnection;
use Workerman\Protocols\Http\Request;
use Workerman\Timer;

/**
 * Lógica del servidor WebSocket (docs/contratos/ws-eventos.md). Un Hub por proceso de Workerman.
 * - Autenticación por el primer mensaje `auth` (nunca en la URL), con la misma validación que
 *   JwtMiddleware + sesión activa (SessionGuard). Reautenticación sobre la misma conexión.
 * - Redis pub/sub: PSUBSCRIBE user:* y session:*; cada proceso reenvía a sus conexiones locales.
 * - typing / seen / presence.query del cliente; presencia online/offline a usuarios relacionados.
 * Las llamadas a la BD y a phpredis son síncronas (rápidas, con timeouts cortos).
 */
class Hub
{
    public const MAX_FRAME = 16384;
    public const MAX_CONN_PER_USER = 10;
    private const HEARTBEAT = 25;
    private const IDLE_LIMIT = 60;
    private const PRESENCE_TTL = 90;
    private const INTERNAL = ['session.revoked', 'block.changed'];

    /** @var array<int, ConnState> */
    private array $state = [];
    /** @var array<int, TcpConnection> */
    private array $conns = [];
    /** @var array<string, array<int, true>> */
    private array $byUser = [];
    /** @var array<string, array<int, true>> */
    private array $bySession = [];
    /** @var array<string, array{0: float, 1: ?array}> conv => [expira, participantes] */
    private array $participantsCache = [];
    /** @var array<string, array{0: float, 1: bool}> "a|b" => [expira, sin bloqueo] */
    private array $relationCache = [];
    /** @var array<string, int> "uid|conv" => timer del stop automático de typing */
    private array $typingTimers = [];
    /** @var array<string, float> "uid|conv" => último start reenviado */
    private array $typingLast = [];
    /** @var array<string, float> ids de eventos ya marcados como entregados */
    private array $deliveredSeen = [];

    public function __construct(
        private readonly Config $config,
        private readonly Db $db,
        private readonly RedisConn $redis,
        private readonly TokenService $tokens,
        private readonly SessionGuard $sessions,
        private readonly EventPublisher $events
    ) {
    }

    // ------------------------------------------------------------------ ciclo de vida

    /** Handshake: valida ruta, Origin (misma lista que CORS) y negocia el subprotocolo cr-chat.v1. */
    public function onHandshake(TcpConnection $conn, Request $request): void
    {
        try {
            if ($request->path() !== '/ws') {
                $conn->close("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", true);
                return;
            }
            $origin = (string) $request->header('origin', '');
            if ($origin !== '' && !in_array($origin, $this->config->corsOrigins, true)) {
                $conn->close("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", true);
                return;
            }
            $protocols = array_map('trim', explode(',', (string) $request->header('sec-websocket-protocol', '')));
            if (in_array('cr-chat.v1', $protocols, true)) {
                $conn->headers = ['Sec-WebSocket-Protocol: cr-chat.v1'];
            }
            $conn->maxPackageSize = 4 * self::MAX_FRAME;
        } catch (Throwable $e) {
            $this->logError('ws_handshake_failed', $e);
            $conn->close("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n", true);
        }
    }

    public function onOpen(TcpConnection $conn): void
    {
        if ($conn->getStatus() !== TcpConnection::STATUS_ESTABLISHED) {
            return;
        }
        $state = new ConnState();
        $this->state[$conn->id] = $state;
        $this->conns[$conn->id] = $conn;
        $state->authTimer = Timer::add(5, function () use ($conn) {
            $s = $this->state[$conn->id] ?? null;
            if ($s !== null && !$s->authenticated()) {
                $this->closeWith($conn, 4001, 'auth_timeout');
            }
        }, [], false);
    }

    public function onMessage(TcpConnection $conn, string $data): void
    {
        $state = $this->state[$conn->id] ?? null;
        if ($state === null) {
            return;
        }
        try {
            $state->lastActive = microtime(true);
            if (strlen($data) > self::MAX_FRAME) {
                $this->closeWith($conn, 1009, 'message_too_big');
                return;
            }
            $msg = json_decode($data, true);
            $type = is_array($msg) && is_string($msg['type'] ?? null) ? $msg['type'] : null;
            $id = is_array($msg) && is_string($msg['id'] ?? null) && strlen($msg['id']) <= 64 ? $msg['id'] : null;
            $payload = is_array($msg) && is_array($msg['data'] ?? null) ? $msg['data'] : [];

            if (!$state->authenticated() && $type !== 'auth') {
                $this->closeWith($conn, 4003, 'not_authenticated');
                return;
            }
            if ($type === null) {
                $this->error($conn, $id, 'invalid_payload', 'Se esperaba un sobre JSON {type, id, ts, data}.');
                return;
            }
            if ($state->authenticated() && !$this->globalLimit($conn, $state, $id)) {
                return;
            }

            match ($type) {
                'auth' => $this->auth($conn, $state, $id, $payload),
                'ping' => $this->ping($conn, $state, $id),
                'typing' => $this->typing($conn, $state, $id, $payload),
                'seen' => $this->seen($conn, $state, $id, $payload),
                'presence.query' => $this->presenceQuery($conn, $state, $id, $payload),
                default => $this->error($conn, $id, 'unknown_type', "Tipo de evento no soportado: $type."),
            };
        } catch (DbException $e) {
            $this->error($conn, $id ?? null, $e->sqlState === 'CR404' ? 'not_found' : ($e->sqlState === 'CR403' ? 'blocked' : 'invalid_payload'),
                $e->sqlState === 'CR404' ? 'Conversación o mensaje no encontrado.' : 'Petición no válida.');
        } catch (Throwable $e) {
            $this->logError('ws_message_failed', $e);
            $this->error($conn, $id ?? null, 'internal', 'Error interno.');
        }
    }

    public function onPong(TcpConnection $conn): void
    {
        if (isset($this->state[$conn->id])) {
            $this->state[$conn->id]->lastActive = microtime(true);
        }
    }

    public function onClose(TcpConnection $conn): void
    {
        $state = $this->state[$conn->id] ?? null;
        unset($this->state[$conn->id], $this->conns[$conn->id]);
        if ($state === null) {
            return;
        }
        foreach ([$state->authTimer, $state->expiringTimer, $state->expiryTimer] as $t) {
            if ($t) {
                Timer::del($t);
            }
        }
        if (!$state->authenticated()) {
            return;
        }
        unset($this->byUser[$state->userId][$conn->id], $this->bySession[$state->sessionId][$conn->id]);
        if (empty($this->bySession[$state->sessionId])) {
            unset($this->bySession[$state->sessionId]);
        }
        if (empty($this->byUser[$state->userId])) {
            unset($this->byUser[$state->userId]);
        }
        try {
            $this->presenceDown($state->userId);
        } catch (Throwable $e) {
            $this->logError('ws_presence_down_failed', $e);
        }
    }

    /** Cada 30 s: ping de control, cierre por inactividad (60 s) y renovación del TTL de presencia. */
    public function heartbeat(): void
    {
        $now = microtime(true);
        foreach ($this->conns as $id => $conn) {
            $state = $this->state[$id] ?? null;
            if ($state === null) {
                continue;
            }
            if ($now - $state->lastActive > self::IDLE_LIMIT) {
                $this->closeWith($conn, 1001, 'heartbeat_timeout');
                continue;
            }
            $prev = $conn->websocketType ?? "\x81";
            $conn->websocketType = "\x89";
            $conn->send('');
            $conn->websocketType = $prev;
        }
        $users = array_keys($this->byUser);
        if ($users) {
            $this->redis->run(function (Redis $r) use ($users) {
                $p = $r->multi(Redis::PIPELINE);
                foreach ($users as $uid) {
                    $p->expire("presence:$uid", self::PRESENCE_TTL);
                }
                return $p->exec();
            });
        }
        // Limpieza de cachés
        $this->participantsCache = array_filter($this->participantsCache, fn($v) => $v[0] > $now);
        $this->relationCache = array_filter($this->relationCache, fn($v) => $v[0] > $now);
        $this->deliveredSeen = array_filter($this->deliveredSeen, fn($t) => $t > $now - 120);
        $this->typingLast = array_filter($this->typingLast, fn($t) => $t > $now - 10);
    }

    // ------------------------------------------------------------------ cliente -> servidor

    private function auth(TcpConnection $conn, ConnState $state, ?string $id, array $data): void
    {
        $token = $data['access_token'] ?? null;
        try {
            if (!is_string($token) || $token === '' || strlen($token) > 4096) {
                throw new InvalidTokenException('Token ausente.');
            }
            $claims = $this->tokens->verifyAccess($token);
            $uid = strtolower($claims->sub);
            $sid = strtolower($claims->sid);
            if ($state->authenticated() && $uid !== $state->userId) {
                throw new InvalidTokenException('El token pertenece a otro usuario.');
            }
            if (!$this->sessions->isActive($uid, $sid)) {
                throw new InvalidTokenException('Sesión revocada.');
            }
        } catch (InvalidTokenException) {
            $this->error($conn, $id, 'invalid_token', 'Token inválido, expirado o de una sesión revocada.');
            $this->closeWith($conn, 4401, 'invalid_token');
            return;
        }

        $first = !$state->authenticated();
        if ($first) {
            Timer::del($state->authTimer);
            $state->authTimer = null;
            $state->userId = $uid;
        } elseif ($state->sessionId !== $sid) {
            unset($this->bySession[$state->sessionId][$conn->id]);
        }
        $state->sessionId = $sid;
        $this->bySession[$sid][$conn->id] = true;
        $this->scheduleExpiry($conn, $state, (int) $claims->exp);

        if ($first) {
            $this->byUser[$uid][$conn->id] = true;
            $this->enforceConnectionLimit($uid);
            $this->presenceUp($uid);
        }

        $this->send($conn, 'auth.ok', [
            'reply_to' => $id,
            'user_id' => $uid,
            'session_id' => $sid,
            'expires_at' => Time::fromUnix($state->exp),
            'heartbeat_interval' => self::HEARTBEAT,
        ]);
    }

    private function ping(TcpConnection $conn, ConnState $state, ?string $id): void
    {
        // Límite: 1 cada 5 s (con tolerancia de ráfaga de 2); el exceso se responde igual sin error
        $state->allow('ping', 2, 5.0);
        $this->send($conn, 'pong', ['reply_to' => $id]);
    }

    private function typing(TcpConnection $conn, ConnState $state, ?string $id, array $data): void
    {
        $conv = $data['conversation_id'] ?? null;
        $mode = $data['state'] ?? null;
        if (!Uuid::isValid($conv) || !in_array($mode, ['start', 'stop'], true)) {
            $this->error($conn, $id, 'invalid_payload', 'typing requiere conversation_id y state (start|stop).');
            return;
        }
        $conv = strtolower($conv);
        $uid = $state->userId;
        $peers = $this->peersOf($uid, $conv);
        if ($peers === null) {
            $this->error($conn, $id, 'not_found', 'Conversación no encontrada.');
            return;
        }
        foreach ($peers as $peer) {
            if (!$this->related($uid, $peer)) {
                $this->error($conn, $id, 'blocked', 'No es posible enviar eventos a este usuario.');
                return;
            }
        }
        $key = "$uid|$conv";
        if ($mode === 'start') {
            // 1 start cada 3 s por conversación: los repetidos solo renuevan la caducidad
            $now = microtime(true);
            $forward = ($this->typingLast[$key] ?? 0) < $now - 3;
            if ($forward) {
                $this->typingLast[$key] = $now;
            }
            if (isset($this->typingTimers[$key])) {
                Timer::del($this->typingTimers[$key]);
            }
            // Un start caduca solo a los 6 s si no llega stop
            $this->typingTimers[$key] = Timer::add(6, function () use ($key, $uid, $conv, $peers) {
                unset($this->typingTimers[$key], $this->typingLast[$key]);
                $this->events->toUsers($peers, 'typing', ['conversation_id' => $conv, 'user_id' => $uid, 'state' => 'stop']);
            }, [], false);
            if (!$forward) {
                return;
            }
        } else {
            if (isset($this->typingTimers[$key])) {
                Timer::del($this->typingTimers[$key]);
                unset($this->typingTimers[$key]);
            }
            unset($this->typingLast[$key]);
        }
        $this->events->toUsers($peers, 'typing', ['conversation_id' => $conv, 'user_id' => $uid, 'state' => $mode]);
    }

    private function seen(TcpConnection $conn, ConnState $state, ?string $id, array $data): void
    {
        if (!$state->allow('seen', 10, 10.0)) {
            $this->error($conn, $id, 'rate_limited', 'Demasiados eventos seen.', ['retry_after' => 10]);
            return;
        }
        $conv = $data['conversation_id'] ?? null;
        $upTo = $data['up_to_message_id'] ?? null;
        if (!Uuid::isValid($conv) || !Uuid::isValid($upTo)) {
            $this->error($conn, $id, 'invalid_payload', 'seen requiere conversation_id y up_to_message_id.');
            return;
        }
        $this->markReceipt($state->userId, strtolower($conv), 'seen', strtolower($upTo));
    }

    private function presenceQuery(TcpConnection $conn, ConnState $state, ?string $id, array $data): void
    {
        if (!$state->allow('presence.query', 5, 60.0)) {
            $this->error($conn, $id, 'rate_limited', 'Demasiadas consultas de presencia.', ['retry_after' => 60]);
            return;
        }
        $ids = $data['user_ids'] ?? null;
        if (!is_array($ids) || count($ids) > 100 || array_filter($ids, fn($u) => !Uuid::isValid($u))) {
            $this->error($conn, $id, 'invalid_payload', 'user_ids debe ser una lista de hasta 100 UUID.');
            return;
        }
        $ids = array_values(array_unique(array_map('strtolower', $ids)));
        if (!$ids) {
            return;
        }
        $rows = $this->db->call('fn_filtrar_relacionados', ['p_usuario' => $state->userId, 'p_ids' => $ids], true);
        $online = $this->redis->run(function (Redis $r) use ($rows) {
            $p = $r->multi(Redis::PIPELINE);
            foreach ($rows as $row) {
                $p->get("presence:{$row['id_usuario']}")->get("last_seen:{$row['id_usuario']}");
            }
            return $p->exec();
        }, []);
        foreach ($rows as $i => $row) {
            $count = (int) ($online[2 * $i] ?? 0);
            $lastSeen = $online[2 * $i + 1] ?? null;
            $this->send($conn, 'presence', [
                'user_id' => $row['id_usuario'],
                'status' => $count > 0 ? 'online' : 'offline',
                'last_seen_at' => $lastSeen ?: Time::rfc3339($row['last_seen_at']),
            ]);
        }
    }

    // ------------------------------------------------------------------ Redis -> clientes

    public function onRedisMessage(string $channel, string $payload): void
    {
        $event = json_decode($payload, true);
        if (!is_array($event) || !is_string($event['type'] ?? null)) {
            return;
        }
        [$kind, $target] = array_pad(explode(':', $channel, 2), 2, '');

        if ($kind === 'session') {
            if ($event['type'] === 'session.revoked') {
                foreach (array_keys($this->bySession[$target] ?? []) as $cid) {
                    if (isset($this->conns[$cid])) {
                        $this->closeWith($this->conns[$cid], 4401, 'session_revoked');
                    }
                }
            }
            return;
        }
        if ($kind !== 'user') {
            return;
        }
        if ($event['type'] === 'block.changed') {
            $users = (array) ($event['data']['users'] ?? []);
            foreach (array_keys($this->relationCache) as $k) {
                [$a, $b] = explode('|', $k);
                if (in_array($a, $users, true) || in_array($b, $users, true)) {
                    unset($this->relationCache[$k]);
                }
            }
            return;
        }
        if (in_array($event['type'], self::INTERNAL, true) || empty($this->byUser[$target])) {
            return;
        }

        $frame = json_encode($event, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        foreach (array_keys($this->byUser[$target]) as $cid) {
            if (isset($this->conns[$cid])) {
                $this->conns[$cid]->send($frame);
            }
        }

        // Entrega automática: el receptor tiene al menos una conexión aquí -> receipt.delivered
        if ($event['type'] === 'message.new') {
            $m = $event['data']['message'] ?? [];
            $key = ($event['id'] ?? '') . "|$target";
            if (($m['sender_id'] ?? $target) !== $target && Uuid::isValid($m['id'] ?? null) && !isset($this->deliveredSeen[$key])) {
                $this->deliveredSeen[$key] = microtime(true);
                try {
                    $this->markReceipt($target, $m['conversation_id'], 'delivered', $m['id']);
                } catch (Throwable $e) {
                    $this->logError('ws_auto_delivered_failed', $e);
                }
            }
        }
    }

    // ------------------------------------------------------------------ auxiliares

    /** fn_marcar_recibos (valida participación con el usuario autenticado) y publica receipt.* al otro. */
    private function markReceipt(string $uid, string $conv, string $status, string $upTo): void
    {
        $r = $this->db->one('fn_marcar_recibos', [
            'p_usuario' => $uid, 'p_conversacion' => $conv, 'p_estado' => $status, 'p_hasta' => $upTo,
        ]);
        if ((int) ($r['actualizados'] ?? 0) > 0) {
            $peers = $this->peersOf($uid, $conv) ?? [];
            $this->events->toUsers($peers, "receipt.$status", [
                'conversation_id' => $conv,
                'user_id' => $uid,
                'up_to_message_id' => $upTo,
                'at' => Time::rfc3339($r['marcado_at']),
            ]);
        }
    }

    /** Otros participantes de la conversación (caché 5 min) o null si no participo. */
    private function peersOf(string $uid, string $conv): ?array
    {
        $now = microtime(true);
        $cached = $this->participantsCache[$conv] ?? null;
        if ($cached === null || $cached[0] < $now) {
            try {
                $ids = array_column($this->db->call('fn_participantes_conversacion', ['p_usuario' => $uid, 'p_conversacion' => $conv], true), 'id_usuario');
            } catch (DbException $e) {
                if ($e->sqlState === 'CR404') {
                    return null;
                }
                throw $e;
            }
            $this->participantsCache[$conv] = $cached = [$now + 300, $ids];
        }
        if (!in_array($uid, $cached[1], true)) {
            return null;
        }
        return array_values(array_diff($cached[1], [$uid]));
    }

    /** Relación sin bloqueo en ningún sentido (caché 30 s, invalidada por block.changed). */
    private function related(string $a, string $b): bool
    {
        $key = "$a|$b";
        $now = microtime(true);
        if (!isset($this->relationCache[$key]) || $this->relationCache[$key][0] < $now) {
            $rows = $this->db->call('fn_filtrar_relacionados', ['p_usuario' => $a, 'p_ids' => [$b]], true);
            $this->relationCache[$key] = [$now + 30, count($rows) > 0];
        }
        return $this->relationCache[$key][1];
    }

    private function presenceUp(string $uid): void
    {
        $count = $this->redis->run(function (Redis $r) use ($uid) {
            $n = $r->incr("presence:$uid");
            $r->expire("presence:$uid", self::PRESENCE_TTL);
            return $n;
        }, 0);
        if ($count === 1) {
            $this->broadcastPresence($uid, 'online', null);
        }
    }

    private function presenceDown(string $uid): void
    {
        $count = $this->redis->run(fn(Redis $r) => $r->decr("presence:$uid"), 0);
        if ($count > 0) {
            return;
        }
        $now = Time::now();
        $this->redis->run(fn(Redis $r) => $r->multi(Redis::PIPELINE)->del("presence:$uid")->setex("last_seen:$uid", 30 * 86400, $now)->exec());
        try {
            $this->db->call('fn_registrar_last_seen', ['p_usuario' => $uid]);
        } catch (DbException) {
            // usuario dado de baja: no hay last_seen que guardar
        }
        $this->broadcastPresence($uid, 'offline', $now);
    }

    /** presence solo a usuarios con relación y sin bloqueo (fn_listar_relacionados). */
    private function broadcastPresence(string $uid, string $status, ?string $lastSeen): void
    {
        try {
            $related = array_column($this->db->call('fn_listar_relacionados', ['p_usuario' => $uid], true), 'id_usuario');
        } catch (DbException|DatabaseUnavailableException $e) {
            return;
        }
        if ($related) {
            $this->events->toUsers($related, 'presence', ['user_id' => $uid, 'status' => $status, 'last_seen_at' => $lastSeen]);
        }
    }

    private function scheduleExpiry(TcpConnection $conn, ConnState $state, int $exp): void
    {
        foreach ([$state->expiringTimer, $state->expiryTimer] as $t) {
            if ($t) {
                Timer::del($t);
            }
        }
        $state->exp = $exp;
        $left = $exp - time();
        $state->expiringTimer = $left > 60 ? Timer::add($left - 60, function () use ($conn, $state) {
            $state->expiringTimer = null;
            $this->send($conn, 'auth.expiring', ['expires_at' => Time::fromUnix($state->exp)]);
        }, [], false) : null;
        $state->expiryTimer = Timer::add(max(1, $left), function () use ($conn, $state) {
            $state->expiryTimer = null;
            $this->closeWith($conn, 4401, 'token_expired');
        }, [], false);
    }

    // Máximo 10 conexiones por usuario (en este proceso): la más antigua se cierra con 4008
    private function enforceConnectionLimit(string $uid): void
    {
        $ids = array_keys($this->byUser[$uid] ?? []);
        while (count($ids) > self::MAX_CONN_PER_USER) {
            $oldest = array_shift($ids);
            if (isset($this->conns[$oldest])) {
                $this->closeWith($this->conns[$oldest], 4008, 'too_many_connections');
            }
        }
    }

    // 20 mensajes / 10 s por conexión; exceso -> error rate_limited; sostenido 30 s -> cierre 4029
    private function globalLimit(TcpConnection $conn, ConnState $state, ?string $id): bool
    {
        if ($state->allow('global', 20, 10.0)) {
            $state->limitedSince = null;
            return true;
        }
        $state->limitedSince ??= microtime(true);
        if (microtime(true) - $state->limitedSince >= 30) {
            $this->closeWith($conn, 4029, 'rate_limited');
        } else {
            $this->error($conn, $id, 'rate_limited', 'Demasiados mensajes.', ['retry_after' => 10]);
        }
        return false;
    }

    private function send(TcpConnection $conn, string $type, array $data): void
    {
        $conn->send(json_encode(EventPublisher::envelope($type, $data), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }

    private function error(TcpConnection $conn, ?string $replyTo, string $code, string $detail, array $extra = []): void
    {
        $data = ['code' => $code, 'detail' => $detail] + $extra;
        if ($replyTo !== null) {
            $data = ['reply_to' => $replyTo] + $data;
        }
        $this->send($conn, 'error', $data);
    }

    /** Cierra con un frame WebSocket de cierre (código + motivo). */
    public function closeWith(TcpConnection $conn, int $code, string $reason): void
    {
        $conn->websocketType = "\x88";
        $conn->close(pack('n', $code) . substr($reason, 0, 120));
    }

    private function logError(string $msg, Throwable $e): void
    {
        Log::error($msg, ['exception' => get_class($e), 'error' => $e->getMessage(), 'where' => basename($e->getFile()) . ':' . $e->getLine()]);
    }
}
