<?php

namespace App\Services;

// Marca un parámetro binario (bytea) para enlazarlo con PDO::PARAM_LOB.
final class Bytea
{
    public function __construct(public readonly string $bytes)
    {
    }
}
