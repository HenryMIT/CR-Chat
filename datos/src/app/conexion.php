<?php

use App\Exceptions\DatabaseUnavailableException;
use Psr\Container\ContainerInterface;

define('PREF_FILE', '/tmp/preferred_db.txt');
define('PREF_TTL', 300); // segundos que se recuerda el motor que respondió

function getPreferredDB()
{
    if (file_exists(PREF_FILE)) {
        $data = json_decode(file_get_contents(PREF_FILE), true);
        if ($data && ($data['time'] + PREF_TTL) > time()) {
            return $data['db']; // 'pg' o 'mysql'
        }
    }
    return null;
}

function setPreferredDB($db)
{
    file_put_contents(PREF_FILE, json_encode(['db' => $db, 'time' => time()]));
}

// Conexión con failover: intenta primero el motor preferido (el último que respondió,
// o el definido en db_primary) y, si falla, el otro.
$container->set('data_base', function (ContainerInterface $c) {
    $conf = $c->get('config_bd');

    $opc = [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_OBJ,
        PDO::ATTR_TIMEOUT => 2
    ];

    $engines = [
        'pg' => fn() => new PDO(
            "pgsql:host=$conf->hostPG;port=$conf->portPG;dbname=$conf->db;connect_timeout=2",
            $conf->usrPG, $conf->passPG, $opc
        ),
        'mysql' => fn() => new PDO(
            "mysql:host=$conf->hostMYSQL;port=$conf->portMYSQL;dbname=$conf->db;charset=utf8mb4",
            $conf->usrMYSQL, $conf->passMYSQL, $opc
        ),
    ];

    $first = getPreferredDB() ?? $conf->primary;
    $order = $first === 'pg' ? ['pg', 'mysql'] : ['mysql', 'pg'];

    $errors = [];
    foreach ($order as $engine) {
        try {
            $con = $engines[$engine]();
            setPreferredDB($engine);
            return $con;
        } catch (PDOException $e) {
            $errors[] = "$engine: " . $e->getMessage();
        }
    }

    error_log('Sin conexión a base de datos -> ' . implode(' | ', $errors));
    throw new DatabaseUnavailableException(implode(' | ', $errors));
});
