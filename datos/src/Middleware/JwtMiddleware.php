<?php

namespace App\Middleware;

use App\Exceptions\InvalidTokenException;
use App\Services\SessionGuard;
use App\Services\TokenService;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;
use Slim\Exception\HttpUnauthorizedException;

/**
 * Valida el access token (Authorization: Bearer <jwt>): firma, alg, iss, aud, typ, exp, y además
 * que la sesión `sid` siga activa (SessionGuard: Redis con respaldo en BD). Expone en el request
 * los atributos `user_id` (uuid público = sub) y `session_id` (sid).
 */
class JwtMiddleware implements MiddlewareInterface
{
    public function __construct(private TokenService $tokens, private SessionGuard $sessions)
    {
    }

    public function process(Request $request, Handler $handler): Response
    {
        $header = $request->getHeaderLine('Authorization');
        if (!preg_match('/^Bearer\s+(\S+)$/i', $header, $matches)) {
            throw new HttpUnauthorizedException($request, 'Token de acceso requerido.');
        }

        try {
            $claims = $this->tokens->verifyAccess($matches[1]);
        } catch (InvalidTokenException $e) {
            throw new HttpUnauthorizedException($request, $e->getMessage());
        }

        if (!$this->sessions->isActive($claims->sub, $claims->sid)) {
            throw new HttpUnauthorizedException($request, 'La sesión fue cerrada o revocada.');
        }

        return $handler->handle($request
            ->withAttribute('user_id', strtolower($claims->sub))
            ->withAttribute('session_id', strtolower($claims->sid))
            ->withAttribute('token_exp', (int) $claims->exp));
    }
}
