<?php

namespace App\Exceptions;

use Slim\Exception\HttpSpecializedException;

class HttpUnprocessableException extends HttpSpecializedException
{
    protected $code = 422;
    protected $message = 'Unprocessable Content.';
    protected string $title = '422 Unprocessable Content';
    protected string $description = 'The request was well-formed but could not be processed.';
}
