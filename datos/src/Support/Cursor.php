<?php

namespace App\Support;

/**
 * Cursores opacos de paginación.
 * - Mensajes: el public_id del mensaje (16 bytes) en base64url.
 * - Listas (contactos, bloqueos, conversaciones): base64url(JSON [clave, id]) de la última fila.
 * Un cursor mal formado devuelve null (el controlador responde 400).
 */
final class Cursor
{
    public static function message(string $messageId): string
    {
        return Base64Url::encode(Uuid::toBytes($messageId));
    }

    public static function decodeMessage(string $cursor): ?string
    {
        $raw = Base64Url::decode($cursor);
        return ($raw !== null && strlen($raw) === 16) ? Uuid::fromBytes($raw) : null;
    }

    public static function pair(string $key, string $id): string
    {
        return Base64Url::encode(json_encode([$key, $id], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
    }

    /** @return array{0:string,1:string}|null */
    public static function decodePair(string $cursor): ?array
    {
        $raw = Base64Url::decode($cursor);
        $data = $raw === null ? null : json_decode($raw, true);
        if (!is_array($data) || count($data) !== 2 || !array_is_list($data)
            || !is_string($data[0]) || $data[0] === '' || strlen($data[0]) > 200 || !Uuid::isValid($data[1])) {
            return null;
        }
        return [$data[0], strtolower($data[1])];
    }
}
