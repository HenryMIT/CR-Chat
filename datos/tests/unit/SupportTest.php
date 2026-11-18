<?php

namespace App\Tests;

use App\Support\ClientIp;
use App\Support\Cursor;
use App\Support\Password;
use App\Support\Phone;
use App\Support\Text;
use App\Support\UserAgent;
use App\Support\Uuid;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class SupportTest extends TestCase
{
    public static function telefonos(): array
    {
        return [
            'CR válido' => ['+50688880001', '+50688880001'],
            'demo seed' => ['+50670000001', '+50670000001'],
            'EE. UU.' => ['+14155552671', '+14155552671'],
            'con forma de email (robo de cuenta)' => ['ana@example.com', null],
            'sin +' => ['50688880001', null],
            'con espacios' => ['+506 8888 0001', null],
            'empieza por 0' => ['+05088880001', null],
            'demasiado corto' => ['+5061234', null],
            'no string' => [50688880001, null],
        ];
    }

    #[DataProvider('telefonos')]
    public function testTelefonoE164Estricto(mixed $input, ?string $expected): void
    {
        $this->assertSame($expected, Phone::normalize($input));
    }

    public function testTextoNfcYSinControl(): void
    {
        $this->assertSame("Jos\u{00E9}", Text::line("Jose\u{0301}"));
        $this->assertNull(Text::line("a\x00b"));
        $this->assertNull(Text::line("a\nb"));
        $this->assertSame("línea 1\nlínea 2\tfin", Text::multiline("línea 1\r\nlínea 2\tfin"));
        $this->assertNull(Text::multiline("a\x07b"));
        $this->assertSame(1, Text::length(Text::line("e\u{0301}")));
    }

    public function testCursores(): void
    {
        $id = Uuid::v4();
        $this->assertSame($id, Cursor::decodeMessage(Cursor::message($id)));
        $this->assertNull(Cursor::decodeMessage('no-es-un-cursor'));
        $this->assertNull(Cursor::decodeMessage('AAAA'));
        $pair = Cursor::pair('2026-10-29 14:03:12.123456+00', $id);
        $this->assertSame(['2026-10-29 14:03:12.123456+00', $id], Cursor::decodePair($pair));
        $this->assertNull(Cursor::decodePair('e30'));          // {}
        $this->assertNull(Cursor::decodePair('!!'));
    }

    public function testUuid(): void
    {
        $id = Uuid::v4();
        $this->assertTrue(Uuid::isValid($id));
        $this->assertSame('4', $id[14]);
        $this->assertFalse(Uuid::isValid('1'));
        $this->assertFalse(Uuid::isValid(null));
        $this->assertSame($id, Uuid::fromBytes(Uuid::toBytes($id)));
    }

    public function testPoliticaDeContrasenas(): void
    {
        $this->assertNull(Password::violation('correcto-caballo-bateria', 'ana@example.com', '+50688880001'));
        $this->assertNotNull(Password::violation('corta'));
        $this->assertNotNull(Password::violation(str_repeat('a', 129)));
        $this->assertNotNull(Password::violation('Password123'));
        $this->assertNotNull(Password::violation('aaaaaaaaaaaa'));
        $this->assertNotNull(Password::violation('ana@example.com', 'ana@example.com'));
        $this->assertNotNull(Password::violation('+50688880001', null, '+50688880001'));
    }

    public function testIpRealSoloDesdeProxyDeConfianza(): void
    {
        $req = (new \Slim\Psr7\Factory\ServerRequestFactory())->createServerRequest('GET', '/', ['REMOTE_ADDR' => '172.18.0.5'])
            ->withHeader('X-Forwarded-For', '198.51.100.7, 10.0.0.2');
        $this->assertSame('172.18.0.5', ClientIp::from($req, []));
        $this->assertSame('198.51.100.7', ClientIp::from($req, ['172.16.0.0/12', '10.0.0.0/8']));
        $this->assertTrue(ClientIp::inCidr('2001:db8::1', '2001:db8::/32'));
        $this->assertFalse(ClientIp::inCidr('192.168.1.1', '10.0.0.0/8'));
    }

    public function testNombreDeDispositivo(): void
    {
        $this->assertSame('Firefox en Linux', UserAgent::deviceName('Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'));
        $this->assertSame('Chrome en Android', UserAgent::deviceName('Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Mobile Safari/537.36'));
        $this->assertSame('Dispositivo desconocido', UserAgent::deviceName(''));
    }
}
