<?php
namespace App\Controllers;

use App\Support\Cursor;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class Block extends BaseController
{
    // GET /api/v1/blocks?cursor=&limit=
    public function index(Request $request, Response $response)
    {
        $limit = $this->limit($request);
        $cursor = $this->pairCursor($request);
        $rows = $this->callProcedure('listar_bloqueos', [
            'p_usuario' => $this->userId($request),
            'p_limite' => $limit,
            'p_cursor_at' => $cursor[0] ?? null,
            'p_cursor_id' => $cursor[1] ?? null,
        ], true);
        $last = end($rows);
        return $this->json($response, [
            'items' => array_map([$this->presenter(), 'block'], $rows),
            'next_cursor' => count($rows) === $limit ? Cursor::pair($last['created_at'], $last['id_usuario']) : null,
        ]);
    }

    // PUT /api/v1/blocks/{userId}
    public function store(Request $request, Response $response, array $args)
    {
        $target = $this->uuidArg($request, $args, 'userId', 'Usuario');
        $me = $this->userId($request);
        $this->callValue('bloquear_usuario', ['p_usuario' => $me, 'p_objetivo' => $target]);
        $this->changed($me, $target, true);
        return $this->noContent($response);
    }

    // DELETE /api/v1/blocks/{userId}
    public function delete(Request $request, Response $response, array $args)
    {
        $target = $this->uuidArg($request, $args, 'userId', 'Usuario');
        $me = $this->userId($request);
        if ($this->callValue('desbloquear_usuario', ['p_usuario' => $me, 'p_objetivo' => $target])) {
            $this->changed($me, $target, false);
        }
        return $this->noContent($response);
    }

    // Evento interno para que el WS invalide su caché de relaciones (typing / presencia) al momento
    private function changed(string $me, string $target, bool $blocked): void
    {
        $this->events()->toUsers([$me, $target], 'block.changed', ['users' => [$me, $target], 'blocked' => $blocked]);
    }
}
