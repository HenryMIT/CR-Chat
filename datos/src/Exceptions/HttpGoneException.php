<?php

namespace App\Exceptions;

// Rutas antiguas /api/* (G-01): responden 410 indicando la ruta nueva.
class HttpGoneException extends ProblemException
{
    protected $code = 410;
    protected $message = 'Esta ruta fue retirada.';
    protected string $title = 'Ruta retirada';
    protected string $description = 'La ruta fue retirada; usa /api/v1.';
    protected string $problemType = 'ruta-retirada';
}
