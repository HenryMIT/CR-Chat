<?php

namespace App\Exceptions;

use Psr\Http\Message\ServerRequestInterface;
use Slim\Exception\HttpSpecializedException;
use Throwable;

/**
 * Error HTTP con forma RFC 9457. `problemType` es el sufijo del URI del tipo
 * (https://cr-chat.example/problemas/<problemType>), `errors` solo en 422 y
 * `extraHeaders` se copian a la respuesta (Retry-After, WWW-Authenticate...).
 */
class ProblemException extends HttpSpecializedException
{
    protected string $problemType = 'error';
    protected array $errors = [];
    protected array $extraHeaders = [];

    public function __construct(
        ServerRequestInterface $request,
        ?string $message = null,
        ?string $problemType = null,
        array $errors = [],
        array $headers = [],
        ?Throwable $previous = null
    ) {
        parent::__construct($request, $message, $previous);
        if ($problemType !== null) {
            $this->problemType = $problemType;
        }
        $this->errors = $errors;
        $this->extraHeaders = $headers;
    }

    public function getProblemType(): string
    {
        return $this->problemType;
    }

    public function getErrors(): array
    {
        return $this->errors;
    }

    public function getHeaders(): array
    {
        return $this->extraHeaders;
    }
}
