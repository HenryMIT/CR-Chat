<?php

namespace App\Tests;

use App\Services\MessageCrypto;
use App\Support\Config;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class MessageCryptoTest extends TestCase
{
    public function testCifraYDescifraConNonceDe24BytesYKeyIdActual(): void
    {
        $crypto = new MessageCrypto(new Config());
        $enc = $crypto->encrypt('Hola, ¿cómo estás?');
        $this->assertSame(24, strlen($enc['nonce']));
        $this->assertSame(2, $enc['key_id']);
        $this->assertNotSame('Hola, ¿cómo estás?', $enc['cipher']);
        $this->assertSame('Hola, ¿cómo estás?', $crypto->decrypt($enc['cipher'], $enc['nonce'], $enc['key_id']));
    }

    public function testNoncesDistintosEnCadaMensaje(): void
    {
        $crypto = new MessageCrypto(new Config());
        $this->assertNotSame($crypto->encrypt('x')['nonce'], $crypto->encrypt('x')['nonce']);
    }

    public function testRechazaCiphertextAlterado(): void
    {
        $crypto = new MessageCrypto(new Config());
        $enc = $crypto->encrypt('secreto');
        $enc['cipher'][0] = chr(ord($enc['cipher'][0]) ^ 1);
        $this->expectException(RuntimeException::class);
        $crypto->decrypt($enc['cipher'], $enc['nonce'], $enc['key_id']);
    }

    public function testKeyIdCambiadoNoAutentica(): void
    {
        $crypto = new MessageCrypto(new Config());
        $enc = $crypto->encrypt('secreto');
        $this->expectException(RuntimeException::class);
        $crypto->decrypt($enc['cipher'], $enc['nonce'], 1); // clave antigua: AAD y clave distintas
    }

    public function testKeyIdDesconocido(): void
    {
        $crypto = new MessageCrypto(new Config());
        $this->expectException(RuntimeException::class);
        $crypto->decrypt('x', str_repeat("\0", 24), 9);
    }
}
