<?php
namespace App\Controllers;

use App\Middleware\JwtMiddleware;
use Slim\Routing\RouteCollectorProxy;

$app->group('/api', function (RouteCollectorProxy $api) use ($container) {

    // Rutas públicas
    $api->group('/auth', function (RouteCollectorProxy $auth) {
        $auth->post('/register', Auth::class . ':register');
        $auth->post('/login', Auth::class . ':starts');
        $auth->post('/refresh', Auth::class . ':refresh');
        $auth->post('/reactivate', Usr::class . ':reactiveUser');
    });

    // Rutas que requieren access token
    $api->group('', function (RouteCollectorProxy $private) {

        $private->post('/auth/logout', Auth::class . ':close');

        //Datos de usuario
        $private->group('/usr', function (RouteCollectorProxy $endpoint) {
            $endpoint->get('/profile', Usr::class . ':loadOwnProfile');
            $endpoint->get('/profile/{id_usr:[0-9]+}', Usr::class . ':loadProfile');
            $endpoint->put('/update', Usr::class . ':update_User');
            $endpoint->delete('/delete', Usr::class . ':deletedUser');
        });

        //Datos de contactos
        $private->group('/contact', function (RouteCollectorProxy $endpoint) {
            $endpoint->post('/create', Contact::class . ':createContact');
            $endpoint->get('/load/{lim:[0-9]+}/{pag:[0-9]+}', Contact::class . ':loadContact');
            $endpoint->put('/update', Contact::class . ':updateContact');
            $endpoint->delete('/delete/{id_contact:[0-9]+}', Contact::class . ':deleteContact');
        });

        //Datos de Chats
        $private->group('/chat', function (RouteCollectorProxy $endpoint) {
            $endpoint->post('/create', Chat::class . ':createChat');
            $endpoint->get('/load', Chat::class . ':loadChat');
        });

        //Datos de mensajes
        $private->group('/message', function (RouteCollectorProxy $endpoint) {
            $endpoint->post('/send', Message::class . ':sendMessage');
            $endpoint->get('/load/{id_chat:[0-9]+}', Message::class . ':loadMessage');
            $endpoint->put('/edit', Message::class . ':editMessage');
            $endpoint->delete('/delete/{id_message:[0-9]+}', Message::class . ':deleteMessage');
        });

    })->add(new JwtMiddleware($container->get('key')));
});
