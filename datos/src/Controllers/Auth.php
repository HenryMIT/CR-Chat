<?php
namespace App\Controllers;

use App\Exceptions\DbException;
use App\Exceptions\HttpProblemException;
use App\Exceptions\HttpTooManyRequestsException;
use App\Exceptions\HttpUnprocessableException;
use App\Services\Bytea;
use App\Services\RateLimiter;
use App\Services\RedisConn;
use App\Services\SessionGuard;
use App\Services\TokenService;
use App\Support\ClientIp;
use App\Support\Password;
use App\Support\Phone;
use App\Support\Text;
use App\Support\UserAgent;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Redis;
use Slim\Exception\HttpUnauthorizedException;

class Auth extends BaseController
{
    // Hash argon2id de una cadena aleatoria descartada: si el identificador no existe se verifica
    // contra él para que el tiempo de respuesta no revele qué cuentas existen (A-03).
    private const DUMMY_HASH = '$argon2id$v=19$m=65536,t=4,p=1$OU1hQjl6Y0U2MW5KaHJlUg$TyKg+sxudU9XkvPXV1xoKOhSQkuUWDr6mYNflu20EWY';

    public const REFRESH_COOKIE = 'cr_refresh';
    private const COOKIE_PATH = '/api/v1/auth';

    // POST /api/v1/auth/register {email, phone, display_name, password}
    public function register(Request $request, Response $response)
    {
        $body = $this->input($request, ['email', 'phone', 'display_name', 'password']);
        $errors = [];

        $email = is_string($body['email']) ? trim($body['email']) : '';
        if (strlen($email) > 254 || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            $errors[] = ['field' => 'email', 'detail' => 'Debe ser un email válido (máximo 254 caracteres).'];
        }
        // El teléfono se valida E.164 estricto: un valor con forma de email nunca pasa (A-01)
        $phone = Phone::normalize($body['phone']);
        if ($phone === null) {
            $errors[] = ['field' => 'phone', 'detail' => 'Debe estar en formato E.164, p. ej. +50688880001.'];
        }
        $name = is_string($body['display_name']) ? Text::line($body['display_name']) : null;
        if ($name === null || $name === '' || Text::length($name) > 50) {
            $errors[] = ['field' => 'display_name', 'detail' => 'Debe tener entre 1 y 50 caracteres, sin caracteres de control.'];
        }
        $password = is_string($body['password']) ? $body['password'] : '';
        if (($violation = Password::violation($password, $email, $phone)) !== null) {
            $errors[] = ['field' => 'password', 'detail' => $violation];
        }
        $this->failIf($request, $errors);

        try {
            $userId = $this->callValue('registrar_usuario', [
                'p_nombre_usuario' => $name,
                'p_telefono' => $phone,
                'p_email' => $email,
                'p_pass_hash' => password_hash($password, PASSWORD_ARGON2ID),
            ]);
        } catch (DbException $e) {
            if ($e->sqlState === 'CR409') {
                // 409 genérico: no se indica si colisiona el email o el teléfono (A-13)
                throw new HttpProblemException($request, 409, 'registro-no-disponible', 'Registro no disponible',
                    'No se pudo completar el registro con esos datos.');
            }
            throw $e;
        }

        $me = $this->callOne('leer_perfil', ['p_usuario' => $userId]);
        return $this->created($response, $this->presenter()->me($me), '/api/v1/me');
    }

    // POST /api/v1/auth/login {identifier, password, device_name?}
    public function login(Request $request, Response $response)
    {
        $body = $this->input($request, ['identifier', 'password'], ['device_name']);
        $identifier = $this->identifier($request, $body['identifier']);
        $password = $this->password($request, $body['password']);
        $device = $this->deviceName($request, $body['device_name'] ?? null);

        $this->assertNotLocked($request, $identifier);

        // Una sola consulta devuelve el hash (por email si tiene "@", si no por teléfono E.164)
        $cred = $this->callOne('credenciales_login', ['p_identificador' => $identifier]);
        $valid = password_verify($password, $cred['pass_hash'] ?? self::DUMMY_HASH);
        if (!$cred || !$valid || $cred['eliminado']) {
            $this->registerFailure($identifier);
            throw new HttpUnauthorizedException($request, 'Credenciales incorrectas.');
        }
        $this->clearFailures($identifier);

        if (password_needs_rehash($cred['pass_hash'], PASSWORD_ARGON2ID)) {
            $this->callProcedure('rehash_pass', [
                'p_usuario' => $cred['id_usuario'],
                'p_pass_hash' => password_hash($password, PASSWORD_ARGON2ID),
            ]);
        }

        $tokens = $this->container->get(TokenService::class);
        $refresh = $tokens->newRefresh();
        $ua = mb_substr($request->getHeaderLine('User-Agent'), 0, 512);
        $session = $this->callOne('crear_sesion', [
            'p_usuario' => $cred['id_usuario'],
            'p_jti' => $refresh['jti'],
            'p_refresh_hash' => new Bytea($refresh['hash']),
            'p_dispositivo' => $device,
            'p_user_agent' => $ua === '' ? null : $ua,
            'p_ip' => ClientIp::from($request, $this->config()->trustedProxies),
            'p_vida' => $this->config()->refreshTtlDays . ' days',
            'p_vida_max' => $this->config()->refreshMaxDays . ' days',
        ]);

        return $this->tokenPair($request, $response, $cred['id_usuario'], $session['id_sesion'], $refresh['token'], $session['expira_at']);
    }

