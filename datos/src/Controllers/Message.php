<?php
namespace App\Controllers;

use App\Services\Bytea;
use App\Services\MessageCrypto;
use App\Services\Presenter;
use App\Support\Cursor;
use App\Support\Text;
use App\Support\Uuid;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpBadRequestException;

class Message extends BaseController
{
    private const MAX_TEXT = 4000;

    // GET /api/v1/conversations/{conversationId}/messages?before=&after=&limit=
    public function index(Request $request, Response $response, array $args)
    {
        $conv = $this->uuidArg($request, $args, 'conversationId', 'Conversación');
        $limit = $this->limit($request);
        $query = $request->getQueryParams();
        $before = $this->messageCursor($request, $query['before'] ?? null);
        $after = $this->messageCursor($request, $query['after'] ?? null);
        if ($before !== null && $after !== null) {
            throw new HttpBadRequestException($request, 'before y after son excluyentes.');
        }
        $me = $this->userId($request);

        $rows = $this->callProcedure('listar_mensajes', [
            'p_usuario' => $me,
            'p_conversacion' => $conv,
            'p_limite' => $limit,
            'p_antes' => $before,
            'p_despues' => $after,
        ], true);
        $items = array_map([$this->presenter(), 'message'], $rows);

        $next = null;
        if (count($rows) === $limit) {
            $next = $after !== null ? end($items)['cursor'] : $items[0]['cursor'];
        }

        // Listar no marca entregado en la BD: se marca aquí hasta el último mensaje recibido
        $lastReceived = null;
        foreach ($rows as $r) {
            if ($r['id_remitente'] !== $me) {
                $lastReceived = $r;
            }
        }
        if ($lastReceived !== null) {
            $this->markReceipt($me, $conv, 'delivered', $lastReceived['id']);
        }

        return $this->json($response, ['items' => $items, 'next_cursor' => $next]);
    }

    // POST /api/v1/conversations/{conversationId}/messages {client_id?, text?, media_id?}
    public function send(Request $request, Response $response, array $args)
    {
        $conv = $this->uuidArg($request, $args, 'conversationId', 'Conversación');
        $body = $this->input($request, [], ['client_id', 'text', 'media_id']);
        $me = $this->userId($request);
        $errors = [];

        // Idempotencia: client_id del cuerpo o encabezado Idempotency-Key (deben coincidir si van ambos)
        $clientId = $body['client_id'] ?? null;
        $header = $request->getHeaderLine('Idempotency-Key');
        if ($header !== '') {
            if (!Uuid::isValid($header)) {
                throw new HttpBadRequestException($request, 'Idempotency-Key debe ser un UUID.');
            }
            if ($clientId !== null && strtolower((string) $clientId) !== strtolower($header)) {
                throw new HttpBadRequestException($request, 'Idempotency-Key y client_id no coinciden.');
            }
            $clientId = $header;
        }
        if ($clientId !== null && !Uuid::isValid($clientId)) {
            $errors[] = ['field' => 'client_id', 'detail' => 'Debe ser un UUID.'];
        }

        $text = null;
        if (array_key_exists('text', $body) && $body['text'] !== null) {
            $text = is_string($body['text']) ? Text::multiline($body['text']) : null;
            if ($text === null || $text === '' || Text::length($text) > self::MAX_TEXT) {
                $errors[] = ['field' => 'text', 'detail' => 'Debe tener entre 1 y 4000 caracteres, sin caracteres de control.'];
            }
        }
        $hasMedia = array_key_exists('media_id', $body) && $body['media_id'] !== null;
        if ($text === null && !$hasMedia && !$errors) {
            $errors[] = ['field' => 'text', 'detail' => 'El mensaje requiere text y/o media_id.'];
        }
        $this->failIf($request, $errors);

        $mediaId = $hasMedia ? $this->verifyMedia($request, $body['media_id'], 'mensaje', 'media_id') : null;
        $enc = $text !== null ? $this->container->get(MessageCrypto::class)->encrypt($text) : null;

        $row = $this->callOne('enviar_mensaje', [
            'p_usuario' => $me,
            'p_conversacion' => $conv,
            'p_contenido' => $enc ? new Bytea($enc['cipher']) : null,
            'p_nonce' => $enc ? new Bytea($enc['nonce']) : null,
            'p_key_id' => $enc['key_id'] ?? null,
            'p_media' => $mediaId,
            'p_client_id' => $clientId !== null ? strtolower($clientId) : null,
        ]);
        $message = $this->presenter()->message($row);

        if (!$row['creado']) {
            return $this->json($response, $message); // reintento idempotente: no se vuelve a publicar
        }

        $participants = $this->participants($me, $conv);
        $this->publishMessage('message.new', $me, $participants, $message);

        // Responder implica haber leído: se marca como visto todo lo recibido antes de este mensaje
        $this->markReceipt($me, $conv, 'seen', $row['id'], $participants);

        return $this->created($response, $message, '/api/v1/messages/' . $row['id']);
    }

