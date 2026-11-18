<?php

namespace App\Handlers;

use App\Exceptions\DbException;

/**
 * SQLSTATE propios de la BD (clase CR) -> HTTP (docs/contratos/db-funciones.md §2).
 *  CR401 -> 401 · CR403 bloqueado -> 403 `bloqueado` · CR403 no-autor -> 403 `no-autor`
 *  (solo llega si el usuario participa en la conversación; si no, la BD da CR404) ·
 *  CR404 -> 404 · CR409 -> 409 genérico · CR422 cursor -> 400 · CR422 edicion-expirada -> 422
 *  `edicion-expirada` · CR422 -> 422 con errors[{field: HINT}]. Cualquier otro SQLSTATE es un 500.
 */
final class DbErrorMap
{
    public static function status(DbException $e): int
    {
        return match ($e->sqlState) {
            'CR401' => 401,
            'CR403' => 403,
            'CR404' => 404,
            'CR409' => 409,
            'CR422' => $e->hint === 'cursor' ? 400 : 422,
            default => 500,
        };
    }

    /** @return array{0:string,1:string,2:string,3:array} slug, título, detalle, errors */
    public static function problem(DbException $e, int $status): array
    {
        return match (true) {
            $status === 401 => ['no-autenticado', 'No autenticado', 'La sesión no es válida.', []],
            $status === 403 && $e->hint === 'no-autor' => ['no-autor', 'Acción no permitida', 'Solo el autor puede modificar este mensaje.', []],
            $status === 403 => ['bloqueado', 'Acción bloqueada', 'No es posible realizar esta acción con este usuario.', []],
            $status === 404 => ['no-encontrado', 'No encontrado', 'Recurso no encontrado.', []],
            $status === 409 => ['no-disponible', 'Valor no disponible', 'El valor no está disponible.', []],
            $status === 400 => ['peticion-invalida', 'Petición inválida', 'El cursor no es válido.', []],
            $e->hint === 'edicion-expirada' => ['edicion-expirada', 'Edición expirada', 'El plazo de edición (15 minutos) expiró.', []],
            $status === 422 => ['validacion', 'Datos inválidos', 'Uno o más campos no son válidos.',
                [['field' => $e->hint ?? 'body', 'detail' => self::cleanDetail($e->dbMessage)]]],
            default => ['error-interno', 'Error interno', 'Error interno del servidor.', []],
        };
    }

    // El mensaje de la BD es texto de negocio (sin SQL); se limita su longitud por prudencia
    private static function cleanDetail(string $msg): string
    {
        $msg = trim($msg);
        return $msg === '' ? 'Valor inválido.' : mb_substr($msg, 0, 200);
    }
}
