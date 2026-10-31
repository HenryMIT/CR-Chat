<?php

namespace App\Tests;

use App\Exceptions\InvalidTokenException;
use App\Services\TokenService;
use App\Support\Config;
use App\Support\Uuid;
use Firebase\JWT\JWT;
use PHPUnit\Framework\TestCase;

final class TokenServiceTest extends TestCase
{
    private TokenService $tokens;

    protected function setUp(): void
    {
        $this->tokens = new TokenService(new Config());
    }

    public function testAccessConClaimsMinimos(): void
    {
        $uid = Uuid::v4();
        $sid = Uuid::v4();
        $claims = $this->tokens->verifyAccess($this->tokens->issueAccess($uid, $sid)['token']);
        $this->assertSame($uid, $claims->sub);
        $this->assertSame($sid, $claims->sid);
        $this->assertSame('access', $claims->typ);
        $this->assertSame('cr-chat-api', $claims->iss);
        $this->assertSame('cr-chat', $claims->aud);
        $this->assertTrue(Uuid::isValid($claims->jti));
        $keys = array_keys((array) $claims);
        sort($keys);
        $this->assertSame(['aud', 'exp', 'iat', 'iss', 'jti', 'sid', 'sub', 'typ'], $keys);
    }

    public function testRechazaOtraClave(): void
    {
        $jwt = JWT::encode(['iss' => 'cr-chat-api', 'aud' => 'cr-chat', 'sub' => Uuid::v4(), 'sid' => Uuid::v4(), 'typ' => 'access', 'exp' => time() + 60],
            'otra-clave-distinta-de-al-menos-32-bytes!!', 'HS256');
        $this->expectException(InvalidTokenException::class);
        $this->tokens->verifyAccess($jwt);
    }

    public function testRechazaIssuerAudienceOTipoIncorrectos(): void
    {
        $key = 'clave-de-prueba-unitaria-de-al-menos-32-bytes';
        $base = ['iss' => 'cr-chat-api', 'aud' => 'cr-chat', 'sub' => Uuid::v4(), 'sid' => Uuid::v4(), 'typ' => 'access', 'exp' => time() + 60];
        foreach ([['iss' => 'otro'], ['aud' => 'otra'], ['typ' => 'refresh'], ['sub' => '42'], ['sid' => null]] as $change) {
            try {
                $this->tokens->verifyAccess(JWT::encode(array_merge($base, $change), $key, 'HS256'));
                $this->fail('Aceptó un token con ' . json_encode($change));
            } catch (InvalidTokenException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function testRechazaExpirado(): void
    {
        $token = $this->tokens->issueAccess(Uuid::v4(), Uuid::v4(), time() - 3600)['token'];
        $this->expectException(InvalidTokenException::class);
        $this->tokens->verifyAccess($token);
    }

    public function testRefreshOpacoYHashSha256Binario(): void
    {
        $r = $this->tokens->newRefresh();
        $this->assertMatchesRegularExpression('/^[A-Za-z0-9_-]{43}$/', $r['token']);
        $this->assertSame(32, strlen($r['hash']));
        $this->assertSame(hash('sha256', $r['token'], true), TokenService::hashRefresh($r['token']));
        $this->assertNotSame($r['token'], $this->tokens->newRefresh()['token']);
    }
}
