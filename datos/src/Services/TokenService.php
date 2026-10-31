<?php

namespace App\Services;

use App\Exceptions\InvalidTokenException;
use App\Support\Base64Url;
use App\Support\Config;
use App\Support\Uuid;
use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Throwable;

/**
 * Access token: JWT HS256 con clave propia (JWT_ACCESS_KEY) y claims mínimos
 * iss, aud, sub (uuid), sid (uuid de la sesión), jti, iat, exp, typ=access. Sin teléfono ni email.
 * Refresh token: 32 bytes aleatorios en base64url (opaco). En la BD solo va su SHA-256 binario.
 */
class TokenService
{
    public function __construct(private readonly Config $config)
    {
    }

    /** @return array{token:string, exp:int, jti:string} */
    public function issueAccess(string $userId, string $sessionId, ?int $now = null): array
    {
        $now ??= time();
        $jti = Uuid::v4();
        $exp = $now + $this->config->accessTtl;
        $claims = [
            'iss' => $this->config->jwtIssuer,
            'aud' => $this->config->jwtAudience,
            'sub' => $userId,
            'sid' => $sessionId,
            'jti' => $jti,
            'iat' => $now,
            'exp' => $exp,
            'typ' => 'access',
        ];
        return ['token' => JWT::encode($claims, $this->config->jwtKey, 'HS256'), 'exp' => $exp, 'jti' => $jti];
    }

    /**
     * Valida firma, alg, exp/iat (30 s de margen), iss, aud, typ y el formato de sub/sid.
     * @return object claims
     */
    public function verifyAccess(string $jwt): object
    {
        JWT::$leeway = $this->config->jwtLeeway;
        try {
            $claims = JWT::decode($jwt, new Key($this->config->jwtKey, 'HS256'));
        } catch (Throwable) {
            throw new InvalidTokenException('Token de acceso inválido o expirado.');
        }
        $aud = $claims->aud ?? null;
        $audOk = is_array($aud) ? in_array($this->config->jwtAudience, $aud, true) : $aud === $this->config->jwtAudience;
        if (($claims->iss ?? null) !== $this->config->jwtIssuer || !$audOk
            || ($claims->typ ?? null) !== 'access'
            || !Uuid::isValid($claims->sub ?? null) || !Uuid::isValid($claims->sid ?? null)
            || !isset($claims->exp)) {
            throw new InvalidTokenException('Token de acceso inválido.');
        }
        return $claims;
    }

    /** @return array{token:string, hash:string, jti:string} */
    public function newRefresh(): array
    {
        $token = Base64Url::encode(random_bytes(32));
        return ['token' => $token, 'hash' => self::hashRefresh($token), 'jti' => Uuid::v4()];
    }

    /** SHA-256 binario (32 bytes), tal como lo espera fn_crear_sesion / fn_rotar_sesion. */
    public static function hashRefresh(string $token): string
    {
        return hash('sha256', $token, true);
    }

    public function refreshTtlSeconds(): int
    {
        return $this->config->refreshTtlDays * 86400;
    }
}
