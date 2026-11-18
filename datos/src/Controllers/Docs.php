<?php
namespace App\Controllers;

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Exception\HttpNotFoundException;

/**
 * Swagger UI en /docs y el contrato en /docs/openapi.yaml (G-08). Los archivos de Swagger UI
 * vienen de swagger-ui-dist (versión fijada en el Dockerfile) y se sirven desde la propia imagen,
 * sin CDN. Con DOCS_ENABLED=false todas estas rutas responden 404.
 */
class Docs extends BaseController
{
    private const ASSETS = [
        'swagger-ui.css' => 'text/css; charset=utf-8',
        'swagger-ui-bundle.js' => 'application/javascript; charset=utf-8',
        'favicon-32x32.png' => 'image/png',
    ];

    private const CSP = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'";

    // GET /docs
    public function index(Request $request, Response $response)
    {
        $this->assertEnabled($request);
        $html = <<<'HTML'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <title>CR_Chat API v1</title>
  <link rel="icon" href="/docs/favicon-32x32.png">
  <link rel="stylesheet" href="/docs/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="/docs/swagger-ui-bundle.js"></script>
  <script src="/docs/init.js"></script>
</body>
</html>
HTML;
        $response->getBody()->write($html);
        return $response->withHeader('Content-Type', 'text/html; charset=utf-8')
            ->withHeader('Content-Security-Policy', self::CSP)
            ->withHeader('Cache-Control', 'no-cache');
    }

    // GET /docs/init.js
    public function init(Request $request, Response $response)
    {
        $this->assertEnabled($request);
        $response->getBody()->write("window.ui = SwaggerUIBundle({ url: '/docs/openapi.yaml', dom_id: '#swagger-ui', deepLinking: true, persistAuthorization: false });\n");
        return $response->withHeader('Content-Type', 'application/javascript; charset=utf-8')
            ->withHeader('Cache-Control', 'no-cache');
    }

    // GET /docs/openapi.yaml
    public function spec(Request $request, Response $response)
    {
        $this->assertEnabled($request);
        $path = $this->config()->openapiPath;
        if (!is_file($path)) {
            throw new HttpNotFoundException($request, 'Contrato no disponible.');
        }
        $response->getBody()->write((string) file_get_contents($path));
        return $response->withHeader('Content-Type', 'application/yaml; charset=utf-8')
            ->withHeader('Cache-Control', 'no-cache');
    }

    // GET /docs/{asset}
    public function asset(Request $request, Response $response, array $args)
    {
        $this->assertEnabled($request);
        $name = $args['asset'] ?? '';
        $file = $this->config()->swaggerDir . '/' . $name;
        if (!isset(self::ASSETS[$name]) || !is_file($file)) {
            throw new HttpNotFoundException($request, 'Recurso no encontrado.');
        }
        $response->getBody()->write((string) file_get_contents($file));
        return $response->withHeader('Content-Type', self::ASSETS[$name])
            ->withHeader('Cache-Control', 'public, max-age=86400');
    }

    private function assertEnabled(Request $request): void
    {
        if (!$this->config()->docsEnabled) {
            throw new HttpNotFoundException($request, 'Recurso no encontrado.');
        }
    }
}
