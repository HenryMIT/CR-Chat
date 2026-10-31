<?php

namespace App\Services;

use App\Support\Env;
use App\Support\Log;
use Redis;

/**
 * Rate limiting en Redis con ventana deslizante aproximada (contador de la ventana actual +
 * fracción de la anterior), atómico con un script Lua. Claves rl:{política}:{sujeto}:{ventana}:{n}.
 * Límites de docs/requerimientos-api.md §6; cada política se puede sobrescribir con
 * RL_<POLITICA> = "límite/segundos[,límite/segundos]" (p. ej. RL_REGISTER=3/3600).
 * Si Redis no responde se permite la petición (fail-open) y se registra un aviso.
 */
class RateLimiter
{
    public const DEFAULTS = [
        'login' => [[5, 60], [20, 3600]],      // IP + identificador
        'login-ip' => [[50, 3600]],             // IP sola
        'register' => [[3, 3600]],
        'reactivate' => [[5, 900]],
        'refresh' => [[30, 60]],
        'refresh-invalid' => [[60, 3600]],
        'sensitive' => [[5, 900]],
        'contact-add' => [[30, 3600], [200, 86400]],
        'profile-read' => [[60, 60]],
        'send' => [[20, 10], [300, 3600]],
        'edit' => [[30, 60]],
        'upload' => [[30, 3600]],
        'default-auth' => [[300, 60]],
        'default-anon' => [[60, 60]],
    ];

    private const LUA = <<<'LUA'
local now = tonumber(ARGV[1])
local n = (#ARGV - 1) / 2
local keys = {}
local blocked = false
local retry = 0
local best = 1
local bestRemaining = nil
local bestReset = 0
for i = 1, n do
  local limit = tonumber(ARGV[2 * i])
  local win = tonumber(ARGV[2 * i + 1])
  local cur = math.floor(now / win)
  local ck = KEYS[1] .. ':' .. win .. ':' .. cur
  local pk = KEYS[1] .. ':' .. win .. ':' .. (cur - 1)
  local c = tonumber(redis.call('GET', ck) or '0')
  local p = tonumber(redis.call('GET', pk) or '0')
  local elapsed = (now - cur * win) / win
  local est = p * (1 - elapsed) + c
  local reset = (cur + 1) * win - now
  if est + 1 > limit then
    blocked = true
    local r
    if c + 1 > limit then
      r = reset + win * (1 - (limit - 1) / c)
    else
      r = win * ((p * (1 - elapsed) + c + 1 - limit) / p)
    end
    if r > retry then retry = r end
  end
  local remaining = math.floor(limit - est - 1)
  if remaining < 0 then remaining = 0 end
  if bestRemaining == nil or remaining < bestRemaining then
    bestRemaining = remaining
    best = i
    bestReset = reset
  end
  keys[i] = {ck, win}
end
if blocked then
  return {0, math.ceil(retry), best, 0, math.ceil(bestReset)}
end
for i = 1, n do
  redis.call('INCR', keys[i][1])
  redis.call('EXPIRE', keys[i][1], keys[i][2] * 2 + 1)
end
return {1, 0, best, bestRemaining, math.ceil(bestReset)}
LUA;

    private array $policies;

    public function __construct(private readonly RedisConn $redis, private readonly bool $enabled = true)
    {
        $this->policies = self::DEFAULTS;
        foreach (array_keys(self::DEFAULTS) as $name) {
            $override = Env::get('RL_' . strtoupper(str_replace('-', '_', $name)));
            if ($override !== null && ($rules = self::parse($override)) !== null) {
                $this->policies[$name] = $rules;
            }
        }
    }

    public static function parse(string $spec): ?array
    {
        $rules = [];
        foreach (explode(',', $spec) as $part) {
            if (preg_match('/^\s*(\d+)\s*\/\s*(\d+)\s*$/', $part, $m) !== 1 || (int) $m[1] < 1 || (int) $m[2] < 1) {
                return null;
            }
            $rules[] = [(int) $m[1], (int) $m[2]];
        }
        return $rules ?: null;
    }

    public function rules(string $policy): array
    {
        return $this->policies[$policy] ?? throw new \InvalidArgumentException("Política desconocida: $policy");
    }

    /**
     * Consume una unidad. Devuelve ['allowed', 'retry_after', 'policy_header', 'ratelimit_header'].
     */
    public function hit(string $policy, string $subject): array
    {
        $rules = $this->rules($policy);
        $policyHeader = implode(', ', array_map(
            fn($r, $i) => sprintf('"%s";q=%d;w=%d', $i === 0 ? $policy : "$policy-{$r[1]}", $r[0], $r[1]),
            $rules,
            array_keys($rules)
        ));
        $result = ['allowed' => true, 'retry_after' => 0, 'policy_header' => $policyHeader, 'ratelimit_header' => null];
        if (!$this->enabled) {
            return $result;
        }
        $argv = [sprintf('%.3F', microtime(true))];
        foreach ($rules as [$limit, $window]) {
            $argv[] = $limit;
            $argv[] = $window;
        }
        $key = 'rl:' . $policy . ':' . hash('sha256', $subject);
        $res = $this->redis->run(fn(Redis $r) => $r->eval(self::LUA, array_merge([$key], $argv), 1));
        if (!is_array($res)) {
            if ($this->redis->get() === null) {
                Log::warning('rate_limit_fail_open', ['policy' => $policy]);
            }
            return $result;
        }
        [$allowed, $retry, $best, $remaining, $reset] = array_map('intval', $res);
        $name = $best === 1 ? $policy : "$policy-" . $rules[$best - 1][1];
        $result['allowed'] = $allowed === 1;
        $result['retry_after'] = max(1, $retry);
        $result['ratelimit_header'] = sprintf('"%s";r=%d;t=%d', $name, $remaining, max(0, $reset));
        return $result;
    }
}
