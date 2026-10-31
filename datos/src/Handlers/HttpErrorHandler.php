<?php

namespace App\Handlers;

use App\Exceptions\DatabaseUnavailableException;
use App\Exceptions\ProblemException;
use App\Support\Log;
use Psr\Http\Message\ResponseInterface;
use Slim\Exception\HttpMethodNotAllowedException;
use Slim\Handlers\ErrorHandler;

// Manejador global: respuesta RFC 9457 + log estructurado de los 5xx (sin trazas al cliente).
class HttpErrorHandler extends ErrorHandler
{
    protected function determineStatusCode(): int
    {
        return JsonErrorRenderer::status($this->exception);
    }

    protected function respond(): ResponseInterface
    {
        $status = $this->statusCode;
        $requestId = $this->request->getAttribute('request_id');
        $problem = JsonErrorRenderer::problem($this->exception, $status, $this->request->getUri()->getPath(), $requestId);

        $response = $this->responseFactory->createResponse($status)
            ->withHeader('Content-Type', 'application/problem+json')
            ->withHeader('Cache-Control', 'no-store');
        $response->getBody()->write(JsonErrorRenderer::encode($problem));

        foreach (\App\Middleware\RateLimitMiddleware::$currentHeaders as $name => $value) {
            $response = $response->withHeader($name, $value);
        }
        if ($this->exception instanceof ProblemException) {
            foreach ($this->exception->getHeaders() as $name => $value) {
                $response = $response->withHeader($name, (string) $value);
            }
        }
        if ($this->exception instanceof HttpMethodNotAllowedException) {
            $response = $response->withHeader('Allow', implode(', ', $this->exception->getAllowedMethods()));
        }
        if ($status === 401 && !$response->hasHeader('WWW-Authenticate')) {
            $response = $response->withHeader('WWW-Authenticate', 'Bearer error="invalid_token"');
        }
        if ($this->exception instanceof DatabaseUnavailableException) {
            $response = $response->withHeader('Retry-After', '5');
        }
        return $response;
    }

    protected function writeToErrorLog(): void
    {
        // 501 deliberado (funcionalidad pendiente) no es un fallo del servidor
        if ($this->statusCode < 500 || $this->exception instanceof ProblemException) {
            return;
        }
        $e = $this->exception;
        Log::error('unhandled_exception', [
            'status' => $this->statusCode,
            'exception' => get_class($e),
            'message' => $e->getMessage(),
            'where' => basename($e->getFile()) . ':' . $e->getLine(),
            'path' => $this->request->getUri()->getPath(),
        ]);
    }
}
