<?php

namespace App\Exceptions;

class HttpTooManyRequestsException extends ProblemException
{
    protected $code = 429;
    protected $message = 'Has superado el límite de peticiones.';
    protected string $title = 'Demasiadas peticiones';
    protected string $description = 'Se excedió un límite de peticiones.';
    protected string $problemType = 'demasiadas-peticiones';
}
