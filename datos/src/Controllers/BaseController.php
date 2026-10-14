<?php
namespace App\Controllers;

use PDO;
use PDOStatement;
use Psr\Container\ContainerInterface;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpBadRequestException;
use Slim\Exception\HttpNotFoundException;

abstract class BaseController
{
    protected ContainerInterface $container;

    public function __construct(ContainerInterface $c)
    {
        $this->container = $c;
    }

    protected function db(): PDO
    {
        return $this->container->get('data_base');
    }

    /**
     * Ejecuta el procedimiento sp_<name> en MySQL o la función fn_<name> en PostgreSQL.
     * $pgName permite indicar el nombre en PostgreSQL cuando difiere del de MySQL.
     */
    protected function procedure(string $name, array $params, ?string $pgName = null): PDOStatement
    {
        $con = $this->db();
        $placeholders = implode(', ', array_map(fn($p) => ":$p", array_keys($params)));

        $sql = $con->getAttribute(PDO::ATTR_DRIVER_NAME) === 'pgsql'
            ? 'SELECT * FROM fn_' . ($pgName ?? $name) . "($placeholders)"
            : "CALL sp_$name($placeholders)";

        $query = $con->prepare($sql);
        foreach ($params as $param => $value) {
            $type = match (true) {
                is_int($value) => PDO::PARAM_INT,
                is_null($value) => PDO::PARAM_NULL,
                default => PDO::PARAM_STR,
            };
            $query->bindValue(":$param", $value, $type);
        }
        $query->execute();

        return $query;
    }

    // Devuelve el valor de la primera columna (los SP devuelven códigos como 1, 0, -1)
    protected function scalar(string $name, array $params, ?string $pgName = null): int
    {
        $query = $this->procedure($name, $params, $pgName);
        $value = $query->fetchColumn();
        $query->closeCursor();
        return (int) $value;
    }

    protected function row(string $name, array $params, ?string $pgName = null): ?array
    {
        $query = $this->procedure($name, $params, $pgName);
        $row = $query->fetch(PDO::FETCH_ASSOC);
        $query->closeCursor();
        return $row ?: null;
    }

    protected function rows(string $name, array $params, ?string $pgName = null): array
    {
        $query = $this->procedure($name, $params, $pgName);
        $rows = $query->fetchAll(PDO::FETCH_ASSOC);
        $query->closeCursor();
        return $rows;
    }

    /**
     * Lee el cuerpo JSON. Lanza 400 si no es JSON o falta un campo obligatorio.
     * Los campos opcionales ausentes se devuelven como null.
     */
    protected function input(Request $request, array $required, array $optional = []): array
    {
        $body = $request->getParsedBody();
        if (!is_array($body)) {
            throw new HttpBadRequestException($request, 'El cuerpo de la petición debe ser un JSON válido.');
        }

        $missing = array_filter($required, fn($f) => !isset($body[$f]) || $body[$f] === '');
        if ($missing) {
            throw new HttpBadRequestException($request, 'Faltan campos obligatorios: ' . implode(', ', $missing) . '.');
        }

        $data = [];
        foreach (array_merge($required, $optional) as $field) {
            $value = $body[$field] ?? null;
            if (!is_null($value) && !is_scalar($value)) {
                throw new HttpBadRequestException($request, "El campo $field tiene un formato inválido.");
            }
            $data[$field] = $value;
        }
        return $data;
    }

    protected function intField(Request $request, mixed $value, string $field): int
    {
        if (filter_var($value, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]) === false) {
            throw new HttpBadRequestException($request, "El campo $field debe ser un entero positivo.");
        }
        return (int) $value;
    }

    // Id del usuario autenticado (lo coloca JwtMiddleware)
    protected function userId(Request $request): int
    {
        return (int) $request->getAttribute('id_usr');
    }

    /**
     * Verifica que el recurso exista y pertenezca al usuario. Responde 404 en ambos casos
     * para no revelar la existencia de recursos ajenos.
     */
    protected function assertOwnership(Request $request, string $sql, array $params, string $resource): void
    {
        $query = $this->db()->prepare($sql);
        $query->execute($params);
        if ($query->fetchColumn() === false) {
            throw new HttpNotFoundException($request, "$resource no encontrado.");
        }
    }

    protected function json(Response $response, mixed $data, int $status = 200): Response
    {
        $response->getBody()->write(json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
        return $response
            ->withHeader('Content-Type', 'application/json')
            ->withStatus($status);
    }

    protected function noContent(Response $response): Response
    {
        return $response->withStatus(204);
    }
}
