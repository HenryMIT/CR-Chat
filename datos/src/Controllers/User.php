<?php
namespace App\Controllers;

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class User extends BaseController
{
    // GET /api/v1/users/{userId}
    // Solo con relación y sin bloqueo (la BD lo valida con el usuario autenticado); si no, 404.
    public function show(Request $request, Response $response, array $args)
    {
        $target = $this->uuidArg($request, $args, 'userId', 'Usuario');
        $row = $this->callOne('perfil_publico', ['p_usuario' => $this->userId($request), 'p_objetivo' => $target], true);
        return $this->json($response, $this->presenter()->publicUser($row));
    }
}
