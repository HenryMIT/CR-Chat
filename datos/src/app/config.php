<?php

use App\Services\EventPublisher;
use App\Services\MessageCrypto;
use App\Services\ObjectStorage;
use App\Services\Presenter;
use App\Services\RateLimiter;
use App\Services\RedisConn;
use App\Services\SessionGuard;
use App\Services\TokenService;
use App\Support\Config;
use Psr\Container\ContainerInterface;

/** @var DI\Container $container */

// Configuración tipada (falla al arrancar si falta un secreto o es inseguro)
$container->set(Config::class, fn() => new Config());

$container->set('debug', fn(ContainerInterface $c) => $c->get(Config::class)->debug);
$container->set('cors_origins', fn(ContainerInterface $c) => $c->get(Config::class)->corsOrigins);

$container->set(RedisConn::class, fn(ContainerInterface $c) => new RedisConn($c->get(Config::class)));
$container->set(RateLimiter::class, fn(ContainerInterface $c) => new RateLimiter(
    $c->get(RedisConn::class),
    $c->get(Config::class)->rateLimitEnabled
));
$container->set(TokenService::class, fn(ContainerInterface $c) => new TokenService($c->get(Config::class)));
$container->set(MessageCrypto::class, fn(ContainerInterface $c) => new MessageCrypto($c->get(Config::class)));
$container->set(ObjectStorage::class, fn(ContainerInterface $c) => new ObjectStorage($c->get(Config::class)));
$container->set(EventPublisher::class, fn(ContainerInterface $c) => new EventPublisher($c->get(RedisConn::class)));
$container->set(Presenter::class, fn(ContainerInterface $c) => new Presenter(
    $c->get(ObjectStorage::class),
    $c->get(MessageCrypto::class),
    $c->get(Config::class)
));
$container->set(SessionGuard::class, fn(ContainerInterface $c) => new SessionGuard(
    $c->get(App\Services\Db::class),
    $c->get(RedisConn::class),
    $c->get(Config::class)
));
