<?php

namespace App\Handlers;

use App\Exceptions\DatabaseUnavailableException;
use App\Exceptions\DbException;
use App\Exceptions\ProblemException;
use Slim\Exception\HttpException;
use Slim\Interfaces\ErrorRendererInterface;
use Throwable;

/**
 * Errores RFC 9457 (application/problem+json): type, title, status, detail, instance,
 * request_id y errors[] (422). Nunca incluye trazas, SQL ni rutas de archivo, aunque
 * APP_DEBUG esté activo: los detalles técnicos solo van al log.
 */
class JsonErrorRenderer implements ErrorRendererInterface
{
    public const TYPE_BASE = 'https://cr-chat.example/problemas/';

    private const BY_STATUS = [
        400 => ['peticion-invalida', 'Petición inválida', 'La petición no es válida.'],
        401 => ['no-autenticado', 'No autenticado', 'Token de acceso inválido o expirado.'],
        403 => ['prohibido', 'Prohibido', 'No tienes permiso para esta acción.'],
        404 => ['no-encontrado', 'No encontrado', 'Recurso no encontrado.'],
        405 => ['metodo-no-permitido', 'Método no permitido', 'El método no está permitido para esta ruta.'],
        409 => ['no-disponible', 'Valor no disponible', 'El valor no está disponible.'],
        410 => ['ruta-retirada', 'Ruta retirada', 'Esta ruta fue retirada.'],
        422 => ['validacion', 'Datos inválidos', 'Uno o más campos no son válidos.'],
        429 => ['demasiadas-peticiones', 'Demasiadas peticiones', 'Has superado el límite de peticiones.'],
        500 => ['error-interno', 'Error interno', 'Error interno del servidor.'],
        501 => ['no-implementado', 'No implementado', 'Funcionalidad aún no disponible.'],
        503 => ['servicio-no-disponible', 'Servicio no disponible', 'El servicio no está disponible temporalmente.'],
    ];

    // Mensajes por defecto de Slim (en inglés) que se sustituyen por el texto en español
    private const SLIM_DEFAULTS = ['Not found.', 'Method not allowed.', 'Unauthorized.', 'Forbidden.', 'Bad request.', 'Internal server error.', 'Gone.'];

    public function __invoke(Throwable $exception, bool $displayErrorDetails): string
    {
        return self::encode(self::problem($exception, self::status($exception)));
    }

    public static function status(Throwable $e): int
    {
        return match (true) {
            $e instanceof HttpException => $e->getCode(),
            $e instanceof DbException => DbErrorMap::status($e),
            $e instanceof DatabaseUnavailableException => 503,
            default => 500,
        };
    }

    public static function problem(Throwable $e, int $status, ?string $instance = null, ?string $requestId = null): array
    {
        [$slug, $title, $detail] = self::BY_STATUS[$status] ?? self::BY_STATUS[$status >= 500 ? 500 : 400];
        $errors = [];

        if ($e instanceof ProblemException) {
            $slug = $e->getProblemType() === 'error' ? $slug : $e->getProblemType();
            $title = $e->getTitle();
            $detail = $e->getMessage();
            $errors = $e->getErrors();
        } elseif ($e instanceof DbException) {
            [$slug, $title, $detail, $errors] = DbErrorMap::problem($e, $status);
        } elseif ($e instanceof HttpException && $status < 500 && !in_array($e->getMessage(), self::SLIM_DEFAULTS, true)) {
            $detail = $e->getMessage();
        }

        $problem = [
            'type' => self::TYPE_BASE . $slug,
            'title' => $title,
            'status' => $status,
            'detail' => $detail,
        ];
        if ($instance !== null) {
            $problem['instance'] = $instance;
        }
        if ($requestId !== null) {
            $problem['request_id'] = $requestId;
        }
        if ($errors) {
            $problem['errors'] = $errors;
        }
        return $problem;
    }

    public static function encode(array $problem): string
    {
        return (string) json_encode($problem, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}
