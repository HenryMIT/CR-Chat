<?php
namespace App\Controllers;

use App\Exceptions\HttpConflictException;
use App\Exceptions\HttpUnprocessableException;
use PDO;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use RuntimeException;

class Chat extends BaseController
{
    // POST /api/chat/create  {id_contact}
    public function createChat(Request $request, Response $response)
    {
        $body = $this->input($request, ['id_contact']);
        $id_contact = $this->intField($request, $body['id_contact'], 'id_contact');
        $id_usr = $this->userId($request);

        $this->assertOwnership(
            $request,
            'SELECT 1 FROM contact WHERE id_contact = :id_contact AND id_user = :id_user AND deleted = false',
            ['id_contact' => $id_contact, 'id_user' => $id_usr],
            'Contacto'
        );

        $res = $this->scalar('create_chat', ['id_usr' => $id_usr, 'id_contact' => $id_contact]);

        if ($res === 0) {
            throw new HttpConflictException($request, 'Ya existe un chat con ese contacto.');
        }
        if ($res === -2) {
            throw new HttpUnprocessableException($request, 'El contacto no corresponde a un usuario registrado.');
        }
        if ($res < 0) {
            throw new RuntimeException("sp_create_chat devolvió $res");
        }

        $query = $this->db()->prepare(
            'SELECT id_chat, id_sender, id_receiver, id_contact FROM chat WHERE id_contact = :id_contact'
        );
        $query->execute(['id_contact' => $id_contact]);

        return $this->json($response, $query->fetch(PDO::FETCH_ASSOC), 201);
    }

    // GET /api/chat/load
    public function loadChat(Request $request, Response $response)
    {
        return $this->json($response, $this->rows('load_chat', ['id_user' => $this->userId($request)]));
    }
}
