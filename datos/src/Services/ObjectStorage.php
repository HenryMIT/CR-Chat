<?php

namespace App\Services;

use App\Support\Config;
use App\Support\Log;

/**
 * Cliente S3 mínimo para MinIO: URLs prefirmadas AWS SigV4 (query string) y HEAD/DELETE de objetos.
 *
 * Se eligió una firma SigV4 propia (~150 líneas, probada con el vector oficial de AWS en
 * tests/unit/ObjectStorageTest.php) en lugar de aws/aws-sdk-php: la API solo necesita presignar
 * PUT/GET y hacer HEAD/DELETE, y el SDK añade decenas de MB, Guzzle y una superficie de
 * actualización mucho mayor que el código que reemplaza.
 *
 * - URLs para el cliente: MINIO_PUBLIC_ENDPOINT (host visible desde el navegador).
 * - Operaciones del servidor: MINIO_ENDPOINT (red interna de Docker). La firma incluye el host,
 *   por eso se firma con el endpoint por el que realmente viaja la petición.
 * Estilo de ruta: {endpoint}/{bucket}/{clave}.
 */
class ObjectStorage
{
    public function __construct(private readonly Config $config)
    {
    }

    /** URL prefirmada para el navegador. $headers firmados (p. ej. content-type, content-length). */
    public function presignPublic(string $method, string $bucket, string $key, int $expires, array $headers = []): string
    {
        return $this->presign($this->config->s3['public_endpoint'], $method, $bucket, $key, $expires, $headers);
    }

    /** HEAD del objeto por la red interna: ['size' => int, 'type' => string] o null si no existe. */
    public function head(string $bucket, string $key): ?array
    {
        $res = $this->request('HEAD', $bucket, $key);
        if ($res === null || $res['status'] !== 200) {
            return null;
        }
        return [
            'size' => isset($res['headers']['content-length']) ? (int) $res['headers']['content-length'] : -1,
            'type' => strtolower(trim(explode(';', $res['headers']['content-type'] ?? '')[0])),
        ];
    }

    /** DELETE idempotente: true si se borró o no existía. */
    public function delete(string $bucket, string $key): bool
    {
        $res = $this->request('DELETE', $bucket, $key);
        return $res !== null && in_array($res['status'], [200, 204, 404], true);
    }

    /** Disponibilidad del bucket (para /ready). */
    public function ping(): bool
    {
        $res = $this->request('HEAD', $this->config->s3['bucket'], '', 1);
        return $res !== null && $res['status'] === 200;
    }

    private function request(string $method, string $bucket, string $key, int $timeout = 2): ?array
    {
        $url = $this->presign($this->config->s3['endpoint'], $method, $bucket, $key, 60);
        $headers = [];
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_NOBODY => $method === 'HEAD',
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => $timeout,
            CURLOPT_TIMEOUT => $timeout,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
            CURLOPT_HEADERFUNCTION => function ($ch, string $line) use (&$headers) {
                if (str_contains($line, ':')) {
                    [$name, $value] = explode(':', $line, 2);
                    $headers[strtolower(trim($name))] = trim($value);
                }
                return strlen($line);
            },
        ]);
        $ok = curl_exec($ch);
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        if ($ok === false) {
            Log::warning('storage_request_failed', ['method' => $method, 'error' => curl_error($ch)]);
            return null;
        }
        return ['status' => $status, 'headers' => $headers];
    }

    private function presign(string $endpoint, string $method, string $bucket, string $key, int $expires, array $headers = []): string
    {
        $parts = parse_url($endpoint);
        $scheme = $parts['scheme'] ?? 'http';
        $host = $parts['host'] ?? 'localhost';
        if (isset($parts['port']) && !(($scheme === 'http' && $parts['port'] === 80) || ($scheme === 'https' && $parts['port'] === 443))) {
            $host .= ':' . $parts['port'];
        }
        $basePath = rtrim($parts['path'] ?? '', '/');
        $path = $basePath . '/' . rawurlencode($bucket) . ($key === '' ? '' : '/' . $key);
        return self::presignUrl(
            $method, $scheme, $host, $path,
            $this->config->s3['region'], $this->config->s3['access_key'], $this->config->s3['secret_key'],
            $expires, gmdate('Ymd\THis\Z'), $headers
        );
    }

    /**
     * Firma AWS SigV4 por query string (servicio s3, UNSIGNED-PAYLOAD).
     * $path sin codificar (cada segmento se codifica con rawurlencode).
     */
    public static function presignUrl(
        string $method,
        string $scheme,
        string $host,
        string $path,
        string $region,
        string $accessKey,
        string $secretKey,
        int $expires,
        string $amzDate,
        array $headers = []
    ): string {
        $date = substr($amzDate, 0, 8);
        $scope = "$date/$region/s3/aws4_request";

        $canonicalHeaders = ['host' => $host];
        foreach ($headers as $name => $value) {
            $canonicalHeaders[strtolower($name)] = trim(preg_replace('/\s+/', ' ', (string) $value));
        }
        ksort($canonicalHeaders, SORT_STRING);
        $signedHeaders = implode(';', array_keys($canonicalHeaders));

        $query = [
            'X-Amz-Algorithm' => 'AWS4-HMAC-SHA256',
            'X-Amz-Credential' => "$accessKey/$scope",
            'X-Amz-Date' => $amzDate,
            'X-Amz-Expires' => (string) $expires,
            'X-Amz-SignedHeaders' => $signedHeaders,
        ];
        ksort($query, SORT_STRING);
        $canonicalQuery = implode('&', array_map(
            fn($k, $v) => rawurlencode($k) . '=' . rawurlencode($v),
            array_keys($query),
            $query
        ));

        $canonicalUri = implode('/', array_map('rawurlencode', explode('/', $path)));
        $headerBlock = '';
        foreach ($canonicalHeaders as $name => $value) {
            $headerBlock .= "$name:$value\n";
        }

        $canonicalRequest = implode("\n", [
            strtoupper($method), $canonicalUri, $canonicalQuery, $headerBlock, $signedHeaders, 'UNSIGNED-PAYLOAD',
        ]);
        $stringToSign = implode("\n", ['AWS4-HMAC-SHA256', $amzDate, $scope, hash('sha256', $canonicalRequest)]);

        $kDate = hash_hmac('sha256', $date, 'AWS4' . $secretKey, true);
        $kRegion = hash_hmac('sha256', $region, $kDate, true);
        $kService = hash_hmac('sha256', 's3', $kRegion, true);
        $kSigning = hash_hmac('sha256', 'aws4_request', $kService, true);
        $signature = hash_hmac('sha256', $stringToSign, $kSigning);

        return "$scheme://$host$canonicalUri?$canonicalQuery&X-Amz-Signature=$signature";
    }
}
