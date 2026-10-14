<?php
namespace App\Controllers;

use App\Exceptions\HttpConflictException;
use App\Exceptions\HttpUnprocessableException;
use PDO;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use RuntimeException;
use Slim\Exception\HttpBadRequestException;
use Slim\Exception\HttpNotFoundException;

class Contact extends BaseController
{
    private const MAX_LIMIT = 100;

    private function assertOwnsContact(Request $request, int $id_contact): void
    {
        $this->assertOwnership(
            $request,
            'SELECT 1 FROM contact WHERE id_contact = :id_contact AND id_user = :id_user AND deleted = false',
            ['id_contact' => $id_contact, 'id_user' => $this->userId($request)],
            'Contacto'
        );
    }

    // POST /api/contact/create  {contact_number, contact_name?}
    public function createContact(Request $request, Response $response)
    {
        $body = $this->input($request, ['contact_number'], ['contact_name']);
        $id_usr = $this->userId($request);
        $number = (string) $body['contact_number'];

        $query = $this->db()->prepare('SELECT id_user FROM usr WHERE phone_number = :phone AND deleted = false');
        $query->execute(['phone' => $number]);
        $contactUser = $query->fetchColumn();
        if ($contactUser === false) {
            throw new HttpUnprocessableException($request, 'El número no pertenece a un usuario registrado.');
        }
        if ((int) $contactUser === $id_usr) {
            throw new HttpUnprocessableException($request, 'No puede agregarse a sí mismo como contacto.');
        }

        $res = $this->scalar('create_contact', [
            'id_usr' => $id_usr,
            'contact_number' => $number,
            'contact_name' => (string) ($body['contact_name'] ?? 'Unknown')
        ]);

        if ($res === 0) {
            throw new HttpConflictException($request, 'El contacto ya existe.');
        }
        if ($res < 0) {
            throw new RuntimeException("sp_create_contact devolvió $res");
        }

        $query = $this->db()->prepare(
            'SELECT id_contact, id_user, contact_number, contact_name FROM contact
             WHERE id_user = :id_user AND contact_number = :phone AND deleted = false'
        );
        $query->execute(['id_user' => $id_usr, 'phone' => $number]);
        $contact = $query->fetch(PDO::FETCH_ASSOC);

        return $this->json($response, $contact, 201);
    }

    // GET /api/contact/load/{lim}/{pag}?phone_contact=&contact_name=
    public function loadContact(Request $request, Response $response, $args)
    {
        $lim = (int) $args['lim'];
        $pag = (int) $args['pag'];
        if ($lim < 1 || $lim > self::MAX_LIMIT || $pag < 1) {
            throw new HttpBadRequestException($request, 'lim debe estar entre 1 y ' . self::MAX_LIMIT . ' y pag debe ser mayor o igual a 1.');
        }

        $filters = $request->getQueryParams();
        $params = ['lim' => $lim];
        if ($this->db()->getAttribute(PDO::ATTR_DRIVER_NAME) !== 'pgsql') {
            $params['pag'] = ($pag - 1) * $lim; // MySQL recibe el desplazamiento (OFFSET)
        }
        $params += [
            'phone_contact' => isset($filters['phone_contact']) && $filters['phone_contact'] !== '' ? (string) $filters['phone_contact'] : null,
            'contact_name' => isset($filters['contact_name']) && $filters['contact_name'] !== '' ? (string) $filters['contact_name'] : null,
            'id_user' => $this->userId($request)
        ];

        return $this->json($response, $this->rows('load_contact', $params));
    }

    // PUT /api/contact/update  {id_contact, contact_number?, contact_name?}
    public function updateContact(Request $request, Response $response)
    {
        $body = $this->input($request, ['id_contact'], ['contact_number', 'contact_name']);
        $id_contact = $this->intField($request, $body['id_contact'], 'id_contact');

        $number = $body['contact_number'] === null || $body['contact_number'] === '' ? null : (string) $body['contact_number'];
        $name = $body['contact_name'] === null || $body['contact_name'] === '' ? null : (string) $body['contact_name'];
        if ($number === null && $name === null) {
            throw new HttpBadRequestException($request, 'Debe enviar contact_number o contact_name.');
        }

        $this->assertOwnsContact($request, $id_contact);

        $res = $this->scalar('update_contact', [
            'id_contact' => $id_contact,
            'contact_number' => $number,
            'contact_name' => $name
        ]);

        if ($res <= 0) {
            throw new HttpNotFoundException($request, 'Contacto no encontrado.');
        }

        return $this->noContent($response);
    }

    // DELETE /api/contact/delete/{id_contact}
    public function deleteContact(Request $request, Response $response, $args)
    {
        $id_contact = (int) $args['id_contact'];
        $this->assertOwnsContact($request, $id_contact);

        $res = $this->scalar('deleted_contact', ['id_contact' => $id_contact]);
        if ($res <= 0) {
            throw new HttpNotFoundException($request, 'Contacto no encontrado.');
        }

        return $this->noContent($response);
    }
}
