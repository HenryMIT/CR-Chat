<?php

namespace App\Exceptions;

// 422 con la lista de campos inválidos en `errors[]` ({field, detail}).
class HttpUnprocessableException extends ProblemException
{
    protected $code = 422;
    protected $message = 'Uno o más campos no son válidos.';
    protected string $title = 'Datos inválidos';
    protected string $description = 'La petición está bien formada pero sus datos no son válidos.';
    protected string $problemType = 'validacion';
}
