<?php
namespace App\Controllers;

use App\Exceptions\HttpUnprocessableException;
use App\Services\Db;
use App\Services\EventPublisher;
use App\Services\Presenter;
use App\Support\Config;
use App\Support\Cursor;
use App\Support\Uuid;
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

    protected function db(): Db
    {
        return $this->container->get(Db::class);
    }

    protected function config(): Config
    {
        return $this->container->get(Config::class);
    }

    protected function presenter(): Presenter
    {
        return $this->container->get(Presenter::class);
    }

    protected function events(): EventPublisher
    {
        return $this->container->get(EventPublisher::class);
    }

    /**
     * Ejecuta la función fn_<name> de PostgreSQL y devuelve sus filas.
     * $readOnly = true usa el pool de lectura (app_ro, haproxy:5001); para releer lo recién
     * escrito se usa siempre el de escritura. Los errores CRxxx llegan como DbException y el
     * manejador global los traduce a RFC 9457.
     */
    protected function callProcedure(string $name, array $params, bool $readOnly = false): array
    {
        return $this->db()->call('fn_' . $name, $params, $readOnly);
    }

    protected function callOne(string $name, array $params, bool $readOnly = false): ?array
    {
        return $this->db()->one('fn_' . $name, $params, $readOnly);
    }

    protected function callValue(string $name, array $params, bool $readOnly = false): mixed
    {
        return $this->db()->value('fn_' . $name, $params, $readOnly);
    }

    /**
     * Lee el cuerpo JSON (objeto). 400 si no es JSON o trae campos desconocidos
     * (additionalProperties: false); 422 si falta un campo obligatorio o un valor no es escalar.
     * Los campos opcionales ausentes no aparecen en el resultado (array_key_exists distingue null).
     */
    protected function input(Request $request, array $required, array $optional = []): array
    {
        $body = $request->getParsedBody();
        if (!is_array($body) || (array_is_list($body) && $body !== [])) {
            throw new HttpBadRequestException($request, 'El cuerpo de la petición debe ser un objeto JSON válido.');
        }

        $unknown = array_diff(array_map('strval', array_keys($body)), $required, $optional);
        if ($unknown) {
            throw new HttpBadRequestException($request, 'Campos no permitidos: ' . implode(', ', $unknown) . '.');
        }

        $errors = [];
        foreach ($required as $field) {
            if (!array_key_exists($field, $body)) {
                $errors[] = ['field' => $field, 'detail' => 'Es obligatorio.'];
            }
        }
        foreach ($body as $field => $value) {
            if (!is_null($value) && !is_scalar($value)) {
                $errors[] = ['field' => (string) $field, 'detail' => 'Tiene un tipo inválido.'];
            }
        }
        if ($errors) {
            throw new HttpUnprocessableException($request, null, null, $errors);
        }
        return $body;
    }

    /** Lanza 422 con la lista acumulada de errores de campo, si hay alguno. */
    protected function failIf(Request $request, array $errors): void
    {
        if ($errors) {
            throw new HttpUnprocessableException($request, null, null, array_values($errors));
        }
    }

    /** Id de la ruta: un UUID mal formado responde 404 (igual que uno inexistente o ajeno). */
    protected function uuidArg(Request $request, array $args, string $name, string $resource = 'Recurso'): string
    {
        $value = $args[$name] ?? null;
        if (!Uuid::isValid($value)) {
            throw new HttpNotFoundException($request, "$resource no encontrado.");
        }
        return strtolower($value);
    }

    protected function limit(Request $request): int
    {
        $raw = $request->getQueryParams()['limit'] ?? null;
        if ($raw === null) {
            return 50;
        }
        $limit = filter_var($raw, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1, 'max_range' => 100]]);
        if ($limit === false) {
            throw new HttpBadRequestException($request, 'limit debe ser un entero entre 1 y 100.');
        }
        return $limit;
    }

    /** Cursor de lista [clave, id] o null si no se envió; 400 si es inválido. */
    protected function pairCursor(Request $request, string $param = 'cursor'): ?array
    {
        $raw = $request->getQueryParams()[$param] ?? null;
        if ($raw === null || $raw === '') {
            return null;
        }
        $pair = is_string($raw) && strlen($raw) <= 200 ? Cursor::decodePair($raw) : null;
        if ($pair === null) {
            throw new HttpBadRequestException($request, 'El cursor no es válido.');
        }
        return $pair;
    }

    /**
     * Verifica una media antes de referenciarla (avatar o adjunto): debe ser propia, del propósito
     * correcto y el objeto real en MinIO (HEAD) debe coincidir en tamaño y tipo MIME con lo
     * declarado en POST /uploads. Cualquier fallo es un 422 sobre $field.
     */
    protected function verifyMedia(Request $request, mixed $mediaId, string $purpose, string $field): string
    {
        $invalid = fn(string $detail) => new HttpUnprocessableException($request, null, null, [['field' => $field, 'detail' => $detail]]);
        if (!Uuid::isValid($mediaId)) {
            throw $invalid('Debe ser un UUID.');
        }
        try {
            $media = $this->callOne('obtener_media', ['p_usuario' => $this->userId($request), 'p_media' => strtolower($mediaId)]);
        } catch (\App\Exceptions\DbException $e) {
            if ($e->sqlState === 'CR404') {
                throw $invalid('Archivo no encontrado.');
            }
            throw $e;
        }
        if ($media['proposito'] !== $purpose || $media['estado'] === 'borrado') {
            throw $invalid('El archivo no se puede usar aquí.');
        }
        if ($media['estado'] === 'pendiente') {
            $head = $this->container->get(\App\Services\ObjectStorage::class)->head($media['bucket'], $media['clave_objeto']);
            if ($head === null) {
                throw $invalid('El archivo aún no se ha subido.');
            }
            if ($head['size'] !== (int) $media['tamano_bytes'] || $head['type'] !== $media['mime']) {
                throw $invalid('El archivo subido no coincide con el tamaño o tipo declarados.');
            }
        }
        return $media['id'];
    }

    // Id del usuario autenticado (uuid público = sub del JWT; lo coloca JwtMiddleware)
    protected function userId(Request $request): string
    {
        return (string) $request->getAttribute('user_id');
    }

    // Sesión del access token (sid)
    protected function sessionId(Request $request): string
    {
        return (string) $request->getAttribute('session_id');
    }

    protected function json(Response $response, mixed $data, int $status = 200): Response
    {
        $response->getBody()->write(json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
        return $response
            ->withHeader('Content-Type', 'application/json')
            ->withStatus($status);
    }

    protected function created(Response $response, mixed $data, string $location): Response
    {
        return $this->json($response, $data, 201)->withHeader('Location', $location);
    }

    protected function noContent(Response $response): Response
    {
        return $response->withStatus(204);
    }
}
