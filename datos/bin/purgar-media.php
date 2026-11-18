<?php

// Ejecución manual del job de huérfanos de media:  php bin/purgar-media.php [antigüedad]
// (por defecto '24 hours'; lo ejecuta cada hora el worker cr-chat-tareas de ws/server.php)

use App\Services\Db;
use App\Services\MediaPurger;
use App\Services\ObjectStorage;

$container = require __DIR__ . '/../src/app/bootstrap.php';
$age = $argv[1] ?? '24 hours';
$result = (new MediaPurger($container->get(Db::class), $container->get(ObjectStorage::class)))->run($age);
echo json_encode($result, JSON_UNESCAPED_UNICODE), PHP_EOL;
