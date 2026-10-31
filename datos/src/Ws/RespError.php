<?php

namespace App\Ws;

// Respuesta de error de Redis (-ERR ...).
final class RespError
{
    public function __construct(public readonly string $message)
    {
    }
}
