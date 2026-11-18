<?php
namespace App\Controllers;

use App\Support\Cursor;
use App\Support\Uuid;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class Conversation extends BaseController
{
    // GET /api/v1/conversations?cursor=&limit=
    public function index(Request $request, Response $response)
    {
        $limit = $this->limit($request);
        $cursor = $this->pairCursor($request);
        $me = $this->userId($request);
        $rows = $this->callProcedure('listar_conversaciones', [
            'p_usuario' => $me,
            'p_limite' => $limit,
            'p_cursor_at' => $cursor[0] ?? null,
            'p_cursor_id' => $cursor[1] ?? null,
        ], true);
        $last = end($rows);
        return $this->json($response, [
            'items' => array_map([$this->presenter(), 'conversation'], $rows),
            'next_cursor' => count($rows) === $limit ? Cursor::pair($last['ultimo_mensaje_at'], $last['id']) : null,
        ]);
    }

    // POST /api/v1/conversations {contact_id}  (idempotente: 201 creada, 200 ya existía)
    public function create(Request $request, Response $response)
    {
        $body = $this->input($request, ['contact_id']);
        if (!Uuid::isValid($body['contact_id'])) {
            $this->failIf($request, [['field' => 'contact_id', 'detail' => 'Debe ser un UUID.']]);
        }
        $me = $this->userId($request);
        $row = $this->callOne('crear_conversacion', ['p_usuario' => $me, 'p_contacto' => strtolower($body['contact_id'])]);
        $conversation = $this->presenter()->conversation($row);

        if (!$row['creada']) {
            return $this->json($response, $conversation);
        }

        // conversation.new con la vista de cada participante. Para el otro se llama
        // fn_obtener_conversacion con SU uuid: única excepción documentada a "p_usuario = sub".
        $this->events()->toUser($me, 'conversation.new', ['conversation' => $conversation]);
        foreach ($this->callProcedure('participantes_conversacion', ['p_usuario' => $me, 'p_conversacion' => $row['id']]) as $p) {
            if ($p['id_usuario'] !== $me) {
                $peerView = $this->callOne('obtener_conversacion', ['p_usuario' => $p['id_usuario'], 'p_conversacion' => $row['id']]);
                $this->events()->toUser($p['id_usuario'], 'conversation.new', [
                    'conversation' => $this->presenter()->conversation($peerView),
                ]);
            }
        }
        return $this->created($response, $conversation, '/api/v1/conversations/' . $row['id']);
    }

    // GET /api/v1/conversations/{conversationId}
    public function show(Request $request, Response $response, array $args)
    {
        $id = $this->uuidArg($request, $args, 'conversationId', 'Conversación');
        $me = $this->userId($request);
        $row = $this->callOne('obtener_conversacion', ['p_usuario' => $me, 'p_conversacion' => $id], true);
        return $this->json($response, $this->presenter()->conversation($row));
    }

}
