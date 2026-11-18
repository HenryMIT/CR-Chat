<?php

namespace App\Exceptions;

use Psr\Http\Message\ServerRequestInterface;
use Throwable;

// Problema con estado y título arbitrarios (403 bloqueado, 403 contraseña incorrecta, 501...).
class HttpProblemException extends ProblemException
{
    public function __construct(
        ServerRequestInterface $request,
        int $status,
        string $problemType,
        string $title,
        string $message,
        array $headers = [],
        ?Throwable $previous = null
    ) {
        $this->code = $status;
        $this->title = $title;
        parent::__construct($request, $message, $problemType, [], $headers, $previous);
    }
}
