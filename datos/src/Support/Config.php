<?php

namespace App\Support;

use RuntimeException;

/**
 * Configuración tipada a partir de variables de entorno (ver datos/.env.example).
 * Falla al arrancar si falta un secreto obligatorio o tiene un formato inseguro.
 */
final class Config
{
    public readonly string $appEnv;
    public readonly bool $debug;

    // PostgreSQL: escritura (haproxy:5000, app_rw) y lectura (haproxy:5001, app_ro)
    public readonly string $dbName;
    public readonly array $dbRw;
    public readonly array $dbRo;

    // JWT de acceso (HS256, clave propia)
    public readonly string $jwtKey;
    public readonly int $accessTtl;
    public readonly string $jwtIssuer;
    public readonly string $jwtAudience;
    public readonly int $jwtLeeway;
    public readonly int $refreshTtlDays;
    public readonly int $refreshMaxDays;
    // A-15: refresh en cookie HttpOnly para el cliente web (opt-in con X-Refresh-Cookie: 1)
    public readonly bool $refreshCookieSecure;

    // Cifrado de mensajes (libsodium XChaCha20-Poly1305): key_id => clave binaria de 32 bytes
    public readonly int $msgKeyId;
    public readonly array $msgKeys;

    public readonly array $redis;
    public readonly array $s3;

    public readonly array $corsOrigins;
    public readonly array $trustedProxies;
    public readonly bool $rateLimitEnabled;
    public readonly bool $docsEnabled;
    public readonly string $openapiPath;
    public readonly string $swaggerDir;

    public function __construct()
    {
        $this->appEnv = Env::get('APP_ENV', 'production');
        // P-05: en producción app_debug se fuerza a false
        $this->debug = $this->appEnv !== 'production' && Env::bool('APP_DEBUG');

        $this->dbName = Env::get('DB_NAME', 'cr_chat');
        $this->dbRw = [
            'host' => Env::get('DB_RW_HOST', 'haproxy'),
            'port' => Env::int('DB_RW_PORT', 5000),
            'user' => Env::get('DB_RW_USER', 'app_rw'),
            'pass' => Env::get('DB_RW_PASSWORD', ''),
        ];
        $this->dbRo = [
            'host' => Env::get('DB_RO_HOST', 'haproxy'),
            'port' => Env::int('DB_RO_PORT', 5001),
            'user' => Env::get('DB_RO_USER', 'app_ro'),
            'pass' => Env::get('DB_RO_PASSWORD', ''),
        ];

        $this->jwtKey = Env::required('JWT_ACCESS_KEY');
        if (strlen($this->jwtKey) < 32) {
            throw new RuntimeException('JWT_ACCESS_KEY debe tener al menos 32 bytes.');
        }
        $this->accessTtl = max(60, Env::int('JWT_ACCESS_TTL', 900));
        $this->jwtIssuer = Env::get('JWT_ISSUER', 'cr-chat-api');
        $this->jwtAudience = Env::get('JWT_AUDIENCE', 'cr-chat');
        $this->jwtLeeway = 30;
        $this->refreshTtlDays = Env::int('REFRESH_TTL_DAYS', 30);
        $this->refreshMaxDays = Env::int('REFRESH_MAX_DAYS', 90);
        // Solo se puede desactivar Secure fuera de producción (http://localhost en desarrollo)
        $this->refreshCookieSecure = $this->appEnv === 'production' || Env::bool('REFRESH_COOKIE_SECURE', true);

        $this->msgKeyId = Env::int('MSG_ENC_KEY_ID', 1);
        $keys = [$this->msgKeyId => self::decodeKey(Env::required('MSG_ENC_KEY'), 'MSG_ENC_KEY')];
        // Claves antiguas para descifrar tras una rotación: "1:base64,2:base64"
        foreach (Env::list('MSG_ENC_KEYS_OLD') as $pair) {
            [$id, $b64] = array_pad(explode(':', $pair, 2), 2, '');
            if ((int) $id < 1 || (int) $id === $this->msgKeyId) {
                throw new RuntimeException('MSG_ENC_KEYS_OLD tiene un key_id inválido.');
            }
            $keys[(int) $id] = self::decodeKey($b64, 'MSG_ENC_KEYS_OLD');
        }
        if ($this->msgKeyId < 1 || $this->msgKeyId > 32767) {
            throw new RuntimeException('MSG_ENC_KEY_ID debe estar entre 1 y 32767.');
        }
        $this->msgKeys = $keys;

        $this->redis = [
            'host' => Env::get('REDIS_HOST', 'redis'),
            'port' => Env::int('REDIS_PORT', 6379),
            'password' => Env::get('REDIS_PASSWORD'),
            'db' => Env::int('REDIS_DB', 0),
        ];

        $endpoint = rtrim(Env::get('MINIO_ENDPOINT', 'http://minio:9000'), '/');
        $this->s3 = [
            'endpoint' => $endpoint,
            'public_endpoint' => rtrim(Env::get('MINIO_PUBLIC_ENDPOINT', $endpoint), '/'),
            'region' => Env::get('MINIO_REGION', 'us-east-1'),
            'access_key' => Env::get('MINIO_ACCESS_KEY', ''),
            'secret_key' => Env::get('MINIO_SECRET_KEY', ''),
            'bucket' => Env::get('MINIO_BUCKET', 'cr-chat-media'),
            'put_ttl' => 300,
            'get_ttl' => 600,
        ];

        $this->corsOrigins = Env::list('CORS_ORIGINS', ['http://localhost:5173', 'http://localhost:4200']);
        if (in_array('*', $this->corsOrigins, true)) {
            throw new RuntimeException('CORS_ORIGINS no admite "*": usa una lista blanca de orígenes.');
        }
        $this->trustedProxies = Env::list('TRUSTED_PROXIES');
        $this->rateLimitEnabled = Env::bool('RATE_LIMIT_ENABLED', true);
        $this->docsEnabled = Env::bool('DOCS_ENABLED', true);
        $this->openapiPath = Env::get('OPENAPI_PATH', '/var/www/html/openapi/openapi.yaml');
        $this->swaggerDir = Env::get('SWAGGER_UI_DIR', '/var/www/html/swagger-ui');
    }

    private static function decodeKey(string $b64, string $name): string
    {
        $raw = base64_decode($b64, true);
        if ($raw === false || strlen($raw) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES) {
            throw new RuntimeException("$name debe ser una clave de 32 bytes en base64.");
        }
        return $raw;
    }
}
