<?php
    $container->set('config_bd', function(){
        return(object)[
            "primary" => $_ENV["db_primary"] ?? 'mysql',
            "hostPG" => $_ENV["hostPG"],
            "portPG" => $_ENV["portPG"],
            "hostMYSQL" => $_ENV["hostMYSQL"],
            "portMYSQL" => $_ENV["portMYSQL"],
            "db" => $_ENV["db"],
            "usrPG" => $_ENV["usrPG"],
            "usrMYSQL" => $_ENV["usrMYSQL"],
            "passPG" => $_ENV["passPG"],
            "passMYSQL" => $_ENV["passMYSQL"]
        ];
    });

    $container->set('key', function(){
        return $_ENV['key'];
    });

    $container->set('key_decript', function(){
        return $_ENV['key_decryption'];
    });

    // Duración de los tokens en segundos
    $container->set('jwt_ttl', function(){
        return [
            'access' => (int) ($_ENV['jwt_access_ttl'] ?? 900),
            'refresh' => (int) ($_ENV['jwt_refresh_ttl'] ?? 604800)
        ];
    });

    $container->set('cors_origin', function(){
        return $_ENV['cors_origin'] ?? '*';
    });

    $container->set('debug', function(){
        return filter_var($_ENV['app_debug'] ?? false, FILTER_VALIDATE_BOOLEAN);
    });
