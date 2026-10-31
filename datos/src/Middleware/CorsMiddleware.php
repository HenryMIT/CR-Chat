<?php

namespace App\Middleware;

use Psr\Http\Message\ResponseFactoryInterface;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;

/**
 * CORS con lista blanca (CORS_ORIGINS): se hace eco del origen permitido, nunca "*", siempre
 * `Vary: Origin`. Allow-Credentials solo para orígenes permitidos (cookie del refresh, A-15).
 * Un origen no permitido no recibe encabezados CORS (el navegador bloquea la respuesta).
 */
class CorsMiddleware implements MiddlewareInterface
{
    private const ALLOW_HEADERS = 'Authorization, Content-Type, Accept, Idempotency-Key, X-Request-Id, X-Refresh-Cookie';
    private const ALLOW_METHODS = 'GET, POST, PUT, PATCH, DELETE, OPTIONS';
    private const EXPOSE_HEADERS = 'Location, Retry-After, RateLimit, RateLimit-Policy, X-Request-Id';

    public function __construct(
        private array $allowedOrigins,
        private ResponseFactoryInterface $responseFactory
    )
    {
    }

    public function isAllowed(string $origin): bool
    {
        return in_array($origin, $this->allowedOrigins, true);
    }

    public function process(Request $request, Handler $handler): Response
    {
        $origin = $request->getHeaderLine('Origin');
        $allowed = $origin !== '' && $this->isAllowed($origin);

        // Las peticiones preflight se responden aquí, sin pasar por el router
        if ($request->getMethod() === 'OPTIONS' && $request->hasHeader('Access-Control-Request-Method')) {
            $response = $this->responseFactory->createResponse(204);
            if ($allowed) {
                $response = $response
                    ->withHeader('Access-Control-Allow-Methods', self::ALLOW_METHODS)
                    ->withHeader('Access-Control-Allow-Headers', self::ALLOW_HEADERS)
                    ->withHeader('Access-Control-Max-Age', '600');
            }
        } else {
            $response = $handler->handle($request);
        }

        $response = $response->withAddedHeader('Vary', 'Origin');
        if (!$allowed) {
            return $response;
        }
        return $response
            ->withHeader('Access-Control-Allow-Origin', $origin)
            ->withHeader('Access-Control-Allow-Credentials', 'true')
            ->withHeader('Access-Control-Expose-Headers', self::EXPOSE_HEADERS);
    }
}
