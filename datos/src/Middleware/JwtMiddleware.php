<?php

namespace App\Middleware;

use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;
use Slim\Exception\HttpUnauthorizedException;
use Throwable;

// Valida el access token (Authorization: Bearer <jwt>) y expone el id del usuario
// autenticado en el atributo "id_usr" del request.
class JwtMiddleware implements MiddlewareInterface
{
    public function __construct(private string $key)
    {
    }

    public function process(Request $request, Handler $handler): Response
    {
        $header = $request->getHeaderLine('Authorization');
        if (!preg_match('/^Bearer\s+(\S+)$/i', $header, $matches)) {
            throw new HttpUnauthorizedException($request, 'Token de acceso requerido.');
        }

        try {
            $payload = JWT::decode($matches[1], new Key($this->key, 'HS256'));
        } catch (Throwable) {
            throw new HttpUnauthorizedException($request, 'Token de acceso inválido o expirado.');
        }

        if (($payload->typ ?? null) !== 'access' || empty($payload->sub)) {
            throw new HttpUnauthorizedException($request, 'Token de acceso inválido.');
        }

        return $handler->handle($request->withAttribute('id_usr', (int) $payload->sub));
    }
}
