<?php
namespace App\Controllers;

use App\Exceptions\HttpConflictException;
use App\Exceptions\HttpUnprocessableException;
use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use RuntimeException;
use Slim\Exception\HttpUnauthorizedException;
use Throwable;

class Auth extends BaseController
{
    private const ISSUER = 'cr-chat-api';

    // En la BD solo se guarda el hash del refresh token, nunca el token en claro
    private function hashToken(?string $tkRef): ?string
    {
        return $tkRef === null ? null : hash('sha256', $tkRef);
    }

    private function storeRefreshToken(int $id_usr, ?string $tkRef): void
    {
        $res = $this->scalar('update_tkr', ['id_usr' => $id_usr, 'tkr' => $this->hashToken($tkRef)]);
        if ($res <= 0) {
            throw new RuntimeException('No se pudo guardar el refresh token.');
        }
    }

    private function generateToken(int $id_usr, string $phone_number, string $username): array
    {
        $key = $this->container->get('key');
        $ttl = $this->container->get('jwt_ttl');
        $now = time();

        $payload = [
            'iss' => self::ISSUER,
            'iat' => $now,
            'exp' => $now + $ttl['access'],
            'sub' => (string) $id_usr,
            'typ' => 'access',
            'num' => $phone_number,
            'name' => $username
        ];

        $payloadRef = [
            'iss' => self::ISSUER,
            'iat' => $now,
            'exp' => $now + $ttl['refresh'],
            'sub' => (string) $id_usr,
            'typ' => 'refresh',
            'jti' => bin2hex(random_bytes(16))
        ];

        return [
            'id_usr' => $id_usr,
            'username' => $username,
            'token_type' => 'Bearer',
            'expires_in' => $ttl['access'],
            'token' => JWT::encode($payload, $key, 'HS256'),
            'tkRef' => JWT::encode($payloadRef, $key, 'HS256')
        ];
    }

    // POST /api/auth/login
    public function starts(Request $request, Response $response)
    {
        $body = $this->input($request, ['phone_number', 'pass']);

        $id_usr = $this->scalar('authorized_user', [
            'phone_number' => (string) $body['phone_number'],
            'pass' => (string) $body['pass'],
            'key' => $this->container->get('key_decript')
        ]);

        $profile = $id_usr > 0 ? $this->row('read_profile', ['id_user' => $id_usr]) : null;
        if (!$profile) {
            throw new HttpUnauthorizedException($request, 'Número de teléfono o contraseña incorrectos.');
        }

        $tokens = $this->generateToken($id_usr, $profile['phone_number'], $profile['username']);
        $this->storeRefreshToken($id_usr, $tokens['tkRef']);

        return $this->json($response, $tokens);
    }

    // POST /api/auth/logout (requiere access token)
    public function close(Request $request, Response $response)
    {
        $this->storeRefreshToken($this->userId($request), null);
        return $this->noContent($response);
    }

    // POST /api/auth/refresh
    public function refresh(Request $request, Response $response)
    {
        $body = $this->input($request, ['tkRef']);
        $tkRef = (string) $body['tkRef'];

        try {
            $datos = JWT::decode($tkRef, new Key($this->container->get('key'), 'HS256'));
        } catch (Throwable) {
            throw new HttpUnauthorizedException($request, 'Refresh token inválido o expirado.');
        }

        $id_usr = (int) ($datos->sub ?? 0);
        if (($datos->typ ?? null) !== 'refresh' || $id_usr <= 0) {
            throw new HttpUnauthorizedException($request, 'Refresh token inválido.');
        }

        // Solo es válido el último refresh token emitido (rotación); uno anterior o revocado se rechaza
        $valid = $this->scalar('verify_tokens', ['id_usr' => $id_usr, 'tkr' => $this->hashToken($tkRef)]);
        $profile = $valid > 0 ? $this->row('read_profile', ['id_user' => $id_usr]) : null;
        if (!$profile) {
            throw new HttpUnauthorizedException($request, 'Refresh token revocado.');
        }

        $tokens = $this->generateToken($id_usr, $profile['phone_number'], $profile['username']);
        $this->storeRefreshToken($id_usr, $tokens['tkRef']);

        return $this->json($response, $tokens);
    }

    // POST /api/auth/register
    public function register(Request $request, Response $response)
    {
        $body = $this->input($request, ['username', 'phone_number', 'email', 'pass']);

        if (!filter_var($body['email'], FILTER_VALIDATE_EMAIL)) {
            throw new HttpUnprocessableException($request, 'El email no tiene un formato válido.');
        }
        Usr::validatePassword($request, (string) $body['pass']);

        $res = $this->scalar('register_user', [
            'username' => (string) $body['username'],
            'phone_number' => (string) $body['phone_number'],
            'email' => (string) $body['email'],
            'pass' => (string) $body['pass'],
            'key' => $this->container->get('key_decript')
        ]);

        if ($res === -1) {
            throw new HttpConflictException($request, 'Ya existe un usuario con ese número de teléfono o email.');
        }
        if ($res <= 0) {
            throw new RuntimeException("sp_register_user devolvió $res");
        }

        return $this->json($response, ['id_usr' => $res], 201)
            ->withHeader('Location', "/api/usr/profile/$res");
    }
}
