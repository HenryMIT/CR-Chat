<?php

namespace App\Services;

use App\Support\Config;
use RuntimeException;

/**
 * Cifrado del contenido de los mensajes en la app (M-05): XChaCha20-Poly1305 IETF de libsodium,
 * nonce aleatorio de 24 bytes por mensaje y key_id para rotar claves. La clave nunca llega a la BD.
 * AAD = "cr-chat/mensaje/v1|{key_id}" (liga el ciphertext a la versión del esquema y a la clave).
 */
class MessageCrypto
{
    public function __construct(private readonly Config $config)
    {
    }

    /** @return array{cipher:string, nonce:string, key_id:int} */
    public function encrypt(string $plain): array
    {
        $keyId = $this->config->msgKeyId;
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $cipher = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt($plain, self::aad($keyId), $nonce, $this->config->msgKeys[$keyId]);
        return ['cipher' => $cipher, 'nonce' => $nonce, 'key_id' => $keyId];
    }

    public function decrypt(string $cipher, string $nonce, int $keyId): string
    {
        $key = $this->config->msgKeys[$keyId] ?? null;
        if ($key === null || strlen($nonce) !== SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES) {
            throw new RuntimeException("No hay clave para descifrar el key_id $keyId.");
        }
        $plain = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt($cipher, self::aad($keyId), $nonce, $key);
        if ($plain === false) {
            throw new RuntimeException('El contenido cifrado no se pudo autenticar.');
        }
        return $plain;
    }

    private static function aad(int $keyId): string
    {
        return "cr-chat/mensaje/v1|$keyId";
    }
}
