<?php

namespace App\Exceptions;

use RuntimeException;
use Throwable;

/**
 * Error de negocio lanzado por una función de BD con SQLSTATE propio (clase CR, ver
 * docs/contratos/db-funciones.md §2). `hint` es estable y elige el tipo del problema.
 */
class DbException extends RuntimeException
{
    public function __construct(
        public readonly string $sqlState,
        public readonly ?string $hint,
        public readonly string $dbMessage,
        public readonly ?string $detail = null,
        ?Throwable $previous = null
    ) {
        parent::__construct("$sqlState: $dbMessage", 0, $previous);
    }
}
