<?php
namespace App\Controllers;

use App\Services\ObjectStorage;
use App\Services\RedisConn;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;

class Health extends BaseController
{
    // GET /api/v1/health  (vida: no toca dependencias)
    public function health(Request $request, Response $response)
    {
        return $this->json($response, ['status' => 'ok']);
    }

    // GET /api/v1/ready  (PG escritura/lectura, Redis y MinIO; 503 si alguna falla; sin hosts ni versiones)
    public function ready(Request $request, Response $response)
    {
        $checks = [
            'db_write' => $this->db()->ping(false),
            'db_read' => $this->db()->ping(true),
            'redis' => $this->container->get(RedisConn::class)->ping(),
            'storage' => $this->container->get(ObjectStorage::class)->ping(),
        ];
        $ok = !in_array(false, $checks, true);
        return $this->json($response, [
            'status' => $ok ? 'ok' : 'fail',
            'checks' => array_map(fn($v) => $v ? 'ok' : 'fail', $checks),
        ], $ok ? 200 : 503);
    }
}
