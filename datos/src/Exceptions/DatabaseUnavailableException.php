<?php

namespace App\Exceptions;

use RuntimeException;

// No hay conexión con PostgreSQL (haproxy:5000 o 5001). Se responde 503 sin detalles.
class DatabaseUnavailableException extends RuntimeException
{
}
