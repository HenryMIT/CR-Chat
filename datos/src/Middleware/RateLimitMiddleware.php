<?php

namespace App\Middleware;

use App\Exceptions\HttpTooManyRequestsException;
use App\Services\RateLimiter;
use App\Support\ClientIp;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface as Handler;

/**
 * Aplica una o varias políticas de RateLimiter a una ruta. Sujeto:
 *   ip          -> IP real del cliente (X-Forwarded-For solo desde TRUSTED_PROXIES)
 *   user        -> uuid del usuario autenticado (requiere JwtMiddleware antes)
 *   ip+identifier -> IP + identificador del cuerpo (login / reactivate), en hash
 * Añade RateLimit-Policy y RateLimit a la respuesta; al exceder responde 429 + Retry-After.
 */
class RateLimitMiddleware implements MiddlewareInterface
{
    /** Encabezados de la petición en curso: HttpErrorHandler los copia también a las respuestas de error. */
    public static array $currentHeaders = [];

    /** @param list<array{0:string,1:string}> $policies [política, sujeto] */
    public function __construct(private RateLimiter $limiter, private array $policies, private array $trustedProxies = [])
    {
    }

    public function process(Request $request, Handler $handler): Response
    {
        $first = null;
        foreach ($this->policies as [$policy, $kind]) {
            $result = $this->limiter->hit($policy, $this->subject($request, $kind));
            $first ??= $result;
            if (!$result['allowed']) {
                throw new HttpTooManyRequestsException(
                    $request,
                    "Has superado el límite de peticiones. Reintenta en {$result['retry_after']} segundos.",
                    null,
                    [],
                    array_filter([
                        'Retry-After' => (string) $result['retry_after'],
                        'RateLimit-Policy' => $result['policy_header'],
                        'RateLimit' => $result['ratelimit_header'],
                    ])
                );
            }
        }

        if ($first !== null) {
            self::$currentHeaders = array_filter([
                'RateLimit-Policy' => $first['policy_header'],
                'RateLimit' => $first['ratelimit_header'],
            ]);
        }
        $response = $handler->handle($request);
        foreach (self::$currentHeaders as $name => $value) {
            $response = $response->withHeader($name, $value);
        }
        return $response;
    }

    private function subject(Request $request, string $kind): string
    {
        $ip = ClientIp::from($request, $this->trustedProxies);
        return match ($kind) {
            'user' => 'u:' . ($request->getAttribute('user_id') ?? $ip),
            'ip+identifier' => 'i:' . $ip . '|' . self::identifier($request),
            default => 'ip:' . $ip,
        };
    }

    private static function identifier(Request $request): string
    {
        $body = $request->getParsedBody();
        $id = is_array($body) && is_string($body['identifier'] ?? null) ? $body['identifier'] : '';
        return mb_strtolower(trim($id));
    }
}
