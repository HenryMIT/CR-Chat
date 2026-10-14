<?php
namespace App\Controllers;

use App\Exceptions\HttpUnprocessableException;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use RuntimeException;
use Slim\Exception\HttpNotFoundException;

class Message extends BaseController
{
    private const MAX_TEXT = 255;

    private function validateText(Request $request, string $text): void
    {
        if (mb_strlen($text) > self::MAX_TEXT) {
            throw new HttpUnprocessableException($request, 'El mensaje no puede superar ' . self::MAX_TEXT . ' caracteres.');
        }
    }

    // Solo el autor (dueño del chat emisor) puede editar o eliminar un mensaje
    private function assertOwnsMessage(Request $request, int $id_message): void
    {
        $this->assertOwnership(
            $request,
            'SELECT 1 FROM message_chat m JOIN chat c ON c.id_chat = m.id_chat_sender
             WHERE m.id_message = :id_message AND c.id_sender = :id_user AND m.deleted = false',
            ['id_message' => $id_message, 'id_user' => $this->userId($request)],
            'Mensaje'
        );
    }

    // POST /api/message/send  {id_chat, text_content, content_media?}
    public function sendMessage(Request $request, Response $response)
    {
        $body = $this->input($request, ['id_chat', 'text_content'], ['content_media']);
        $id_chat = $this->intField($request, $body['id_chat'], 'id_chat');
        $id_usr = $this->userId($request);
        $this->validateText($request, (string) $body['text_content']);

        // El receptor se obtiene del chat, no del cliente
        $query = $this->db()->prepare('SELECT id_receiver FROM chat WHERE id_chat = :id_chat AND id_sender = :id_user');
        $query->execute(['id_chat' => $id_chat, 'id_user' => $id_usr]);
        $id_receiver = $query->fetchColumn();
        if ($id_receiver === false) {
            throw new HttpNotFoundException($request, 'Chat no encontrado.');
        }
        if ($id_receiver === null) {
            throw new HttpUnprocessableException($request, 'El chat no tiene un receptor válido.');
        }

        $res = $this->scalar('send_message', [
            'id_chat_sender' => $id_chat,
            'content_media' => $body['content_media'] === null ? null : (string) $body['content_media'],
            'text_content' => (string) $body['text_content'],
            'id_user' => $id_usr,
            'id_receiver' => (int) $id_receiver,
            'key' => $this->container->get('key_decript')
        ]);

        if ($res <= 0) {
            throw new RuntimeException("sp_send_message devolvió $res");
        }

        return $response->withStatus(201);
    }

    // GET /api/message/load/{id_chat}
    public function loadMessage(Request $request, Response $response, $args)
    {
        $id_chat = (int) $args['id_chat'];
        $this->assertOwnership(
            $request,
            'SELECT 1 FROM chat WHERE id_chat = :id_chat AND id_sender = :id_user',
            ['id_chat' => $id_chat, 'id_user' => $this->userId($request)],
            'Chat'
        );

        $messages = $this->rows('load_message', [
            'id_chat' => $id_chat,
            'key' => $this->container->get('key_decript')
        ]);

        return $this->json($response, $messages);
    }

    // PUT /api/message/edit  {id_message, new_text}
    public function editMessage(Request $request, Response $response)
    {
        $body = $this->input($request, ['id_message', 'new_text']);
        $id_message = $this->intField($request, $body['id_message'], 'id_message');
        $this->validateText($request, (string) $body['new_text']);
        $this->assertOwnsMessage($request, $id_message);

        $res = $this->scalar('edit_message', [
            'id_message' => $id_message,
            'new_text' => (string) $body['new_text'],
            'key' => $this->container->get('key_decript')
        ]);

        if ($res <= 0) {
            throw new HttpNotFoundException($request, 'Mensaje no encontrado.');
        }

        return $this->noContent($response);
    }

    // DELETE /api/message/delete/{id_message}
    public function deleteMessage(Request $request, Response $response, $args)
    {
        $id_message = (int) $args['id_message'];
        $this->assertOwnsMessage($request, $id_message);

        $res = $this->scalar('delete_message', ['id_message' => $id_message], 'deleted_message');
        if ($res <= 0) {
            throw new HttpNotFoundException($request, 'Mensaje no encontrado.');
        }

        return $this->noContent($response);
    }
}
