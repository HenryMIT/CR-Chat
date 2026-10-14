<?php

namespace App\Handlers;

use App\Exceptions\DatabaseUnavailableException;
use Slim\Exception\HttpException;
use Slim\Interfaces\ErrorRendererInterface;
use Throwable;

// Respuesta de error uniforme: {"error": "<código y título>", "message": "<detalle>"}
class JsonErrorRenderer implements ErrorRendererInterface
{
    public function __invoke(Throwable $exception, bool $displayErrorDetails): string
    {
        if ($exception instanceof HttpException) {
            $error = ['error' => $exception->getTitle(), 'message' => $exception->getMessage()];
        } elseif ($exception instanceof DatabaseUnavailableException) {
            $error = ['error' => '503 Service Unavailable', 'message' => 'La base de datos no está disponible.'];
        } else {
            $error = ['error' => '500 Internal Server Error', 'message' => 'Error interno del servidor.'];
        }

        if ($displayErrorDetails && !$exception instanceof HttpException) {
            $error['exception'] = [
                'type' => get_class($exception),
                'message' => $exception->getMessage(),
                'file' => $exception->getFile(),
                'line' => $exception->getLine(),
            ];
        }

        return (string) json_encode($error, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}
