<?php

use App\Services\Db;
use App\Support\Config;
use Psr\Container\ContainerInterface;

/** @var DI\Container $container */

// PostgreSQL es la única fuente de verdad. Sin failover entre motores ni /tmp/preferred_db.txt:
// Db abre (de forma perezosa) dos PDO, escritura DB_RW_* (haproxy:5000, app_rw) y
// lectura DB_RO_* (haproxy:5001, app_ro). La alta disponibilidad la dan Patroni + HAProxy.
$container->set(Db::class, fn(ContainerInterface $c) => new Db(
    $c->get(Config::class),
    PHP_SAPI === 'cli' ? 'cr_chat_ws' : 'cr_chat_api'
));
