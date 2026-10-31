<?php

namespace App\Support;

use Psr\Http\Message\ServerRequestInterface as Request;

/**
 * IP real del cliente. X-Forwarded-For solo se usa si la conexión viene de un proxy de confianza
 * (TRUSTED_PROXIES, CIDR separados por comas); se toma el salto más a la derecha que no sea de confianza.
 */
final class ClientIp
{
    public static function from(Request $request, array $trusted): string
    {
        $remote = (string) ($request->getServerParams()['REMOTE_ADDR'] ?? '0.0.0.0');
        if (!$trusted || !self::inAny($remote, $trusted)) {
            return $remote;
        }
        $hops = array_reverse(array_map('trim', explode(',', $request->getHeaderLine('X-Forwarded-For'))));
        foreach ($hops as $hop) {
            if (filter_var($hop, FILTER_VALIDATE_IP) && !self::inAny($hop, $trusted)) {
                return $hop;
            }
        }
        return $remote;
    }

    public static function inAny(string $ip, array $cidrs): bool
    {
        foreach ($cidrs as $cidr) {
            if (self::inCidr($ip, $cidr)) {
                return true;
            }
        }
        return false;
    }

    public static function inCidr(string $ip, string $cidr): bool
    {
        [$net, $bits] = str_contains($cidr, '/') ? explode('/', $cidr, 2) : [$cidr, null];
        $ipBin = @inet_pton($ip);
        $netBin = @inet_pton($net);
        if ($ipBin === false || $netBin === false || strlen($ipBin) !== strlen($netBin)) {
            return false;
        }
        $bits = $bits === null ? strlen($ipBin) * 8 : (int) $bits;
        $bytes = intdiv($bits, 8);
        if (substr($ipBin, 0, $bytes) !== substr($netBin, 0, $bytes)) {
            return false;
        }
        $rest = $bits % 8;
        if ($rest === 0) {
            return true;
        }
        $mask = (0xff << (8 - $rest)) & 0xff;
        return (ord($ipBin[$bytes]) & $mask) === (ord($netBin[$bytes]) & $mask);
    }
}
