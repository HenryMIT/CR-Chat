<?php

namespace App\Services;

use App\Exceptions\DatabaseUnavailableException;
use App\Exceptions\DbException;
use App\Support\Config;
use App\Support\Log;
use InvalidArgumentException;
use PDO;
use PDOException;

/**
 * Acceso a PostgreSQL solo mediante funciones `fn_*` (docs/contratos/db-funciones.md).
 * Dos conexiones perezosas: escritura (DB_RW_*, haproxy:5000, app_rw) y lectura
 * (DB_RO_*, haproxy:5001, app_ro). Sin failover entre motores: PostgreSQL es la única fuente de verdad.
 * Todas las llamadas usan sentencias preparadas y notación con nombre (p_x => :p_x).
 */
class Db
{
    private ?PDO $rw = null;
    private ?PDO $ro = null;

    public function __construct(private readonly Config $config, private readonly string $appName = 'cr_chat_api')
    {
    }

    /** Ejecuta SELECT * FROM fn(...) y devuelve todas las filas. */
    public function call(string $function, array $params = [], bool $readOnly = false): array
    {
        if (preg_match('/^fn_[a-z0-9_]+$/', $function) !== 1) {
            throw new InvalidArgumentException("Nombre de función inválido: $function");
        }
        $args = [];
        foreach (array_keys($params) as $name) {
            if (preg_match('/^p_[a-z0-9_]+$/', $name) !== 1) {
                throw new InvalidArgumentException("Parámetro inválido: $name");
            }
            $args[] = "$name => :$name";
        }
        $sql = "SELECT * FROM $function(" . implode(', ', $args) . ')';

        $pdo = $this->pdo($readOnly);
        try {
            $stmt = $pdo->prepare($sql);
            foreach ($params as $name => $value) {
                $this->bind($stmt, ":$name", $value);
            }
            $stmt->execute();
            $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
            $stmt->closeCursor();
        } catch (PDOException $e) {
            throw $this->translate($e, $readOnly);
        }
        foreach ($rows as &$row) {
            foreach ($row as $k => $v) {
                if (is_resource($v)) {
                    $row[$k] = stream_get_contents($v);
                }
            }
        }
        return $rows;
    }

    public function one(string $function, array $params = [], bool $readOnly = false): ?array
    {
        return $this->call($function, $params, $readOnly)[0] ?? null;
    }

    /** Primera columna de la primera fila (funciones que devuelven un escalar). */
    public function value(string $function, array $params = [], bool $readOnly = false): mixed
    {
        $row = $this->one($function, $params, $readOnly);
        return $row === null ? null : reset($row);
    }

    public function ping(bool $readOnly): bool
    {
        try {
            return $this->pdo($readOnly)->query('SELECT 1')->fetchColumn() == 1;
        } catch (\Throwable) {
            $this->reset();
            return false;
        }
    }

    public function reset(): void
    {
        $this->rw = null;
        $this->ro = null;
    }

    public function pdo(bool $readOnly): PDO
    {
        $slot = $readOnly ? 'ro' : 'rw';
        if ($this->$slot !== null) {
            return $this->$slot;
        }
        $c = $readOnly ? $this->config->dbRo : $this->config->dbRw;
        $dsn = sprintf(
            'pgsql:host=%s;port=%d;dbname=%s;connect_timeout=2;application_name=%s;options=-cTimeZone=UTC',
            $c['host'], $c['port'], $this->config->dbName, $this->appName
        );
        try {
            $pdo = new PDO($dsn, $c['user'], $c['pass'], [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
                PDO::ATTR_TIMEOUT => 2,
            ]);
        } catch (PDOException $e) {
            Log::error('db_connect_failed', ['pool' => $slot, 'sqlstate' => $e->getCode()]);
            throw new DatabaseUnavailableException("Sin conexión a PostgreSQL ($slot).", 0, $e);
        }
        return $this->$slot = $pdo;
    }

    private function bind(\PDOStatement $stmt, string $name, mixed $value): void
    {
        match (true) {
            $value === null => $stmt->bindValue($name, null, PDO::PARAM_NULL),
            is_bool($value) => $stmt->bindValue($name, $value, PDO::PARAM_BOOL),
            is_int($value) => $stmt->bindValue($name, $value, PDO::PARAM_INT),
            $value instanceof Bytea => $stmt->bindValue($name, $value->bytes, PDO::PARAM_LOB),
            is_array($value) => $stmt->bindValue($name, self::pgArray($value), PDO::PARAM_STR),
            default => $stmt->bindValue($name, (string) $value, PDO::PARAM_STR),
        };
    }

    /** Arreglo de valores simples (uuid) a literal '{a,b}'. */
    private static function pgArray(array $values): string
    {
        $items = array_map(function ($v) {
            $v = (string) $v;
            if (preg_match('/^[0-9A-Za-z_-]+$/', $v) !== 1) {
                throw new InvalidArgumentException('Elemento de arreglo inválido.');
            }
            return $v;
        }, array_values($values));
        return '{' . implode(',', $items) . '}';
    }

    private function translate(PDOException $e, bool $readOnly): \Throwable
    {
        $state = (string) ($e->errorInfo[0] ?? $e->getCode());
        $text = (string) ($e->errorInfo[2] ?? $e->getMessage());
        if (str_starts_with($state, 'CR')) {
            return new DbException(
                $state,
                self::field($text, 'HINT'),
                self::message($text),
                self::field($text, 'DETAIL'),
                $e
            );
        }
        // Conexión perdida (failover de Patroni, reinicio): se reconecta en la siguiente llamada
        if (str_starts_with($state, '08') || in_array($state, ['57P01', '57P02', '57P03', 'HY000'], true)) {
            $this->reset();
            Log::error('db_connection_lost', ['pool' => $readOnly ? 'ro' : 'rw', 'sqlstate' => $state]);
            return new DatabaseUnavailableException('Conexión con PostgreSQL perdida.', 0, $e);
        }
        // 42501 / 25006 = rol equivocado: es un error de programación (500 + alerta en el log)
        Log::error('db_error', ['sqlstate' => $state, 'pool' => $readOnly ? 'ro' : 'rw', 'message' => self::message($text)]);
        return $e;
    }

    private static function field(string $text, string $name): ?string
    {
        return preg_match('/^' . $name . ':\s+(.+)$/m', $text, $m) === 1 ? trim($m[1]) : null;
    }

    private static function message(string $text): string
    {
        $line = strtok($text, "\n") ?: $text;
        return trim(preg_replace('/^(SQLSTATE\[[^\]]*\]:?\s*[^:]*:\s*\d*\s*)?(ERROR:\s*)?/', '', $line) ?? $line);
    }
}
