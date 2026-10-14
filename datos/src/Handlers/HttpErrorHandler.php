<?php

namespace App\Handlers;

use App\Exceptions\DatabaseUnavailableException;
use Slim\Handlers\ErrorHandler;

class HttpErrorHandler extends ErrorHandler
{
    protected function determineStatusCode(): int
    {
        if ($this->exception instanceof DatabaseUnavailableException) {
            return 503;
        }
        return parent::determineStatusCode();
    }
}
