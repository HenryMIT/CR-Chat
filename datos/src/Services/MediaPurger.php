<?php

namespace App\Services;

use App\Support\Log;

/**
 * Job de huérfanos de media (M-09): objetos `pendiente` con más de 24 h y todos los `borrado`.
 * Primero borra el objeto en MinIO y después la fila con fn_purgar_media, que revalida la
 * condición (una media pudo confirmarse mientras tanto). Lo ejecuta cada hora el worker `tareas`
 * de datos/ws/server.php, o a mano con `php bin/purgar-media.php`.
 */
class MediaPurger
{
    public function __construct(private readonly Db $db, private readonly ObjectStorage $storage)
    {
    }

    /** @return array{candidatos:int, borrados_storage:int, filas_purgadas:int} */
    public function run(string $age = '24 hours', int $batch = 100): array
    {
        $total = ['candidatos' => 0, 'borrados_storage' => 0, 'filas_purgadas' => 0];
        for ($i = 0; $i < 50; $i++) {
            $rows = $this->db->call('fn_listar_media_huerfana', ['p_antiguedad' => $age, 'p_limite' => $batch]);
            if (!$rows) {
                break;
            }
            $ids = [];
            foreach ($rows as $row) {
                if ($this->storage->delete($row['bucket'], $row['clave_objeto'])) {
                    $ids[] = $row['id'];
                }
            }
            $total['candidatos'] += count($rows);
            $total['borrados_storage'] += count($ids);
            if (!$ids) {
                break; // MinIO no responde: se reintenta en la próxima ejecución
            }
            $total['filas_purgadas'] += (int) $this->db->value('fn_purgar_media', ['p_ids' => $ids, 'p_antiguedad' => $age]);
            if (count($rows) < $batch) {
                break;
            }
        }
        Log::info('media_purge', $total);
        return $total;
    }
}
