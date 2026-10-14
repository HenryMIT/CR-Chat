<?php
namespace App\Controllers;

use App\Exceptions\HttpConflictException;
use App\Exceptions\HttpUnprocessableException;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpBadRequestException;
use Slim\Exception\HttpForbiddenException;
use Slim\Exception\HttpNotFoundException;
use Slim\Exception\HttpUnauthorizedException;

class Usr extends BaseController
{
    // La columna pass es VARBINARY(64) en MySQL: AES deja espacio para hasta 47 bytes en claro
    public static function validatePassword(Request $request, string $pass): void
    {
        if (strlen($pass) < 8 || strlen($pass) > 40) {
            throw new HttpUnprocessableException($request, 'La contraseña debe tener entre 8 y 40 caracteres.');
        }
    }

    private function profile(Request $request, int $id_usr): array
    {
        $profile = $this->row('read_profile', ['id_user' => $id_usr]);
        if (!$profile) {
            throw new HttpNotFoundException($request, 'Usuario no encontrado.');
        }
        return $profile;
    }

    // GET /api/usr/profile
    public function loadOwnProfile(Request $request, Response $response)
    {
        return $this->json($response, $this->profile($request, $this->userId($request)));
    }

    // GET /api/usr/profile/{id_usr}
    public function loadProfile(Request $request, Response $response, $args)
    {
        return $this->json($response, $this->profile($request, (int) $args['id_usr']));
    }

    // DELETE /api/usr/delete  {pass}
    public function deletedUser(Request $request, Response $response)
    {
        $body = $this->input($request, ['pass']);
        $id_usr = $this->userId($request);

        $res = $this->scalar('delete_user', [
            'id_usr' => $id_usr,
            'pass' => (string) $body['pass'],
            'key' => $this->container->get('key_decript')
        ], 'deleted_user');

        if ($res <= 0) {
            throw new HttpForbiddenException($request, 'Contraseña incorrecta.');
        }

        // Se revoca la sesión del usuario desactivado
        $this->scalar('update_tkr', ['id_usr' => $id_usr, 'tkr' => null]);

        return $this->noContent($response);
    }

    // POST /api/auth/reactivate  {phone_number, pass}  (pública: el usuario desactivado no puede iniciar sesión)
    public function reactiveUser(Request $request, Response $response)
    {
        $body = $this->input($request, ['phone_number', 'pass']);

        $res = $this->scalar('reactive_User', [
            'phone_number' => (string) $body['phone_number'],
            'pass' => (string) $body['pass'],
            'key' => $this->container->get('key_decript')
        ], 'reactive_user');

        if ($res <= 0) {
            throw new HttpUnauthorizedException($request, 'Credenciales incorrectas o la cuenta no está desactivada.');
        }

        return $this->noContent($response);
    }

    // PUT /api/usr/update  {username?, pass?, phone_number?, profile_picture?, profile_description?}
    public function update_User(Request $request, Response $response)
    {
        $fields = ['username', 'pass', 'phone_number', 'profile_picture', 'profile_description'];
        $body = $this->input($request, [], $fields);
        $id_usr = $this->userId($request);

        // Los SP ignoran los campos nulos o vacíos
        $body = array_map(fn($v) => $v === '' || $v === null ? null : (string) $v, $body);
        if (count(array_filter($body, fn($v) => $v !== null)) === 0) {
            throw new HttpBadRequestException($request, 'Debe enviar al menos un campo a actualizar: ' . implode(', ', $fields) . '.');
        }
        if ($body['pass'] !== null) {
            self::validatePassword($request, $body['pass']);
        }
        if ($body['phone_number'] !== null) {
            $query = $this->db()->prepare('SELECT 1 FROM usr WHERE phone_number = :phone AND id_user <> :id');
            $query->execute(['phone' => $body['phone_number'], 'id' => $id_usr]);
            if ($query->fetchColumn() !== false) {
                throw new HttpConflictException($request, 'El número de teléfono ya está en uso.');
            }
        }

        $res = $this->scalar('update_user', [
            'id_usr' => $id_usr,
            'username' => $body['username'],
            'pass' => $body['pass'],
            'phone_number' => $body['phone_number'],
            'profile_picture' => $body['profile_picture'],
            'profile_description' => $body['profile_description'],
            'key' => $this->container->get('key_decript')
        ]);

        if ($res <= 0) {
            throw new HttpNotFoundException($request, 'Usuario no encontrado.');
        }

        return $this->json($response, $this->profile($request, $id_usr));
    }
}
