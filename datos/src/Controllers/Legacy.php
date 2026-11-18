<?php
namespace App\Controllers;

use App\Exceptions\HttpGoneException;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class Legacy extends BaseController
{
    // /api/* (rutas anteriores a v1): 410 Gone indicando la versión nueva (G-01)
    public function gone(Request $request, Response $response)
    {
        throw new HttpGoneException($request, 'Las rutas /api/* se retiraron. Usa /api/v1 (ver /docs y docs/requerimientos-api.md §8).');
    }
}
