<?php

namespace App\Middleware;

use App\Support\Log;
use App\Support\Uuid;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;

// X-Request-Id en cada respuesta y en los logs (G-07). Se respeta el del proxy si es un UUID válido.
class RequestIdMiddleware implements MiddlewareInterface
{
    public function process(Request $request, Handler $handler): Response
    {
        $id = $request->getHeaderLine('X-Request-Id');
        if (!Uuid::isValid($id)) {
            $id = Uuid::v4();
        }
        Log::$requestId = $id;
        return $handler->handle($request->withAttribute('request_id', $id))->withHeader('X-Request-Id', $id);
    }
}
