<?php

namespace App\Exceptions;

// 409 genérico: nunca indica qué dato de un tercero colisiona (A-13).
class HttpConflictException extends ProblemException
{
    protected $code = 409;
    protected $message = 'El valor no está disponible.';
    protected string $title = 'Valor no disponible';
    protected string $description = 'La petición entra en conflicto con el estado actual del recurso.';
    protected string $problemType = 'no-disponible';
}
