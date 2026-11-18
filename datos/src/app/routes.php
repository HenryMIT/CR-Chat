<?php
namespace App\Controllers;

use App\Middleware\JwtMiddleware;
use App\Middleware\RateLimitMiddleware;
use App\Services\RateLimiter;
use App\Services\SessionGuard;
use App\Services\TokenService;
use App\Support\Config;
use Slim\Routing\RouteCollectorProxy;

/** @var \Slim\App $app */
/** @var \DI\Container $container */

// Fábrica de middleware de rate limiting: rl(['login', 'ip+identifier'], ['login-ip', 'ip'])
$rl = fn(array ...$policies) => new RateLimitMiddleware(
    $container->get(RateLimiter::class),
    $policies,
    $container->get(Config::class)->trustedProxies
);
$jwt = new JwtMiddleware($container->get(TokenService::class), $container->get(SessionGuard::class));

$app->group('/api/v1', function (RouteCollectorProxy $api) use ($rl, $jwt) {

    // Sondas (sin rate limit)
    $api->get('/health', Health::class . ':health');
    $api->get('/ready', Health::class . ':ready');

    // Rutas públicas
    $api->group('/auth', function (RouteCollectorProxy $auth) use ($rl) {
        $auth->post('/register', Auth::class . ':register')->add($rl(['register', 'ip']));
        $auth->post('/login', Auth::class . ':login')->add($rl(['login', 'ip+identifier'], ['login-ip', 'ip']));
        $auth->post('/refresh', Auth::class . ':refresh')->add($rl(['refresh', 'ip']));
        $auth->post('/reactivate', Auth::class . ':reactivate')->add($rl(['reactivate', 'ip+identifier']));
    });

    // Rutas que requieren access token (JwtMiddleware corre antes que el rate limit de la ruta)
    $api->group('', function (RouteCollectorProxy $private) use ($rl) {
        $default = fn() => $rl(['default-auth', 'user']);
        $sensitive = fn() => $rl(['sensitive', 'user']);
        $edit = fn() => $rl(['edit', 'user']);

        $private->post('/auth/logout', Auth::class . ':logout')->add($default());

        // Perfil propio, cuenta y sesiones
        $private->get('/me', Me::class . ':show')->add($default());
        $private->patch('/me', Me::class . ':update')->add($default());
        $private->delete('/me', Me::class . ':delete')->add($sensitive());
        $private->put('/me/password', Me::class . ':changePassword')->add($sensitive());
        $private->put('/me/phone', Me::class . ':changePhone')->add($sensitive());
        $private->get('/me/sessions', Me::class . ':sessions')->add($default());
        $private->delete('/me/sessions', Me::class . ':revokeOthers')->add($default());
        $private->delete('/me/sessions/{sessionId}', Me::class . ':revokeSession')->add($default());

        // Perfil público (solo con relación)
        $private->get('/users/{userId}', User::class . ':show')->add($rl(['profile-read', 'user']));

        // Contactos
        $private->get('/contacts', Contact::class . ':index')->add($default());
        $private->post('/contacts', Contact::class . ':create')->add($rl(['contact-add', 'user']));
        $private->get('/contacts/{contactId}', Contact::class . ':show')->add($default());
        $private->patch('/contacts/{contactId}', Contact::class . ':update')->add($default());
        $private->delete('/contacts/{contactId}', Contact::class . ':delete')->add($default());

        // Bloqueos
        $private->get('/blocks', Block::class . ':index')->add($default());
        $private->put('/blocks/{userId}', Block::class . ':store')->add($default());
        $private->delete('/blocks/{userId}', Block::class . ':delete')->add($default());

        // Conversaciones y mensajes
        $private->get('/conversations', Conversation::class . ':index')->add($default());
        $private->post('/conversations', Conversation::class . ':create')->add($default());
        $private->get('/conversations/{conversationId}', Conversation::class . ':show')->add($default());
        $private->get('/conversations/{conversationId}/messages', Message::class . ':index')->add($default());
        $private->post('/conversations/{conversationId}/messages', Message::class . ':send')->add($rl(['send', 'user']));
        $private->post('/conversations/{conversationId}/receipts', Message::class . ':receipts')->add($default());
        $private->patch('/messages/{messageId}', Message::class . ':update')->add($edit());
        $private->delete('/messages/{messageId}', Message::class . ':delete')->add($edit());

        // Subidas (URL prefirmada de MinIO)
        $private->post('/uploads', Upload::class . ':create')->add($rl(['upload', 'user']));

    })->add($jwt);
});

// Swagger UI (estático, versión fijada) y el contrato OpenAPI
$app->group('/docs', function (RouteCollectorProxy $docs) {
    $docs->get('', Docs::class . ':index');
    $docs->get('/', Docs::class . ':index');
    $docs->get('/openapi.yaml', Docs::class . ':spec');
    $docs->get('/init.js', Docs::class . ':init');
    $docs->get('/{asset:[A-Za-z0-9._-]+}', Docs::class . ':asset');
})->add($rl(['default-anon', 'ip']));

// Rutas anteriores a v1: 410 Gone
$app->any('/api[/{rest:(?!v1(?:/|$)).*}]', Legacy::class . ':gone')->add($rl(['default-anon', 'ip']));
