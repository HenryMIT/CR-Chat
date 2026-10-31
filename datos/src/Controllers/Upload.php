<?php
namespace App\Controllers;

use App\Services\ObjectStorage;
use App\Support\Time;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class Upload extends BaseController
{
    private const TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf', 'audio/ogg', 'audio/mpeg', 'video/mp4'];
    private const AVATAR_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
    private const MAX = 20971520;       // 20 MiB
    private const MAX_AVATAR = 2097152; // 2 MiB

    // POST /api/v1/uploads {purpose, content_type, size_bytes}
    // Devuelve una URL PUT prefirmada de MinIO (5 min); el archivo nunca pasa por PHP.
    public function create(Request $request, Response $response)
    {
        $body = $this->input($request, ['purpose', 'content_type', 'size_bytes']);
        $errors = [];
        $purpose = $body['purpose'];
        if (!in_array($purpose, ['avatar', 'message'], true)) {
            $errors[] = ['field' => 'purpose', 'detail' => 'Debe ser avatar o message.'];
        }
        $type = $body['content_type'];
        $allowed = $purpose === 'avatar' ? self::AVATAR_TYPES : self::TYPES;
        if (!in_array($type, $allowed, true)) {
            $errors[] = ['field' => 'content_type', 'detail' => 'Tipo no permitido: ' . implode(', ', $allowed) . '.'];
        }
        $size = $body['size_bytes'];
        $max = $purpose === 'avatar' ? self::MAX_AVATAR : self::MAX;
        if (!is_int($size) || $size < 1 || $size > $max) {
            $errors[] = ['field' => 'size_bytes', 'detail' => "Debe ser un entero entre 1 y $max."];
        }
        $this->failIf($request, $errors);

        $cfg = $this->config()->s3;
        $row = $this->callOne('registrar_media', [
            'p_usuario' => $this->userId($request),
            'p_proposito' => $purpose === 'avatar' ? 'avatar' : 'mensaje',
            'p_mime' => $type,
            'p_tamano' => $size,
            'p_bucket' => $cfg['bucket'],
        ]);

        // Content-Type y Content-Length van firmados: MinIO rechaza una subida distinta de lo declarado
        $signed = ['content-type' => $type, 'content-length' => (string) $size];
        $url = $this->container->get(ObjectStorage::class)
            ->presignPublic('PUT', $row['bucket'], $row['clave_objeto'], $cfg['put_ttl'], $signed);

        return $this->json($response, [
            'media_id' => $row['id'],
            'upload_url' => $url,
            'method' => 'PUT',
            'headers' => ['Content-Type' => $type, 'Content-Length' => (string) $size],
            'expires_at' => Time::fromUnix(time() + $cfg['put_ttl']),
        ], 201);
    }
}
