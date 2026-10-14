<?php

use App\Handlers\HttpErrorHandler;
use App\Handlers\JsonErrorRenderer;
use App\Middleware\CorsMiddleware;
use DI\Container;
use Slim\Factory\AppFactory;

require __DIR__ . '/../../vendor/autoload.php';

$dotenv = Dotenv\Dotenv::createImmutable('/var/www/html');
$dotenv->load();
$dotenv->required(['key', 'key_decryption', 'db'])->notEmpty();

$container = new Container();
AppFactory::setContainer($container);
$app = AppFactory::create();

require 'config.php';
require 'conexion.php';

$app->addBodyParsingMiddleware();
$app->addRoutingMiddleware();

// Todos los errores (404, 405, 401, 500...) se devuelven como JSON
$debug = $container->get('debug');
$errorHandler = new HttpErrorHandler($app->getCallableResolver(), $app->getResponseFactory());
$errorHandler->forceContentType('application/json');
$errorHandler->registerErrorRenderer('application/json', JsonErrorRenderer::class);
$errorMiddleware = $app->addErrorMiddleware($debug, true, $debug);
$errorMiddleware->setDefaultErrorHandler($errorHandler);

// CORS va al final para que también envuelva las respuestas de error
$app->add(new CorsMiddleware($container->get('cors_origin'), $app->getResponseFactory()));

require 'routes.php';

$app->run();
