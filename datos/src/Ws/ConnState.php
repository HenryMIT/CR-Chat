<?php

namespace App\Ws;

// Estado de una conexión WebSocket (por proceso de Workerman).
final class ConnState
{
    public ?string $userId = null;
    public ?string $sessionId = null;
    public int $exp = 0;
    public float $connectedAt;
    public float $lastActive;
    public ?int $authTimer = null;
    public ?int $expiringTimer = null;
    public ?int $expiryTimer = null;
    /** @var float[] marcas de tiempo de los últimos mensajes (límite 20 / 10 s) */
    public array $recent = [];
    public ?float $limitedSince = null;
    /** @var array<string, float[]> límites por tipo (ping, seen, presence.query) */
    public array $perType = [];

    public function __construct()
    {
        $this->connectedAt = $this->lastActive = microtime(true);
    }

    public function authenticated(): bool
    {
        return $this->userId !== null;
    }

    /** Ventana deslizante en memoria: true si se permite un evento más. */
    public function allow(string $kind, int $limit, float $window): bool
    {
        $now = microtime(true);
        $list = array_values(array_filter($this->perType[$kind] ?? [], fn($t) => $t > $now - $window));
        if (count($list) >= $limit) {
            $this->perType[$kind] = $list;
            return false;
        }
        $list[] = $now;
        $this->perType[$kind] = $list;
        return true;
    }
}