    // PATCH /api/v1/messages/{messageId} {text}
    // 404 si no existe o no participo; 403 `no-autor` si participo pero no soy el autor;
    // 422 `edicion-expirada` pasados 15 minutos.
    public function update(Request $request, Response $response, array $args)
    {
        $id = $this->uuidArg($request, $args, 'messageId', 'Mensaje');
        $body = $this->input($request, ['text']);
        $text = is_string($body['text']) ? Text::multiline($body['text']) : null;
        if ($text === null || $text === '' || Text::length($text) > self::MAX_TEXT) {
            $this->failIf($request, [['field' => 'text', 'detail' => 'Debe tener entre 1 y 4000 caracteres, sin caracteres de control.']]);
        }
        $me = $this->userId($request);
        $enc = $this->container->get(MessageCrypto::class)->encrypt($text);
        $row = $this->callOne('editar_mensaje', [
            'p_usuario' => $me,
            'p_mensaje' => $id,
            'p_contenido' => new Bytea($enc['cipher']),
            'p_nonce' => new Bytea($enc['nonce']),
            'p_key_id' => $enc['key_id'],
        ]);
        $message = $this->presenter()->message($row);
        $this->publishMessage('message.edited', $me, $this->participants($me, $row['id_conversacion']), $message);
        return $this->json($response, $message);
    }

    // DELETE /api/v1/messages/{messageId}  (lápida para todos; idempotente)
    public function delete(Request $request, Response $response, array $args)
    {
        $id = $this->uuidArg($request, $args, 'messageId', 'Mensaje');
        $me = $this->userId($request);
        $row = $this->callOne('borrar_mensaje', ['p_usuario' => $me, 'p_mensaje' => $id]);
        if ($row['borrado']) {
            $this->events()->toUsers($this->participants($me, $row['id_conversacion']), 'message.deleted', [
                'conversation_id' => $row['id_conversacion'],
                'message_id' => $id,
                'deleted_at' => \App\Support\Time::rfc3339($row['deleted_at']),
            ]);
        }
        return $this->noContent($response);
    }

    // POST /api/v1/conversations/{conversationId}/receipts {status, up_to_message_id}
    public function receipts(Request $request, Response $response, array $args)
    {
        $conv = $this->uuidArg($request, $args, 'conversationId', 'Conversación');
        $body = $this->input($request, ['status', 'up_to_message_id']);
        $errors = [];
        if (!in_array($body['status'], ['delivered', 'seen'], true)) {
            $errors[] = ['field' => 'status', 'detail' => 'Debe ser delivered o seen.'];
        }
        if (!Uuid::isValid($body['up_to_message_id'])) {
            $errors[] = ['field' => 'up_to_message_id', 'detail' => 'Debe ser un UUID.'];
        }
        $this->failIf($request, $errors);

        $upTo = strtolower($body['up_to_message_id']);
        $result = $this->markReceipt($this->userId($request), $conv, $body['status'], $upTo);
        return $this->json($response, [
            'conversation_id' => $conv,
            'status' => $body['status'],
            'up_to_message_id' => $upTo,
            'updated_count' => (int) $result['actualizados'],
            'unread_count' => (int) $result['no_leidos'],
        ]);
    }

    // ------------------------------------------------------------------ auxiliares

    private function messageCursor(Request $request, mixed $raw): ?string
    {
        if ($raw === null || $raw === '') {
            return null;
        }
        $id = is_string($raw) && strlen($raw) <= 200 ? Cursor::decodeMessage($raw) : null;
        if ($id === null) {
            throw new HttpBadRequestException($request, 'El cursor no es válido.');
        }
        return $id;
    }

    private function participants(string $me, string $conv): array
    {
        return array_column($this->callProcedure('participantes_conversacion', ['p_usuario' => $me, 'p_conversacion' => $conv]), 'id_usuario');
    }

    // El emisor recibe su vista (client_id + status); el otro participante, la suya
    private function publishMessage(string $type, string $me, array $participants, array $message): void
    {
        $items = [];
        foreach ($participants as $uid) {
            $view = $uid === $me ? $message : Presenter::forPeer($message);
            $items[] = ["user:$uid", \App\Services\EventPublisher::envelope($type, ['message' => $view])];
        }
        $this->events()->publishMany($items);
    }

    /** fn_marcar_recibos por el pool rw y publica receipt.* a los demás participantes si cambió algo. */
    private function markReceipt(string $me, string $conv, string $status, string $upTo, ?array $participants = null): array
    {
        $result = $this->callOne('marcar_recibos', [
            'p_usuario' => $me,
            'p_conversacion' => $conv,
            'p_estado' => $status,
            'p_hasta' => $upTo,
        ]);
        if ((int) $result['actualizados'] > 0) {
            $others = array_values(array_diff($participants ?? $this->participants($me, $conv), [$me]));
            $this->events()->toUsers($others, "receipt.$status", [
                'conversation_id' => $conv,
                'user_id' => $me,
                'up_to_message_id' => $upTo,
                'at' => \App\Support\Time::rfc3339($result['marcado_at']),
            ]);
        }
        return $result;
    }
}
