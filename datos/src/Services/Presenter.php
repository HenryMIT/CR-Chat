<?php

namespace App\Services;

use App\Support\Config;
use App\Support\Cursor;
use App\Support\Log;
use App\Support\Time;
use Throwable;

/**
 * Convierte filas de las funciones de BD en los schemas de openapi.yaml.
 * - Media: genera la URL GET prefirmada; nunca expone bucket ni clave_objeto.
 * - Mensajes: descifra el contenido (libsodium) y añade el cursor opaco.
 */
class Presenter
{
    public function __construct(
        private readonly ObjectStorage $storage,
        private readonly MessageCrypto $crypto,
        private readonly Config $config
    ) {
    }

    public function media(mixed $json): ?array
    {
        $m = is_string($json) ? json_decode($json, true) : $json;
        if (!is_array($m) || !isset($m['id'], $m['bucket'], $m['clave_objeto'])) {
            return null;
        }
        $ttl = $this->config->s3['get_ttl'];
        return [
            'id' => $m['id'],
            'content_type' => $m['mime'],
            'size_bytes' => (int) $m['tamano_bytes'],
            'width' => isset($m['ancho']) ? (int) $m['ancho'] : null,
            'height' => isset($m['alto']) ? (int) $m['alto'] : null,
            'url' => $this->storage->presignPublic('GET', $m['bucket'], $m['clave_objeto'], $ttl),
            'url_expires_at' => Time::fromUnix(time() + $ttl),
        ];
    }

    public function me(array $r): array
    {
        return [
            'id' => $r['id'],
            'email' => $r['email'],
            'phone' => $r['telefono'],
            'display_name' => $r['nombre_usuario'],
            'about' => $r['descripcion'],
            'avatar' => $this->media($r['avatar']),
            'created_at' => Time::rfc3339($r['created_at']),
        ];
    }

    public function publicUser(array $r): array
    {
        $out = [
            'id' => $r['id'],
            'display_name' => $r['nombre_usuario'],
            'about' => $r['descripcion'],
            'avatar' => $this->media($r['avatar']),
        ];
        if ($r['es_contacto'] && $r['telefono'] !== null) {
            $out['phone'] = $r['telefono'];
        }
        return $out;
    }

    public function userSummary(string $id, string $name, mixed $avatar): array
    {
        return ['id' => $id, 'display_name' => $name, 'avatar' => $this->media($avatar)];
    }

    public function contact(array $r): array
    {
        return [
            'id' => $r['id'],
            'alias' => $r['alias'],
            'phone' => $r['telefono'],
            'user' => $this->userSummary($r['id_usuario'], $r['nombre_usuario'], $r['avatar']),
            'conversation_id' => $r['id_conversacion'],
            'blocked' => (bool) $r['bloqueado'],
            'created_at' => Time::rfc3339($r['created_at']),
        ];
    }

    public function block(array $r): array
    {
        return [
            'user' => $this->userSummary($r['id_usuario'], $r['nombre_usuario'], $r['avatar']),
            'created_at' => Time::rfc3339($r['created_at']),
        ];
    }

    public function session(array $r): array
    {
        return [
            'id' => $r['id'],
            'device_name' => $r['dispositivo'],
            'ip_hint' => $r['ip_hint'],
            'created_at' => Time::rfc3339($r['created_at']),
            'last_used_at' => Time::rfc3339($r['last_used_at']),
            'current' => (bool) $r['actual'],
        ];
    }

    /** contact_alias = contacto_alias de fn__conversaciones: alias que yo le puse al otro (NULL si no hay). */
    public function conversation(array $r): array
    {
        $last = null;
        if ($r['ult_id'] !== null) {
            $last = $this->message([
                'id' => $r['ult_id'],
                'id_conversacion' => $r['id'],
                'id_remitente' => $r['ult_id_remitente'],
                'client_id' => $r['ult_client_id'],
                'contenido' => $r['ult_contenido'],
                'nonce' => $r['ult_nonce'],
                'key_id' => $r['ult_key_id'],
                'media' => $r['ult_media'],
                'created_at' => $r['ult_created_at'],
                'editado_at' => $r['ult_editado_at'],
                'deleted_at' => $r['ult_deleted_at'],
                'estado' => $r['ult_estado'],
            ]);
        }
        return [
            'id' => $r['id'],
            'peer' => $this->userSummary($r['id_peer'], $r['peer_nombre'], $r['peer_avatar']),
            'contact_id' => $r['id_contacto'],
            'contact_alias' => $r['contacto_alias'],
            'is_contact' => (bool) $r['es_contacto'],
            'blocked' => (bool) $r['bloqueado'],
            'unread_count' => (int) $r['no_leidos'],
            'last_message' => $last,
            'created_at' => Time::rfc3339($r['created_at']),
        ];
    }

    public function message(array $r): array
    {
        $text = null;
        if ($r['contenido'] !== null && $r['deleted_at'] === null) {
            try {
                $text = $this->crypto->decrypt($r['contenido'], (string) $r['nonce'], (int) $r['key_id']);
            } catch (Throwable $e) {
                Log::error('message_decrypt_failed', ['message_id' => $r['id'], 'key_id' => $r['key_id']]);
            }
        }
        $out = [
            'id' => $r['id'],
            'conversation_id' => $r['id_conversacion'],
            'sender_id' => $r['id_remitente'],
            'client_id' => $r['client_id'],
            'text' => $text,
            'media' => $r['deleted_at'] === null ? $this->media($r['media']) : null,
            'created_at' => Time::rfc3339($r['created_at']),
            'edited_at' => Time::rfc3339($r['editado_at']),
            'deleted_at' => Time::rfc3339($r['deleted_at']),
            'cursor' => Cursor::message($r['id']),
        ];
        if ($r['estado'] !== null) {
            $out['status'] = $r['estado'];
        }
        return $out;
    }

    /** Vista de un mensaje propio tal como la ve el otro participante (sin client_id ni status). */
    public static function forPeer(array $message): array
    {
        $message['client_id'] = null;
        unset($message['status']);
        return $message;
    }
}
