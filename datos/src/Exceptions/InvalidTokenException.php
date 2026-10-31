<?php

namespace App\Exceptions;

use RuntimeException;

// Token de acceso inválido, expirado o de una sesión revocada (lo usan la API y el WS).
class InvalidTokenException extends RuntimeException
{
}
