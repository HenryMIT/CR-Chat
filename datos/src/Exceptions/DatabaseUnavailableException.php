<?php

namespace App\Exceptions;

use RuntimeException;

// Se lanza cuando ningún motor de base de datos (PostgreSQL ni MySQL) responde.
class DatabaseUnavailableException extends RuntimeException
{
}
