<?php

namespace App\Tests;

use App\Exceptions\DbException;
use App\Exceptions\HttpUnprocessableException;
use App\Handlers\JsonErrorRenderer;
use PHPUnit\Framework\TestCase;
use RuntimeException;
use Slim\Exception\HttpNotFoundException;
use Slim\Psr7\Factory\ServerRequestFactory;

final class ErrorsTest extends TestCase
{
    public static function mapeos(): array
    {
        return [
            ['CR401', null, 401, 'no-autenticado'],
            ['CR403', 'bloqueado', 403, 'bloqueado'],
            ['CR403', 'no-autor', 403, 'no-autor'],
            ['CR404', null, 404, 'no-encontrado'],
            ['CR409', 'client_id', 409, 'no-disponible'],
            ['CR422', 'cursor', 400, 'peticion-invalida'],
            ['CR422', 'edicion-expirada', 422, 'edicion-expirada'],
            ['CR422', 'alias', 422, 'validacion'],
        ];
    }

    #[\PHPUnit\Framework\Attributes\DataProvider('mapeos')]
    public function testSqlstateCrAHttp(string $state, ?string $hint, int $status, string $slug): void
    {
        $e = new DbException($state, $hint, 'mensaje de la BD');
        $this->assertSame($status, JsonErrorRenderer::status($e));
        $p = JsonErrorRenderer::problem($e, $status);
        $this->assertSame(JsonErrorRenderer::TYPE_BASE . $slug, $p['type']);
        $this->assertSame($status, $p['status']);
        if ($slug === 'validacion') {
            $this->assertSame('alias', $p['errors'][0]['field']);
        }
    }

    public function testErrorInternoSinDetalles(): void
    {
        $e = new RuntimeException('SQLSTATE[42501]: insufficient_privilege en /var/www/html/src/x.php');
        $p = JsonErrorRenderer::problem($e, JsonErrorRenderer::status($e), '/api/v1/me', 'rid');
        $this->assertSame(500, $p['status']);
        $this->assertSame('Error interno del servidor.', $p['detail']);
        $this->assertStringNotContainsString('SQLSTATE', json_encode($p));
        $this->assertSame(['type', 'title', 'status', 'detail', 'instance', 'request_id'], array_keys($p));
    }

    public function testValidacionConErrores(): void
    {
        $req = (new ServerRequestFactory())->createServerRequest('POST', '/api/v1/contacts');
        $e = new HttpUnprocessableException($req, null, null, [['field' => 'phone', 'detail' => 'E.164']]);
        $p = JsonErrorRenderer::problem($e, 422);
        $this->assertSame('Datos inválidos', $p['title']);
        $this->assertSame([['field' => 'phone', 'detail' => 'E.164']], $p['errors']);
    }

    public function testNotFoundDeSlimEnEspanol(): void
    {
        $req = (new ServerRequestFactory())->createServerRequest('GET', '/x');
        $p = JsonErrorRenderer::problem(new HttpNotFoundException($req), 404);
        $this->assertSame('Recurso no encontrado.', $p['detail']);
    }
}
