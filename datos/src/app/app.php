<?php

use App\Handlers\HttpErrorHandler;
use App\Handlers\JsonErrorRenderer;
use App\Middleware\CorsMiddleware;
use App\Middleware\RequestIdMiddleware;
use App\Middleware\SecurityHeadersMiddleware;
use Slim\Factory\AppFactory;

/** @var DI\Container $container */
$container = require __DIR__ . '/bootstrap.php';

AppFactory::setContainer($container);
$app = AppFactory::create();

$app->addBodyParsingMiddleware();
$app->addRoutingMiddleware();

// Todos los errores (404, 405, 401, 429, 500...) se devuelven como application/problem+json.
// APP_DEBUG nunca añade trazas a la respuesta (solo al log).
$debug = $container->get('debug');
$errorHandler = new HttpErrorHandler($app->getCallableResolver(), $app->getResponseFactory());
$errorHandler->forceContentType('application/json');
$errorHandler->registerErrorRenderer('application/json', JsonErrorRenderer::class);
$errorMiddleware = $app->addErrorMiddleware(false, true, $debug);
$errorMiddleware->setDefaultErrorHandler($errorHandler);

// Fuera del manejador de errores para que también envuelvan las respuestas de error
$app->add(new SecurityHeadersMiddleware());
$app->add(new CorsMiddleware($container->get('cors_origins'), $app->getResponseFactory()));
$app->add(new RequestIdMiddleware());

require __DIR__ . '/routes.php';

$app->run();