    // POST /api/v1/auth/refresh {refresh_token}  (o cookie cr_refresh con X-Refresh-Cookie: 1)
    public function refresh(Request $request, Response $response)
    {
        $body = $request->getParsedBody();
        $cookieMode = $this->cookieMode($request);
        if ($cookieMode && (!is_array($body) || !array_key_exists('refresh_token', $body))) {
            $this->assertSameSiteOrigin($request);
            $token = $request->getCookieParams()[self::REFRESH_COOKIE] ?? null;
        } else {
            $body = $this->input($request, ['refresh_token']);
            $token = $body['refresh_token'];
        }
        if (!is_string($token) || preg_match('/^[A-Za-z0-9_-]{32,512}$/', $token) !== 1) {
            $this->refreshFailed($request, 'Refresh token inválido.');
        }

        $tokens = $this->container->get(TokenService::class);
        $new = $tokens->newRefresh();
        try {
            $row = $this->callOne('rotar_sesion', [
                'p_refresh_hash' => new Bytea(TokenService::hashRefresh($token)),
                'p_jti_nuevo' => $new['jti'],
                'p_hash_nuevo' => new Bytea($new['hash']),
                'p_vida' => $this->config()->refreshTtlDays . ' days',
            ]);
        } catch (DbException $e) {
            if ($e->sqlState === 'CR401') {
                $this->refreshFailed($request, 'Refresh token inválido, expirado o revocado.');
            }
            throw $e;
        }

        if ($row['estado'] === 'reutilizacion') {
            // Refresh ya rotado: posible robo. La BD ya revocó la sesión; se invalida el access
            // en Redis y se cierran sus WebSocket. (Dos refresh simultáneos del mismo token también
            // llegan aquí: el cliente debe serializar el refresh.)
            $this->container->get(SessionGuard::class)->revoked([$row['id_sesion']]);
            $this->events()->sessionsRevoked([$row['id_sesion']], 'refresh_reuse');
            $this->refreshFailed($request, 'Refresh token reutilizado: la sesión fue revocada.');
        }

        return $this->tokenPair($request, $response, $row['id_usuario'], $row['id_sesion'], $new['token'], $row['expira_at']);
    }

    // POST /api/v1/auth/logout (requiere access token)
    public function logout(Request $request, Response $response)
    {
        $sid = $this->sessionId($request);
        $this->callValue('revocar_sesion', ['p_usuario' => $this->userId($request), 'p_sesion' => $sid, 'p_motivo' => 'logout']);
        $this->container->get(SessionGuard::class)->revoked([$sid]);
        $this->events()->sessionsRevoked([$sid], 'logout');
        return $this->clearCookie($this->noContent($response));
    }

    // POST /api/v1/auth/reactivate {identifier, password}
    public function reactivate(Request $request, Response $response)
    {
        $body = $this->input($request, ['identifier', 'password'], ['device_name']);
        $identifier = $this->identifier($request, $body['identifier']);
        $password = $this->password($request, $body['password']);
        $this->assertNotLocked($request, $identifier);

        $cred = $this->callOne('credenciales_login', ['p_identificador' => $identifier]);
        $valid = password_verify($password, $cred['pass_hash'] ?? self::DUMMY_HASH);
        // Mismo 401 si las credenciales fallan, si la cuenta está activa o si pasó el plazo
        if (!$cred || !$valid || !$cred['eliminado']) {
            $this->registerFailure($identifier);
            throw new HttpUnauthorizedException($request, 'Credenciales incorrectas.');
        }
        try {
            $this->callProcedure('reactivar_usuario', ['p_usuario' => $cred['id_usuario']]);
        } catch (DbException $e) {
            if ($e->sqlState === 'CR404') {
                throw new HttpUnauthorizedException($request, 'Credenciales incorrectas.');
            }
            throw $e;
        }
        $this->clearFailures($identifier);
        return $this->noContent($response);
    }

    // ------------------------------------------------------------------ auxiliares

    private function tokenPair(Request $request, Response $response, string $userId, string $sid, string $refresh, string $refreshExp): Response
    {
        $access = $this->container->get(TokenService::class)->issueAccess($userId, $sid);
        $this->container->get(SessionGuard::class)->remember($userId, $sid);
        $me = $this->callOne('leer_perfil', ['p_usuario' => $userId]);
        $refreshIn = max(0, (new \DateTimeImmutable($refreshExp))->getTimestamp() - time());

        $data = [
            'access_token' => $access['token'],
            'token_type' => 'Bearer',
            'expires_in' => $this->config()->accessTtl,
            'refresh_token' => $refresh,
            'refresh_expires_in' => $refreshIn,
            'session_id' => $sid,
            'user' => $this->presenter()->me($me),
        ];
        // A-15: con X-Refresh-Cookie: 1 el refresh viaja solo en una cookie HttpOnly
        if ($this->cookieMode($request)) {
            unset($data['refresh_token']);
            $response = $response->withHeader('Set-Cookie', $this->cookie($refresh, $refreshIn));
        }
        return $this->json($response, $data)->withHeader('Cache-Control', 'no-store');
    }

