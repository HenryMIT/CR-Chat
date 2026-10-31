<?php

// Contenedor compartido por la API (public/index.php), el servidor WS (ws/server.php) y los
// scripts de bin/. Devuelve un PHP-DI Container con la configuración y los servicios.

use DI\Container;

require_once __DIR__ . '/../../vendor/autoload.php';

// El .env es opcional: en Docker las variables pueden llegar por `environment`/`env_file`.
// createImmutable no sobrescribe variables que ya existan en el entorno.
Dotenv\Dotenv::createImmutable(dirname(__DIR__, 2))->safeLoad();

$container = new Container();
require __DIR__ . '/config.php';
require __DIR__ . '/conexion.php';

return $container;
