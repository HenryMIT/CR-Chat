<?php

/**
 * Servidor WebSocket de CR_Chat (Workerman). Servicio `ws` de docker-compose.yml, misma imagen que
 * la API:  php ws/server.php start   (puerto 8080, ruta /ws)
 * Contrato: docs/contratos/ws-eventos.md.
 *
 * Procesos:
 *  - "cr-chat-ws" (WS_WORKERS, 1 por defecto): conexiones WebSocket + suscripción Redis user:* / session:*.
 *  - "cr-chat-tareas" (1): job horario de huérfanos de media (MinIO + fn_purgar_media).
 */

use App\Services\Db;
use App\Services\EventPublisher;
use App\Services\MediaPurger;
use App\Services\ObjectStorage;
use App\Services\RedisConn;
use App\Services\SessionGuard;
use App\Services\TokenService;
use App\Support\Config;
use App\Support\Env;
use App\Support\Log;
use App\Ws\Hub;
use App\Ws\RedisSubscriber;
use Workerman\Timer;
use Workerman\Worker;

require_once __DIR__ . '/../vendor/autoload.php';

$port = Env::int('WS_PORT', 8080);
$ws = new Worker("websocket://0.0.0.0:$port");
$ws->name = 'cr-chat-ws';
$ws->count = max(1, Env::int('WS_WORKERS', 1));
$ws->reusePort = true;
// Los procesos hijos no corren como root (el maestro solo abre el puerto)
$ws->user = Env::get('WS_USER', 'www-data');

/** @var Hub|null $hub */
$hub = null;

$ws->onWorkerStart = function () use (&$hub) {
    // El contenedor (y las conexiones a PG/Redis) se crea después del fork, uno por proceso
    $container = require __DIR__ . '/../src/app/bootstrap.php';
    $config = $container->get(Config::class);
    $hub = new Hub(
        $config,
        $container->get(Db::class),
        $container->get(RedisConn::class),
        $container->get(TokenService::class),
        $container->get(SessionGuard::class),
        $container->get(EventPublisher::class)
    );
    (new RedisSubscriber(
        $config->redis['host'],
        $config->redis['port'],
        $config->redis['password'],
        ['user:*', 'session:*'],
        fn(string $channel, string $payload) => $hub->onRedisMessage($channel, $payload)
    ))->start();
    Timer::add(30, fn() => $hub->heartbeat());
    Log::info('ws_worker_started');
};

$ws->onWebSocketConnect = function ($conn, $request) use (&$hub) {
    $hub->onHandshake($conn, $request);
};
$ws->onWebSocketConnected = function ($conn) use (&$hub) {
    $hub->onOpen($conn);
};
$ws->onMessage = function ($conn, $data) use (&$hub) {
    $hub->onMessage($conn, (string) $data);
};
$ws->onWebSocketPong = function ($conn) use (&$hub) {
    $hub->onPong($conn);
};
$ws->onClose = function ($conn) use (&$hub) {
    $hub?->onClose($conn);
};

// Proceso de tareas periódicas (sin puerto)
$tasks = new Worker();
$tasks->name = 'cr-chat-tareas';
$tasks->count = 1;
$tasks->user = Env::get('WS_USER', 'www-data');
$tasks->onWorkerStart = function () {
    $container = require __DIR__ . '/../src/app/bootstrap.php';
    $purger = new MediaPurger($container->get(Db::class), $container->get(ObjectStorage::class));
    $run = function () use ($purger, $container) {
        try {
            $purger->run();
        } catch (Throwable $e) {
            $container->get(Db::class)->reset();
            Log::error('media_purge_failed', ['error' => $e->getMessage()]);
        }
    };
    Timer::add(60, $run, [], false);
    Timer::add(max(60, Env::int('MEDIA_PURGE_INTERVAL', 3600)), $run);
};

Worker::$logFile = 'php://stdout';
Worker::$pidFile = sys_get_temp_dir() . '/cr-chat-ws.pid';
Worker::runAll();