    private function cookieMode(Request $request): bool
    {
        return $request->getHeaderLine('X-Refresh-Cookie') === '1';
    }

    private function cookie(string $value, int $maxAge): string
    {
        return sprintf('%s=%s; Path=%s; Max-Age=%d; HttpOnly; SameSite=Strict%s',
            self::REFRESH_COOKIE, $value, self::COOKIE_PATH, $maxAge,
            $this->config()->refreshCookieSecure ? '; Secure' : '');
    }

    private function clearCookie(Response $response): Response
    {
        return $response->withAddedHeader('Set-Cookie', $this->cookie('', 0));
    }

    // CSRF en modo cookie: SameSite=Strict + encabezado propio (fuerza preflight) + Origin en lista blanca
    private function assertSameSiteOrigin(Request $request): void
    {
        $origin = $request->getHeaderLine('Origin');
        if ($origin !== '' && !in_array($origin, $this->config()->corsOrigins, true)) {
            throw new HttpProblemException($request, 403, 'origen-no-permitido', 'Origen no permitido',
                'El origen de la petición no está permitido.');
        }
    }

    private function refreshFailed(Request $request, string $detail): never
    {
        $ip = ClientIp::from($request, $this->config()->trustedProxies);
        $rl = $this->container->get(RateLimiter::class)->hit('refresh-invalid', "ip:$ip");
        if (!$rl['allowed']) {
            throw new HttpTooManyRequestsException($request, "Demasiados intentos de refresh inválidos. Reintenta en {$rl['retry_after']} segundos.",
                null, [], ['Retry-After' => (string) $rl['retry_after']]);
        }
        $e = new HttpUnauthorizedException($request, $detail);
        throw $e;
    }

    private function identifier(Request $request, mixed $value): string
    {
        $value = is_string($value) ? trim($value) : '';
        if (str_contains($value, '@')) {
            if (strlen($value) <= 254 && filter_var($value, FILTER_VALIDATE_EMAIL)) {
                return $value;
            }
        } elseif (Phone::looksE164($value)) {
            return $value;
        }
        throw new HttpUnprocessableException($request, null, null, [
            ['field' => 'identifier', 'detail' => 'Debe ser un email o un teléfono en formato E.164.'],
        ]);
    }

    private function password(Request $request, mixed $value): string
    {
        if (!is_string($value) || $value === '' || mb_strlen($value) > 128) {
            throw new HttpUnprocessableException($request, null, null, [
                ['field' => 'password', 'detail' => 'Debe tener entre 1 y 128 caracteres.'],
            ]);
        }
        return $value;
    }

    // device_name es obligatorio en la BD: si el cliente no lo envía se deriva del User-Agent
    private function deviceName(Request $request, mixed $value): string
    {
        if ($value === null || $value === '') {
            return UserAgent::deviceName($request->getHeaderLine('User-Agent'));
        }
        $name = is_string($value) ? Text::line($value) : null;
        if ($name === null || $name === '' || Text::length($name) > 100) {
            throw new HttpUnprocessableException($request, null, null, [
                ['field' => 'device_name', 'detail' => 'Debe tener entre 1 y 100 caracteres.'],
            ]);
        }
        return $name;
    }

    // Bloqueo progresivo por identificador tras 10 fallos seguidos: 1, 5 y 15 minutos (§6)
    private function assertNotLocked(Request $request, string $identifier): void
    {
        $key = 'lock:' . hash('sha256', mb_strtolower($identifier));
        $ttl = $this->container->get(RedisConn::class)->run(fn(Redis $r) => $r->ttl($key), -2);
        if ($ttl > 0) {
            throw new HttpTooManyRequestsException($request, "Cuenta bloqueada temporalmente por intentos fallidos. Reintenta en $ttl segundos.",
                null, [], ['Retry-After' => (string) $ttl]);
        }
    }

    private function registerFailure(string $identifier): void
    {
        $h = hash('sha256', mb_strtolower($identifier));
        $this->container->get(RedisConn::class)->run(function (Redis $r) use ($h) {
            $fails = $r->incr("lf:$h");
            $r->expire("lf:$h", 3600);
            if ($fails >= 10) {
                $r->setex("lock:$h", $fails >= 20 ? 900 : ($fails >= 15 ? 300 : 60), '1');
            }
            return $fails;
        });
    }

    private function clearFailures(string $identifier): void
    {
        $h = hash('sha256', mb_strtolower($identifier));
        $this->container->get(RedisConn::class)->run(fn(Redis $r) => $r->del("lf:$h", "lock:$h"));
    }
}
