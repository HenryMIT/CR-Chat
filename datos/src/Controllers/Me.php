<?php
namespace App\Controllers;

use App\Exceptions\DbException;
use App\Exceptions\HttpConflictException;
use App\Exceptions\HttpProblemException;
use App\Services\SessionGuard;
use App\Support\Password;
use App\Support\Phone;
use App\Support\Text;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpBadRequestException;

class Me extends BaseController
{
    // GET /api/v1/me
    public function show(Request $request, Response $response)
    {
        $me = $this->callOne('leer_perfil', ['p_usuario' => $this->userId($request)], true);
        return $this->json($response, $this->presenter()->me($me));
    }

    // PATCH /api/v1/me {display_name?, about?, avatar_media_id?}
    public function update(Request $request, Response $response)
    {
        $body = $this->input($request, [], ['display_name', 'about', 'avatar_media_id']);
        if (!$body) {
            throw new HttpBadRequestException($request, 'Envía al menos un campo.');
        }
        $params = ['p_usuario' => $this->userId($request)];
        $errors = [];

        if (array_key_exists('display_name', $body)) {
            $name = is_string($body['display_name']) ? Text::line($body['display_name']) : null;
            if ($name === null || $name === '' || Text::length($name) > 50) {
                $errors[] = ['field' => 'display_name', 'detail' => 'Debe tener entre 1 y 50 caracteres, sin caracteres de control.'];
            } else {
                $params['p_nombre_usuario'] = $name;
            }
        }
        if (array_key_exists('about', $body)) {
            if ($body['about'] === null) {
                $params['p_quitar_descripcion'] = true;
            } else {
                $about = is_string($body['about']) ? Text::line($body['about']) : null;
                if ($about === null || Text::length($about) > 140) {
                    $errors[] = ['field' => 'about', 'detail' => 'Máximo 140 caracteres, sin caracteres de control.'];
                } elseif ($about === '') {
                    $params['p_quitar_descripcion'] = true;
                } else {
                    $params['p_descripcion'] = $about;
                }
            }
        }
        $this->failIf($request, $errors);

        if (array_key_exists('avatar_media_id', $body)) {
            if ($body['avatar_media_id'] === null) {
                $params['p_quitar_avatar'] = true;
            } else {
                $params['p_avatar'] = $this->verifyMedia($request, $body['avatar_media_id'], 'avatar', 'avatar_media_id');
            }
        }

        $me = $this->callOne('actualizar_usuario', $params);
        return $this->json($response, $this->presenter()->me($me));
    }

    // DELETE /api/v1/me {password}
    public function delete(Request $request, Response $response)
    {
        $body = $this->input($request, ['password']);
        $this->assertPassword($request, $body['password']);
        $sids = array_column($this->callProcedure('borrar_usuario', ['p_usuario' => $this->userId($request)]), 'id_sesion');
        $this->revoked($sids, 'account_deleted');
        return $this->noContent($response);
    }

    // PUT /api/v1/me/password {current_password, new_password}
    public function changePassword(Request $request, Response $response)
    {
        $body = $this->input($request, ['current_password', 'new_password']);
        $me = $this->assertPassword($request, $body['current_password']);
        $new = is_string($body['new_password']) ? $body['new_password'] : '';
        if (($violation = Password::violation($new, $me['email'], $me['telefono'])) !== null) {
            $this->failIf($request, [['field' => 'new_password', 'detail' => $violation]]);
        }
        $sids = array_column($this->callProcedure('cambiar_pass_hash', [
            'p_usuario' => $this->userId($request),
            'p_pass_hash' => password_hash($new, PASSWORD_ARGON2ID),
            'p_sesion_actual' => $this->sessionId($request),
        ]), 'id_sesion');
        $this->revoked($sids, 'password_changed');
        return $this->noContent($response);
    }

    // PUT /api/v1/me/phone {current_password, phone}
    public function changePhone(Request $request, Response $response)
    {
        $body = $this->input($request, ['current_password', 'phone']);
        $this->assertPassword($request, $body['current_password']);
        $phone = Phone::normalize($body['phone']);
        if ($phone === null) {
            $this->failIf($request, [['field' => 'phone', 'detail' => 'Debe estar en formato E.164, p. ej. +50688880001.']]);
        }
        try {
            $sids = array_column($this->callProcedure('cambiar_telefono', [
                'p_usuario' => $this->userId($request),
                'p_telefono' => $phone,
                'p_sesion_actual' => $this->sessionId($request),
            ]), 'id_sesion');
        } catch (DbException $e) {
            if ($e->sqlState === 'CR409') {
                throw new HttpConflictException($request, 'El número de teléfono no está disponible.');
            }
            throw $e;
        }
        $this->revoked($sids, 'phone_changed');
        $me = $this->callOne('leer_perfil', ['p_usuario' => $this->userId($request)]);
        return $this->json($response, $this->presenter()->me($me));
    }

    // GET /api/v1/me/sessions
    public function sessions(Request $request, Response $response)
    {
        $rows = $this->callProcedure('listar_sesiones', [
            'p_usuario' => $this->userId($request),
            'p_sesion_actual' => $this->sessionId($request),
        ]);
        return $this->json($response, ['items' => array_map([$this->presenter(), 'session'], $rows)]);
    }

    // DELETE /api/v1/me/sessions/{sessionId}
    public function revokeSession(Request $request, Response $response, array $args)
    {
        $sid = $this->uuidArg($request, $args, 'sessionId', 'Sesión');
        $changed = $this->callValue('revocar_sesion', [
            'p_usuario' => $this->userId($request),
            'p_sesion' => $sid,
            'p_motivo' => 'revocada',
        ]);
        if ($changed) {
            $this->revoked([$sid], 'revoked');
        }
        return $this->noContent($response);
    }

    // DELETE /api/v1/me/sessions (todas menos la actual)
    public function revokeOthers(Request $request, Response $response)
    {
        $sids = array_column($this->callProcedure('revocar_sesiones', [
            'p_usuario' => $this->userId($request),
            'p_excepto' => $this->sessionId($request),
        ]), 'id_sesion');
        $this->revoked($sids, 'revoked');
        return $this->noContent($response);
    }

    /**
     * Verifica la contraseña actual (login en una sola consulta por el email del perfil).
     * 403 si no coincide. Devuelve el perfil.
     */
    private function assertPassword(Request $request, mixed $password): array
    {
        $me = $this->callOne('leer_perfil', ['p_usuario' => $this->userId($request)]);
        $cred = $this->callOne('credenciales_login', ['p_identificador' => $me['email']]);
        if (!is_string($password) || $password === '' || !$cred || $cred['id_usuario'] !== $me['id']
            || !password_verify($password, $cred['pass_hash'])) {
            throw new HttpProblemException($request, 403, 'contrasena-incorrecta', 'Contraseña incorrecta',
                'La contraseña actual no es correcta.');
        }
        return $me;
    }

    // Tras el COMMIT: invalida los access en Redis y cierra los WebSocket de esas sesiones
    private function revoked(array $sids, string $reason): void
    {
        $this->container->get(SessionGuard::class)->revoked($sids);
        $this->events()->sessionsRevoked($sids, $reason);
    }
}
