<?php
namespace App\Controllers;

use App\Exceptions\HttpProblemException;
use App\Support\Cursor;
use App\Support\Phone;
use App\Support\Text;
use App\Support\Uuid;
use PDOException;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpBadRequestException;

class Contact extends BaseController
{
    // GET /api/v1/contacts?q=&cursor=&limit=
    public function index(Request $request, Response $response)
    {
        $limit = $this->limit($request);
        $cursor = $this->pairCursor($request);
        $q = $request->getQueryParams()['q'] ?? null;
        if ($q !== null) {
            $q = is_string($q) ? Text::line($q) : null;
            if ($q === null || Text::length($q) > 50) {
                throw new HttpBadRequestException($request, 'q debe tener entre 1 y 50 caracteres.');
            }
        }
        $rows = $this->callProcedure('listar_contactos', [
            'p_usuario' => $this->userId($request),
            'p_busqueda' => $q === '' ? null : $q,
            'p_limite' => $limit,
            'p_cursor_orden' => $cursor[0] ?? null,
            'p_cursor_id' => $cursor[1] ?? null,
        ], true);
        $last = end($rows);
        return $this->json($response, [
            'items' => array_map([$this->presenter(), 'contact'], $rows),
            'next_cursor' => count($rows) === $limit ? Cursor::pair($last['orden'], $last['id']) : null,
        ]);
    }

    // POST /api/v1/contacts {phone, alias?} o {user_id, alias?}
    // Idempotente: 201 si se creó, 200 si ya existía. Mismo 404 si no hay usuario/relación.
    public function create(Request $request, Response $response)
    {
        $body = $this->input($request, [], ['phone', 'user_id', 'alias']);
        $alias = $this->alias($request, $body, false);
        $hasPhone = array_key_exists('phone', $body);
        $hasUser = array_key_exists('user_id', $body);
        if ($hasPhone === $hasUser) {
            $this->failIf($request, [['field' => 'phone', 'detail' => 'Envía exactamente uno de phone o user_id.']]);
        }

        if ($hasPhone) {
            $phone = Phone::normalize($body['phone']);
            if ($phone === null) {
                $this->failIf($request, [['field' => 'phone', 'detail' => 'Debe estar en formato E.164, p. ej. +50688880001.']]);
            }
            $row = $this->callOne('crear_contacto', [
                'p_usuario' => $this->userId($request), 'p_telefono' => $phone, 'p_alias' => $alias,
            ]);
        } else {
            if (!Uuid::isValid($body['user_id'])) {
                $this->failIf($request, [['field' => 'user_id', 'detail' => 'Debe ser un UUID.']]);
            }
            $row = $this->createFromUser($request, strtolower($body['user_id']), $alias);
        }

        $contact = $this->presenter()->contact($row);
        return $row['creado']
            ? $this->created($response, $contact, '/api/v1/contacts/' . $row['id'])
            : $this->json($response, $contact);
    }

    // GET /api/v1/contacts/{contactId}
    public function show(Request $request, Response $response, array $args)
    {
        $id = $this->uuidArg($request, $args, 'contactId', 'Contacto');
        $row = $this->callOne('obtener_contacto', ['p_usuario' => $this->userId($request), 'p_contacto' => $id], true);
        return $this->json($response, $this->presenter()->contact($row));
    }

    // PATCH /api/v1/contacts/{contactId} {alias}   (alias: null vuelve al nombre del usuario)
    public function update(Request $request, Response $response, array $args)
    {
        $id = $this->uuidArg($request, $args, 'contactId', 'Contacto');
        $body = $this->input($request, ['alias']);
        $row = $this->callOne('actualizar_contacto', [
            'p_usuario' => $this->userId($request),
            'p_contacto' => $id,
            'p_alias' => $this->alias($request, $body, true),
        ]);
        return $this->json($response, $this->presenter()->contact($row));
    }

    // DELETE /api/v1/contacts/{contactId}
    public function delete(Request $request, Response $response, array $args)
    {
        $id = $this->uuidArg($request, $args, 'contactId', 'Contacto');
        $this->callProcedure('borrar_contacto', ['p_usuario' => $this->userId($request), 'p_contacto' => $id]);
        return $this->noContent($response);
    }

    private function alias(Request $request, array $body, bool $nullable): ?string
    {
        if (!array_key_exists('alias', $body) || ($nullable && $body['alias'] === null)) {
            return null;
        }
        $alias = is_string($body['alias']) ? Text::line($body['alias']) : null;
        if ($alias === null || $alias === '' || Text::length($alias) > 50) {
            $this->failIf($request, [['field' => 'alias', 'detail' => 'Debe tener entre 1 y 50 caracteres, sin caracteres de control.']]);
        }
        return $alias;
    }

    /**
     * Agregar desde una solicitud de mensaje sin conocer el teléfono (U-06). Requiere la función
     * de BD fn_crear_contacto_usuario (pedida al DBA); mientras no exista responde 501.
     */
    private function createFromUser(Request $request, string $target, ?string $alias): array
    {
        try {
            return $this->callOne('crear_contacto_usuario', [
                'p_usuario' => $this->userId($request), 'p_objetivo' => $target, 'p_alias' => $alias,
            ]);
        } catch (PDOException $e) {
            if (($e->errorInfo[0] ?? '') === '42883') {
                throw new HttpProblemException($request, 501, 'no-implementado', 'No implementado',
                    'Agregar un contacto por user_id aún no está disponible; usa phone.');
            }
            throw $e;
        }
    }
}
