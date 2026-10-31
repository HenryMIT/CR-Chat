<?php

namespace App\Middleware;

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;

// Encabezados de seguridad (G-10). HSTS solo si la petición llegó por HTTPS (directo o vía proxy).
class SecurityHeadersMiddleware implements MiddlewareInterface
{
    public function process(Request $request, Handler $handler): Response
    {
        $response = $handler->handle($request)
            ->withHeader('X-Content-Type-Options', 'nosniff')
            ->withHeader('Referrer-Policy', 'no-referrer')
            ->withHeader('X-Frame-Options', 'DENY');

        if (!$response->hasHeader('Cache-Control')) {
            $response = $response->withHeader('Cache-Control', 'no-store');
        }
        if (!$response->hasHeader('Content-Security-Policy')) {
            $response = $response->withHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
        }
        $https = $request->getUri()->getScheme() === 'https' || $request->getHeaderLine('X-Forwarded-Proto') === 'https';
        if ($https) {
            $response = $response->withHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
        }
        return $response;
    }
}
