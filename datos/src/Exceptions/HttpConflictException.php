<?php

namespace App\Exceptions;

use Slim\Exception\HttpSpecializedException;

class HttpConflictException extends HttpSpecializedException
{
    protected $code = 409;
    protected $message = 'Conflict.';
    protected string $title = '409 Conflict';
    protected string $description = 'The request conflicts with the current state of the resource.';
}
