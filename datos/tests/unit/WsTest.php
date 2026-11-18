<?php

namespace App\Tests;

use App\Services\RateLimiter;
use App\Ws\ConnState;
use App\Ws\RedisSubscriber;
use App\Ws\RespError;
use PHPUnit\Framework\TestCase;

final class WsTest extends TestCase
{
    public function testParserRespPmessageYParciales(): void
    {
        $msg = RedisSubscriber::command(['pmessage', 'user:*', 'user:abc', '{"type":"x"}']);
        $off = 0;
        $this->assertNull(RedisSubscriber::parse(substr($msg, 0, 20), $off));
        $this->assertSame(0, $off);
        $v = RedisSubscriber::parse($msg . '+OK' . "\r\n", $off);
        $this->assertSame(['pmessage', 'user:*', 'user:abc', '{"type":"x"}'], $v[0]);
        $this->assertSame(strlen($msg), $off);
        $v = RedisSubscriber::parse($msg . "+OK\r\n", $off);
        $this->assertSame('OK', $v[0]);
        $o = 0;
        $this->assertInstanceOf(RespError::class, RedisSubscriber::parse("-NOAUTH x\r\n", $o)[0]);
        $o = 0;
        $this->assertSame([['psubscribe', 'user:*', 1]], [RedisSubscriber::parse("*3\r\n\$10\r\npsubscribe\r\n\$6\r\nuser:*\r\n:1\r\n", $o)[0]]);
    }

    public function testLimitePorConexion(): void
    {
        $s = new ConnState();
        for ($i = 0; $i < 20; $i++) {
            $this->assertTrue($s->allow('global', 20, 10.0));
        }
        $this->assertFalse($s->allow('global', 20, 10.0));
    }

    public function testPoliticasDeRateLimit(): void
    {
        $this->assertSame([[5, 60], [20, 3600]], RateLimiter::parse('5/60, 20/3600'));
        $this->assertNull(RateLimiter::parse('cinco/60'));
        $this->assertNull(RateLimiter::parse('0/60'));
        $this->assertSame([[3, 3600]], RateLimiter::DEFAULTS['register']);
        $this->assertSame([[20, 10], [300, 3600]], RateLimiter::DEFAULTS['send']);
    }
}
